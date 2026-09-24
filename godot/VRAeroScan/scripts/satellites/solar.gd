class_name Solar
extends RefCounted
## Where the sun is, and whether a satellite is in Earth's shadow.
##
## Information for the label only. Satellites shine by reflected sunlight, so one in
## Earth's shadow cannot be seen however dark your sky. The app still draws it exactly as
## it draws a lit one: it is for awareness of what is overhead, seen or not, so eye
## visibility never hides or dims a marker.
##
## Deliberately low-precision. The sun direction is the Astronomical Almanac's short
## series, good to ~0.01°, and the shadow is a cylinder with no penumbra. Both are far
## inside what matters here, and tests/satellite_fixture.json checks them against
## Skyfield (DE421 ephemeris, full frames).

## Mean equatorial radius, km. The shadow cylinder's radius.
const EARTH_RADIUS_KM := 6378.137


## Unit vector toward the sun in the true-of-date equatorial frame, which is TEME to far
## better than this series' own accuracy.
static func sun_direction_teme(jd: float) -> Vector3:
	var n := jd - 2451545.0
	var mean_longitude := 280.460 + 0.9856474 * n
	var g := deg_to_rad(357.528 + 0.9856003 * n)
	var ecliptic_longitude := deg_to_rad(mean_longitude + 1.915 * sin(g) + 0.020 * sin(2.0 * g))
	var obliquity := deg_to_rad(23.439 - 0.0000004 * n)
	return Vector3(cos(ecliptic_longitude),
			cos(obliquity) * sin(ecliptic_longitude),
			sin(obliquity) * sin(ecliptic_longitude))


## Whether a satellite at TEME position r (km) is in sunlight. On the sun's side of the
## Earth it always is; on the far side, only if it is outside the shadow cylinder.
static func is_sunlit(rx: float, ry: float, rz: float, sun: Vector3) -> bool:
	var along := rx * sun.x + ry * sun.y + rz * sun.z
	if along >= 0.0:
		return true
	var px := rx - along * sun.x
	var py := ry - along * sun.y
	var pz := rz - along * sun.z
	return px * px + py * py + pz * pz > EARTH_RADIUS_KM * EARTH_RADIUS_KM


## The sun's position in the observer's sky.
static func sun_look_angles(frame: PackedFloat64Array, jd: float) -> LookAngles:
	var s := sun_direction_teme(jd)
	var e := teme_to_ecef_direction(s, Sgp4.gstime(jd))
	return GeoMath.direction_look_angles(frame, e.x, e.y, e.z)


## Rotate a TEME vector into Earth-fixed axes by Greenwich sidereal time.
static func teme_to_ecef_direction(v: Vector3, gmst: float) -> Vector3:
	var c := cos(gmst)
	var s := sin(gmst)
	return Vector3(c * v.x + s * v.y, -s * v.x + c * v.y, v.z)
