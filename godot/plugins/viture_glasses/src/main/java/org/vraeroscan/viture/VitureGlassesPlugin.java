package org.vraeroscan.viture;

import android.Manifest;
import android.app.Activity;
import android.app.ActivityOptions;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Display;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

import viture.glasses.jni.GlassesBridge;

/**
 * Godot singleton "VitureGlasses": connects to the Viture glasses over USB and exposes
 * their head pose to GDScript. Also provides the phone's position, since Godot has no
 * location API on Android and this is already the app's one Android plugin.
 *
 * GDScript polls {@link #getPose()} once per frame rather than receiving a signal per IMU
 * sample: the IMU runs far faster than the frame rate and on its own native thread, and a
 * poll of the latest sample is both cheaper and free of cross-thread queueing lag.
 *
 * The pose array is passed through as the SDK gives it. Its layout was established on
 * hardware on 2026-09-23 and is documented, and converted, in VitureHeadTracker.gd.
 */
public class VitureGlassesPlugin extends GodotPlugin {
    private static final String TAG = "VitureGlasses";

    private static final int VITURE_VENDOR_ID = 0x35CA;
    private static final String ACTION_USB_PERMISSION = "org.vraeroscan.viture.USB_PERMISSION";

    private static final int IMU_MODE_POSE = 1;
    /** SpaceWalker's default. The meaning of the value is not documented. */
    private static final int IMU_FREQUENCY = 3;
    /** SpaceWalker waits after start() before opening the IMU; 500 ms is a safe margin. */
    private static final long IMU_OPEN_DELAY_MS = 500;

    private static final int LOCATION_PERMISSION_REQUEST = 7301;
    private static final long LOCATION_INTERVAL_MS = 2000;

    private static final SignalInfo STATUS_CHANGED = new SignalInfo("status_changed", String.class);
    private static final SignalInfo GLASSES_STATE_CHANGED =
            new SignalInfo("glasses_state_changed", Integer.class, Integer.class);

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Object lock = new Object();

    private UsbDeviceConnection connection;
    private BroadcastReceiver permissionReceiver;
    private boolean initialized;
    private int deviceType = -1;
    private String status = "idle";

    private LocationManager locationManager;
    private LocationListener locationListener;
    private volatile Location latestFix;
    private String locationStatus = "not started";

    // Written on the SDK's native thread, read on Godot's.
    private volatile float[] latestPose = new float[0];
    private volatile long latestPoseTimestamp;
    private volatile long poseCount;

