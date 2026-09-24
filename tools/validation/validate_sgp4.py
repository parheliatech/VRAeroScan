#!/usr/bin/env python3
"""SGP4 validation harness.

Satellite propagation is the third piece of VRAeroScan that fails *silently*. A typo
in a drag coefficient does not crash; it puts a satellite in a plausible orbit that is
off by a degree, which in a finder app means a marker sitting confidently on empty sky.

Unlike the aircraft path, the feed carries no ground truth to check against: CelesTrak
gives orbital elements, not positions. So the ground truth has to come from the
canonical verification suite instead.

What this does, in order:

  1. Verifies the ORACLE. Runs python-sgp4 (which wraps Vallado's reference C++)
     against the published SGP4-VER.TLE / tcppver.out vectors. If this disagrees,
     nothing below it can be trusted.
  2. Emits a fixture for the app (godot/VRAeroScan/tests/sgp4_fixture.json), so the
     GDScript port in scripts/satellites/sgp4.gd is checked against the same numbers
     without needing Python at test time.
  3. Cross-checks a live ISS position against an independent public tracker, which
     catches whole-pipeline mistakes the static vectors cannot: wrong epoch handling,
     UTC/TAI confusion, stale elements.

The verification suite is chosen deliberately to be nasty. It includes the Lyddane
fix case, a 12-hour resonant Molniya orbit, deep-space cases and decayed satellites.
An implementation that passes all of it is very unlikely to be subtly wrong.

Usage:
    python3 validate_sgp4.py                 # verify oracle + live ISS check
    python3 validate_sgp4.py --emit-fixture  # also write the app's sgp4_fixture.json

Requires:  pip install sgp4
"""

import argparse
import json
import math
import os
import sys
import urllib.request

try:
    from sgp4.api import Satrec, WGS72, accelerated
except ImportError:
    sys.exit("sgp4 not installed.  python3 -m venv venv && ./venv/bin/pip install sgp4")

import sgp4 as sgp4_pkg

DATA_DIR = os.path.dirname(sgp4_pkg.__file__)
VER_TLE = os.path.join(DATA_DIR, "SGP4-VER.TLE")
TCPPVER = os.path.join(DATA_DIR, "tcppver.out")

# A correct implementation reproduces the reference to far better than this. The
# reference itself is printed to 8 decimal places in km, i.e. 0.01 mm.
POSITION_TOLERANCE_KM = 1e-6
VELOCITY_TOLERANCE_KMS = 1e-7


# --------------------------------------------------------------------------- parsing

def parse_ver_tle(path):
    """Yield (satnum, line1, line2, start_min, stop_min, step_min).

    A standard TLE line 2 is 69 characters. This file appends the propagation
    schedule after that, which is what makes it a test suite rather than just
    elements.
    """
    cases = []
    line1 = None

    with open(path) as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("#") or not line.strip():
                continue

            if line.startswith("1 "):
                line1 = line[:69]
            elif line.startswith("2 ") and line1 is not None:
                line2 = line[:69]
                extra = line[69:].split()
                if len(extra) >= 3:
                    start, stop, step = (float(extra[0]), float(extra[1]), float(extra[2]))
                else:
                    start, stop, step = 0.0, 1440.0, 120.0
                # Normalise to int: the TLE pads to 5 digits ("00005") while the
                # expected-output file does not ("5"). Comparing them as strings
                # silently skipped six satellites, including the headline TEME
                # example and the Lyddane-fix regression case - the two most
                # valuable tests in the suite.
                cases.append((int(line1[2:7]), line1, line2, start, stop, step))
                line1 = None

    return cases


def parse_tcppver(path):
    """Parse the expected-output file into {satnum: [(tsince, x,y,z, vx,vy,vz), ...]}.

    Rows after the first carry extra orbital-element columns which are not checked
    here; position and velocity are what the propagator is responsible for.
    """
    expected = {}
    current = None

    with open(path) as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                continue

            if line.rstrip().endswith("xx"):
                current = int(line.split()[0])
                expected[current] = []
                continue

            if current is None:
                continue

            parts = line.split()
            # Error rows carry text rather than 7 leading numbers; skip them, the
            # oracle reports the same errors via its error code.
            if len(parts) < 7:
                continue
            try:
                vals = [float(p) for p in parts[:7]]
            except ValueError:
                continue
            expected[current].append(tuple(vals))

    return expected


# ----------------------------------------------------------------- oracle verification

