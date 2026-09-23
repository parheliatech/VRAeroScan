# VRAeroScan — Project Notes

**An augmented-reality "finder" for what is above you.** Look up through AR glasses
and see the aircraft and satellites actually passing overhead, drawn where they really
are in the sky.

Status: **planning complete, scaffolding started — no working code yet.**
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
   │                          world-fixed sky markers in Unity                  │
   │                                              │                             │
   │   Unity stereo camera rig ◄── head orientation                             │
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

### Framework
**Unity + Viture SDK**, building an Android APK. Chosen over native Kotlin because
Viture ships Unity integration and Unity gives the stereo rig and 3D math for free;
hand-rolling OpenGL stereo in Kotlin is more code for the same result.

---

## 3. Hardware

| Device | Role | Notes |
|---|---|---|
| **Viture Pro XR** | **Display + head IMU** | Optical see-through. 3DoF only. 46° FOV. No GPS, no compass, no compute, no cameras. |
| **Android phone** | **The entire computer** | Must support USB-C DisplayPort Alt Mode. Provides GPS + magnetometer. |
| Linux box | Dev machine | Unity Hub installed at `/usr/bin/unityhub`; Android SDK at `~/Android/Sdk`; `adb` present. |
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

⚠️ `alt_baro` is **mixed-type** (number *or* `"ground"`). Unity's `JsonUtility` cannot
handle that — use Newtonsoft (`com.unity.nuget.newtonsoft-json`).

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

1. **SGP4 is the piece not to write blind.** Satellite propagation is easy to get
   subtly, silently wrong. Near-Earth SGP4 covers ISS and Starlink; GEO objects need
   deep-space SDP4 terms. Two paths: port it and validate against a reference
   implementation with real test vectors, or pull in a vetted C# library. **Decide
   before writing it.** A hand-written, unvalidated propagator is the single most
   likely source of "the app points at empty sky."
2. **Viture's *Unity XR* SDK appears aimed at their 6DoF Neckband**, not at
   phone-tethered Pro XR glasses. The real integration path may be the Viture
   **Android** SDK wrapped as a JNI/AAR plugin called from Unity. Verify against the
   actual hardware early — this is an architecture assumption, not a fact.
3. **Phone → glasses display path unverified.** Requires DisplayPort Alt Mode on the
   phone, and Unity rendering to an external display on Android (Presentation API).
   Confirm the specific phone can do this *before* building anything on top of it.
4. **Heading accuracy** (§4.2). A phone magnetometer may not be good enough. The
   nudge control is the safety net.
5. **46° FOV is small.** Only a narrow slice of sky is visible at once. Needs
   off-screen indicators ("ISS — 40° left, rising") and aggressive decluttering, or
   the app is a guessing game.

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
| three.js + 3DTilesRendererJS + WebXR | **Unity + Viture SDK**, Android APK |
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

```
VRAeroScan/
├── PROJECT_NOTES.md                  ← this file
├── docs/archive/
│   └── PROJECT_NOTES-2026-08-03-quest3-webxr.md   ← superseded plan
└── unity/VRAeroScan/                 ← scaffolded, EMPTY
    ├── Assets/Scripts/{Core,Tracking,DataFeeds,Satellites,Rendering,UI,App}/
    ├── Packages/
    └── ProjectSettings/
```

`git init` has been run. Nothing committed yet. **No code has been written.**

### Planned script layout
| Path | Responsibility |
|---|---|
| `Core/GeoMath.cs` | WGS84 geodetic↔ECEF, ENU, observer→target az/el/range |
| `Core/CompassCalibration.cs` | Glasses-yaw → true-heading offset, declination, nudge |
| `Tracking/IHeadTracker.cs` | Abstraction over the head IMU |
| `Tracking/VitureHeadTracker.cs` | Real SDK binding (Unity XR *or* Android AAR — risk 2) |
| `Tracking/MockHeadTracker.cs` | Mouse/keyboard look, for desk testing without hardware |
| `DataFeeds/AdsbService.cs` | Poll adsb.lol, parse (Newtonsoft), dead-reckon between polls |
| `DataFeeds/AircraftClassifier.cs` | Emitter category + type → filter classes |
| `Satellites/ISatellitePropagator.cs` | Propagator abstraction (see risk 1) |
| `Satellites/SatelliteService.cs` | CelesTrak fetch, TLE cache, propagate, filter |
| `Rendering/SkyRig.cs` | World-fixed north-up frame; camera rotates inside it |
| `Rendering/SkyMarker.cs` | One target's billboard + label |
| `UI/FilterState.cs`, `UI/FilterPanel.cs` | Touchscreen filter controls on the phone |
| `App/AppBootstrap.cs` | Wiring |

**The `IHeadTracker` / `MockHeadTracker` split matters:** it lets the entire geometry
and data pipeline be developed and debugged on the desktop, before the Viture display
path (risk 2/3) is resolved. Do not let unresolved hardware block the math.

---

## 11. Open questions

- [ ] SGP4: port-and-validate, or vendor a library? (risk 1 — decide first)
- [ ] Does the Viture Unity XR SDK support phone-tethered Pro XR, or is the Android
      SDK + JNI the real path? (risk 2)
- [ ] Which phone, and does it do DisplayPort Alt Mode? (risk 3)
- [ ] Magnetic declination source — bundled WMM coefficients, or an API?
- [ ] Is the phone magnetometer accurate enough, or is a celestial fix needed? (§4.2)
- [ ] Marker rendering distance: fixed-radius dome with size-by-range, or true-scale
      placement? (Fixed radius is almost certainly correct — true-scale makes a 737 at
      30 nm sub-pixel.)

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
