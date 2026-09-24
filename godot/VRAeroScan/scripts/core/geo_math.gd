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
	var t := geodetic_to_ecef(target)
	return enu_in_frame(local_frame(observer), t[0], t[1], t[2])


## Where to look to see target from observer.
##
## Curvature is handled implicitly: working from the ECEF difference rotated into the
## local tangent frame, a distant low target falls below the horizon on its own. No
## fudge factor is needed or wanted.
static func to_look_angles(observer: GeoPoint, target: GeoPoint) -> LookAngles:
	var t := geodetic_to_ecef(target)
	return look_angles_in_frame(local_frame(observer), t[0], t[1], t[2])


## The observer's local tangent frame, precomputed so that many targets given in ECEF —
## a satellite catalogue — cost a subtraction and nine multiplies each rather than a
## round of trig. Layout: [ox, oy, oz, east xyz, north xyz, up xyz].
static func local_frame(observer: GeoPoint) -> PackedFloat64Array:
	var o := geodetic_to_ecef(observer)
	var lat := deg_to_rad(observer.latitude_deg)
	var lon := deg_to_rad(observer.longitude_deg)
	var sin_lat := sin(lat)
	var cos_lat := cos(lat)
	var sin_lon := sin(lon)
	var cos_lon := cos(lon)
	return PackedFloat64Array([
		o[0], o[1], o[2],
		-sin_lon, cos_lon, 0.0,
		-sin_lat * cos_lon, -sin_lat * sin_lon, cos_lat,
		cos_lat * cos_lon, cos_lat * sin_lon, sin_lat,
	])


## ECEF metres -> [east, north, up] metres from the frame's observer.
static func enu_in_frame(f: PackedFloat64Array, x: float, y: float, z: float) -> PackedFloat64Array:
	var dx := x - f[0]
	var dy := y - f[1]
	var dz := z - f[2]
	return PackedFloat64Array([
		f[3] * dx + f[4] * dy + f[5] * dz,
		f[6] * dx + f[7] * dy + f[8] * dz,
		f[9] * dx + f[10] * dy + f[11] * dz,
	])


## ECEF metres -> look angles from the frame's observer.
static func look_angles_in_frame(f: PackedFloat64Array, x: float, y: float, z: float) -> LookAngles:
	var enu := enu_in_frame(f, x, y, z)
	var e := enu[0]
	var n := enu[1]
	var u := enu[2]

	var horizontal := sqrt(e * e + n * n)
	var azimuth := rad_to_deg(atan2(e, n))
	if azimuth < 0.0:
		azimuth += 360.0

	return LookAngles.new(azimuth, rad_to_deg(atan2(u, horizontal)), sqrt(e * e + n * n + u * u))


## Direction only, for things effectively at infinity (the sun): the observer's
## position drops out, so this takes an ECEF unit vector rather than a point.
static func direction_look_angles(f: PackedFloat64Array, dx: float, dy: float, dz: float) -> LookAngles:
	return look_angles_in_frame(f, f[0] + dx, f[1] + dy, f[2] + dz)


## ECEF metres -> WGS84 geodetic. Bowring's method, iterated, which is
## sub-millimetre from the ground to beyond GEO.
static func ecef_to_geodetic(x: float, y: float, z: float) -> GeoPoint:
	var a := SEMI_MAJOR_AXIS
	var b := a * (1.0 - FLATTENING)
	var ep2 := (a * a - b * b) / (b * b)
	var p := sqrt(x * x + y * y)
	var lon := atan2(y, x)

	# beta is the parametric latitude; each pass refines it from the latest estimate.
	var beta := atan2(z * a, p * b)
	var lat := 0.0
	for i in 3:
		lat = atan2(z + ep2 * b * pow(sin(beta), 3.0), p - ECCENTRICITY_SQ * a * pow(cos(beta), 3.0))
		beta = atan2((1.0 - FLATTENING) * sin(lat), cos(lat))

	var sin_lat := sin(lat)
	var n := a / sqrt(1.0 - ECCENTRICITY_SQ * sin_lat * sin_lat)
	var alt: float
	if absf(cos(lat)) > 1e-9:
		alt = p / cos(lat) - n
	else:
		alt = absf(z) - b
	return GeoPoint.new(rad_to_deg(lat), rad_to_deg(lon), alt)


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