def verify_oracle():
    """Check python-sgp4 against the published vectors."""
    cases = parse_ver_tle(VER_TLE)
    expected = parse_tcppver(TCPPVER)

    print(f"SGP4 reference suite: {len(cases)} satellites, "
          f"{sum(len(v) for v in expected.values())} expected state vectors")
    print(f"python-sgp4 C++ accelerated: {accelerated}\n")

    worst_pos = 0.0
    worst_vel = 0.0
    worst_case = None
    checked = 0
    skipped_error = 0
    missing = []

    for satnum, line1, line2, start, stop, step in cases:
        if satnum not in expected:
            missing.append(satnum)
            continue

        sat = Satrec.twoline2rv(line1, line2, WGS72)

        for row in expected[satnum]:
            tsince = row[0]
            err, r, v = sat.sgp4_tsince(tsince)

            if err != 0:
                # The suite includes deliberately decayed/invalid cases.
                skipped_error += 1
                continue

            dp = math.dist(r, row[1:4])
            dv = math.dist(v, row[4:7])

            if dp > worst_pos:
                worst_pos, worst_case = dp, (satnum, tsince)
            worst_vel = max(worst_vel, dv)
            checked += 1

    print(f"  state vectors checked : {checked}")
    print(f"  error-code rows skipped: {skipped_error}")
    if missing:
        print(f"  satellites with no expected output: "
              f"{', '.join(str(m) for m in missing)}")
    print(f"  worst position delta  : {worst_pos:.3e} km   ({worst_pos*1e6:.3f} mm)")
    print(f"  worst velocity delta  : {worst_vel:.3e} km/s")
    if worst_case:
        print(f"  worst case            : sat {worst_case[0]} at t+{worst_case[1]:g} min")

    ok = worst_pos <= POSITION_TOLERANCE_KM and worst_vel <= VELOCITY_TOLERANCE_KMS
    print(f"\n  ORACLE {'VERIFIED' if ok else 'FAILED'} "
          f"(tolerance {POSITION_TOLERANCE_KM:g} km / {VELOCITY_TOLERANCE_KMS:g} km/s)")
    return ok


# ------------------------------------------------------------------------ app fixture

