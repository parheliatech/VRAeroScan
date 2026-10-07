package org.vraeroscan.viture;

import android.app.Activity;
import android.util.DisplayMetrics;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import com.google.android.gms.ads.AdRequest;
import com.google.android.gms.ads.AdSize;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.MobileAds;
import com.google.android.ump.ConsentInformation;
import com.google.android.ump.ConsentRequestParameters;
import com.google.android.ump.UserMessagingPlatform;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The one banner ad, along the bottom of the phone's control panel.
 *
 * Ads exist only here. The glasses display is the Godot app, which never loads the ads SDK,
 * so nothing can appear in front of the eyes. This class is used by ControlPanelActivity and
 * nothing else.
 *
 * Order matters: the user's consent choice (Google's UMP form, shown only where the law
 * asks for it) comes first, and the ads SDK is not started nor an ad requested until
 * UMP says ads may be requested.
 */
final class AdBanner {
    /** Space that stays reserved whether or not an ad has loaded, so the controls never jump. */
    private final FrameLayout slot;
    private final Activity activity;
    private final AtomicBoolean started = new AtomicBoolean(false);
    private AdView adView;

    AdBanner(Activity activity, FrameLayout slot) {
        this.activity = activity;
        this.slot = slot;
    }

    /** Ask for consent where required, then load the ad. Safe to call on every onCreate. */
    void start() {
        ConsentInformation consent = UserMessagingPlatform.getConsentInformation(activity);
        consent.requestConsentInfoUpdate(activity, new ConsentRequestParameters.Builder().build(),
                () -> UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity, formError -> {
                    if (consent.canRequestAds()) initAds();
                }),
                // Offline or a failed lookup: a previous choice may still allow ads.
                requestError -> {
                    if (consent.canRequestAds()) initAds();
                });
        // A choice made in an earlier session already allows ads: do not wait for the network.
        if (consent.canRequestAds()) initAds();
    }

    private void initAds() {
        if (!started.compareAndSet(false, true)) return;
        MobileAds.initialize(activity, status -> activity.runOnUiThread(this::loadBanner));
    }

    private void loadBanner() {
        if (activity.isFinishing() || activity.isDestroyed()) return;
        DisplayMetrics dm = activity.getResources().getDisplayMetrics();
        int widthDp = (int) (slot.getWidth() / dm.density);
        if (widthDp <= 0) widthDp = (int) (dm.widthPixels / dm.density);
        adView = new AdView(activity);
        adView.setAdUnitId(activity.getString(R.string.admob_banner_id));
        adView.setAdSize(AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(activity, widthDp));
        slot.addView(adView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                android.view.Gravity.CENTER));
        adView.loadAd(new AdRequest.Builder().build());
    }

    void pause() { if (adView != null) adView.pause(); }
    void resume() { if (adView != null) adView.resume(); }
    void destroy() {
        if (adView != null) {
            adView.destroy();
            adView = null;
        }
    }
}
