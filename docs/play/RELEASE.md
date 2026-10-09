# Publishing on Google Play

## Build (repeatable)
1. `godot/plugins/viture_glasses/build.sh ../../VRAeroScan` (needs `vendor/viture/lib`, JDK 17)
2. `tools/release/build_play_aab.sh` → `godot/VRAeroScan/vraeroscan.aab`, signed with the
   upload key in `~/.config/vraeroscan/` (`signing.env` + `upload.keystore`).
   **Back up that folder somewhere safe.** If it is lost you can still ask Play to reset the
   upload key, but it takes days.
3. Bump `version/code` (must rise every upload) and `version/name` in the "Android Play" preset.

## Ads
`godot/plugins/viture_glasses/src/main/res/values/ads.xml` holds Google's *test* ids. Replace
`admob_app_id` and `admob_banner_id` with yours, rebuild the plugin (step 1), then the AAB.
Never click your own live ads: AdMob can ban the account. Use test ids while developing.

## One-time account setup
1. **Play Console**: https://play.google.com/console — $25 fee, identity verification. Register as
   an **Organization** (needs the company's D-U-N-S number; name and address must match it exactly).
   Organization accounts are not subject to the personal-account rule of a closed test with 12
   testers for 14 days, so you can go straight to production (confirm the current rule in the Console).
2. **AdMob**: https://admob.google.com — same Google account. Add app (Android), create a
   *Banner* ad unit, add payment/tax details. The app can be added before it is published and
   linked after.
3. **Privacy policy URL**: publish `privacy-policy.md` at a public URL (GitHub Pages, or its
   GitHub page) and paste it into the Console.

## Create the app
Console > Create app: name, English, App, **Free**, accept declarations. Then:

| Section | Answer |
|---|---|
| Store listing | text from `store-listing.md`, `graphics/`, ≥2 phone screenshots |
| Privacy policy | URL above |
| Ads | **Yes, contains ads** |
| App access | all functionality available without login |
| Content rating | questionnaire: utility app, no violence/gambling/user content → expect Everyone |
| Target audience | 13+ / 18+ (not "children": ads) |
| Data safety | see below |
| Government/news/health/finance | no |

### Data safety
- Data collected **Location → Precise location**: collected, shared (adsb.lol receives it),
  not optional processing for core function, purpose *App functionality*; not retained by us.
- **Device or other IDs → Advertising ID**: collected and shared for *Advertising*.
- Also from AdMob: IP address / app interactions / diagnostics — follow Google's table
  "Declare data for AdMob": https://support.google.com/admob/answer/9755941 (check it is current).
- Data encrypted in transit: yes (HTTPS). Users can request deletion: no data held by us.
- Advertising ID declaration (Policy > App content): yes, used for advertising.

## Upload and test
1. Testing > **Internal testing** (or Closed testing) > create a release > upload `vraeroscan.aab` >
   add your own Google account as a tester > install from the opt-in link on a real phone and check it.
   Accept **Play App Signing** when asked.
2. When the dashboard tasks are complete: Production > Create new release > upload the bundle >
   submit for review.
3. Updates: raise `version/code`, rebuild, upload to the track, roll out.

## Risks to keep in mind
- **Accidental clicks.** AdMob invalid-traffic rules: the ad sits 24 dp below the touch pad with a
  reserved gap. Check on a real phone before release that nothing near it is tapped by mistake.
- **adsb.lol terms**: confirm commercial/ad-supported use is allowed, or ask them.
- **Viture libraries** ship in binary form (permitted); never put them or their source in git.