def emit_fixture(path, max_rows_per_sat=12):
    """Write a compact fixture the Godot tests can consume without Python.

    TEME position/velocity is what SGP4 natively produces, so that is what gets
    compared. Converting to look angles happens downstream in GeoMath, which is
    already independently validated - keeping the two layers separately testable
    means a failure points at one of them rather than at "somewhere in satellites".
    """
    cases = parse_ver_tle(VER_TLE)
    expected = parse_tcppver(TCPPVER)

    out = {
        "_comment": (
            "SGP4 reference vectors from Vallado's published verification suite "
            "(SGP4-VER.TLE / tcppver.out, shipped with python-sgp4). Position in km "
            "and velocity in km/s, TEME frame, WGS72 gravity model. Generated by "
            "tools/validation/validate_sgp4.py."
        ),
        "gravityModel": "WGS72",
        "frame": "TEME",
        "positionToleranceKm": 1e-4,
        "velocityToleranceKmPerSec": 1e-5,
        "satellites": [],
    }

    for satnum, line1, line2, start, stop, step in cases:
        rows = expected.get(satnum)
        if not rows:
            continue

        sat = Satrec.twoline2rv(line1, line2, WGS72)
        samples = []

        # Spread the samples across the case's full time span rather than taking the
        # first N, so late-time drag and resonance terms stay covered.
        stride = max(1, len(rows) // max_rows_per_sat)
        for row in rows[::stride][:max_rows_per_sat]:
            tsince = row[0]
            err, r, v = sat.sgp4_tsince(tsince)
            if err != 0:
                continue
            samples.append({
                "tsinceMin": tsince,
                "r": [round(c, 8) for c in r],
                "v": [round(c, 9) for c in v],
            })

        if samples:
            out["satellites"].append({
                "satnum": satnum,
                "line1": line1,
                "line2": line2,
                "samples": samples,
            })

    with open(path, "w") as fh:
        json.dump(out, fh, indent=2)

    n = sum(len(s["samples"]) for s in out["satellites"])
    print(f"\n  fixture written: {path}")
    print(f"  {len(out['satellites'])} satellites, {n} state vectors")


# ------------------------------------------------------------------- live sanity check

def live_iss_check():
    """Propagate the current ISS elements and compare against an independent tracker.

    The static vectors prove the propagator's arithmetic. They cannot catch mistakes
    in everything *around* it - fetching the wrong elements, mishandling the TLE
    epoch, confusing time scales - because those live outside the algorithm. This
    does, and it is the check that most resembles what the app actually does.
    """
    print("\n" + "=" * 70)
    print("LIVE CROSS-CHECK: ISS")
    print("=" * 70)

    # Reference is wheretheiss.at, NOT open-notify.
    #
    # open-notify was tried first and disagreed by ~4,900 km. It was not our bug:
    # its reported position matched our own propagation at +13 minutes, i.e. it
    # serves stale positions, and even at that offset it left a 139 km residual.
    # Against wheretheiss.at the same code agrees to under 5 km. Noted here because
    # "the reference is wrong" is a tempting and usually incorrect conclusion, and
    # this is the rare case where it held up - it was worth proving rather than
    # assuming in either direction.
    try:
        url = ("https://celestrak.org/NORAD/elements/gp.php"
               "?CATNR=25544&FORMAT=TLE")
        with urllib.request.urlopen(url, timeout=30) as r:
            tle = [l.strip() for l in r.read().decode().splitlines() if l.strip()]
        if len(tle) < 3:
            print("  could not fetch ISS TLE; skipping")
            return True
        line1, line2 = tle[1], tle[2]

        with urllib.request.urlopen("https://api.wheretheiss.at/v1/satellites/25544",
                                    timeout=30) as r:
            live = json.load(r)
    except Exception as e:
        print(f"  network unavailable ({e}); skipping - this check is advisory")
        return True

    ts = float(live["timestamp"])
    ref_lat = float(live["latitude"])
    ref_lon = float(live["longitude"])

    sat = Satrec.twoline2rv(line1, line2, WGS72)

    # Unix time -> Julian date.
    jd = ts / 86400.0 + 2440587.5
    err, r_teme, _ = sat.sgp4(math.floor(jd) + 0.5, jd - (math.floor(jd) + 0.5))
    if err != 0:
        print(f"  propagation error {err}")
        return False

    lat, lon = teme_to_geodetic_latlon(r_teme, jd)

    dlat = lat - ref_lat
    dlon = (lon - ref_lon + 180.0) % 360.0 - 180.0
    # Rough ground distance, adequate for an order-of-magnitude check.
    ground_km = math.hypot(dlat, dlon * math.cos(math.radians(lat))) * 111.32

    print(f"  TLE epoch         : {sat.epochyr:02d}-{sat.epochdays:.4f}")
    print(f"  our position      : {lat:8.3f}, {lon:9.3f}")
    print(f"  wheretheiss.at    : {ref_lat:8.3f}, {ref_lon:9.3f}")
    print(f"  ground difference : {ground_km:.1f} km")

    # The reference is itself an SGP4 propagation of possibly different elements, so
    # this is a gross-error check rather than a precision one. Single-digit km is
    # normal agreement; hundreds would mean something structural is wrong. The ISS
    # travels 7.7 km/s, so a few km is also just clock skew between the two services.
    ok = ground_km < 50.0
    print(f"\n  {'AGREES' if ok else 'DISAGREES'} "
          f"(expect < 50 km; both sides propagate their own elements)")
    return ok


def teme_to_geodetic_latlon(r_teme, jd):
    """TEME -> geodetic latitude/longitude. Enough for a sanity check.

    Rotates by Greenwich Mean Sidereal Time to get an Earth-fixed frame, then solves
    for geodetic latitude iteratively on the WGS84 ellipsoid. Polar motion and the
    small TEME/PEF offset are ignored, which costs far less than this check's
    threshold.
    """
    a = 6378.137
    f = 1.0 / 298.257223563
    e2 = f * (2.0 - f)

    t = (jd - 2451545.0) / 36525.0
    gmst_sec = (67310.54841 + (876600.0 * 3600.0 + 8640184.812866) * t
                + 0.093104 * t * t - 6.2e-6 * t * t * t)
    gmst = math.radians((gmst_sec % 86400.0) / 240.0)

    x, y, z = r_teme
    xf = x * math.cos(gmst) + y * math.sin(gmst)
    yf = -x * math.sin(gmst) + y * math.cos(gmst)

    lon = math.degrees(math.atan2(yf, xf))
    lon = (lon + 540.0) % 360.0 - 180.0

    p = math.hypot(xf, yf)
    lat = math.atan2(z, p * (1.0 - e2))
    for _ in range(8):
        n = a / math.sqrt(1.0 - e2 * math.sin(lat) ** 2)
        alt = p / math.cos(lat) - n
        lat = math.atan2(z, p * (1.0 - e2 * n / (n + alt)))

    return math.degrees(lat), lon


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--emit-fixture", action="store_true",
                    help="write the Godot tests' sgp4_fixture.json")
    ap.add_argument("--skip-live", action="store_true",
                    help="skip the network-dependent ISS cross-check")
    args = ap.parse_args()

    print("=" * 70)
    print("ORACLE VERIFICATION: python-sgp4 vs published reference vectors")
    print("=" * 70)
    ok = verify_oracle()

    if args.emit_fixture:
        here = os.path.dirname(os.path.abspath(__file__))
        emit_fixture(os.path.join(here, "..", "..", "godot", "VRAeroScan", "tests",
                                  "sgp4_fixture.json"))

    if not args.skip_live:
        ok = live_iss_check() and ok

    print()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
