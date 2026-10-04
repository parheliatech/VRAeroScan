class_name PoleStar
extends RefCounted
## The star nearest each celestial pole, to set true north by eye.
##
## Sight the star in the glasses' circle and tap: the app knows exactly where that star is
## (az/el from your position and the time), so it knows which way you are facing. It is an
## option, never a requirement: the star may be behind cloud or the roof, so the drag pad
## and the landmark fix always work without it.
##
## North has Polaris, 0.65° from the pole (so its azimuth swings about ±1° through the
## night: this works out where it actually is rather than assuming it is due north). The
## south has no bright pole star: Sigma Octantis, magnitude 5.4, 1.0° from the pole, is
## faint enough that it needs a dark sky.
##
## Precession from J2000 to the date (IAU 1976) and sidereal time; no nutation (9"),
## aberration (20") or refraction (a minute of arc at 30°), all far inside what an eye
## on a star can aim. Checked against Skyfield by tests/star_fixture.json
## (tools/validation/export_star_fixture.py).

class Target:
	var name: String
	var short_name: String
	## J2000 right ascension and declination, degrees.
	var ra_deg: float
	var dec_deg: float
	## Apparent magnitude, to warn about the faint one.
	var magnitude: float

	func _init(n: String, short: String, ra: float, dec: float, mag: float) -> void:
		name = n
		short_name = short
		ra_deg = ra
		dec_deg = dec
		magnitude = mag


static var POLARIS := Target.new("Polaris", "Polaris", 37.95456067, 89.26410897, 2.0)
static var SIGMA_OCTANTIS := Target.new("Sigma Octantis", "Sigma Oct", 317.19528, -88.95650, 5.4)


## The star to sight from this latitude: Polaris in the north, Sigma Octantis in the south.
static func for_latitude(latitude_deg: float) -> Target:
	return POLARIS if latitude_deg >= 0.0 else SIGMA_OCTANTIS


## Where the star is now, as seen from a place on the ground. Range is not meaningful.
static func look_angles(target: Target, latitude_deg: float, longitude_deg: float,
		unix_s: float) -> LookAngles:
	var jd := Sgp4.unix_to_jd(unix_s)
	var t := (jd - 2451545.0) / 36525.0  # Julian centuries from J2000

	# Precess to the date: a rotation by zeta, theta and z (arcseconds in the series).
	var zeta := deg_to_rad((2306.2181 * t + 0.30188 * t * t + 0.017998 * t * t * t) / 3600.0)
	var z := deg_to_rad((2306.2181 * t + 1.09468 * t * t + 0.018203 * t * t * t) / 3600.0)
	var theta := deg_to_rad((2004.3109 * t - 0.42665 * t * t - 0.041833 * t * t * t) / 3600.0)
	var ra0 := deg_to_rad(target.ra_deg)
	var dec0 := deg_to_rad(target.dec_deg)
	var a := cos(dec0) * sin(ra0 + zeta)
	var b := cos(theta) * cos(dec0) * cos(ra0 + zeta) - sin(theta) * sin(dec0)
	var c := sin(theta) * cos(dec0) * cos(ra0 + zeta) + cos(theta) * sin(dec0)
	var ra := atan2(a, b) + z
	var dec := asin(clampf(c, -1.0, 1.0))

	# Hour angle from Greenwich mean sidereal time (UT1 taken as UTC: 0.9 s at most, 0.004°).
	var hour_angle := Sgp4.gstime(jd) + deg_to_rad(longitude_deg) - ra
	var lat := deg_to_rad(latitude_deg)
	var sin_el := sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour_angle)
	# Azimuth from north, through east.
	var azimuth := atan2(-cos(dec) * sin(hour_angle),
			sin(dec) * cos(lat) - cos(dec) * sin(lat) * cos(hour_angle))
	return LookAngles.new(GeoMath.wrap360(rad_to_deg(azimuth)), rad_to_deg(asin(clampf(sin_el, -1.0, 1.0))), 0.0)
