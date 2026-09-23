"""Emit look-angle reference cases for the GDScript port of GeoMath.

validate_geomath.py proves the Python maths against live adsb.lol ground truth. This
freezes that same maths into a fixture, so the Godot side is checked against a
validated oracle instead of against whatever the port happens to compute.

Cases are chosen for the bugs that fail silently: southern and western hemispheres
(sign flips), the antimeridian (longitude wrap), high latitude, targets below the
horizon (curvature), and targets straight overhead (azimuth undefined).

    python3 export_geomath_fixture.py > ../../godot/VRAeroScan/tests/geomath_fixture.json
"""
import json

from validate_geomath import great_circle, look_angles

OBSERVERS = [
    ("Seattle", (47.6, -122.3, 100.0)),
    ("Los Angeles", (34.0522, -118.2437, 90.0)),
    ("Sydney", (-33.8688, 151.2093, 30.0)),
    ("Antimeridian Fiji", (-17.7, 179.9, 10.0)),
    ("Tromso", (69.65, 18.96, 20.0)),
    ("Quito", (-0.18, -78.47, 2850.0)),
]

# (label, dlat, dlon, altitude m) relative to the observer.
OFFSETS = [
    ("north 30nm FL350", 0.5, 0.0, 10668.0),
    ("east low", 0.0, 0.3, 1500.0),
    ("south-west", -0.4, -0.6, 7000.0),
    ("across the antimeridian", 0.1, 0.3, 9000.0),
    ("far and low, below horizon", 2.5, 2.5, 300.0),
    ("nearly overhead", 0.001, 0.001, 11000.0),
]


def main():
    cases = []
    for obs_name, obs in OBSERVERS:
        for label, dlat, dlon, alt in OFFSETS:
            lon = obs[1] + dlon
            lon = (lon + 540.0) % 360.0 - 180.0
            tgt = (obs[0] + dlat, lon, alt)
            az, el, rng = look_angles(obs, tgt)
            dist, brg = great_circle(obs, tgt)
            cases.append({
                "name": f"{obs_name}: {label}",
                "observer": list(obs),
                "target": list(tgt),
                "azimuth_deg": az,
                "elevation_deg": el,
                "range_m": rng,
                "gc_distance_m": dist,
                "gc_bearing_deg": brg,
            })

    json.dump({"source": "tools/validation/validate_geomath.py", "cases": cases},
              fp=__import__("sys").stdout, indent=1)


if __name__ == "__main__":
    main()
