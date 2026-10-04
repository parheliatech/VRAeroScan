# VRAeroScan — Project Notes

**An augmented-reality "finder" for what is above you.** Look up through AR glasses
and see the aircraft and satellites actually passing overhead, drawn where they really
are in the sky.

Status: **running on the phone and Viture glasses** — aircraft and 16,749 satellites with
icons, head tracking, stereo, calibration controls — with 3,500+ headless checks and
live-data checks passing. See §10 "Resume here".

> **This plan replaces the 2026-08-03 plan**, which targeted a Quest 3 tabletop
> terrain god-view in WebXR. That plan is archived at
> `docs/archive/PROJECT_NOTES-2026-08-03-quest3-webxr.md`. See §9 for what changed
> and why.

---

## 1. The idea

You are standing outside. You look up. Through the glasses you see labelled markers
sitting on the real sky, at the real bearing and elevation of every aircraft and
satellite above you — callsign, type, altitude for planes; name and pass info for
satellites. It is a *finder*: the point is to look up and know what that moving light
is, or where to look for the ISS thirty seconds before it clears the roofline.

This is **optical see-through AR, not VR and not video passthrough.** The Viture
glasses are transparent; the real sky is the background. The app draws only the
overlay. There is no terrain, no globe, no basemap, no 3D world to render — which is
precisely why the project got dramatically easier (§9).

---

## 2. Architecture

The Viture Pro XR has **no onboard computing**. An Android phone does everything;
the glasses are a stereo display plus an IMU on the end of a USB-C cable.

```
   ┌──────────────────────────── Android phone (all compute) ───────────────────┐
   │                                                                            │
   │   GPS ──────────────► observer lat/lon/alt                                 │
   │   Magnetometer ─────► absolute heading (true north), for calibration only  │
   │                                                                            │
   │   adsb.lol  ────────► aircraft lat/lon/alt ──┐                             │
   │   CelesTrak ────────► TLE/OMM ──► SGP4 ──────┤                             │
   │                                              ▼                             │
   │                                    look-angle math (§4)                    │
   │                                     az / el / range                        │
   │                                              │                             │
   │                                              ▼                             │
   │                          world-fixed sky markers in Godot                  │
   │                                              │                             │
   │   Godot stereo camera rig ◄── head orientation                             │
   │              │                                                             │
   └──────────────┼─────────────────────────────────────────────────────────────┘
                  │ USB-C: DisplayPort Alt Mode out, IMU in
                  ▼
        ┌─────────────────────────┐
        │   Viture Pro XR         │  3DoF IMU (yaw/pitch/roll)
        │   optical see-through   │  SBS 3840x1080 → 1920x1080/eye
        │   46° FOV               │  real sky visible through the lens
        └─────────────────────────┘
```

**The key rendering pattern:** markers live in a *world-fixed* frame (`SkyRig`) whose
+Z axis is true north and +Y is up. Markers never move with your head. The camera
rotates inside that frame, driven by the glasses' IMU. That is what makes a marker
stay glued to the real aircraft as you turn your head.

### Framework — Godot 4 (switched from Unity 2026-09-23)
**Godot 4.7, GDScript**, exporting Android (and later Linux/macOS). Switched from Unity
the same day, before Unity had ever opened the project, for three reasons:

1. **Licensing.** Godot is MIT: no account, no seat licence, no future terms change to
   worry about. This was Kendel's deciding reason.
2. **Testable here.** Godot runs headless on the dev box, so the code is compiled and
   tested on every change — the Unity C# had never seen a compiler.
3. **The Unity advantage was probably illusory.** Viture's Unity SDK appears aimed at
   the Neckband (risk 2); the phone-tethered path is likely their Android SDK, which
   Godot can wrap as an Android plugin just as Unity would via JNI.

**GDScript, not C#:** no .NET SDK needed, Godot's most mature Android export, and
GDScript floats are 64-bit, which the geodesy wants. Cost: the C# was ported, not reused.

**Known Godot gaps:** no built-in GPS on Android (needs a plugin — the same plugin can
wrap the Viture SDK), and no obvious API for a *separate* image on an external display
(the phone may simply mirror to the glasses; see risk 3). Neither is verified.

The hardware spike settled it: Godot drives the glasses natively. The Unity C# was
removed on 2026-09-24 (still in git history before that date), and Unity itself was
uninstalled from the dev machine.

## 3. Hardware

| Device | Role | Notes |
|---|---|---|
| **Viture Pro XR** | **Display + head IMU** | Optical see-through. 3DoF only. 46° FOV. No GPS, no compass, no compute, no cameras. |
| **Android phone** | **The entire computer** | Must support USB-C DisplayPort Alt Mode. Provides GPS + magnetometer. |
| Linux box | Dev machine | Godot 4.7.2 at `~/.local/bin/godot` (→ `~/.local/opt/godot/`); Android SDK at `~/Android/Sdk`; `adb` present. (Unity removed 2026-09-24.) |
| AeroScan Pi | *Not used in v1* | Kept as a future local-feed option, see §5. |

---

## 4. The two problems that actually matter

Everything else is plumbing. These two decide whether the app feels magic or broken.

### 4.1 Knowing where you are — solved
Phone GPS gives lat/lon/alt directly. Manual coordinate entry as a fallback and for
a fixed observing spot. This is genuinely easy and was the reason the Quest 3 was
abandoned (a Quest has no GPS at all).

