package org.vraeroscan.viture;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.widget.Toast;

/**
 * The "VRAeroScan (glasses)" launcher icon: start the app on the glasses' display.
 *
 * Launched from the phone's launcher the app opens on the phone's own screen, which the
 * glasses then only mirror, and the control panel (which needs the phone screen to itself)
 * never opens. The glasses are a separate Android display; this finds it and starts the
 * app there, the same as `am start --display <id>`, so the panel opens on the phone.
 *
 * Runs in its own process (see the manifest) so that it can stop the app's own process
 * first: an app already open on the phone's screen would otherwise have to share one
 * Godot instance between two displays.
 */
public class LaunchOnGlassesActivity extends Activity {
    private static final String GODOT_LAUNCHER = "com.godot.game.GodotAppLauncher";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Display glasses = findGlasses();
        if (glasses == null) {
            Toast.makeText(this, "Glasses not found: plug them into the phone, in 3D mode.",
                    Toast.LENGTH_LONG).show();
            finish();
            return;
        }

        // Stop a running copy (it would be on the phone's screen), then start on the glasses.
        ((ActivityManager) getSystemService(Context.ACTIVITY_SERVICE)).killBackgroundProcesses(getPackageName());
        final int displayId = glasses.getDisplayId();
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
