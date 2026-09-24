class_name SatelliteSky
extends RefCounted
## Keeps a satellite catalogue's positions current, within a per-frame budget, and says
## which satellites are in the observer's sky.
##
## A catalogue can be 11,000 Starlinks, and only a few percent are ever above one
## observer's horizon. So satellites are sorted by their last known elevation:
##
## - NEAR (above NEAR_ELEVATION_DEG): re-propagated about every near_refresh_s, and
##   placed each frame by straight-line extrapolation from that sample — metres of error,
##   not jumps.
## - FAR: re-propagated round-robin, the whole catalogue every scan_period_s, only to
##   notice when one climbs into NEAR.
##
## The NEAR margin below the horizon is what makes the round-robin safe: a LEO satellite
## takes well over a minute to climb 10° from below the horizon, and the whole catalogue
## is rescanned every scan_period_s.

const NEAR_ELEVATION_DEG := -10.0

## Seconds between SGP4 samples for a satellite in or near the sky.
var near_refresh_s := 1.0
## Seconds to rescan the whole catalogue. Near the horizon a LEO satellite climbs at
## most ~0.2°/s, so crossing the 10° NEAR margin takes a minute; 10 s is safe.
var scan_period_s := 10.0

var satellites: Array[Satellite] = []
## norad_id -> Satellite, for everything NEAR.
var near: Dictionary = {}

var _frame := PackedFloat64Array()
var _cursor := 0
var _last_update_unix := -INF
## Fractional satellites owed to the round-robin, carried between frames.
var _scan_debt := 0.0


## Replace the catalogue and place every satellite now: a single hitch on load (tens of
## milliseconds for Starlink on a desktop) rather than satellites trickling in.
func set_catalogue(list: Array[Satellite], observer: GeoPoint, unix_s: float) -> void:
	satellites = list
	near.clear()
	_cursor = 0
	_scan_debt = 0.0
	_prepare(observer, unix_s)
	var gmst := _gmst(unix_s)
	var sun := _sun(unix_s)
	for sat in satellites:
		_sample(sat, unix_s, gmst, sun)
	_last_update_unix = unix_s


## Advance to unix_s: refresh NEAR satellites that are due, and scan some FAR ones.
func update(observer: GeoPoint, unix_s: float) -> void:
	_prepare(observer, unix_s)
	if satellites.is_empty():
		return

	var gmst := _gmst(unix_s)
	var sun := _sun(unix_s)

	var elapsed := clampf(unix_s - _last_update_unix, 0.0, scan_period_s)
	_last_update_unix = unix_s

	# Refresh due NEAR satellites, but no more per frame than an even share. Everything
	# loaded together falls due together; without the cap, a thousand Starlinks would
	# all resample in one frame every second. With it, they spread out within a second.
	# Iterates a copy (values()): sampling can move a satellite out of NEAR.
	var allowance := ceili(near.size() * maxf(elapsed, 1.0 / 60.0) / near_refresh_s)
	for sat: Satellite in near.values():
		if allowance <= 0:
			break
		if absf(unix_s - sat.sampled_unix) >= near_refresh_s:
			_sample(sat, unix_s, gmst, sun)
			allowance -= 1

	# Round-robin over the rest, at a rate that covers the catalogue once per scan period.
	# A clock jump (tests, or a suspended app) is capped at one full pass.
	_scan_debt += satellites.size() * elapsed / scan_period_s
	# The epsilon stops float dust (7.9999999) from leaving one satellite a frame late.
	var count := mini(int(_scan_debt + 1e-6), satellites.size())
	_scan_debt -= count
	for i in count:
		var sat := satellites[_cursor]
		_cursor = (_cursor + 1) % satellites.size()
		if not near.has(sat.norad_id):
			_sample(sat, unix_s, gmst, sun)


## Where a NEAR satellite is in the sky at unix_s. Call after update() for this frame.
func look_angles(sat: Satellite, unix_s: float) -> LookAngles:
	var p := sat.ecef_at(unix_s)
	return GeoMath.look_angles_in_frame(_frame, p[0], p[1], p[2])


## Whether another satellite already stands for this one: docked vehicles and a
## station's separately-catalogued modules share one position, and a stack of identical
## markers helps nobody. The lowest catalogue number wins, which is the station itself
## (ISS 25544, CSS 48274) rather than whatever is docked to it.
##
## Compared at one instant, not at each one's last sample: the ISS covers 7.7 km in a
## second, more than the threshold. Only MANNED satellites are compared — they are the
## only ones that dock, and few enough to compare pairwise.
func is_duplicate_of_neighbour(sat: Satellite, unix_s: float) -> bool:
	if sat.category != Satellite.MANNED:
		return false
	const SAME_OBJECT_M := 5000.0
	var p := sat.ecef_at(unix_s)
	for other: Satellite in near.values():
		if other.category != Satellite.MANNED or other.norad_id >= sat.norad_id:
			continue
		var q := other.ecef_at(unix_s)
		var dx := q[0] - p[0]
		var dy := q[1] - p[1]
		var dz := q[2] - p[2]
		if dx * dx + dy * dy + dz * dz < SAME_OBJECT_M * SAME_OBJECT_M:
			return true
	return false


func _prepare(observer: GeoPoint, unix_s: float) -> void:
	# The observer can move (GPS), so the frame is rebuilt each update — twelve numbers.
	_frame = GeoMath.local_frame(observer)


func _sample(sat: Satellite, unix_s: float, gmst: float, sun: Vector3) -> void:
	if not sat.ok:
		return
	if not sat.sample(unix_s, gmst, sun):
		near.erase(sat.norad_id)
		return
	var look := GeoMath.look_angles_in_frame(_frame, sat.ecef[0], sat.ecef[1], sat.ecef[2])
	sat.sampled_elevation_deg = look.elevation_deg
	if look.elevation_deg > NEAR_ELEVATION_DEG:
		near[sat.norad_id] = sat
	else:
		near.erase(sat.norad_id)


static func _gmst(unix_s: float) -> float:
	return Sgp4.gstime(Sgp4.unix_to_jd(unix_s))


static func _sun(unix_s: float) -> Vector3:
	return Solar.sun_direction_teme(Sgp4.unix_to_jd(unix_s))