### 4.2 Knowing which way is north — the real problem

The glasses' IMU reports yaw relative to *an arbitrary reference set at power-on*,
and it **drifts**. The phone's magnetometer knows true north but is not on your head.
Bridging those two is the crux of the app: if the heading is wrong by 10°, every
marker is wrong by 10° and the app is useless.

**Chosen approach — phone-referenced calibration:**
1. User holds the phone flat, pointed the same direction they are looking.
2. Taps *Calibrate*.
3. App captures phone magnetometer heading `H_true` and glasses yaw `Y_raw` at the
   same instant, stores `offset = H_true − Y_raw`.
4. Thereafter `trueHeading = normalize(glassesYaw + offset)`.

Plus, because the IMU will drift over minutes:
- A manual nudge control (±, a degree at a time) to walk a marker onto a known
  object — a landmark, or a plane you can see.
- Periodic re-sync prompt.

**Open refinement:** a celestial fix (point at the sun or a bright star, solve for
north from position + time) would be more accurate than a phone magnetometer, which
is easily 5–15° off near metal or electronics. Worth building as a second
calibration mode once the first one works.

### 4.3 Magnetic vs true north
Phone compasses report magnetic heading. Must apply magnetic declination for the
observer's location (WMM model, or a lookup) to get true north. Skipping this is a
silent 0–20° error depending on where you are. **Do not skip this.**

---

## 5. Data sources — both verified live on 2026-09-23

### Aircraft: adsb.lol
```
GET https://api.adsb.lol/v2/point/{lat}/{lon}/{radius_nm}
```
Free, no key, ODbL 1.0. Confirmed working. Response is `{"ac":[...], "now": <ms>}`,
each aircraft carrying:

| Field | Meaning |
|---|---|
| `hex` | ICAO 24-bit address — the stable unique id |
| `flight` | Callsign (space-padded) |
| `r` | Registration |
| `t` | ICAO type designator (`A321`, `C206`, …) |
| `category` | ADS-B emitter category (`A1`–`A7`, `B…`, `C…`) |
| `lat`, `lon` | Position |
| `alt_baro` | Barometric altitude in ft — **or the string `"ground"`** |
| `alt_geom` | Geometric altitude, ft |
| `gs`, `track` | Ground speed kt, track deg |
| `dst`, `dir` | Distance nm and bearing from the query point |

