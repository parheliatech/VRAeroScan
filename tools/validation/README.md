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

## `validate_classifier.py`

Mirrors `Assets/Scripts/DataFeeds/AircraftClassifier.cs` and measures coverage across
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

## A note on what these do *not* cover

Neither harness touches SGP4. Satellite propagation is the third piece that fails
silently, and it has no equivalent free ground truth in the feed itself — validating
it needs reference test vectors or a known-good implementation to compare against.
That remains an open decision; see `PROJECT_NOTES.md` §7.