    public VitureGlassesPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "VitureGlasses";
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(STATUS_CHANGED);
        signals.add(GLASSES_STATE_CHANGED);
        return signals;
    }

    // --- GDScript API --------------------------------------------------------------------

    /** Find the glasses, ask for USB permission if needed, and start the head pose stream. */
    @UsedByGodot
    public void startGlasses() {
        runOnUiThread(this::connectOnUiThread);
    }

    @UsedByGodot
    public void stopGlasses() {
        release("stopped");
    }

    /** Latest head pose sample, the SDK's array as-is. Empty until the first sample. */
    @UsedByGodot
    public float[] getPose() {
        return latestPose;
    }

    /** SDK timestamp of the latest pose sample. */
    @UsedByGodot
    public long getPoseTimestamp() {
        return latestPoseTimestamp;
    }

    /** Samples received since start — shows the stream is alive and at what rate. */
    @UsedByGodot
    public long getPoseCount() {
        return poseCount;
    }

    @UsedByGodot
    public String getStatus() {
        return status;
    }

    /** 0 = GEN1, 1 = GEN2, 2 = Carina; -1 before initialisation. */
    @UsedByGodot
    public int getDeviceType() {
        return deviceType;
    }

    @UsedByGodot
    public int getDisplayMode() {
        synchronized (lock) {
            return initialized ? GlassesBridge.nativeGetDisplayMode() : -1;
        }
    }

    @UsedByGodot
    public int setDisplayMode(int mode) {
        synchronized (lock) {
            return initialized ? GlassesBridge.nativeSetDisplayMode(mode) : -1;
        }
    }

    /**
     * Android display id of the glasses, or -1. The glasses are an external display named
     * "VITURE"; a 2D/3D switch replaces it with a new id, so ask again after one.
     */
    @UsedByGodot
    public int getGlassesDisplayId() {
        DisplayManager dm = (DisplayManager) getContext().getSystemService(Context.DISPLAY_SERVICE);
        for (Display d : dm.getDisplays()) {
            if (d.getDisplayId() != Display.DEFAULT_DISPLAY && d.getName() != null
                    && d.getName().toUpperCase().contains("VITURE")) {
                return d.getDisplayId();
            }
        }
        return -1;
    }

    /** Display id this activity is currently shown on. */
    @UsedByGodot
    public int getCurrentDisplayId() {
        Activity activity = getActivity();
        return activity != null && activity.getDisplay() != null ? activity.getDisplay().getDisplayId() : -1;
    }

    // --- Phone control panel ---------------------------------------------------------------

    /**
     * Open the control panel (ControlPanelActivity) on the phone's own screen, for when
     * the app itself is on the glasses. Android 10+ keeps an activity on each display
     * resumed at once, so the app keeps rendering while the panel is used.
     */
    @UsedByGodot
    public void showControlPanel() {
        runOnUiThread(() -> {
            Activity activity = getActivity();
            if (activity == null) return;
            Intent intent = new Intent(activity, ControlPanelActivity.class);
            // Its own task (see the manifest's taskAffinity), reused if already open: an
            // app restart — a 2D/3D replug of the glasses — must not stack a second panel.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            ActivityOptions options = ActivityOptions.makeBasic();
            options.setLaunchDisplayId(Display.DEFAULT_DISPLAY);
            try {
                activity.startActivity(intent, options.toBundle());
            } catch (RuntimeException e) {
                Log.w(TAG, "Could not open the control panel", e);
            }
        });
    }

    /** Commands posted by the control panel since the last call, oldest first. */
    @UsedByGodot
    public String[] takeCommands() {
        java.util.ArrayList<String> out = new java.util.ArrayList<>();
        String c;
        while ((c = ControlPanelActivity.COMMANDS.poll()) != null) out.add(c);
        return out.toArray(new String[0]);
    }

    /** The status line the control panel shows. */
    @UsedByGodot
    public void setPanelStatus(String text) {
        ControlPanelActivity.status = text;
    }

    // --- Location --------------------------------------------------------------------------

    /** Start GPS + network location updates, asking for permission first if needed. */
    @UsedByGodot
    public void startLocation() {
        runOnUiThread(() -> {
            Activity activity = getActivity();
            if (activity == null) return;
            if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED) {
                startLocationUpdates();
            } else {
                // Note: this dialog appears on whichever display the activity is on. On the
                // glasses nobody can tap it; grant with `adb shell pm grant` until the phone
                // UI asks for it instead.
                locationStatus = "waiting for location permission";
                activity.requestPermissions(new String[] {
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION }, LOCATION_PERMISSION_REQUEST);
            }
        });
    }

    /**
     * Latest fix as [latitude, longitude, altitude m, horizontal accuracy m, age s], or an
     * empty array before the first fix.
     *
     * Altitude is above mean sea level where Android can provide it (API 34+), which
     * matches the barometric altitudes aircraft report; otherwise it is WGS84 ellipsoidal,
     * which differs by the local geoid height (about -30 m in Arizona) — negligible for
     * pointing at aircraft kilometres away.
     */
    @UsedByGodot
    public double[] getLocation() {
        Location l = latestFix;
        if (l == null) return new double[0];
        double altitude = l.getAltitude();
        if (Build.VERSION.SDK_INT >= 34 && l.hasMslAltitude()) {
            altitude = l.getMslAltitudeMeters();
        }
        double ageS = (SystemClock.elapsedRealtimeNanos() - l.getElapsedRealtimeNanos()) / 1e9;
        return new double[] { l.getLatitude(), l.getLongitude(), altitude, l.getAccuracy(), ageS };
    }

    @UsedByGodot
    public String getLocationStatus() {
        return locationStatus;
    }

    @Override
    public void onMainRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != LOCATION_PERMISSION_REQUEST) return;
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        if (granted) {
            startLocationUpdates();
        } else {
            locationStatus = "location permission denied";
        }
    }

    @SuppressWarnings("MissingPermission") // checked by every caller
    private void startLocationUpdates() {
        if (locationListener != null) return;
        locationManager = (LocationManager) getContext().getSystemService(Context.LOCATION_SERVICE);
        locationListener = this::offerFix;

        int providers = 0;
        for (String provider : new String[] { LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER }) {
            if (!locationManager.isProviderEnabled(provider)) continue;
            Location last = locationManager.getLastKnownLocation(provider);
            if (last != null) offerFix(last);
            locationManager.requestLocationUpdates(provider, LOCATION_INTERVAL_MS, 0f,
                    locationListener, Looper.getMainLooper());
            providers++;
        }
        locationStatus = providers > 0 ? "listening" : "location services off";
        Log.i(TAG, "location: " + locationStatus + " (" + providers + " providers)");
    }

    /**
     * Keep a new fix if it is newer and not much worse, or more accurate. GPS and network
     * fixes interleave, and a fresh 1 km network fix must not replace a 5 m GPS fix taken
     * two seconds ago.
     */
    private void offerFix(Location candidate) {
        Location current = latestFix;
        boolean accept = current == null
                || candidate.getAccuracy() <= current.getAccuracy()
                || (candidate.getElapsedRealtimeNanos() - current.getElapsedRealtimeNanos() > 30_000_000_000L);
        if (!accept) return;
        if (current == null) {
            Log.i(TAG, "first location fix: " + candidate.getProvider() + " ±" + candidate.getAccuracy() + "m");
        }
        latestFix = candidate;
        locationStatus = candidate.getProvider() + " ±" + Math.round(candidate.getAccuracy()) + "m";
    }

    // --- Connection ----------------------------------------------------------------------

    private void connectOnUiThread() {
        Context context = getContext();
        UsbManager usb = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        UsbDevice device = findGlasses(usb);
        if (device == null) {
            setStatus("no glasses on USB");
            return;
        }

        if (usb.hasPermission(device)) {
            open(usb, device);
            return;
        }

        setStatus("waiting for USB permission");
        registerPermissionReceiver(context);
        // Explicit (package-scoped) and mutable: UsbManager adds extras to the intent, and
        // Android 14+ rejects mutable implicit PendingIntents.
        Intent intent = new Intent(ACTION_USB_PERMISSION).setPackage(context.getPackageName());
        int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? PendingIntent.FLAG_MUTABLE : 0;
        usb.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags));
    }

    private UsbDevice findGlasses(UsbManager usb) {
        for (UsbDevice d : usb.getDeviceList().values()) {
            if (d.getVendorId() == VITURE_VENDOR_ID) {
                Log.i(TAG, "found " + d.getProductName() + " pid=0x" + Integer.toHexString(d.getProductId()));
                return d;
            }
        }
        return null;
    }

    private void registerPermissionReceiver(Context context) {
        if (permissionReceiver != null) return;
        permissionReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                if (!ACTION_USB_PERMISSION.equals(intent.getAction())) return;
                UsbDevice device = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
                if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && device != null) {
                    open((UsbManager) c.getSystemService(Context.USB_SERVICE), device);
                } else {
                    setStatus("USB permission denied");
                }
            }
        };
        IntentFilter filter = new IntentFilter(ACTION_USB_PERMISSION);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            context.registerReceiver(permissionReceiver, filter);
        }
    }

    private void open(UsbManager usb, UsbDevice device) {
        synchronized (lock) {
            if (initialized) return;

            connection = usb.openDevice(device);
            if (connection == null) {
                setStatus("could not open USB device");
                return;
            }

            int fd = connection.getFileDescriptor();
            boolean ok;
            try {
                ok = GlassesBridge.nativeXRDeviceInitialize(fd, null, device.getProductId());
            } catch (Throwable t) {
                Log.e(TAG, "initialize threw", t);
                setStatus("initialize threw: " + t);
                return;
            }
            if (!ok) {
                setStatus("SDK initialize failed");
                return;
            }

            initialized = true;
            deviceType = GlassesBridge.nativeGetDeviceType();
            Log.i(TAG, "initialized: fd=" + fd + " deviceType=" + deviceType
                    + " version=" + GlassesBridge.nativeGetGlassesVersion());

            GlassesBridge.nativeRegisterViturePoseCallback(new PoseCallback());
            GlassesBridge.nativeRegisterStateCallback(new StateCallback());
            GlassesBridge.nativeXRDeviceStart();
            setStatus("started, opening IMU");
        }

        mainHandler.postDelayed(this::openImu, IMU_OPEN_DELAY_MS);
    }

    private void openImu() {
        synchronized (lock) {
            if (!initialized) return;
            int result = GlassesBridge.nativeOpenImu(IMU_MODE_POSE, IMU_FREQUENCY);
            setStatus(result == 0 ? "streaming" : "openImu failed: " + result);
        }
    }

    private void release(String reason) {
        synchronized (lock) {
            if (initialized) {
                try {
                    GlassesBridge.nativeCloseImu(IMU_MODE_POSE);
                    GlassesBridge.nativeUnregisterViturePoseCallback();
                    GlassesBridge.nativeUnregisterStateCallback();
                    GlassesBridge.nativeXRDeviceStop();
                    GlassesBridge.nativeXRDeviceRelease();
                } catch (Throwable t) {
                    Log.w(TAG, "release", t);
                }
                initialized = false;
            }
            if (connection != null) {
                connection.close();
                connection = null;
            }
        }
        setStatus(reason);
    }

    private void setStatus(String s) {
        status = s;
        Log.i(TAG, "status: " + s);
        emitSignal(STATUS_CHANGED.getName(), s);
    }

    @Override
    public void onMainDestroy() {
        release("destroyed");
        if (locationManager != null && locationListener != null) {
            locationManager.removeUpdates(locationListener);
            locationListener = null;
        }
        if (permissionReceiver != null) {
            try {
                getContext().unregisterReceiver(permissionReceiver);
            } catch (IllegalArgumentException ignored) {
                // Already unregistered.
            }
            permissionReceiver = null;
        }
    }

    // --- Native callbacks: invoked by name and signature from the SDK's thread ----------

    private final class PoseCallback {
        private boolean loggedLayout;

        @SuppressWarnings("unused") // called from native: onImuPoseData([FJ)V
        public void onImuPoseData(float[] data, long timestamp) {
            latestPose = data.clone();
            latestPoseTimestamp = timestamp;
            poseCount++;
            if (!loggedLayout) {
                loggedLayout = true;
                Log.i(TAG, "first pose sample: length=" + data.length + " " + Arrays.toString(data));
            }
        }
    }

    private final class StateCallback {
        @SuppressWarnings("unused") // called from native: onStateChange(II)V
        public void onStateChange(int id, int value) {
            Log.i(TAG, "glasses state " + id + " = " + value);
            emitSignal(GLASSES_STATE_CHANGED.getName(), id, value);
        }
    }
}