⚠️ `alt_baro` is **mixed-type** (number *or* `"ground"`). Check it with `typeof()`
(Godot's JSON hands back a Variant); in the Unity version this forced Newtonsoft.

⚠️ `dir` is a **spherical** great-circle bearing, rounded to 0.1°. The app's ellipsoidal
azimuth differs from it by up to ~0.13° — correctly. Compare great-circle to `dir`.

*Deferred:* the AeroScan Pi's own dump1090 feed as a local source. v1 uses the public
API only; a local feed is a later option, not a v1 requirement.

### Satellites: CelesTrak
```
GET https://celestrak.org/NORAD/elements/gp.php?GROUP={group}&FORMAT=json
```
Confirmed working. Returns OMM JSON (`MEAN_MOTION`, `ECCENTRICITY`, `INCLINATION`,
`RA_OF_ASC_NODE`, `ARG_OF_PERICENTER`, `MEAN_ANOMALY`, `BSTAR`, `EPOCH`,
`NORAD_CAT_ID`, `OBJECT_NAME`) — exactly the inputs SGP4 needs.

Useful groups: `stations` (ISS, CSS — 4 objects), `starlink` (**11,108 objects**),
`active`, `geo`, `visual`.

⚠️ 11k Starlink objects is a real load-and-propagate cost and a real clutter problem.
Filtering (§6) is not a nice-to-have, it is load-bearing.

TLEs change slowly — fetch and cache, refresh every few hours, never per-frame.

---

## 6. Filtering (user requirement)

Both categories must be independently selectable — **some / all / none**:

- **Aircraft:** commercial, private, military, jet, piston, rotorcraft.
  Derived primarily from the ADS-B `category` emitter field plus the `t` type
  designator. Military identification is *heuristic* — ADS-B does not carry a
  "military" flag. Best-effort from type designators and callsign patterns; a proper
  job would need an aircraft metadata database, which is a later refinement.
- **Satellites:** Starlink, LEO, GEO, manned.
  **No "visible now" filter — decided 2026-09-24.** The app is for situational awareness
  of what is overhead, *including what the naked eye cannot see*, so sun position never
  hides or dims a satellite. Earth's shadow is shown as a `shadow` label only.

---

## 7. Known risks — unresolved, in priority order

1. **SGP4 — de-risked 2026-09-23, decision now cheap.** Satellite propagation is easy
   to get subtly, silently wrong, and it was the single most likely source of "the app
   points at empty sky." The insight that collapsed it: *the validation work is
   identical whichever implementation is chosen*, so the harness was built first and
   now decides. See §7.1.
2. **Viture's *Unity XR* SDK appears aimed at their 6DoF Neckband**, not at
   phone-tethered Pro XR glasses. The real integration path is probably the Viture
   **Android** SDK, wrapped as a Godot Android plugin (v2, AAR). Verify against the
   actual hardware early — this is an architecture assumption, not a fact.
3. **Phone → glasses display path — RESOLVED 2026-09-23 (native SBS from Godot, see §10).** Kendel's phone is a
   **OnePlus 7 Pro (LTE)**, and Viture's SpaceWalker app drives the glasses from it
   without problems. (Several web sources claim the 7 Pro has no DP Alt Mode; direct
   observation beats them.) Still open: how a *Godot* app reaches the glasses. Requires DisplayPort Alt Mode on the
   phone. Godot likely cannot drive a *separate* external display, so expect the phone to
   mirror; check whether a mirrored side-by-side frame fills the glasses or letterboxes.
   Confirm the specific phone can do this *before* building anything on top of it.
4. **Heading accuracy** (§4.2). A phone magnetometer may not be good enough. The
   nudge control is the safety net.
5. **46° FOV is small.** Only a narrow slice of sky is visible at once. Needs
   off-screen indicators ("ISS — 40° left, rising") and aggressive decluttering, or
   the app is a guessing game.

### 7.1 SGP4 validation — built 2026-09-23

`tools/validation/validate_sgp4.py`, with `sgp4_fixture.json` for the C# side.

Why it exists: satellites broadcast nothing. CelesTrak gives *mean* orbital elements
fitted by SGP4 itself, so they are only valid with SGP4 — feeding them to ordinary
Keplerian math silently reintroduces the perturbations that were subtracted out. And
unlike the aircraft path, the feed carries no ground truth to check against.

Ground truth therefore comes from the published verification suite (`SGP4-VER.TLE` /
`tcppver.out`, which ship inside the python-sgp4 package — no download). It is
deliberately nasty: Lyddane fix regression, a 12-hour resonant Molniya orbit,
deep-space cases, decayed satellites.

| Check | Result |
|---|---|
| Oracle vs published vectors | 710 state vectors, **worst delta 0.117 mm** |
| C# fixture emitted | 32 satellites, 354 state vectors, TEME / WGS72 |
| Live ISS vs wheretheiss.at | **0.1 km** |

**Model accuracy is not the constraint.** SGP4 is good to ~1 km near epoch; at the
ISS's altitude that is ~0.14° of pointing error, invisible at 46° FOV. The entire risk
was implementation correctness, which the harness now settles. What *does* matter more
than expected is TLE freshness and clock accuracy: the ISS moves 7.7 km/s, so one
second of clock error is ~1.1° — larger than the model's own error budget. Refetch
elements often, especially for Starlink, which maneuvers constantly.

**Decided 2026-09-23: port Vallado, deep space included.** `scripts/satellites/sgp4.gd`
is a line-for-line GDScript port of python-sgp4's `propagation.py` (MIT), SDP4 and both
resonances included, so GEO, GPS and Molniya orbits work. It matches the fixture to
**0.03 mm** (the fixture's own rounding) at ~4.5 µs per propagation. The rest of the
chain (OMM parsing, TEME to ECEF, look angles, sun, shadow) is checked end to end against
Skyfield by `satellite_fixture.json`; see §10.

---

## 8. Build order

Each step is independently verifiable, risky things first.

1. **Spike the display path.** Get *anything* — a triangle — from the phone onto the
   glasses in stereo, and read the IMU. Resolves risks 2 and 3 before any real work.
2. **Aircraft only, no satellites.** adsb.lol → look-angle math → markers on the sky.
   Aircraft are visually confirmable: point at a plane you can see and check the
   marker sits on it. This validates the whole geometry + calibration chain against
   ground truth.
3. **Calibration UX.** Phone-compass fix, declination correction, nudge control.
   Not done until a marker stays on a real plane as you turn your head.
4. **Satellites.** Only after aircraft prove the pipeline. Start with the ISS alone —
   one object, checkable against any public ISS tracker.
5. **Filtering + labels + decluttering.**

**Deliberate ordering note:** aircraft come before satellites because aircraft are
*verifiable by looking up*. Debugging satellite math and calibration math at the same
time, against an object you may not be able to see, is how this project stalls.

---

## 9. What changed from the 2026-08-03 plan, and why

| Old plan | New plan |
|---|---|
| Quest 3 primary, Viture secondary | **Viture Pro XR only**, Quest 3 dropped |
| VR tabletop god-view of a coverage volume | **AR finder** — real sky, real directions, 1:1 |
| three.js + 3DTilesRendererJS + WebXR | **Godot 4 + Viture Android SDK**, Android APK (briefly Unity) |
| Streamed 3D Tiles terrain = the #1 risk | **No terrain at all** |
| AeroScan Pi as the data source | **Public APIs** (adsb.lol, CelesTrak) |
| Aircraft only | **Aircraft + satellites** |

**The big win:** the old plan's project-killing risk was streaming globally
referenced 3D terrain into a browser in stereo at 90fps. Optical see-through AR
deletes that entire problem — the real world *is* the background. Nothing needs to be
rendered except markers and text.

**The new risk profile is different, not absent.** The old project could have died on
rendering performance. This one dies on *pointing accuracy*: a marker 10° off is worse
than no marker. Effort moves from GPU budget to sensor fusion and calibration.

**Still relevant from the old plan:**
- skytrace's `web/src/aircraft-motion.js` (1 Hz ADS-B → smooth interpolation /
  dead reckoning) and `aircraft-attitude.js` — pure renderer-agnostic logic, still
  worth porting. adsb.lol polls at seconds-scale; markers must not visibly jump.
- skytrace is **GPL-3.0**: consuming over HTTP is clean, copying code is not.
- Any library that owns its own camera (MapLibre, CesiumJS) remains disqualified.

**No longer relevant:** terrain streaming, Cesium ion keys, 3D Tiles, tabletop scale
and LOD design, WebXR, PCVR/WiVRn/Monado, the whole Linux-vs-Mac dev question (the
build target is now an Android phone).

---

## 10. Current state of the repo

**As of 2026-09-23: aircraft pipeline runs on the desktop in Godot.** Build-order step 2
works end to end against live adsb.lol traffic with the mouse mock tracker. Nothing has
touched the phone or glasses yet.

```
VRAeroScan/
├── PROJECT_NOTES.md                  ← this file
├── docs/archive/…                    ← superseded Quest 3 plan
├── tools/validation/                 ← Python oracles, all passing
│   ├── validate_geomath.py           ← look angles vs adsb.lol ground truth
│   ├── export_geomath_fixture.py     ← freezes it → godot tests/geomath_fixture.json
│   ├── validate_classifier.py        ← 2.7% unclassified over 892 aircraft
│   ├── validate_sgp4.py              ← 0.117 mm vs published vectors
│   └── export_satellite_fixture.py   ← Skyfield → godot tests/satellite_fixture.json
├── godot/VRAeroScan/                 ← THE APP
│   ├── project.godot, main.tscn      ← hand-written; main.tscn is one node + AppBootstrap
│   ├── scripts/core/                 ← geo_point, look_angles, geo_math, compass_calibration
│   ├── scripts/tracking/             ← head_tracker (base), mock_head_tracker
│   ├── scripts/data/                 ← aircraft, aircraft_classifier, adsb_service,
│   │                                    celestrak_service (OMM fetch + user:// cache)
│   ├── scripts/satellites/           ← sgp4, satellite, satellite_sky (budgeted), solar
│   ├── scripts/rendering/            ← ar_visuals, sky_rig, cardinal_markers, sky_marker
│   ├── scripts/ui/                   ← touch_horizon_control
│   ├── scripts/app/                  ← app_bootstrap
│   └── tests/                        ← run.sh (220 checks), live_check.gd, fixture
```

### Conventions that are load-bearing (all pinned by tests)
- **World frame: −Z = true north, +X = east, +Y = up.** An unrotated camera looks north.
  This is *not* the Unity version's +Z-north — never copy signs across.
- **Yaw is compass sense** (clockwise from above) everywhere in app code. The one
  conversion to Godot's counter-clockwise rotation is in
  `CompassCalibration.to_world_basis()`, which pre-multiplies (world-up rotation) so
  pitch survives. A `HeadTracker` must return compass-sense `raw_yaw_deg()`.
- **Drag sign:** `rotate_sky(+d)` moves the sky right, via `nudge(-d)`. A mutation test
  confirmed flipping it fails the suite.

### Verified 2026-09-23
| Check | Result |
|---|---|
| `tests/run.sh` (geometry vs fixture, frame, calibration, pitch, drag sign, parsing, classifier, whole-app marker placement) | **220 checks, 0 failed** |
| `tests/live_check.gd`, 79 live aircraft near Seattle | great-circle vs `dir` **0.049°** (rounding bound), dst **0.096 nm** |
| Rendered frames via `--write-movie` | 183 LA aircraft drawn; ghost N lands 5° left at heading 5° |

**`run.sh`, not the bare script:** a GDScript runtime error aborts only its own function
and Godot still exits 0, so run.sh fails the run on any `SCRIPT ERROR`. This was hit
for real — a crashed test once reported "0 failed".

### Resume here (updated 2026-09-24, end of session)

**State:** everything committed on `master` (last: `0f2d779`, no remote). 3521 headless
checks pass (`godot/VRAeroScan/tests/run.sh`). The app runs on the phone + glasses at
60 fps with 16,749 satellites (CelesTrak active+visual+stations) and live aircraft: head
tracking, SBS stereo, GPS, satellite + aircraft icons, pass prediction, pointers,
phone control panel + glasses menu for calibration. The latest build (panel-waits-for-USB-
permission fix) is INSTALLED on the phone but not yet seen running with the glasses.

**Added 2026-10-04 (uncommitted until Kendel says):** viewpoint altitude (surface / Earth
centre / 0 km–GEO via `GeoPoint.earth_centre` and `AppBootstrap.view_point()`; rise markers
and horizon culls are off away from the ground), satellite-kind and aircraft-group toggles,
a phone panel with North / Show / View tabs, and glasses-menu pages for each. Commands:
`view:`, `sat:`, `air:`, `page:` (see `run_command`). 3572 checks pass; the APK builds but
the phone was offline, so it is **not yet installed or seen on hardware**.

**Pole-star sighting (2026-10-04, uncommitted):** optional way to set north: put Polaris
(north) or Sigma Octantis (south, mag 5.4) in a circle in the glasses and tap. `PoleStar`
computes the star's real az/el (matches Skyfield to 0.0074°; fixture from
`tools/validation/export_star_fixture.py`); `CompassCalibration.calibrate_from_gaze` takes the
fix from the gaze direction, so head pitch does not matter. Command `star`; phone North tab
button and glasses-menu row. Refuses when the star is under 3° up (near the equator).

