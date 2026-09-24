#!/usr/bin/env python3
"""Emit end-to-end satellite reference cases for the Godot app, from Skyfield.

sgp4_fixture.json proves the propagator's arithmetic in TEME. It cannot catch what
happens around it: reading CelesTrak's OMM JSON (units, epoch format), turning TEME
into Earth-fixed coordinates with sidereal time, the observer's local frame, and
whether the satellite is in sunlight. Each of those fails silently too — a GMST sign
error puts every satellite at the wrong azimuth by a plausible-looking amount.

Skyfield is an independent implementation of that whole chain (full IAU precession-
nutation, UT1 from IERS data, JPL DE421 for the sun), so agreement with it checks the
app's shortcuts (GMST-only TEME->ECEF, low-precision sun, cylindrical shadow) as well
as its correctness.

Live CelesTrak elements are fetched once and FROZEN into the fixture along with the
expected answers, so the Godot test is offline and deterministic.

    python3 -m venv venv && ./venv/bin/pip install sgp4 skyfield
    ./venv/bin/python export_satellite_fixture.py                    # fresh live elements
    ./venv/bin/python export_satellite_fixture.py --reuse-elements   # same elements, new cases

Writes ../../godot/VRAeroScan/tests/satellite_fixture.json. Downloads de421.bsp (17 MB)
into the working directory on first run.
"""
import json
import os
import sys
import urllib.request

from skyfield.api import EarthSatellite, load, wgs84

# Chosen to cover every orbit regime the app classifies, and SDP4's resonance paths.
CATALOG_NUMBERS = [
    25544,  # ISS (ZARYA) — manned, LEO
    48274,  # CSS (TIANHE) — manned, LEO
    20580,  # HST — LEO, 28.5 deg inclination
    44714,  # STARLINK-1008 — Starlink
    694,    # ATLAS CENTAUR 2 — eccentric LEO, from the visual group
    39166,  # NAVSTAR 68 (GPS) — MEO, 12 h resonant (deep space)
    41866,  # GOES 16 — GEO, 24 h resonant (deep space)
    40296,  # MERIDIAN 7 — Molniya orbit: HEO, 12 h resonant, e ~0.7
]

OBSERVERS = [
    ("Tucson", 32.2226, -110.9747, 730.0),
    ("Sydney", -33.8688, 151.2093, 30.0),
    ("Tromso", 69.65, 18.96, 20.0),
]

# Hours after the base time. The base is the ISS element epoch rounded down to the
# hour, so these cases sit within ~1.5 days of their elements, as the app's would.
# (The night-pass cases added below may be up to ten days out: they compare two
# implementations on the same elements, so age does not matter there.)
OFFSETS_H = [0.5, 7.25, 31.0]


def fetch_omm(catnr):
    url = f"https://celestrak.org/NORAD/elements/gp.php?CATNR={catnr}&FORMAT=json"
    req = urllib.request.Request(url, headers={"User-Agent": "VRAeroScan-validation/0.1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode()
    try:
        records = json.loads(body)
    except json.JSONDecodeError:
        print(f"  {catnr}: not JSON ({body[:60]!r}); skipped")
        return None
    return records[0] if records else None


def main():
    ts = load.timescale()
    eph = load("de421.bsp")
    sun, earth = eph["sun"], eph["earth"]

    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "godot", "VRAeroScan", "tests", "satellite_fixture.json")

    if "--reuse-elements" in sys.argv:
        # Keep the frozen elements and only recompute cases, so a change to the case
        # list does not also move every existing answer.
        with open(path) as fh:
            records = json.load(fh)["omm"]
    else:
        records = [r for r in (fetch_omm(n) for n in CATALOG_NUMBERS) if r]
    iss = next(r for r in records if r["NORAD_CAT_ID"] == 25544)
    base = ts.utc(*[int(x) for x in iss["EPOCH"][:13].replace("T", "-").split("-")])

    # Plus the next ISS pass over Tucson, at culmination, so LEO satellites are covered
    # ABOVE the horizon too, where the app actually draws them.
    iss_sat = EarthSatellite.from_omm(ts, iss)
    tucson = wgs84.latlon(*OBSERVERS[0][1:3], elevation_m=OBSERVERS[0][3])
    times, events = iss_sat.find_events(tucson, base, ts.tt_jd(base.tt + 2.0), altitude_degrees=10.0)
    culmination = next(t for t, e in zip(times, events) if e == 1)
    offsets_h = OFFSETS_H + [(culmination.tt - base.tt) * 24.0]

    # And two night-time moments: the ISS up in a dark Tucson sky and sunlit, and up in
    # a dark sky but in Earth's shadow, so the app's shadow flag (a label, never a
    # filter) is checked at night overhead. Searched over ten days; both are common.
    times, events = iss_sat.find_events(tucson, base, ts.tt_jd(base.tt + 10.0), altitude_degrees=10.0)
    sun_el = lambda t: (earth + tucson).at(t).observe(sun).apparent().altaz()[0].degrees
    wanted = {True: None, False: None}
    for t, e in zip(times, events):
        if e == 1 and sun_el(t) < -12.0 and wanted[bool(iss_sat.at(t).is_sunlit(eph))] is None:
            wanted[bool(iss_sat.at(t).is_sunlit(eph))] = t
    for lit, t in wanted.items():
        if t is None:
            print(f"  no {'sunlit' if lit else 'eclipsed'} night pass of the ISS over Tucson found")
        else:
            offsets_h.append((t.tt - base.tt) * 24.0)

    cases = []
    for rec in records:
        sat = EarthSatellite.from_omm(ts, rec)
        for obs_name, lat, lon, alt in OBSERVERS:
            site = wgs84.latlon(lat, lon, elevation_m=alt)
            for h in offsets_h:
                t = ts.tt_jd(base.tt + h / 24.0)
                topo = (sat - site).at(t)
                el, az, dist = topo.altaz()
                sun_el, sun_az, _ = (earth + site).at(t).observe(sun).apparent().altaz()
                geo = wgs84.geographic_position_of(sat.at(t))
                cases.append({
                    "norad": rec["NORAD_CAT_ID"],
                    "observer": [lat, lon, alt],
                    "observerName": obs_name,
                    "unix": round(float((t.utc_datetime().timestamp())), 6),
                    "azimuthDeg": az.degrees,
                    "elevationDeg": el.degrees,
                    "rangeKm": dist.km,
                    "subLatDeg": geo.latitude.degrees,
                    "subLonDeg": geo.longitude.degrees,
                    "altitudeKm": geo.elevation.km,
                    "sunlit": bool(sat.at(t).is_sunlit(eph)),
                    "sunAzimuthDeg": sun_az.degrees,
                    "sunElevationDeg": sun_el.degrees,
                })

    out = {
        "_comment": ("End-to-end satellite references from Skyfield (IAU 2000 frames, "
                     "DE421 sun), for CelesTrak OMM elements frozen at generation. "
                     "Generated by tools/validation/export_satellite_fixture.py."),
        "omm": records,
        "cases": cases,
    }
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"{len(records)} satellites, {len(cases)} cases -> {os.path.normpath(path)}")
    for rec in records:
        print(f"  {rec['NORAD_CAT_ID']:>6}  {rec['OBJECT_NAME']:<24} epoch {rec['EPOCH']}"
              f"  n={rec['MEAN_MOTION']:.4f} rev/day")


if __name__ == "__main__":
    main()
