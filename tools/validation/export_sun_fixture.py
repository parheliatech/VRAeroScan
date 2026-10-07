#!/usr/bin/env python3
"""Emit Sun position reference cases for the Godot app, from Skyfield.

The shadow sighting sets north from the Sun's azimuth: a shadow points directly away from
the Sun. The app's Sun is the Astronomical Almanac's low-precision series (Solar.gd, good to
~0.01 deg) turned into az/el with sidereal time. Skyfield (JPL DE421, full precession-
nutation, aberration) is the independent check. Neither includes refraction.

    python3 -m venv venv && ./venv/bin/pip install skyfield
    ./venv/bin/python tools/validation/export_sun_fixture.py

Writes godot/VRAeroScan/tests/sun_fixture.json. Needs de421.bsp in the working directory
(Skyfield downloads it, 17 MB, on first run).
"""
import json
import os

from skyfield.api import load, wgs84

OBSERVERS = {
    "Titan Missile Museum": (31.90306, -110.99861, 880.0),
    "Seattle": (47.6, -122.3, 100.0),
    "Reykjavik": (64.15, -21.94, 20.0),
    "Quito": (-0.18, -78.47, 2850.0),
    "Cape Town": (-33.92, 18.42, 20.0),
    "Sydney": (-33.87, 151.21, 40.0),
    "Tokyo": (35.68, 139.69, 40.0),
}
# Through a day in each season, so the Sun is up somewhere at every time.
TIMES = [(2026, 10, 4, h, 17, 0) for h in range(0, 24, 3)] + \
        [(2027, 6, 21, 18, 0, 0), (2027, 12, 21, 18, 0, 0), (2027, 3, 20, 6, 30, 0)]


def main():
    ts = load.timescale()
    eph = load("de421.bsp")
    earth, sun = eph["earth"], eph["sun"]
    cases = []
    for name, (lat, lon, alt) in OBSERVERS.items():
        site = earth + wgs84.latlon(lat, lon, elevation_m=alt)
        for time in TIMES:
            t = ts.utc(*time)
            el, az, _ = site.at(t).observe(sun).apparent().altaz()
            cases.append({"observerName": name, "observer": [lat, lon, alt],
                          "unix": t.utc_datetime().timestamp(),
                          "azimuthDeg": az.degrees, "elevationDeg": el.degrees})
    out = os.path.join(os.path.dirname(__file__), "..", "..", "godot", "VRAeroScan", "tests", "sun_fixture.json")
    with open(out, "w") as f:
        json.dump({"cases": cases}, f, indent=1)
    print("wrote %d cases to %s" % (len(cases), os.path.normpath(out)))


if __name__ == "__main__":
    main()