**Launching on the glasses (2026-10-04):** the normal "VRAeroScan" icon opens the app on the
phone's own screen (the glasses just mirror it) and the control panel never opens. The second
icon, **"VRAeroScan (glasses)"** (`LaunchOnGlassesActivity`, own process), stops any running copy
and starts the app on the VITURE display, so the panel opens on the phone. Seen working: app task
on the glasses display, panel task on display 0. Plugin manifest adds KILL_BACKGROUND_PROCESSES.

**Published (2026-10-04):** https://github.com/parheliatech/VRAeroScan (public, branch `master`),
release `v0.1.0` with `VRAeroScan-0.1.0.apk` (debug-signed, ~112 MB, includes Viture's libs). To
release again: build the APK, `gh release create vX.Y.Z <apk> --repo parheliatech/VRAeroScan`.

**Next, in order:**
1. **Verify the fix on hardware:** connect glasses (3D mode), launch, tap OK on the USB
   permission prompt (tick "use by default"), confirm head tracking streams and the
   control panel opens by itself a few seconds later.
2. **Outdoor calibration + truth test:** calibrate north (panel "I'm facing north" or
   drag the pad until the ghost N sits on true north — the Catalinas are north), then
   check a marker against a real aircraft, and an ISS pass (the panel/HUD list passes).
3. **More HUD options** (Kendel chose "both" inputs; calibration was first): satellite
   filters (kinds, groups), aircraft filters, display (label size — labels are large;
   ~2× smaller was suggested — gaze-label radius/count, horizon ring, pointers).
4. Smaller ideas: CRJ/E145 rear-engine regional jets → business-jet silhouette; aircraft
   off-screen pointers (OffscreenPointers already takes any direction); a terrain/
   obstruction horizon for rise times; profile the phone with the whole catalogue over a
   long session (it was 60 fps at launch).

**Kendel's standing rules (do not regress):** never hide or dim satellites the eye cannot
see (shadow, daylight, below the horizon — draw them through the Earth); Godot/MIT only
(no GPL assets; Unity removed); validate against live data / Skyfield, not assumptions.

**Working with the phone (OnePlus 7 Pro, Android 16):**
- Wi-Fi adb `192.168.86.114:5555`; after a phone reboot re-enable it over USB:
  `adb -s dee0f13e tcpip 5555 && adb connect 192.168.86.114:5555`. The first connect
  can fail while the phone's Wi-Fi wakes — ping, then retry.
- **Running Godot (export, `--import`, tests) restarts the adb server**, dropping the
  Wi-Fi connection: reconnect afterwards, and wrap adb calls in `timeout`.
- Build + install: `godot --headless --path godot/VRAeroScan --export-debug "Android"
  vraeroscan.apk`, then `adb install -r` (USB is far faster for the 111 MB APK).
- Launch on the glasses: `ADB=adb ADB_SERIAL=192.168.86.114:5555
  godot/DisplaySpike/launch_on_glasses.sh org.vraeroscan.app`. Status every 5 s:
  `adb logcat -s godot | grep VRAEROSCAN`. Capture: `adb exec-out screencap -p -d
  4615860159156968452` (glasses), `-d 4630946797824131201` (phone screen).
- Drive the panel remotely: `adb shell input -d 0 tap/swipe …` on the phone display.
- After a reboot or reinstall, Android re-asks USB permission for the glasses on the
  phone screen, and location permission. A 2D↔3D switch replugs the glasses as a new
  display id; the launch script finds it.
- Viture plugin: `godot/plugins/viture_glasses/build.sh ../../VRAeroScan` (JDK 17,
  needs `vendor/viture/lib`, gitignored — never commit Viture's libraries).
- CelesTrak: 17 groups per refresh (every 4 h, cached in `user://celestrak/`). Seed a
  device's cache rather than re-downloading within 2 h (debug build: `adb push` to
  /data/local/tmp, then `run-as org.vraeroscan.app cp … files/celestrak/`).
- Don't `pkill -f` with a pattern that appears in your own command line — it kills
  the shell running it.

**Pending on Kendel's side:** Unity Hub apt package (528 MB) still installed; needs
`sudo apt purge -y unityhub` plus removing `/etc/apt/sources.list.d/unityhub.*` and
`/usr/share/keyrings/Unity_Technologies_ApS.gpg`.

### Viture SDK — found inside SpaceWalker (2026-09-23)
Kendel's `~/Vibe/SpaceJumper/` has SpaceWalker 1.7.2.0 (Viture's official app) already
decompiled (`apk_source/jadx`, `apk_source/apktool`). It bundles Viture's Android glasses
SDK, which is what our plugin should wrap:

- Java API: `viture.glasses.VitureGlassesProvider` — `initialize(int, String, int)`,
  `openImu(int, int)`, `registerViturePoseCallback(Viture.Pose)` →
  `onImuPoseData(float[], long)`, `registerVitureRawCallback`, `getImuPose(float[],
  double)`, `resetPose()`, `setDisplayMode(int)` (likely the 2D / 3D-SBS switch),
  `getWearStatus()`. Device types: GEN1=0, GEN2=1, CARINA=2.
- JNI: `viture.glasses.jni.GlassesBridge` (static natives). JNI binds by class name, so a
  plugin must declare that exact class and signatures.
- Native: `libglasses-jni.so` → `libglasses-internal.so`, `libcarina_vio.so`,
  `libcloud_protocol.so`; nothing else beyond Android system libs.
- Display: SpaceWalker uses Android's `Presentation` API (`DisplayPresentationManager`),
  so the phone exposes the glasses as a **separate display**, not only a mirror.
- Not yet traced: the actual arguments to `initialize`/`openImu` (call sites obfuscated)
  and the pose array layout.

Local copies are in `vendor/viture/` (APK + the four `.so` files), **gitignored — this is
Viture's proprietary code. The source tree never contains it (`vendor/` stays gitignored), but
Kendel chose on 2026-10-04 to bundle it in the public release APK so the app runs out of the box.**

