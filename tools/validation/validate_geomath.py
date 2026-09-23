"""Prototype of VRAeroScan's look-angle math, validated against adsb.lol ground truth.

adsb.lol returns `dst` (great-circle distance, nm) and `dir` (bearing from the query
point, deg) for every aircraft. Our own observer->target computation must reproduce
those. This catches exactly the bugs that matter: lat/lon swaps, sign flips,
degree/radian mistakes.

Once this agrees, transliterate to C# as Core/GeoMath.cs.
"""
import json
import math
import urllib.request

# WGS84
A = 6378137.0
F = 1.0 / 298.257223563
E2 = F * (2.0 - F)

NM_PER_M = 1.0 / 1852.0
FT_TO_M = 0.3048


def geodetic_to_ecef(lat_deg, lon_deg, alt_m):
    lat = math.radians(lat_deg)
    lon = math.radians(lon_deg)
    sin_lat = math.sin(lat)
    cos_lat = math.cos(lat)
    # radius of curvature in the prime vertical
    n = A / math.sqrt(1.0 - E2 * sin_lat * sin_lat)
    x = (n + alt_m) * cos_lat * math.cos(lon)
    y = (n + alt_m) * cos_lat * math.sin(lon)
    z = (n * (1.0 - E2) + alt_m) * sin_lat
    return x, y, z


def ecef_to_enu(obs_lla, target_ecef):
    """Rotate the observer->target ECEF vector into the observer's local
    East/North/Up frame."""
    olat, olon, oalt = obs_lla
    ox, oy, oz = geodetic_to_ecef(olat, olon, oalt)
    dx = target_ecef[0] - ox
    dy = target_ecef[1] - oy
    dz = target_ecef[2] - oz

    lat = math.radians(olat)
    lon = math.radians(olon)
    sin_lat, cos_lat = math.sin(lat), math.cos(lat)
    sin_lon, cos_lon = math.sin(lon), math.cos(lon)

    e = -sin_lon * dx + cos_lon * dy
    n = -sin_lat * cos_lon * dx - sin_lat * sin_lon * dy + cos_lat * dz
    u = cos_lat * cos_lon * dx + cos_lat * sin_lon * dy + sin_lat * dz
    return e, n, u


def look_angles(obs_lla, tgt_lla):
    """Observer -> target azimuth (deg true, 0=N, 90=E), elevation (deg above
    horizon), and slant range (m)."""
    tgt_ecef = geodetic_to_ecef(*tgt_lla)
    e, n, u = ecef_to_enu(obs_lla, tgt_ecef)
    horiz = math.hypot(e, n)
    az = math.degrees(math.atan2(e, n)) % 360.0
    el = math.degrees(math.atan2(u, horiz))
    rng = math.sqrt(e * e + n * n + u * u)
    return az, el, rng


def great_circle(obs_lla, tgt_lla):
    """Haversine distance (m) and initial bearing (deg) - what adsb.lol's
    dst/dir should correspond to."""
    lat1, lon1 = math.radians(obs_lla[0]), math.radians(obs_lla[1])
    lat2, lon2 = math.radians(tgt_lla[0]), math.radians(tgt_lla[1])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    dist = 2 * 6371008.8 * math.asin(math.sqrt(a))  # mean earth radius
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    brg = math.degrees(math.atan2(y, x)) % 360.0
    return dist, brg


def ang_diff(a, b):
    """Smallest signed difference between two bearings, in degrees."""
    return (a - b + 180.0) % 360.0 - 180.0


def main():
    obs_lat, obs_lon, obs_alt = 47.6, -122.3, 100.0
    url = f"https://api.adsb.lol/v2/point/{obs_lat}/{obs_lon}/50"
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.load(r)

    rows = []
    for ac in data.get("ac", []):
        if "lat" not in ac or "lon" not in ac:
            continue
        if "dst" not in ac or "dir" not in ac:
            continue

        alt_baro = ac.get("alt_baro", 0)
        alt_m = 0.0 if alt_baro == "ground" else float(alt_baro) * FT_TO_M

        tgt = (ac["lat"], ac["lon"], alt_m)
        obs = (obs_lat, obs_lon, obs_alt)

        az, el, rng = look_angles(obs, tgt)
        gc_dist, gc_brg = great_circle(obs, tgt)

        rows.append({
            "hex": ac["hex"],
            "flight": (ac.get("flight") or "").strip() or "-",
            "alt_ft": alt_baro,
            "our_az": az,
            "api_dir": ac["dir"],
            "d_az": ang_diff(az, ac["dir"]),
            "gc_brg": gc_brg,
            "d_gc_brg": ang_diff(gc_brg, ac["dir"]),
            "our_slant_nm": rng * NM_PER_M,
            "our_gc_nm": gc_dist * NM_PER_M,
            "api_dst": ac["dst"],
            "d_gc_nm": gc_dist * NM_PER_M - ac["dst"],
            "el": el,
        })

    if not rows:
        print("no aircraft with dst/dir returned; try again or widen the radius")
        return

    hdr = (f"{'hex':<8}{'flight':<9}{'alt':>7}{'ourAz':>8}{'apiDir':>8}{'dAz':>7}"
           f"{'gcBrg':>8}{'dGcBrg':>8}{'gcNM':>8}{'apiDst':>8}{'dNM':>7}{'el':>7}")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['hex']:<8}{r['flight']:<9}{str(r['alt_ft']):>7}"
              f"{r['our_az']:>8.2f}{r['api_dir']:>8.1f}{r['d_az']:>7.2f}"
              f"{r['gc_brg']:>8.2f}{r['d_gc_brg']:>8.2f}"
              f"{r['our_gc_nm']:>8.2f}{r['api_dst']:>8.2f}{r['d_gc_nm']:>7.2f}"
              f"{r['el']:>7.2f}")

    print()
    print(f"n = {len(rows)}")
    max_daz = max(abs(r["d_az"]) for r in rows)
    max_dgc = max(abs(r["d_gc_brg"]) for r in rows)
    max_dnm = max(abs(r["d_gc_nm"]) for r in rows)
    print(f"max |ENU az   - api dir| = {max_daz:.3f} deg")
    print(f"max |gc bearing - api dir| = {max_dgc:.3f} deg")
    print(f"max |gc dist  - api dst| = {max_dnm:.3f} nm")


if __name__ == "__main__":
    main()
