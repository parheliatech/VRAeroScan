# VRAeroScan — Project Notes

**A stereoscopic 3D / VR viewer for live ADS-B aircraft traffic.**

Status: **planning only — no code yet.** Last updated 2026-08-03.

Reference implementation: [luftaquila/skytrace](https://github.com/luftaquila/skytrace) —
self-hosted 3D ADS-B flight tracker (3D, but not VR).

---

## 1. The idea

Take the live ADS-B picture that [AeroScan](https://github.com/parheliatech/AeroScan)
already produces (RTL-SDR + dump1090 on a Raspberry Pi) and render it as a real
stereoscopic 3D world you can look around in, rather than a flat map.

The receiver half is **already solved**. This project is a renderer, not a data
pipeline. That framing matters — it's easy to burn weeks rebuilding an ingest stack
that already exists on the Pi.

---

## 2. Hardware on hand

| Device | Tracking | FOV | Role |
|---|---|---|---|
| **Quest 3** | 6DoF, controllers, hand tracking | ~110° | **Primary target** |
| **Viture Pro XR** | **3DoF only** (no cameras) | 46° | Secondary target |
| M2 MacBook | — | — | Secondary dev machine |
| Linux box | — | — | **Primary dev machine** |
| AeroScan Pi | — | — | Live 1090 MHz feed |

The Viture Pro XR has **no positional tracking, no hand tracking, no controllers**.
6DoF on Viture's line only starts at the Luma Ultra (fisheye temple cameras); the
Beast's is a promised software update. Don't design around 6DoF for these glasses.

---

## 3. Decisions made

### 3.1 Develop on Linux, not the Mac

This is a hard blocker, not a preference:

- Valve **dropped SteamVR for macOS** and never rewrote it for Metal / Apple Silicon.
- **Quest Link has no macOS support.** No Air Link. ALVR has no macOS server either.
- The only thing in the space is [OpenXR OSX](https://skarredghost.com/2026/05/07/openxr-osx-vr-mac/),
  a one-person experimental project. Not a foundation.

⇒ PCVR simply does not exist on the M2. Quest *native* dev on Mac also degrades to
build-APK + `adb install` on every iteration, since you can't preview through Link.

Linux gives you **WiVRn** or **Monado** (open-source OpenXR, streams to Quest 3 over
Wi-Fi) or ALVR. The AeroScan feed and `~/Vibe/breezy-desktop-2.9.13/` are already
there too.

The Mac stays useful for: flat WebXR preview in Chrome, and Viture SBS output
(Viture's SDK and Immersive 3D app do support macOS).

### 3.2 Two presentation modes, not one design scaled down

- **Quest 3 → tabletop god-view.** The whole coverage volume on a table you walk
  around, grab, and scale. Lean in to inspect a corner. This is the mode VR is
  actually better at than a monitor.
- **Viture Pro XR → fixed-viewpoint stereoscopic scope.** You look *around* a world
  in front of you; you cannot move through it or reach into it. The 46° window also
  demands much more aggressive label decluttering than the Quest.

### 3.3 Stack recommendation (awaiting go-ahead)

**three.js + [3DTilesRendererJS](https://github.com/NASA-AMMOS/3DTilesRendererJS) + WebXR.**

One codebase, three outputs, no build step between them:

```
        three.js + 3DTilesRendererJS + SSE traffic feed
                            │
        ┌───────────────────┼───────────────────┐
  Quest 3 Browser     desktop Chrome        SBS window
  WebXR, 6DoF,     → WiVRn / Monado      3840x1080, 3DoF pose
  controllers        → Quest 3 PCVR       from XRLinuxDriver
  (standalone)       (more GPU headroom)   (Viture Pro XR)
```

Same page URL for all three. No APK, no Meta developer account, no store review.

Alternatives weighed and rejected:

| Option | Why not |
|---|---|
| **Unity + [Cesium for Unity](https://github.com/CesiumGS/cesium-unity)** | Most turnkey geospatial, and Viture ships a Unity XR package. But needs a separate build per target, proprietary editor, heavier loop. **Keep as the fallback** if WebXR perf fails. |
| **Godot 4** | Best FOSS OpenXR-on-Linux story, but no Cesium — you'd write the tile streamer yourself. Only worth it if that becomes the project. |
| **Fork skytrace's frontend** | Impossible, see §4. |

### 3.4 Known risk

Quest 3's **browser** rendering streamed 3D Tiles terrain in stereo at 72–90fps is
**unproven for this workload**. Browser overhead plus 3D Tiles' memory appetite is
the specific worry. The terrain-first milestone (§6) exists to test exactly this.
Fallback is a Unity + Cesium native APK — and you'd know within a week, not a month.

---

## 4. What's reusable from skytrace

| Layer | Stack | Reusable? |
|---|---|---|
| Receiver agent | Go — reads `aircraft.json` from readsb / dump1090-fa / tar1090 | **Yes, as-is** |
| Server | Go 1.26 — `ingest/normalize`, `tracks/live+history`, `coverage` domes, `airfields` (OurAirports), `sse/hub`, retention, SQLite | **Yes, as-is** |
| Frontend | Vue 3 + **MapLibre GL JS 6.0** (globe mode, terrain, custom model layer) | **No — total rewrite** |

### 4.1 Why the frontend can't be ported

**MapLibre GL JS owns its own canvas and a single monoscopic camera.** There is no
WebXR path and no way to render two eye views per frame. **CesiumJS has the same
problem.**

This generalizes to a selection rule: *any geospatial library that owns the camera is
disqualified.* 3DTilesRendererJS works precisely because you own the camera — it
loads 3D Tiles into a plain three.js scene and gets out of the way.

### 4.2 Highest-value files to actually read

- `web/src/aircraft-motion.js` — 1 Hz ADS-B → smooth 90 Hz interpolation / dead reckoning
- `web/src/aircraft-attitude.js` — roll & pitch derived from ADS-B
- `web/src/aircraft-size.js`, `aircraft-kind.js` — LOD and type classification

These are pure logic, renderer-agnostic, and port directly.

### 4.3 License

skytrace is **GPL-3.0**.

- Consuming its server over HTTP/SSE from a separate client: **clean**.
- Forking the Go server: **makes VRAeroScan GPL too**. Decide before copying code.

---

## 5. Problems specific to VR (skytrace never had to solve these)

1. **Terrain is the hard part, not aircraft.** A few hundred aircraft transforms per
   frame is trivial. A streamed, globally-referenced terrain + imagery surface is the
   thing that kills the project if it's going to die. skytrace sidesteps it by letting
   MapLibre do it (Mapterhorn terrain, Esri World Imagery, OpenFreeMap labels).
2. **Scale is a design decision, not a setting.** Tabletop (~1:100k) and 1:1
   standing-on-the-field need different LOD pipelines *and* different interaction
   models. Tabletop first.
3. **LOD crossover.** At true scale a 737 at 30 nm is sub-pixel. Needs a
   billboard-icon → mesh crossover.
4. **Labels.** No CSS overlay in VR. Callsign / altitude / speed must be world-space
   billboards with aggressive decluttering, or moved to a wrist/controller panel.
   Much harsher constraint on the Viture's 46° FOV.
5. **1 Hz data → 90 Hz display.** Interpolation and dead reckoning — see §4.2.
6. **Comfort.** Grab-to-pan and scale the table. Never move the user's viewpoint for
   them.

---

## 6. First milestone — terrain first, canned traffic

Chosen deliberately: attack the highest-risk item before building anything on top of it.

**Build:** Vite + three.js + `3d-tiles-renderer`, terrain around the receiver's
location, WebXR session, served over HTTPS on the LAN so the Quest browser can reach
it. Traffic replayed from a recorded `aircraft.json` capture off the AeroScan Pi —
or omitted entirely for the first pass.

**Success criterion:** a frame-time number you can live with while looking around in
stereo. Not visual polish.

**Blocking question before scaffolding:** Cesium ion API key (free tier, global
coverage, works immediately) **vs.** self-hosted tiles (GDAL pre-tiling, same
approach as AeroScan's FAA sectionals — no accounts, but you build the tiler).
Recommendation: start with the ion key to de-risk the renderer; swap the tile source
later if you want to cut the dependency.

---

## 7. Open questions

- [ ] Cesium ion key vs. self-hosted tiles? (see §6)
- [ ] Own data plane, or run skytrace's Go server behind it? (GPL implications, §4.3)
- [ ] Does the Quest 3 browser hold frame rate with streamed 3D Tiles? (§3.4)
- [ ] Viture SBS pose source on Linux — XRLinuxDriver/breezy vs. Viture's own Linux SDK?

---

## 8. References

**Reference project**
- skytrace: https://github.com/luftaquila/skytrace (GPL-3.0)

**Rendering / geospatial**
- 3DTilesRendererJS: https://github.com/NASA-AMMOS/3DTilesRendererJS (Apache-2.0)
- Cesium for Unity: https://github.com/CesiumGS/cesium-unity (Apache-2.0)
- Cesium for Unreal: https://github.com/CesiumGS/cesium-unreal (Apache-2.0)

**Glasses / runtimes**
- Viture developer portal: https://www.viture.com/developer
- Viture Linux SDK: https://www.viture.com/developer/viture-one-sdk-for-linux
- XRLinuxDriver SBS notes: https://github.com/wheaney/XRLinuxDriver/discussions/35
- Local: `~/Vibe/breezy-desktop-2.9.13/` (v2.9.13)

**Data sources used by skytrace** (worth reusing)
- Airports/runways: OurAirports · Terrain: Mapterhorn · Imagery: Esri World Imagery ·
  Labels/boundaries: OpenFreeMap

---

## 9. Related prior work

`~/Vibe/VRTAK-Plan/` (2026-07-27) — VR-TAK implementation plan (docx + pdf) for a VR
port of ATAK, with software and hardware architecture diagrams. Different project,
but the hardware-architecture reasoning (processing external to the goggles,
connectivity between users) is likely reusable here.

`~/Vibe/AeroScan/` — the receiver. See its `DEVELOPMENT_PLAN.md`. Note especially the
offline GDAL pre-tiling approach used for FAA sectionals; the same technique is the
self-hosted option for terrain here.
