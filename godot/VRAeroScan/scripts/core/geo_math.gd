class_name GeoMath
extends RefCounted
## Geodesy for turning an aircraft or satellite position into a direction to look.
##
## GDScript floats are 64-bit, so everything here is double precision for free. The
## one place precision is lost is sky_direction(), which returns a 32-bit Vector3 —
## deliberately last, once the numbers are small unit-vector components.
##
## Checked by tests/run_tests.gd against tests/geomath_fixture.json, which is emitted
## from tools/validation/validate_geomath.py — itself validated against live adsb.lol
## ground truth to 0.06°. Re-run the tests after touching anything here: a regression
## breaks the whole app in a way that looks like a calibration problem.
##
## WORLD FRAME (Godot is right-handed, -Z forward):
##   -Z = true north, +X = east, +Y = up.
## So an unrotated Camera3D looks due north. This differs from the Unity build, which
## used +Z north; any code ported from there needs its signs re-derived, not copied.

# WGS84 ellipsoid
const SEMI_MAJOR_AXIS := 6378137.0
const FLATTENING := 1.0 / 298.257223563
const ECCENTRICITY_SQ := FLATTENING * (2.0 - FLATTENING)

## Mean Earth radius, for great-circle work only — never for ECEF.
const MEAN_RADIUS := 6371008.8

const METERS_PER_NAUTICAL_MILE := 1852.0
const FEET_TO_METERS := 0.3048


## Earth-Centred Earth-Fixed cartesian metres, as [x, y, z] doubles.
static func geodetic_to_ecef(p: GeoPoint) -> PackedFloat64Array:
	var lat := deg_to_rad(p.latitude_deg)
	var lon := deg_to_rad(p.longitude_deg)
	var sin_lat := sin(lat)
	var cos_lat := cos(lat)

	# Radius of curvature in the prime vertical.
	var n := SEMI_MAJOR_AXIS / sqrt(1.0 - ECCENTRICITY_SQ * sin_lat * sin_lat)

	return PackedFloat64Array([
		(n + p.altitude_m) * cos_lat * cos(lon),
		(n + p.altitude_m) * cos_lat * sin(lon),
		(n * (1.0 - ECCENTRICITY_SQ) + p.altitude_m) * sin_lat,
	])


## The observer-to-target vector in the observer's local frame, as [east, north, up].
static func to_enu(observer: GeoPoint, target: GeoPoint) -> PackedFloat64Array:
	var o := geodetic_to_ecef(observer)
	var t := geodetic_to_ecef(target)
	var dx := t[0] - o[0]
	var dy := t[1] - o[1]
	var dz := t[2] - o[2]

	var lat := deg_to_rad(observer.latitude_deg)
	var lon := deg_to_rad(observer.longitude_deg)
	var sin_lat := sin(lat)
	var cos_lat := cos(lat)
	var sin_lon := sin(lon)
	var cos_lon := cos(lon)

	return PackedFloat64Array([
		-sin_lon * dx + cos_lon * dy,
		-sin_lat * cos_lon * dx - sin_lat * sin_lon * dy + cos_lat * dz,
		cos_lat * cos_lon * dx + cos_lat * sin_lon * dy + sin_lat * dz,
	])


## Where to look to see target from observer.
##
## Curvature is handled implicitly: working from the ECEF difference rotated into the
## local tangent frame, a distant low target falls below the horizon on its own. No
## fudge factor is needed or wanted.
static func to_look_angles(observer: GeoPoint, target: GeoPoint) -> LookAngles:
	var enu := to_enu(observer, target)
	var e := enu[0]
	var n := enu[1]
	var u := enu[2]

	var horizontal := sqrt(e * e + n * n)
	var azimuth := rad_to_deg(atan2(e, n))
	if azimuth < 0.0:
		azimuth += 360.0

	return LookAngles.new(azimuth, rad_to_deg(atan2(u, horizontal)), sqrt(e * e + n * n + u * u))


## Unit direction in the world frame: -Z north, +X east, +Y up.
static func sky_direction(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	var cos_el := cos(el)
	return Vector3(cos_el * sin(az), sin(el), -cos_el * cos(az))


## Great-circle distance (m) and initial bearing (deg true), as [distance, bearing].
## Only for cross-checking feeds that report ground distance, such as adsb.lol's
## dst/dir — the renderer wants to_look_angles().
static func great_circle(observer: GeoPoint, target: GeoPoint) -> PackedFloat64Array:
	var lat1 := deg_to_rad(observer.latitude_deg)
	var lon1 := deg_to_rad(observer.longitude_deg)
	var lat2 := deg_to_rad(target.latitude_deg)
	var lon2 := deg_to_rad(target.longitude_deg)
	var d_lat := lat2 - lat1
	var d_lon := lon2 - lon1

	var a := sin(d_lat / 2.0) ** 2 + cos(lat1) * cos(lat2) * sin(d_lon / 2.0) ** 2
	var distance := 2.0 * MEAN_RADIUS * asin(sqrt(a))

	var y := sin(d_lon) * cos(lat2)
	var x := cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(d_lon)
	return PackedFloat64Array([distance, wrap360(rad_to_deg(atan2(y, x)))])


## Move distance_m along bearing_deg from start, keeping altitude. Spherical, which is
## ample for dead reckoning an aircraft over the seconds between feed updates.
static func destination_point(start: GeoPoint, bearing_deg: float, distance_m: float) -> GeoPoint:
	if distance_m == 0.0:
		return start

	var lat1 := deg_to_rad(start.latitude_deg)
	var lon1 := deg_to_rad(start.longitude_deg)
	var brg := deg_to_rad(bearing_deg)
	var angular := distance_m / MEAN_RADIUS

	var sin_lat2 := sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(brg)
	var lat2 := asin(sin_lat2)
	var lon2 := lon1 + atan2(sin(brg) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin_lat2)

	# Keep longitude in [-180, 180) rather than letting it wind up.
	var lon_deg := fposmod(rad_to_deg(lon2) + 180.0, 360.0) - 180.0
	return GeoPoint.new(rad_to_deg(lat2), lon_deg, start.altitude_m)


## Smallest signed difference between two bearings, in [-180, 180).
static func bearing_delta(a_deg: float, b_deg: float) -> float:
	return fposmod(a_deg - b_deg + 180.0, 360.0) - 180.0


## Wrap any angle into [0, 360).
static func wrap360(deg: float) -> float:
	return fposmod(deg, 360.0)
