#!/usr/bin/env python3
"""Emit pole-star reference cases for the Godot app, from Skyfield.

The app finds Polaris (north) and Sigma Octantis (south) itself, from J2000 coordinates
precessed to the date and a sidereal-time hour angle, so the user can sight the star in
the glasses and set north from it (PoleStar). Skyfield is the independent check: full
precession-nutation, aberration and UT1 from IERS data. The app ignores nutation and
aberration (a few arcseconds) and refraction, so the test tolerance is 0.02 degrees.

    python3 -m venv venv && ./venv/bin/pip install skyfield
    ./venv/bin/python tools/validation/export_star_fixture.py

Writes godot/VRAeroScan/tests/star_fixture.json. Needs de421.bsp in the working directory
(Skyfield downloads it, 17 MB, on first run).
"""
import json
import os

from skyfield.api import Star, load, wgs84

# J2000 catalogue positions, no proper motion: the same constants as scripts/core/pole_star.gd.
STARS = {
    "Polaris": (37.95456067, 89.26410897),
    "Sigma Octantis": (317.19528, -88.95650),
}
OBSERVERS = {
    "Titan Missile Museum": (31.90306, -110.99861, 880.0),
    "Seattle": (47.6, -122.3, 100.0),
    "Reykjavik": (64.15, -21.94, 20.0),
    "Quito": (-0.18, -78.47, 2850.0),
    "Cape Town": (-33.92, 18.42, 20.0),
    "Sydney": (-33.87, 151.21, 40.0),
    "Ushuaia": (-54.8, -68.3, 10.0),
}
TIMES = [(2026, 10, 4, 3, 0, 0), (2026, 10, 4, 9, 30, 0), (2026, 10, 4, 14, 0, 0),
         (2026, 10, 4, 21, 15, 0), (2027, 3, 21, 6, 0, 0), (2028, 7, 1, 1, 0, 0)]


def main():
    ts = load.timescale()
    eph = load("de421.bsp")
    earth = eph["earth"]
    cases = []
    for oname, (lat, lon, alt) in OBSERVERS.items():
        site = earth + wgs84.latlon(lat, lon, elevation_m=alt)
        for time in TIMES:
            t = ts.utc(*time)
            for sname, (ra, dec) in STARS.items():
                star = Star(ra_hours=ra / 15.0, dec_degrees=dec)
                alt_el, az, _ = site.at(t).observe(star).apparent().altaz()
                cases.append({
                    "observerName": oname, "observer": [lat, lon, alt], "star": sname,
                    "unix": t.utc_datetime().timestamp(),
                    "azimuthDeg": az.degrees, "elevationDeg": alt_el.degrees,
                })
    out = os.path.join(os.path.dirname(__file__), "..", "..", "godot", "VRAeroScan", "tests", "star_fixture.json")
    with open(out, "w") as f:
        json.dump({"cases": cases}, f, indent=1)
    print("wrote %d cases to %s" % (len(cases), os.path.normpath(out)))


if __name__ == "__main__":
    main()