### Display spike — PASSED 2026-09-23
`godot/DisplaySpike/` (`display_spike.apk`, debug-signed arm64) on the OnePlus 7 Pro —
which runs **Android 16** (custom ROM; OnePlus stopped at 12), `adb` serial `dee0f13e`,
Wi-Fi adb at `192.168.86.114:5555`.

| Test | Result |
|---|---|
| Glasses as an Android display | **Separate EXTERNAL display "VITURE"**, not just a mirror |
| Normal launch (mirrored) | 1920×886 letterboxed inside 1920×1080 — wastes 18% of FOV |
| `am start --display <id>` onto glasses, 2D | **1920×1080 native, 60 fps**, phone screen stays free |
| Same, glasses in 3D mode | **3840×1080 SBS, 60 fps; Kendel confirmed L/R per eye and the horizon lines fuse** |
| Phone gyro / accel / magnetometer in Godot | All live |

Behaviours the app must handle (all observed in logs):
- **2D↔3D is a display replug.** The glasses drop the 1920×1080 display and re-appear as
  a *new* logical display at 3840×1080 (ids went 2 → 6). Android moves our activity back
  to the phone. The app must detect the VITURE display and move onto it.
- **Android 16 gates new displays** behind a "Mirror to external display?" prompt on the
  phone; until answered the display is `mIsEnabled=false`, state OFF → black glasses.
  Check how SpaceWalker avoids this (the SDK's `setDisplayMode` may, since it may not
  replug). Otherwise the app must prompt the user.
- Godot's `DisplayServer` only ever sees the display the activity is on
  (`get_screen_count()` = 1), so choosing the display is the plugin's job, not Godot's.
- Launch activity is `com.godot.game.GodotAppLauncher` (exported); `GodotApp` is not.
- `adb exec-out screencap -p -d <physical id>` captures what is sent to the glasses —
  useful for remote checks. Physical id of the glasses: `4615860159156968452`.

`godot/DisplaySpike/launch_on_glasses.sh` finds the glasses display and launches onto it.

### Satellites — working on the desktop 2026-09-23
CelesTrak OMM → SGP4 → TEME→ECEF (GMST) → look angles → diamond markers, in the same
world frame as the aircraft. Labels read `NAME / 420km up 1034km`, with `shadow`
appended when the satellite is in Earth's shadow. That is information only: shadowed
satellites are drawn exactly like lit ones (see §6).

| Check | Result |
|---|---|
| GDScript SGP4 vs Vallado suite (32 sats, 354 vectors, deep space, resonances) | **0.03 mm** |
| Whole chain vs Skyfield (8 sats × 3 observers × 6 times, frozen live elements) | az **0.0006°**, el **0.0004°**, range 40 m, sun 0.007°, shadow **144/144** |
| Mutation tests: GMST sign, ω×r sign, shadow off, docking dedupe off | each fails the suite |
| `live_satellite_check.gd`, ISS vs wheretheiss.at | **0.8 km**, shadow state agrees |
| Rendered frame, Tucson | rocket body at az 227.5 el 37.6 drawn 4° left / 2° up at heading 231.5 |

Design points:
- **Groups** default to `stations` + `visual` + `starlink` (~11,300 objects; Starlink on
  by default since 2026-09-24 — it is most of what is up there). `geo` is opt-in via
  `AppBootstrap.satellite_groups`. Kinds (Manned / Starlink / LEO /
  MEO-HEO / GEO) are one per satellite and filtered by `satellite_types` bitmask.
- **CelesTrak etiquette:** each group is cached in `user://celestrak/` and refetched only
  after `refresh_hours` (≥2, default 4). The cache is used at start, so it works offline.
  CelesTrak throttles clients that download unchanged data too often (HTTP 403).
- **Docked vehicles and station modules** (ISS, POISK, NAUKA, Dragon, Soyuz…) share a
  position; MANNED satellites within 5 km collapse to the lowest catalogue number.
