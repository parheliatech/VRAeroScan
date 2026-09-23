# VRAeroScan — Project Notes

**An augmented-reality "finder" for what is above you.** Look up through AR glasses
and see the aircraft and satellites actually passing overhead, drawn where they really
are in the sky.

Status: **aircraft pipeline running on the desktop in Godot**, with headless tests and a
live-data check passing. Hardware (phone → glasses) not yet attempted.
Last updated 2026-09-23.

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

The Unity C# remains in `unity/` for reference until the hardware spike settles the
engine question for good. Do not develop it further.

## 3. Hardware

| Device | Role | Notes |
|---|---|---|
| **Viture Pro XR** | **Display + head IMU** | Optical see-through. 3DoF only. 46° FOV. No GPS, no compass, no compute, no cameras. |
| **Android phone** | **The entire computer** | Must support USB-C DisplayPort Alt Mode. Provides GPS + magnetometer. |
| Linux box | Dev machine | Godot 4.7.2 at `~/.local/bin/godot` (→ `~/.local/opt/godot/`); Android SDK at `~/Android/Sdk`; `adb` present. Unity Hub also installed, unused. |
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
- **Satellites:** Starlink, LEO, GEO, manned, plus "visible now" as the most useful
  filter of all.

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
3. **Phone → glasses display path unverified.** Requires DisplayPort Alt Mode on the
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

**Still to decide** (but now cheap, since anything proposed either passes the fixture
or does not): vendor a C# library, port Vallado's reference, or implement near-Earth
only and treat GEO specially. Note that GEO is the one case needing deep-space SDP4 —
and also the one where it matters least, since a GEO satellite is stationary in the sky
by definition.

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
│   └── sgp4_fixture.json             ← 32 sats / 354 vectors, for the app side
├── godot/VRAeroScan/                 ← THE APP
│   ├── project.godot, main.tscn      ← hand-written; main.tscn is one node + AppBootstrap
│   ├── scripts/core/                 ← geo_point, look_angles, geo_math, compass_calibration
│   ├── scripts/tracking/             ← head_tracker (base), mock_head_tracker
│   ├── scripts/data/                 ← aircraft, aircraft_classifier, adsb_service
│   ├── scripts/rendering/            ← ar_visuals, sky_rig, cardinal_markers, sky_marker
│   ├── scripts/ui/                   ← touch_horizon_control
│   ├── scripts/app/                  ← app_bootstrap
│   └── tests/                        ← run.sh (220 checks), live_check.gd, fixture
└── unity/VRAeroScan/                 ← superseded C# version, reference only
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

### Resume here

1. **Hardware spike (build-order step 1)** — now the top risk. Needs: the phone model
   (does it do DisplayPort Alt Mode?), Godot Android export templates (~1.2 GB, from the
   Godot editor's *Manage Export Templates*), and a debug keystore. Goal: a stereo test
   pattern on the glasses and IMU numbers printed, from a Godot APK. Answers risks 2
   and 3 — including whether mirroring fills the glasses or letterboxes.
2. **Declutter + filter.** The LA render showed 183 aircraft piled along the horizon;
   at 46° FOV this is essential, not polish. Filter UI over `AircraftClassifier` flags,
   plus a max-range/min-elevation default. Labels could also shrink (~2× smaller).
3. **Side-by-side stereo** in `SkyRig` (two cameras into SubViewports), once step 1
   says what the glasses actually accept.
4. Then satellites: the SGP4 decision (§7.1) — `sgp4_fixture.json` now checks a GDScript
   propagator exactly as it would have checked C#.

Commands:
```
godot/VRAeroScan/tests/run.sh                                        # unit + app tests
godot --headless --path godot/VRAeroScan --script res://tests/live_check.gd   # live feed
godot --path godot/VRAeroScan                                        # run it (desk)
godot -e --path godot/VRAeroScan                                     # open the editor
```

## 11. Open questions

- [ ] SGP4: vendor a C# library, port Vallado's reference, or near-Earth-only with GEO
      treated specially? Harness now exists (§7.1), so any candidate can be judged
      rather than argued about.
- [ ] Can the Viture Android SDK be wrapped as a Godot Android plugin, and does it expose
      the Pro XR's IMU when phone-tethered? (risk 2)
- [ ] GPS on Android from Godot: write a small plugin, or use an existing one?
- [ ] Which phone, and does it do DisplayPort Alt Mode? (risk 3)
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
