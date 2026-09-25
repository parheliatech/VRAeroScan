class_name PassPredictor
extends RefCounted
## When tracked satellites next cross the observer's sky: rise, highest point, set.
##
## A satellite you want to see is usually below the horizon. What you need then is when
## and where it will come up — "ISS rises in 4:12 in the WSW, peaks at 67°" — so you are
## looking at the right patch of sky when it clears the roofline.
##
## The search steps forward in time on SGP4, finds each horizon crossing between steps,
## and refines it by bisection; the highest point is refined by golden-section search.
## Geometric 0° horizon, no refraction or terrain, matching Skyfield's find_events
## (checked against it in tests/satellite_fixture.json).
##
## A day of search is several hundred propagations per satellite, so it runs a slice per
## frame (budget_usec) rather than all at once, one satellite at a time. The budget is
## time, not a step count, because a step costs ~20 µs on a desktop and several times
## that on the phone.

## Seconds between samples while the satellite is within FAR_BELOW_DEG of the horizon.
## A pass must last longer than this above 0° to be found; LEO passes clearing the
## horizon at all last minutes.
const STEP_S := 20.0
## Deep below the horizon, bigger steps are safe: nothing climbs 15° in 30 seconds from
## there.
const FAR_STEP_S := 60.0
const FAR_BELOW_DEG := -15.0
## Crossing times are refined to this.
const REFINE_S := 0.05

## How far ahead to look, seconds.
var horizon_s := 86400.0
## Microseconds of search per update() call.
var budget_usec := 1000
## Satellites predicted at most — each costs a day of search. Tracking all of Starlink
## would be 11,000 of them; the first max_satellites by catalogue number get passes.
var max_satellites := 50

## norad_id -> SatellitePass, or null when there is no pass within horizon_s.
var passes: Dictionary = {}

## norad_id -> [Satellite, search start unix, observer ECEF] for the last search.
var _searched: Dictionary = {}
var _queue: Array[Satellite] = []
var _search: Search


## One pass. Times are Unix seconds; rise is NAN if the pass was already under way when
## the search started, set is NAN if it outlasts the search horizon.
class SatellitePass:
	var norad_id := 0
	var rise_unix := NAN
	var rise_azimuth_deg := NAN
	var max_unix := NAN
	var max_elevation_deg := NAN
	var max_azimuth_deg := NAN
	var set_unix := NAN
	var set_azimuth_deg := NAN

	func in_progress_at(unix_s: float) -> bool:
		return (is_nan(rise_unix) or rise_unix <= unix_s) and (is_nan(set_unix) or unix_s < set_unix)

	func _to_string() -> String:
		return "pass %d: rise %.1f az %.1f, max %.1f el %.1f, set %.1f az %.1f" % [norad_id,
				rise_unix, rise_azimuth_deg, max_unix, max_elevation_deg, set_unix, set_azimuth_deg]


## A resumable search for the next pass of one satellite from one observer.
class Search:
	var sat: Satellite
	var frame: PackedFloat64Array
	var result: SatellitePass
	## SGP4 evaluations made by the last advance().
	var used := 0

	var _t: float
	var _end: float
	var _el: float
	var _phase := 0  # 0 looking for the rise, 1 for the set, 2 done
	var _best_t := 0.0
	var _best_el := -INF

	func _init(p_sat: Satellite, p_frame: PackedFloat64Array, from_unix: float, horizon: float) -> void:
		sat = p_sat
		frame = p_frame
		_t = from_unix
		_end = from_unix + horizon
		result = SatellitePass.new()
		result.norad_id = sat.norad_id
		_el = _elevation(_t)
		if is_nan(_el):
			result = null
			_phase = 2
		elif _el > 0.0:
			# Already up: a pass in progress, rise unknown.
			_phase = 1
			_best_t = _t
			_best_el = _el

	func done() -> bool:
		return _phase == 2

	## Up to max_evals propagations. Returns true when finished; result is then the
	## pass, or null if none was found.
	func advance(max_evals: int) -> bool:
		used = 0
		while _phase < 2 and used < max_evals:
			if _t >= _end:
				if _phase == 0:
					result = null
				else:
					_finish_max()  # set beyond the horizon; keep what we have
				_phase = 2
				break

			var step := STEP_S if _el > FAR_BELOW_DEG else FAR_STEP_S
			var t2 := minf(_t + step, _end)
			var el2 := _elevation(t2)
			if is_nan(el2):
				result = null
				_phase = 2
				break

			if _phase == 0 and el2 > 0.0:
				var rise := _crossing(_t, t2)
				result.rise_unix = rise
				result.rise_azimuth_deg = _look(rise).azimuth_deg
				_phase = 1
				_best_t = t2
				_best_el = el2
			elif _phase == 1:
				if el2 > _best_el:
					_best_t = t2
					_best_el = el2
				if el2 <= 0.0:
					var set_t := _crossing(_t, t2)
					result.set_unix = set_t
					result.set_azimuth_deg = _look(set_t).azimuth_deg
					_finish_max()
					_phase = 2
			_t = t2
			_el = el2
		return _phase == 2

	## The highest point: golden-section search around the best sample, within the pass.
	func _finish_max() -> void:
		var lo := maxf(_best_t - STEP_S, result.rise_unix if not is_nan(result.rise_unix) else _best_t - STEP_S)
		var hi := minf(_best_t + STEP_S, result.set_unix if not is_nan(result.set_unix) else _best_t + STEP_S)
		const INV_PHI := 0.6180339887498949
		var a := hi - INV_PHI * (hi - lo)
		var b := lo + INV_PHI * (hi - lo)
		var ea := _elevation(a)
		var eb := _elevation(b)
		while hi - lo > REFINE_S:
			if ea > eb:
				hi = b
				b = a
				eb = ea
				a = hi - INV_PHI * (hi - lo)
				ea = _elevation(a)
			else:
				lo = a
				a = b
				ea = eb
				b = lo + INV_PHI * (hi - lo)
				eb = _elevation(b)
		var t_max := (lo + hi) / 2.0
		var look := _look(t_max)
		result.max_unix = t_max
		result.max_elevation_deg = look.elevation_deg
		result.max_azimuth_deg = look.azimuth_deg

	## The moment elevation crosses 0 between a and b, by bisection.
	func _crossing(a: float, b: float) -> float:
		var ea := _elevation(a)
		while b - a > REFINE_S:
			var m := (a + b) / 2.0
			var em := _elevation(m)
			if (em > 0.0) == (ea > 0.0):
				a = m
				ea = em
			else:
				b = m
		return (a + b) / 2.0

	func _look(unix_s: float) -> LookAngles:
		used += 1
		var p := sat.ecef_position_at(unix_s)
		if p.is_empty():
			return null
		return GeoMath.look_angles_in_frame(frame, p[0], p[1], p[2])

	## Elevation only: the search's inner loop, so it skips building a LookAngles.
	func _elevation(unix_s: float) -> float:
		used += 1
		var p := sat.ecef_position_at(unix_s)
		if p.is_empty():
			return NAN
		var f := frame
		var dx := p[0] - f[0]
		var dy := p[1] - f[1]
		var dz := p[2] - f[2]
		var e := f[3] * dx + f[4] * dy + f[5] * dz
		var n := f[6] * dx + f[7] * dy + f[8] * dz
		var u := f[9] * dx + f[10] * dy + f[11] * dz
		return rad_to_deg(atan2(u, sqrt(e * e + n * n)))