- **The whole sky, through the Earth (2026-09-24).** Every satellite is drawn wherever it
  is, below the horizon and on the far side of the planet included — Kendel's rule; a
  horizon cut had hidden 96% of Starlink. (Checked first that nothing was being moved
  above the horizon: drawn elevations matched SGP4 to 0.04°; the pile-up along the
  horizon is real geometry — 60% of the Starlinks above the horizon are within 10° of it.)
  - `SatelliteField`: one MultiMesh for all diamonds. Each instance holds its last SGP4
    sample (position relative to the observer, velocity, sample time); the vertex shader
    extrapolates, projects onto the dome and billboards. GDScript touches an instance
    only when it is resampled. `direction_now()` mirrors the shader on the CPU for tests
    (the rendering server keeps no readable copy, and none at all headless).
  - `SatelliteSky`: a timing wheel resamples each satellite at a period set by range —
    2 s overhead to 20 s on the far side (≤0.05° drift, checked over a simulated minute
    for a 288-satellite all-sky catalogue) — within a 2 ms/frame budget. A 5° direction
    index answers "what is near where I'm looking" without scanning 11,000.
  - Tracked satellites (Manned) keep full markers, labels and pointers everywhere,
    never faded; rise markers still count down. Aircraft still stop at the horizon.
  - **Labels only near the gaze:** at most 8, within 8° of the view centre, nearest
    first, skipping any that would overlap one already placed. Every diamond stays.
  - **Phone: 60 fps with all 11,308 satellites** (OnePlus 7 Pro, Adreno 640), head
    tracking live. Desktop (Intel HD 620): ~16–23 ms/frame.
  - Whole-catalogue check vs Skyfield (all 11,133 Starlinks, one instant): app 0.006°,
    GPU replica 0.026°. The distribution is physics, not a bug: 1 Starlink above 75°,
    ~10,600 below the horizon; far-side ones move ~2°/min (look frozen), overhead ~40°/min.
  - Diamonds scale with √range (1× at 1,000 km, 0.3×–1.4×): the far side reads as a fine
    distant layer. Tracked markers stay full size.
  - Dashed horizon ring on by default (`SkyRig.show_horizon_ring`, runtime-switchable).
  - No label overlaps: edge pointers slide along the edge to clear each other; gaze
    labels are placed last and skip anything that would cover a pointer, a tracked or
    rise label, or another gaze label (`AppBootstrap.occupied_view_rects`).
- **Clock accuracy matters more than the model:** 1 s of clock error ≈ 1.1° at the ISS.
  The phone's network time is fine; the HUD shows median element age and flags >72 h.

- **Off-screen pointers** (`OffscreenPointers`, 2026-09-24): a chevron on the edge of the
  view, aimed at each off-screen satellite of `tracked_types` (default Manned), labelled
  with name and angle to turn, e.g. `ISS (ZARYA) 97°`. Nearest first, capped at 4. They
  are 3D nodes on the camera, so they render in the eye viewport and work in SBS stereo
  (checked in a rendered frame); a 2D CanvasLayer would have spanned both eyes. Targets
  behind you point the short way round.
- **Pass prediction** (`PassPredictor`, 2026-09-24): for `tracked_types` satellites
  (GEO excluded — it never rises), the next rise / peak / set within 24 h. Within
  `rise_lead_minutes` (20) of a rise, an up-chevron sits on the horizon at the rise
  azimuth, labelled `ISS (ZARYA) rises in 4:12 / max 67°`, and gets a pointer when off
  screen; at rise the satellite's own marker takes over. The HUD (and the phone's log
  line) lists the next three: `ISS (ZARYA) in 4:12 from SSW, max 21°`. Docked vehicles
  and station modules have the station's pass and are folded into it.
  - Search: 20 s steps near the horizon (60 s when >15° below), bisection for crossings,
    golden-section for the peak, geometric 0° horizon (no refraction or terrain).
  - **vs Skyfield `find_events`, 55 passes, 4 satellites, 3 observers:** rise/set
    **0.19 s**, azimuth **0.02°**, peak elevation **0.004°**; no-pass cases (Hubble and
    CSS never reach Tromsø) and a mid-pass start also checked. Mutation-checked
    (crossing offset, coarse steps, docking dedupe).
  - Cost: time-budgeted at 1 ms/frame. Re-predicting all 13 manned objects takes ~160
    frames (~3 s); it reruns only when a pass ends, elements refresh, or the observer
    moves >5 km. At most 50 satellites are predicted, so tracking Starlink is capped.

### Aircraft icons (2026-09-24)
Silhouettes replace the aircraft squares (`AircraftIcons`): airliner, heavy (drawn 1.25×),
business jet, twin prop, light single, helicopter, fighter, glider, balloon, generic.
**Our own drawings (MIT)** — the ADS-B Exchange/tar1090 set was considered and rejected:
tar1090 is GPL-2.0+, and its shapes have mixed attributions. Outline-only line meshes,
top-down planform (also the view from below).
- Chosen from the classifier + ADS-B emitter category + an ICAO type-prefix table (own,
  not tar1090's). Live Tucson traffic mapped sensibly (737/E175/CRJ → airliner, B763 →
  heavy, C172/P28A/SR20/C208 → light, B350/E120 → twin prop).
- **The nose points along the aircraft's motion across YOUR view** (track projected
  into the marker plane via a point 500 m ahead), not map-north-up. Balloons stay upright.
- Idea, not done: regional jets with rear engines (CRJ, E145) could use the business-jet
  shape, which matches them better; their colour already says commercial.
- Also fixed while here: gaze labels now avoid aircraft labels, and edge pointers slide
  sideways along the top/bottom edges instead of drifting into the view.

### Satellite icons and the active catalogue (2026-09-24)
Twelve silhouettes (`SatelliteIcons`, our own drawings, MIT): ISS, space station
(Tiangong), crew/cargo capsule, Hubble, Starlink (lopsided single array), communications,
navigation, Earth observation/weather, rocket body, debris, CubeSat, generic. Shape says
what it is; colour stays with the orbit category, **military in amber** (as for aircraft).
- **Catalogue is now CelesTrak `active` + `visual` + `stations`** (16,749 objects; `active`
  ⊇ Starlink). Purpose comes from CelesTrak's purpose groups, fetched and cached like the
  rest but used only for tagging: gnss, weather, resource, planet, geo, intelsat, ses,
  iridium-NEXT, oneweb, globalstar, orbcomm, cubesat, spire, military (names verified
  2026-09-24). Then name patterns, then orbit (GEO with nothing else → comms).
