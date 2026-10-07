# VRAeroScan privacy policy

*Last updated: 2026-10-06*

VRAeroScan is an Android app that shows aircraft and satellites in the sky on AR glasses.
It has no accounts and no server of its own. This page says what leaves your phone.

## What the app uses

**Your location.** The app reads your phone's precise location (GPS) to work out where
aircraft and satellites are relative to you. It is used while the app is open and is not
stored by the app. To list aircraft near you, the app sends your position
(latitude and longitude, to about a metre) to **adsb.lol** (api.adsb.lol), a public flight-data
service, and receives the aircraft around that point. adsb.lol sees your IP address and
that position as any web service would; see its own policy for what it keeps.

**Satellite data.** The app downloads public satellite orbit data from **CelesTrak**
(celestrak.org). That request carries no location, only your IP address, as any download does.

**Glasses and motion.** Head orientation comes from the connected glasses over USB. It stays on
the device.

**Settings.** Your choices (which groups are shown, label sizes) are saved on the phone only.

## Advertising

The phone's control panel shows a banner ad, supplied by **Google AdMob**. Ads never appear on
the glasses display. Google's ads software may collect and use your device's advertising ID,
IP address, and information about how the app and ads are used, to deliver and measure ads and
prevent fraud. Where the law requires it (for example in the EU, EEA and UK) the app first
asks for your consent, and you can change that choice in your Google settings.
How Google handles this: https://policies.google.com/technologies/partner-sites .
You can reset or delete your advertising ID in Android settings (Settings > Privacy > Ads).

## What the app does not do

It has no accounts, does not sell your data, does not use analytics of its own, and does not
read your contacts, photos, microphone or camera.

## Children

The app is not directed at children under 13.

## Changes and contact

If this policy changes, the date above changes. Questions: open an issue at
https://github.com/parheliatech/VRAeroScan/issues .
