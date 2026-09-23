# Validation harnesses

Python mirrors of the C# logic, checked against live data. They exist because two
pieces of this app fail *silently* when wrong — the look-angle maths and the aircraft
classifier both produce plausible-looking output when they are subtly broken, and the
symptom is markers pointing at empty sky rather than an exception.

Run them with a plain `python3`; no dependencies beyond the standard library.

## `validate_geomath.py`

Checks `Assets/Scripts/Core/GeoMath.cs` against ground truth.

adsb.lol reports `dst` (great-circle distance, nm) and `dir` (bearing from the query
point, degrees) for every aircraft. Our own observer-to-target computation must
reproduce both. This catches precisely the bugs that matter and are otherwise
invisible: latitude/longitude swaps, sign flips, and degree/radian mistakes.

Result on 2026-09-23, 7 aircraft near Seattle:

```
max |ENU az     - api dir| = 0.060 deg    (adsb.lol rounds dir to 1 decimal)
max |gc bearing - api dir| = 0.049 deg
max |gc dist    - api dst| = 0.020 nm
```

If you change `GeoMath.cs`, re-run this. A regression here breaks the entire app in a
way that looks like a calibration problem.

**Correction, 2026-09-23, from a 72-aircraft rerun:** `dir` is a *spherical*
great-circle bearing rounded to 0.1°. Great-circle bearing matches it to 0.049°, the
rounding bound, with zero mean bias. The ENU azimuth the app actually points along is
ellipsoidal (WGS84) and differs from `dir` by up to ~0.13° at mid-latitudes. That is
correct, not an error — the 0.060° above was a lucky 7-aircraft sample. Compare
great-circle to `dir`; never tighten a tolerance on ENU-vs-`dir`.

## `export_geomath_fixture.py`

Freezes this validated maths into `godot/VRAeroScan/tests/geomath_fixture.json`: 36
cases chosen for the silent bugs (southern/western hemispheres, the antimeridian, high
latitude, below-horizon, near-zenith). The Godot tests check the GDScript `GeoMath`
against it to 1e-6°. `godot/VRAeroScan/tests/live_check.gd` is the live-data twin of
`validate_geomath.py`, running the real GDScript request, parser and maths.

## `validate_classifier.py`

Mirrors `AircraftClassifier` (now `godot/VRAeroScan/scripts/data/aircraft_classifier.gd`; originally the Unity C#) and measures coverage across
several busy metros, reporting what it could not classify.

This is how the classifier's real bugs were found, and none of them would have shown
up in a unit test written from assumptions:

- The airliner rule originally required a letter followed by digits only, which missed
  `A21N`, `A20N`, `B38M`, `B77L` — i.e. most of the traffic actually in the sky, since
  modern variant designators end in a letter.
- Emitter categories `C0`-`C7` are ground vehicles, roughly 3% of returns.
- `TWR` entries are radio towers with no emitter category at all. They would have
  rendered as aircraft hanging motionless in the sky.

Result on 2026-09-23, 892 aircraft across Los Angeles, New York, London and Miami:
**2.7% unclassified**, 33 surface vehicles correctly excluded.

The unclassified remainder is mostly European light aircraft and gliders. Growing the
type tables is the fix; the tables are the first thing to check when something shows
up unlabelled.

## `validate_sgp4.py`

Needs `pip install sgp4` (see `requirements.txt`); the other two need nothing.

Satellite propagation is the third silent-failure piece, and the hardest to check,
because the feed carries no ground truth: CelesTrak gives orbital *elements*, not
positions. So the ground truth comes from the canonical verification suite instead.

Three stages, in order:

1. **Verify the oracle.** Runs python-sgp4 — which wraps Vallado's reference C++ —
   against the published `SGP4-VER.TLE` / `tcppver.out` vectors, both of which ship
   inside the package, so no download is needed. Result: **710 state vectors, worst
   position delta 0.117 mm.**
2. **Emit `sgp4_fixture.json`** (`--emit-fixture`), so whichever propagator VRAeroScan
   ends up using can be checked against the same numbers from C# or GDScript, with no
   Python in the build. 32 satellites, 354 state vectors, TEME frame, WGS72 gravity model.
3. **Live ISS cross-check.** The static vectors prove the arithmetic but cannot catch
   mistakes *around* it — wrong elements, mishandled TLE epoch, confused time scales.
   This does, and it most resembles what the app actually does. Current agreement:
   **0.1 km.**

The verification suite is deliberately nasty: it includes the Lyddane fix regression
case, a 12-hour resonant Molniya orbit, deep-space cases and decayed satellites. An
implementation that passes all of it is very unlikely to be subtly wrong.

### Two bugs this found in itself, worth knowing about

**Leading zeros.** `SGP4-VER.TLE` pads satellite numbers to five digits (`00005`)
while `tcppver.out` does not (`5`). Comparing them as strings silently skipped six
satellites — including the headline TEME example and the Lyddane-fix case, the two
most valuable tests in the suite. The harness reported a clean pass on the remaining
603 vectors. A validator that quietly tests less than it claims is worse than none,
so it now reports what it *could not* check, and normalises to `int`.

**Bad reference source.** The live check first used open-notify.org and disagreed by
~4,900 km. That was not our bug: open-notify's reported position matched our own
propagation at +13 minutes, meaning it serves stale data, and even at that offset
left a 139 km residual. The same code agrees with wheretheiss.at to under 5 km.
Recorded because "the reference must be wrong" is usually the wrong conclusion, and
this is the uncommon case where it held — which is exactly why it was worth proving
instead of assuming in either direction.

## Why these exist at all

All three cover failures that produce *plausible* output. Nothing here throws an
exception when it is wrong; it just points at empty sky. That is the whole argument
for checking against live data and published vectors rather than against assumptions —
every real bug above was invisible to inspection and would have survived a unit test
written from the same assumptions that produced the code.
