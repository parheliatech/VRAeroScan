package org.vraeroscan.viture;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.Manifest;
import android.content.pm.PackageManager;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.widget.Toast;

/**
 * The app's launcher icon: start the app on the glasses' display.
 *
 * Launched the ordinary way the app would open on the phone's own screen, which the glasses
 * then only mirror, and the control panel (which needs the phone screen to itself) never
 * opens. The glasses are a separate Android display; this finds it and starts the app there,
 * the same as `am start --display <id>`, so the panel opens on the phone. Godot's own
 * launcher entry is hidden (export preset), so this is the only icon.
 *
 * Without the glasses it starts the app on the phone's screen, so it can still be looked at.
 *
 * Runs in its own process (see the manifest) so that it can stop the app's own process
 * first: an app already open on the phone's screen would otherwise have to share one
 * Godot instance between two displays.
 *
 * It also asks for location permission first, here on the phone's screen. Asked by the
 * app itself, the prompt would appear on the glasses, where nobody can tap it, and the
 * app would run without a position.
 */
public class LaunchOnGlassesActivity extends Activity {
    private static final String GODOT_LAUNCHER = "com.godot.game.GodotAppLauncher";
    private static final int LOCATION_REQUEST = 7302;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION }, LOCATION_REQUEST);
            return;  // onRequestPermissionsResult carries on, granted or not
        }
        launch();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        if (requestCode != LOCATION_REQUEST) return;
        if (results.length == 0 || results[0] != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "No location: the sky will be drawn for a default position.",
                    Toast.LENGTH_LONG).show();
        }
        launch();
    }

    private void launch() {
        Display glasses = findGlasses();
        if (glasses == null) {
            Toast.makeText(this, "Glasses not found: starting on the phone. For the glasses, plug them "
                    + "in (3D mode) and open VRAeroScan again.", Toast.LENGTH_LONG).show();
        }

        // Stop a running copy (it may be on the other screen), then start where it belongs.
        ((ActivityManager) getSystemService(Context.ACTIVITY_SERVICE)).killBackgroundProcesses(getPackageName());
        final int displayId = glasses != null ? glasses.getDisplayId() : Display.DEFAULT_DISPLAY;
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            Intent intent = new Intent(Intent.ACTION_MAIN)
                    .setComponent(new ComponentName(getPackageName(), GODOT_LAUNCHER))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            ActivityOptions options = ActivityOptions.makeBasic();
            options.setLaunchDisplayId(displayId);
            try {
                startActivity(intent, options.toBundle());
            } catch (RuntimeException e) {
                Toast.makeText(this, "Could not start on the glasses: " + e.getMessage(),
                        Toast.LENGTH_LONG).show();
            }
            finish();
        }, 600);
    }

    /** The external display the glasses appear as: not the phone's own screen. */
    private Display findGlasses() {
        DisplayManager dm = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        Display fallback = null;
        for (Display d : dm.getDisplays()) {
            if (d.getDisplayId() == Display.DEFAULT_DISPLAY) continue;
            if (d.getName() != null && d.getName().toUpperCase().contains("VITURE")) return d;
            if (fallback == null) fallback = d;
        }
        return fallback;
    }
}