## The next pass of sat from observer, starting at from_unix — all at once. For tests
## and one-off questions; the app uses update(), which spreads the work over frames.
static func next_pass(sat: Satellite, observer: GeoPoint, from_unix: float,
		horizon: float = 86400.0) -> SatellitePass:
	var search := Search.new(sat, GeoMath.local_frame(observer), from_unix, horizon)
	while not search.advance(1 << 30):
		pass
	return search.result


## Keep passes current for these satellites, doing at most budget_usec of search.
## Re-searches a satellite when its pass is over, its elements change (a new Satellite
## object), the observer moves more than 5 km, or an empty search is an hour old.
func update(tracked: Array[Satellite], observer: GeoPoint, unix_s: float) -> void:
	var observer_ecef := GeoMath.geodetic_to_ecef(observer)
	var wanted := {}
	for sat in tracked.slice(0, max_satellites):
		wanted[sat.norad_id] = true
		if _needs_search(sat, observer_ecef, unix_s) and not _queue.has(sat) \
				and not (_search != null and _search.sat == sat):
			_queue.append(sat)

	# Forget satellites no longer tracked.
	for id: int in passes.keys():
		if not wanted.has(id):
			passes.erase(id)
			_searched.erase(id)
	_queue = _queue.filter(func(s: Satellite) -> bool: return wanted.has(s.norad_id))
	if _search != null and not wanted.has(_search.sat.norad_id):
		_search = null

	var deadline := Time.get_ticks_usec() + budget_usec
	var frame := GeoMath.local_frame(observer)
	while Time.get_ticks_usec() < deadline:
		if _search == null:
			if _queue.is_empty():
				break
			var next: Satellite = _queue.pop_front()
			_search = Search.new(next, frame, unix_s, horizon_s)
			_searched[next.norad_id] = [next, unix_s, observer_ecef]
		# Small slices, so the deadline is checked often.
		var finished := _search.advance(8)
		if finished:
			passes[_search.sat.norad_id] = _search.result
			_search = null


## Whether every tracked satellite has a current prediction.
func is_idle() -> bool:
	return _search == null and _queue.is_empty()


func _needs_search(sat: Satellite, observer_ecef: PackedFloat64Array, unix_s: float) -> bool:
	if not _searched.has(sat.norad_id):
		return true
	var last: Array = _searched[sat.norad_id]
	if last[0] != sat:
		return true  # new elements
	if not passes.has(sat.norad_id):
		return false  # searching now
	var o: PackedFloat64Array = last[2]
	var moved := Vector3(o[0] - observer_ecef[0], o[1] - observer_ecef[1], o[2] - observer_ecef[2]).length()
	if moved > 5000.0:
		return true
	var p: SatellitePass = passes[sat.norad_id]
	if p == null or is_nan(p.set_unix):
		return unix_s - float(last[1]) > 3600.0
	return unix_s >= p.set_unix


## "in 4:12" under ten minutes, "in 37m" under an hour, then "in 3h05m".
static func countdown(seconds: float) -> String:
	var s := maxi(roundi(seconds), 0)
	if s < 600:
		return "in %d:%02d" % [s / 60, s % 60]
	if s < 3600:
		return "in %dm" % roundi(s / 60.0)
	return "in %dh%02dm" % [s / 3600, (s % 3600) / 60]


## 16-point compass name for an azimuth: "N", "NNE", ... "WSW".
static func compass_point(azimuth_deg: float) -> String:
	const POINTS := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
			"S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
	return POINTS[int(fposmod(azimuth_deg + 11.25, 360.0) / 22.5) % 16]
