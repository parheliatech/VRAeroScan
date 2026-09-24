class_name Satellite
extends RefCounted
## One satellite: its identity, its propagator, and where it was last computed to be.
##
## Positions are kept in ECEF metres (WGS84 axes), the frame GeoMath's look angles work
## in, converted from SGP4's TEME by Greenwich sidereal time. That rotation ignores
## polar motion and UT1-UTC, together worth ~15 m on the ground — invisible.

## Exactly one category per satellite, so a filter is a plain bitmask test. Identity
## beats orbit: the ISS is MANNED, not LEO; a Starlink is STARLINK, not LEO.
const MANNED := 1
const STARLINK := 2
const LEO := 4
## Everything between LEO and GEO, including the eccentric Molniya and transfer orbits.
const MEO := 8
const GEO := 16
const ALL_CATEGORIES := MANNED | STARLINK | LEO | MEO | GEO

## Earth's rotation rate, rad/s, for the velocity term of TEME -> ECEF.
const EARTH_ROTATION := 7.292115146706979e-5

## Crewed stations, their modules (each tracked as its own object) and the vehicles that
## dock with them. Docked craft sit on the station's position, which SatelliteSky uses
## to draw one marker rather than a stack.
const MANNED_PREFIXES := ["ISS", "CSS", "POISK", "TIANGONG", "CREW DRAGON", "DRAGON",
		"SOYUZ", "PROGRESS", "SHENZHOU", "TIANZHOU", "CYGNUS", "STARLINER", "HTV"]

var norad_id := 0
var name := ""
var category := LEO
var sgp4: Sgp4

# --- Tracking state, owned by SatelliteSky --------------------------------------------

## ECEF position (m) and velocity (m/s) at sampled_unix: [x, y, z, vx, vy, vz].
var ecef := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
var sampled_unix := -INF
## Whether it was in sunlight at the last sample.
var sunlit := true
## Elevation at the last sample, degrees, from SatelliteSky's observer.
var sampled_elevation_deg := -90.0
## False once SGP4 reports the elements unusable (decayed, bad eccentricity).
var ok := true


## From a CelesTrak OMM JSON record. Null if the record is unusable.
static func from_omm(o: Dictionary) -> Satellite:
	var propagator := Sgp4.from_omm(o)
	if propagator == null:
		return null
	var sat := Satellite.new()
	sat.sgp4 = propagator
	sat.norad_id = propagator.satnum
	sat.name = str(o.get("OBJECT_NAME", "")).strip_edges()
	if sat.name.is_empty():
		sat.name = str(sat.norad_id)
	sat.category = classify(sat.name, float(o["MEAN_MOTION"]), float(o["ECCENTRICITY"]))
	return sat


static func classify(object_name: String, mean_motion_rev_per_day: float, eccentricity: float) -> int:
	var upper := object_name.to_upper()
	# "ISS DEB", "FREGAT DEB", "CZ-2F R/B": debris and rocket bodies share the prefixes.
	var junk := upper.contains(" DEB") or upper.contains("R/B")
	for prefix: String in MANNED_PREFIXES:
		if upper.begins_with(prefix) and not junk:
			return MANNED
	if upper.begins_with("STARLINK"):
		return STARLINK
	# Geosynchronous: one revolution per sidereal day, near-circular.
	if absf(mean_motion_rev_per_day - 1.0027) < 0.05 and eccentricity < 0.05:
		return GEO
	# Period under 128 minutes, i.e. below ~2000 km.
	if mean_motion_rev_per_day > 11.25:
		return LEO
	return MEO


## Propagate to unix_s and store the ECEF state. gmst and sun (TEME unit vector) are
## for the same instant, passed in because a whole catalogue shares them.
func sample(unix_s: float, gmst: float, sun: Vector3) -> bool:
	var err := sgp4.propagate(sgp4.minutes_since_epoch(unix_s))
	if err != Sgp4.Fault.NONE:
		ok = false
		return false

	var r := sgp4.r
	var v := sgp4.v
	var c := cos(gmst)
	var s := sin(gmst)
	var x := (c * r[0] + s * r[1]) * 1000.0
	var y := (-s * r[0] + c * r[1]) * 1000.0
	ecef[0] = x
	ecef[1] = y
	ecef[2] = r[2] * 1000.0
	# The Earth-fixed frame turns under the satellite, hence the omega x r term.
	ecef[3] = (c * v[0] + s * v[1]) * 1000.0 + EARTH_ROTATION * y
	ecef[4] = (-s * v[0] + c * v[1]) * 1000.0 - EARTH_ROTATION * x
	ecef[5] = v[2] * 1000.0
	sampled_unix = unix_s
	sunlit = Solar.is_sunlit(r[0], r[1], r[2], sun)
	return true


## ECEF position (m) at unix_s, extrapolated in a straight line from the last sample.
## Over the ~1 s between samples that is a few metres off the true curved path. Doubles,
## not a Vector3: see GeoPoint.
func ecef_at(unix_s: float) -> PackedFloat64Array:
	var dt := unix_s - sampled_unix
	return PackedFloat64Array([ecef[0] + ecef[3] * dt, ecef[1] + ecef[4] * dt, ecef[2] + ecef[5] * dt])


## Height above the WGS84 ellipsoid at the last sample, km.
func altitude_km() -> float:
	return GeoMath.ecef_to_geodetic(ecef[0], ecef[1], ecef[2]).altitude_m / 1000.0


static func describe(c: int) -> String:
	match c:
		MANNED: return "manned"
		STARLINK: return "Starlink"
		LEO: return "LEO"
		MEO: return "MEO"
		GEO: return "GEO"
	return "?"


func _to_string() -> String:
	return "%s [%d] %s" % [name, norad_id, describe(category)]