- Gotchas found: `gnss` lists comsats hosting WAAS/EGNOS payloads (Galaxy, Astra) — in GEO
  only BeiDou/QZSS/NavIC count as navigation; "ISS OBJECT xx" are CubeSats released from
  the ISS, not the station (they had been classed manned → tracked); the public
  `military` group has only 24 objects, so military is mostly by name (Yaogan, TJS, USA-,
  non-GLONASS Cosmos): 400 flagged.
- Real-catalogue split: Starlink 11,134, comms ~2,470, EO ~800, nav ~200, CubeSat ~180,
  rocket bodies 98, generic ~1,800 (Cosmos, launch-designator names, rideshare carriers,
  Chinese experimental Shiyan/Shijian — genuinely hard to type).
- Rendering: one MultiMesh per icon (`SatelliteField` layers), same shader.
  Desktop ~29 ms/frame with 16,749 drawn (Intel HD 620); phone not yet measured.
- CelesTrak courtesy: 17 groups per refresh (every 4 h, cached). The desktop cache was
  seeded from validation downloads so nothing was fetched twice within 2 h.

### Controls: phone panel + glasses menu (2026-09-24)
Calibration first; more options (satellite/aircraft filters, display) to follow.
- **One command path**: `AppBootstrap.run_command()` — `north`, `sky:<deg>`,
  `drag:<frac>:<fingers>`, `drag_end`, `tap`, `menu` — used by the phone panel, the glasses
  menu and keys (N north, Space tap, M menu, ←/→ nudge; `adb shell input keyevent`).
- **Phone panel** (`ControlPanelActivity`, in the Viture plugin): opens on the phone's own
  display when the app starts on the glasses (Android multi-resume keeps both running:
  60 fps confirmed). "I'm facing north", sky ←/→ 1° and 0.1°, and a large pad: **drag to
  turn the sky** (the original primary calibration design, back since the app moved to
  the glasses; two fingers fine), tap to open/select in the glasses menu. Live status
  line. Keeps the phone screen on (the phone sleeping had paused the app). Commands cross
  from Java through a queue the app polls each frame (`takeCommands`).
- **Glasses menu** (`QuickMenu`): opens world-anchored where you look; a centre reticle
  selects by head gaze, the pad's tap chooses. "Set north…" is two steps (choose, face
  north, tap) — aiming at a menu item and facing north can't happen at once. Closes after
  20 s idle or a tap looking away.
- Verified on hardware via `adb shell input -d 0 tap/swipe` on the phone display: button
  nudges, pad drag (300 px right = 17.5° sky right, swipe back = exact return), pad tap
  opening the glasses menu with the hovered row boxed.

Not done: pointers for aircraft (`OffscreenPointers` takes any world direction, so that
is wiring, not new maths), and a terrain/obstruction horizon for rise times.

Commands:
```
godot/VRAeroScan/tests/run.sh                                        # unit + app tests
godot --headless --path godot/VRAeroScan --script res://tests/live_check.gd   # live feed
godot --headless --path godot/VRAeroScan --script res://tests/live_satellite_check.gd  # ISS vs wheretheiss.at
godot --path godot/VRAeroScan                                        # run it (desk)
godot -e --path godot/VRAeroScan                                     # open the editor
```

## 11. Open questions

- [x] SGP4: ported Vallado (via python-sgp4) to GDScript, deep space included (§7.1).
- [ ] Can the Viture Android SDK be wrapped as a Godot Android plugin, and does it expose
      the Pro XR's IMU when phone-tethered? (risk 2)
- [ ] GPS on Android from Godot: write a small plugin, or use an existing one?
- [x] Which phone, and does it do DisplayPort Alt Mode? — OnePlus 7 Pro; yes, SpaceWalker drives the glasses. (risk 3)
- [ ] Magnetic declination source — bundled WMM coefficients, or an API?
- [ ] Is the phone magnetometer accurate enough, or is a celestial fix needed? (§4.2)
- [x] Marker rendering distance: fixed-radius dome (500 m), range shown in the label.

---

## 12. References

**Data**
- adsb.lol API: https://api.adsb.lol/docs · docs: https://www.adsb.lol/docs/open-data/api/
- CelesTrak GP data: https://celestrak.org/NORAD/documentation/gp-data-formats.php

**Hardware / SDK**
- Viture developer portal: https://www.viture.com/developer
- Viture Android SDK: https://www.viture.com/developer/viture-one-sdk-for-android
- Viture Unity XR SDK: https://www.viture.com/developer/unity-sdk/unity
- Local: `~/Vibe/breezy-desktop-2.9.13/` (Linux driver, reference for IMU handling)

**Reference project**
- skytrace: https://github.com/luftaquila/skytrace (GPL-3.0) — motion interpolation

**Related prior work**
- `~/Vibe/AeroScan/` — the RTL-SDR receiver (deferred as a data source, see §5)
- `~/Vibe/VRTAK-Plan/` — VR ATAK port plan; hardware-architecture reasoning
