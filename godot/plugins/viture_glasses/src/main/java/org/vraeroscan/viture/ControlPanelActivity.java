package org.vraeroscan.viture;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
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

    /** Commands for the app, oldest first: "north", "star", "shadow", "sky:<deg>", "tap", "drag:<fraction of pad width>:<fingers>", "drag_end". */
    static final ConcurrentLinkedQueue<String> COMMANDS = new ConcurrentLinkedQueue<>();
    /** Status line from the app. */
    static volatile String status = "starting…";
    /** What is switched on, "key=value;…": view=surface|centre|altitude, alt=<km>, sat=<mask>, air=<mask>. */
    static volatile String state = "";

    /**
     * Group names and their bits in the app's masks, in the order the app numbers them: the
     * command "sat:2" flips the third. Mirrors AppBootstrap.SATELLITE_KINDS and AIRCRAFT_GROUPS.
     */
    private static final String[] SAT_NAMES = {"Manned", "Starlink", "LEO", "MEO / HEO", "GEO"};
    private static final int[] SAT_BITS = {1, 2, 4, 8, 16};
    private static final String[] AIR_NAMES = {"Commercial", "Private", "Military", "Helicopters", "Other"};
    private static final int[] AIR_BITS = {1 << 0, 1 << 1, 1 << 2, 1 << 6, 1 << 20};
    /** Top of the altitude slider: geostationary orbit, km. The slider is a cube, fine near the ground. */
    private static final double GEO_KM = 35786.0;
    private static final int SLIDER_MAX = 1000;
    private static final long SLIDER_SEND_MS = 150;

    /** Finger travel, in pixels, before a touch counts as a drag rather than a tap. */
    private static final float DRAG_THRESHOLD_PX = 24f;
    /** Lines the status always takes, so the buttons below it never move (used by feel). */
    private static final int STATUS_LINES = 7;
    /** Button colours: what is on is lit, the rest is the default grey. */
    private static final int ON_COLOR = Color.rgb(40, 112, 150);
    private static final int OFF_COLOR = Color.rgb(70, 74, 82);
    private static final String[] LABEL_SIZES = {"small", "medium", "large"};
    private static final long STATUS_REFRESH_MS = 250;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView statusView;
    private final Button[] satButtons = new Button[SAT_NAMES.length];
    private final Button[] airButtons = new Button[AIR_NAMES.length];
    private Button surfaceButton, centreButton, starButton, shadowButton, identifyButton;
    private static final String SHADOW_LABEL = "Sight your shadow (sunny day)";
    private static final String IDENTIFY_OFF = "◎  Identify: off — tap to aim a circle";
    private static final String IDENTIFY_ON = "◎  Identify: on — tap to turn off";
    /** Height of the drag/tap pad at the bottom of every tab. */
    private static final int PAD_DP = 150;
    private final Button[] tabButtons = new Button[3];
    private final Button[] labelButtons = new Button[LABEL_SIZES.length];
    private static final String STAR_LABEL = "Sight the pole star (clear sky)";
    private SeekBar altitudeBar;
    private TextView altitudeView;
    private boolean sliderTouched;
    private long lastSliderSend;

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
        statusView.setLines(STATUS_LINES);
        statusView.setEllipsize(TextUtils.TruncateAt.END);
        root.addView(statusView);

        // Identify is used while looking around, not set once: on every tab, above them.
        identifyButton = button(IDENTIFY_OFF, "identify");
        identifyButton.setTextSize(19);
        root.addView(identifyButton, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

        LinearLayout tabs = new LinearLayout(this);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        root.addView(tabs, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));

        // One page at a time under the tabs: North (set it), Show (what is drawn, how big),
        // View (where from). The pad is under all three.
        LinearLayout northPage = page();
        LinearLayout showPage = page();
        LinearLayout viewPage = page();
        LinearLayout[] pages = {northPage, showPage, viewPage};
        String[] tabNames = {"North", "Show", "View"};
        for (int i = 0; i < pages.length; i++) {
            final int shown = i;
            Button tab = new Button(this);
            tab.setText(tabNames[i]);
            tab.setAllCaps(false);
            tab.setTextSize(17);
            tab.setOnClickListener(v -> {
                for (int j = 0; j < pages.length; j++) {
                    pages[j].setVisibility(j == shown ? View.VISIBLE : View.GONE);
                    mark(tabButtons[j], j == shown);
                }
            });
            tabButtons[i] = tab;
            mark(tab, i == 0);
            tabs.addView(tab, weight());
            root.addView(pages[i], new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
            pages[i].setVisibility(i == 0 ? View.VISIBLE : View.GONE);
        }

        buildShowPage(showPage);
        buildViewPage(viewPage);

        Button north = button("I'm facing north", "north");
        north.setTextSize(20);
        northPage.addView(north, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(84)));

        // Optional: put the pole star in the glasses' circle and tap. Needs a clear sky.
        starButton = button(STAR_LABEL, "star");
        northPage.addView(starButton,
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

        // Optional, by day: look along a shadow, which points directly away from the Sun.
        shadowButton = button(SHADOW_LABEL, "shadow");
        northPage.addView(shadowButton,
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

        LinearLayout nudges = new LinearLayout(this);
        nudges.setOrientation(LinearLayout.HORIZONTAL);
        // Sky moves the way the arrow points, like dragging the pad.
        nudges.addView(button("← 1°", "sky:-1"), weight());
        nudges.addView(button("← 0.1°", "sky:-0.1"), weight());
        nudges.addView(button("0.1° →", "sky:0.1"), weight());
        nudges.addView(button("1° →", "sky:1"), weight());
        northPage.addView(nudges, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(72)));

        TextView padView = new TextView(this);
        padView.setText("Tap: glasses menu / select\nDrag ← →: turn the sky (two fingers: fine)");
        padView.setTextColor(Color.rgb(120, 140, 160));
        padView.setTextSize(16);
        padView.setGravity(Gravity.CENTER);
        padView.setBackgroundColor(Color.rgb(24, 28, 36));
        padView.setOnTouchListener(new PadListener());
        // On every tab: the glasses menu is a tap away whatever page is showing.
        LinearLayout.LayoutParams padParams =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(PAD_DP));
        padParams.topMargin = dp(12);
        root.addView(padView, padParams);

        setContentView(root);

        // The app may have been started on the glasses without location permission (from a
        // computer, say): its own prompt would be on the glasses, so ask here.
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {
                    android.Manifest.permission.ACCESS_FINE_LOCATION,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION }, 7303);
        }
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

    private LinearLayout page() {
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        return page;
    }

    private TextView heading(String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextColor(Color.rgb(180, 220, 255));
        t.setTextSize(16);
        t.setPadding(0, dp(10), 0, dp(4));
        return t;
    }

    /** What is drawn: a toggle per satellite kind and aircraft group, and the label size. */
    private void buildShowPage(LinearLayout page) {
        LinearLayout inner = page();
        ScrollView scroll = new ScrollView(this);
        scroll.addView(inner);
        page.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        inner.addView(heading("Satellites"));
        for (int i = 0; i < SAT_NAMES.length; i++) {
            satButtons[i] = button(SAT_NAMES[i], "sat:" + i);
            inner.addView(satButtons[i], new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));
        }
        inner.addView(allNone("sat"));

        inner.addView(heading("Aircraft"));
        for (int i = 0; i < AIR_NAMES.length; i++) {
            airButtons[i] = button(AIR_NAMES[i], "air:" + i);
            inner.addView(airButtons[i], new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));
        }
        inner.addView(allNone("air"));

        inner.addView(heading("Label size"));
        LinearLayout sizes = new LinearLayout(this);
        sizes.setOrientation(LinearLayout.HORIZONTAL);
        for (int i = 0; i < LABEL_SIZES.length; i++) {
            String name = LABEL_SIZES[i];
            labelButtons[i] = button(Character.toUpperCase(name.charAt(0)) + name.substring(1), "labels:" + name);
            sizes.addView(labelButtons[i], weight());
        }
        inner.addView(sizes, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));
    }

    private LinearLayout allNone(String prefix) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(button("All on", prefix + ":all"), weight());
        row.addView(button("All off", prefix + ":none"), weight());
        row.setLayoutParams(new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));
        return row;
    }

    /** Where to view the sky from: the ground, the Earth's centre, or any height up to GEO. */
    private void buildViewPage(LinearLayout page) {
        page.addView(heading("View the sky from"));
        LinearLayout modes = new LinearLayout(this);
        modes.setOrientation(LinearLayout.HORIZONTAL);
        surfaceButton = button("Surface", "view:surface");
        centreButton = button("Earth centre", "view:centre");
        modes.addView(surfaceButton, weight());
        modes.addView(centreButton, weight());
        page.addView(modes, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

        altitudeView = new TextView(this);
        altitudeView.setTextColor(Color.rgb(180, 220, 255));
        altitudeView.setTextSize(18);
        altitudeView.setTypeface(Typeface.MONOSPACE);
        altitudeView.setPadding(0, dp(16), 0, dp(4));
        page.addView(altitudeView);

        altitudeBar = new SeekBar(this);
        altitudeBar.setMax(SLIDER_MAX);
        altitudeBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser) return;
                altitudeView.setText(altitudeText(sliderToKm(progress)));
                bar.setAlpha(1f);
                long now = System.currentTimeMillis();
                if (now - lastSliderSend >= SLIDER_SEND_MS) {
                    lastSliderSend = now;
                    COMMANDS.add(String.format(Locale.US, "view:%.0f", sliderToKm(progress)));
                }
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) {
                sliderTouched = true;
            }

            @Override
            public void onStopTrackingTouch(SeekBar bar) {
                sliderTouched = false;
                COMMANDS.add(String.format(Locale.US, "view:%.0f", sliderToKm(bar.getProgress())));
            }
        });
        page.addView(altitudeBar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));

        LinearLayout steps = new LinearLayout(this);
        steps.setOrientation(LinearLayout.HORIZONTAL);
        steps.addView(button("▼ Lower", "view:down"), weight());
        steps.addView(button("▲ Higher", "view:up"), weight());
        page.addView(steps, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

        page.addView(heading("Presets"));
        LinearLayout presets = new LinearLayout(this);
        presets.setOrientation(LinearLayout.HORIZONTAL);
        presets.addView(button("400 km", "view:400"), weight());
        presets.addView(button("20,200", "view:20200"), weight());
        presets.addView(button("GEO", "view:35786"), weight());
        page.addView(presets, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)));

    }

    /** Light a button that is on (a selected tab, a group shown, the current mode). */
    private static void mark(Button b, boolean on) {
        b.setBackgroundTintList(ColorStateList.valueOf(on ? ON_COLOR : OFF_COLOR));
        b.setTextColor(on ? Color.WHITE : Color.rgb(220, 224, 230));
    }

    private static double sliderToKm(int progress) {
        double f = progress / (double) SLIDER_MAX;
        return GEO_KM * f * f * f;
    }

    private static int kmToSlider(double km) {
        return (int) Math.round(SLIDER_MAX * Math.cbrt(Math.max(0.0, Math.min(km, GEO_KM)) / GEO_KM));
    }

    private static String altitudeText(double km) {
        return String.format(Locale.US, "%,.0f km up", km);
    }

    /** Show the app's state on the buttons: a check by what is on, and the slider where the altitude is. */
    private void applyState(String text) {
        Map<String, String> kv = new HashMap<>();
        for (String pair : text.split(";")) {
            int eq = pair.indexOf('=');
            if (eq > 0) kv.put(pair.substring(0, eq), pair.substring(eq + 1));
        }
        if (kv.isEmpty()) return;
        try {
            int sat = Integer.parseInt(kv.get("sat"));
            int air = Integer.parseInt(kv.get("air"));
            for (int i = 0; i < SAT_NAMES.length; i++) {
                boolean on = (sat & SAT_BITS[i]) != 0;
                satButtons[i].setText((on ? "☑  " : "☐  ") + SAT_NAMES[i]);
                mark(satButtons[i], on);
            }
            for (int i = 0; i < AIR_NAMES.length; i++) {
                boolean on = (air & AIR_BITS[i]) != 0;
                airButtons[i].setText((on ? "☑  " : "☐  ") + AIR_NAMES[i]);
                mark(airButtons[i], on);
            }
            boolean identifying = "1".equals(kv.get("identify"));
            identifyButton.setText(identifying ? IDENTIFY_ON : IDENTIFY_OFF);
            mark(identifyButton, identifying);
            // The star button is also its own cancel while a sighting is going.
            boolean sighting = "1".equals(kv.get("star"));
            starButton.setText(sighting ? "Cancel sighting" : STAR_LABEL);
            mark(starButton, sighting);
            boolean shadowing = "1".equals(kv.get("shadow"));
            shadowButton.setText(shadowing ? "Cancel sighting" : SHADOW_LABEL);
            mark(shadowButton, shadowing);
            String view = kv.get("view");
            double km = Double.parseDouble(kv.get("alt"));
            boolean altitude = "altitude".equals(view);
            mark(surfaceButton, "surface".equals(view));
            mark(centreButton, "centre".equals(view));
            for (int i = 0; i < LABEL_SIZES.length; i++) {
                mark(labelButtons[i], LABEL_SIZES[i].equals(kv.get("labels")));
            }
            if (!sliderTouched) {
                altitudeBar.setProgress(kmToSlider(km));
                // The slider keeps the last altitude; dimmed, it reads as "not in use".
                altitudeBar.setAlpha(altitude ? 1f : 0.4f);
                altitudeView.setText(altitude ? altitudeText(km)
                        : "centre".equals(view) ? "Earth's centre · drag for a height"
                        : "Ground · drag for a height");
            }
        } catch (RuntimeException e) {
            // A malformed state line: keep what is showing.
        }
    }

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            statusView.setText(status);
            applyState(state);
            handler.postDelayed(this, STATUS_REFRESH_MS);
        }
    };

    private Button button(String label, String command) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(17);
        b.setOnClickListener(v -> COMMANDS.add(command));
        mark(b, false);
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
