package org.vraeroscan.viture;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * The phone-screen half of VRAeroScan's controls, shown on the phone's own display while
 * the Godot app runs on the glasses.
 *
 * The phone is in your hand, not in view, so the panel is built to be used by feel: big
 * buttons, and most of the screen a pad. Drag the pad sideways to turn the sky until the
 * ghost N sits on true north (two fingers for fine), and tap it to open or select in the
 * menu floating in the glasses.
 *
 * Nothing here decides anything: every action is posted to {@link #COMMANDS} as text,
 * and the app polls the queue once a frame (VitureGlassesPlugin.takeCommands), so the
 * same commands work from this panel, the glasses menu and the keyboard. The app pushes
 * back a status line (heading, calibration) through {@link #status}.
 *
 * Keeps the phone's screen on while shown: the app is on the glasses, so without this
 * the phone times out, locks, and the app is paused with it.
 */
public class ControlPanelActivity extends Activity {

    /** Commands for the app, oldest first: "north", "sky:<deg>", "tap", "drag:<fraction of pad width>:<fingers>", "drag_end". */
    static final ConcurrentLinkedQueue<String> COMMANDS = new ConcurrentLinkedQueue<>();
    /** Status line from the app. */
    static volatile String status = "starting…";

    /** Finger travel, in pixels, before a touch counts as a drag rather than a tap. */
    private static final float DRAG_THRESHOLD_PX = 24f;
    private static final long STATUS_REFRESH_MS = 250;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView statusView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(12, 14, 18));
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);
        // Android 15+ draws apps edge to edge: keep clear of the status and navigation bars.
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            int l = 0, t = 0, r = 0, b = 0;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                l = bars.left; t = bars.top; r = bars.right; b = bars.bottom;
            } else {
                l = insets.getSystemWindowInsetLeft(); t = insets.getSystemWindowInsetTop();
                r = insets.getSystemWindowInsetRight(); b = insets.getSystemWindowInsetBottom();
            }
            v.setPadding(pad + l, pad + t, pad + r, pad + b);
            return insets;
        });

        statusView = new TextView(this);
        statusView.setTextColor(Color.rgb(180, 220, 255));
        statusView.setTextSize(15);
        statusView.setTypeface(Typeface.MONOSPACE);
        statusView.setPadding(0, 0, 0, dp(8));
        root.addView(statusView);

        Button north = button("I'm facing north", "north");
        north.setTextSize(20);
        root.addView(north, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(84)));

        LinearLayout nudges = new LinearLayout(this);
        nudges.setOrientation(LinearLayout.HORIZONTAL);
        // Sky moves the way the arrow points, like dragging the pad.
        nudges.addView(button("← 1°", "sky:-1"), weight());
        nudges.addView(button("← 0.1°", "sky:-0.1"), weight());
        nudges.addView(button("0.1° →", "sky:0.1"), weight());
        nudges.addView(button("1° →", "sky:1"), weight());
        root.addView(nudges, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(72)));

        TextView padView = new TextView(this);
        padView.setText("Drag ← → to turn the sky\n(two fingers: fine)\n\nTap: glasses menu / select");
        padView.setTextColor(Color.rgb(120, 140, 160));
        padView.setTextSize(18);
        padView.setGravity(Gravity.CENTER);
        padView.setBackgroundColor(Color.rgb(24, 28, 36));
        padView.setOnTouchListener(new PadListener());
        LinearLayout.LayoutParams padParams =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        padParams.topMargin = dp(12);
        root.addView(padView, padParams);

        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(refresh);
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(refresh);
    }

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            statusView.setText(status);
            handler.postDelayed(this, STATUS_REFRESH_MS);
        }
    };

    private Button button(String label, String command) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(17);
        b.setOnClickListener(v -> COMMANDS.add(command));
        return b;
    }

    private LinearLayout.LayoutParams weight() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    /**
     * Tap versus drag. A drag reports each move as a fraction of the pad's width — the
     * app turns that into degrees, like its own touch control — with the finger count,
     * so two fingers mean fine adjustment. A touch that never travels past the threshold
     * is a tap.
     */
    private static final class PadListener implements View.OnTouchListener {
        private float downX, downY, lastX;
        private boolean dragging;

        @Override
        public boolean onTouch(View v, MotionEvent e) {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = lastX = e.getX();
                    downY = e.getY();
                    dragging = false;
                    return true;
                case MotionEvent.ACTION_MOVE: {
                    float x = e.getX();
                    if (!dragging && Math.hypot(x - downX, e.getY() - downY) > DRAG_THRESHOLD_PX) {
                        dragging = true;
                        lastX = x;  // start from here: the threshold travel is not a turn
                    }
                    if (dragging) {
                        float fraction = (x - lastX) / Math.max(1, v.getWidth());
                        lastX = x;
                        if (fraction != 0f) {
                            COMMANDS.add(String.format(Locale.US, "drag:%.5f:%d", fraction, e.getPointerCount()));
                        }
                    }
                    return true;
                }
                case MotionEvent.ACTION_POINTER_DOWN:
                case MotionEvent.ACTION_POINTER_UP:
                    // The primary finger's x stays the reference; re-anchor so adding or
                    // lifting a second finger does not jump the sky.
                    lastX = e.getX();
                    return true;
                case MotionEvent.ACTION_UP:
                    COMMANDS.add(dragging ? "drag_end" : "tap");
                    dragging = false;
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    if (dragging) COMMANDS.add("drag_end");
                    dragging = false;
                    return true;
            }
            return false;
        }
    }
}
