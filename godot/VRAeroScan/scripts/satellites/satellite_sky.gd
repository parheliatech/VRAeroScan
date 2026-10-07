class_name SatelliteSky
extends RefCounted
## Keeps every satellite in a catalogue positioned, within a per-frame budget — above the
## horizon or below it, all the way round to the far side of the Earth.
##
## Nothing is culled at the horizon. The app shows what is out there whether or not you
## could see it, and that includes looking down through the ground (owner, 2026-09-24:
## "I should be able to look down and see satellites, even if they're directly opposite
## me on the earth"). From one spot, 96% of Starlink is below the horizon.
##
## Each satellite is propagated with SGP4 now and then, and in between is carried along
## a straight line at its sampled velocity — in GDScript for the few that need it (look
## angles, labels), on the GPU for the diamonds (SatelliteField). The straight line
## drifts from the curved orbit by ½·a·t², so how often a satellite needs resampling
## depends on how far away it is: REFRESH_S_PER_1000_KM, between MIN and MAX. A Starlink
## overhead is resampled every 2 s (16 m of drift, invisible); one on the far side of
## the Earth every 20 s (1.6 km at 12,000 km, 0.008°). Across 11,000 Starlinks that is
## ~750 propagations a second.
##
## Scheduling is a timing wheel: a ring of half-second slots, each holding the satellites
## due in it, so a frame touches only what is due rather than scanning the catalogue.

const MIN_REFRESH_S := 2.0
const MAX_REFRESH_S := 20.0
const REFRESH_S_PER_1000_KM := 1.6
const SLOT_S := 0.5
## Wheel length: must exceed MAX_REFRESH_S / SLOT_S.
const SLOTS := 64
## A satellite this far off where it was when the observer moved gets resampled; the
## world-frame positions the GPU holds are relative to the observer.
const OBSERVER_MOVE_M := 100.0

## Microseconds of SGP4 per update(). A catalogue refresh or big observer move queues
## everything at once; this spreads it over frames.
var budget_usec := 2000

var satellites: Array[Satellite] = []
## Satellites resampled by the last update(), for the renderer to re-upload.
var resampled: Array[Satellite] = []
## Unix time all world-frame sample times are relative to (float32 on the GPU).
var time_base_unix := 0.0

var _frame := PackedFloat64Array()
var _frame_observer_ecef := PackedFloat64Array()
var _wheel: Array = []  # SLOTS arrays of Satellite
var _wheel_slot := 0  # slot index for _wheel_time
var _wheel_time := 0.0  # unix start of the current slot
var _overdue: Array[Satellite] = []
## Direction index: cell key -> Array of Satellite, from each one's last sample.
var _bins: Dictionary = {}


## Replace the catalogue and place every satellite now. One hitch per catalogue load
## (~100 ms for Starlink on a desktop) rather than satellites trickling in.
func set_catalogue(list: Array[Satellite], observer: GeoPoint, unix_s: float) -> void:
	satellites = list
	time_base_unix = unix_s
	_set_frame(observer)
	_wheel = []
	for i in SLOTS:
		_wheel.append([])
	_wheel_slot = 0
	_wheel_time = unix_s
	_overdue.clear()
	_bins.clear()
	for sat in satellites:
		sat.bin_key = -1
	resampled.clear()
	var gmst := _gmst(unix_s)
	var sun := _sun(unix_s)
	for sat in satellites:
		_sample(sat, unix_s, gmst, sun)
	resampled.assign(satellites)


## Advance to unix_s: resample whatever is due, within the budget.
func update(observer: GeoPoint, unix_s: float) -> void:
	resampled.clear()
	if satellites.is_empty():
		return

	# The GPU's positions are relative to the observer at sampling time; if the observer
	# has moved (GPS), everything needs redoing — spread over frames by the budget.
	var o := GeoMath.geodetic_to_ecef(observer)
	if Vector3(o[0] - _frame_observer_ecef[0], o[1] - _frame_observer_ecef[1],
			o[2] - _frame_observer_ecef[2]).length() > OBSERVER_MOVE_M:
		_set_frame(observer)
		for slot: Array in _wheel:
			for sat: Satellite in slot:
				_overdue.append(sat)
			slot.clear()

	# Turn the wheel: every slot that has fully passed moves its satellites to overdue.
	# A clock jump of more than a whole turn (a test, a suspended app) empties the wheel.
	var turns := 0
	while unix_s >= _wheel_time + SLOT_S and turns < SLOTS:
		_overdue.append_array(_wheel[_wheel_slot])
		_wheel[_wheel_slot].clear()
		_wheel_slot = (_wheel_slot + 1) % SLOTS
		_wheel_time += SLOT_S
		turns += 1
	if unix_s >= _wheel_time + SLOT_S:
		_wheel_time = unix_s  # caught up after a jump

	if _overdue.is_empty():
		return
	var gmst := _gmst(unix_s)
	var sun := _sun(unix_s)
	var deadline := Time.get_ticks_usec() + budget_usec
	var done := 0
	while done < _overdue.size() and Time.get_ticks_usec() < deadline:
		var sat := _overdue[done]
		done += 1
		_sample(sat, unix_s, gmst, sun)
		resampled.append(sat)
	_overdue = _overdue.slice(done)


## Where a satellite is in the sky at unix_s, extrapolated from its last sample.
func look_angles(sat: Satellite, unix_s: float) -> LookAngles:
	var p := sat.ecef_at(unix_s)
	return GeoMath.look_angles_in_frame(_frame, p[0], p[1], p[2])


## Satellites whose last-sampled direction is within radius_deg of (azimuth, elevation),
## plus some beyond it: a coarse pre-filter from the direction index, so a gaze query
## touches a few cells instead of the whole catalogue. Callers measure exact angles.
## Include in radius_deg how far a satellite may have moved since its sample.
func near_direction(azimuth_deg: float, elevation_deg: float, radius_deg: float) -> Array[Satellite]:
	var out: Array[Satellite] = []
	var el_lo := maxi(_el_cell(elevation_deg - radius_deg), 0)
	var el_hi := mini(_el_cell(elevation_deg + radius_deg), EL_CELLS - 1)
	for el_cell in range(el_lo, el_hi + 1):
		# Azimuth cells shrink toward the zenith and nadir, so widen the span there.
		var cell_centre := -90.0 + (el_cell + 0.5) * CELL_DEG
		var squeeze := cos(deg_to_rad(minf(absf(cell_centre) + CELL_DEG, 90.0)))
		var span := AZ_CELLS if squeeze < 0.05 else mini(ceili(radius_deg / squeeze / CELL_DEG) + 1, AZ_CELLS)
		var az_mid := _az_cell(azimuth_deg)
		var cells := {}
		for d in range(-span, span + 1):
			cells[posmod(az_mid + d, AZ_CELLS)] = true
		for az_cell: int in cells:
			var bin: Variant = _bins.get(el_cell * AZ_CELLS + az_cell)
			if bin != null:
				out.append_array(bin)
	return out


## Satellites waiting for a sample beyond this frame's budget.
func backlog() -> int:
	return _overdue.size()


## Whether another satellite in `others` already stands for this one: docked vehicles
## and a station's separately-catalogued modules share one position, and a stack of
## identical markers helps nobody. The lowest catalogue number wins, which is the
## station itself (ISS 25544, CSS 48274) rather than whatever is docked to it.
##
## Compared at one instant, not at each one's last sample: the ISS covers 7.7 km in a
## second, more than the threshold.
func is_duplicate_of_neighbour(sat: Satellite, others: Array[Satellite], unix_s: float) -> bool:
	const SAME_OBJECT_M := 5000.0
	var p := sat.ecef_at(unix_s)
	for other in others:
		if other.norad_id >= sat.norad_id or not other.ok:
			continue
		var q := other.ecef_at(unix_s)
		var dx := q[0] - p[0]
		var dy := q[1] - p[1]
		var dz := q[2] - p[2]
		if dx * dx + dy * dy + dz * dz < SAME_OBJECT_M * SAME_OBJECT_M:
			return true
	return false


## World-frame (x east, y up, z south) position and velocity of the last sample,
## relative to the observer: [px, py, pz, vx, vy, vz], metres and m/s. What the GPU
## extrapolates from.
func world_state(sat: Satellite) -> PackedFloat64Array:
	var f := _frame
	var dx := sat.ecef[0] - f[0]
	var dy := sat.ecef[1] - f[1]
	var dz := sat.ecef[2] - f[2]
	var vx := sat.ecef[3]
	var vy := sat.ecef[4]
	var vz := sat.ecef[5]
	var e := f[3] * dx + f[4] * dy + f[5] * dz
	var n := f[6] * dx + f[7] * dy + f[8] * dz
	var u := f[9] * dx + f[10] * dy + f[11] * dz
	var ve := f[3] * vx + f[4] * vy + f[5] * vz
	var vn := f[6] * vx + f[7] * vy + f[8] * vz
	var vu := f[9] * vx + f[10] * vy + f[11] * vz
	return PackedFloat64Array([e, u, -n, ve, vu, -vn])


func _set_frame(observer: GeoPoint) -> void:
	_frame = GeoMath.local_frame(observer)
	_frame_observer_ecef = GeoMath.geodetic_to_ecef(observer)


func _sample(sat: Satellite, unix_s: float, gmst: float, sun: Vector3) -> void:
	if not sat.ok or not sat.sample(unix_s, gmst, sun):
		return  # decayed or unusable: never rescheduled
	var look := GeoMath.look_angles_in_frame(_frame, sat.ecef[0], sat.ecef[1], sat.ecef[2])
	sat.sampled_elevation_deg = look.elevation_deg
	sat.sampled_azimuth_deg = look.azimuth_deg
	_bin(sat)
	var period := clampf(look.range_m / 1.0e6 * REFRESH_S_PER_1000_KM, MIN_REFRESH_S, MAX_REFRESH_S)
	var slots_ahead := clampi(ceili((unix_s + period - _wheel_time) / SLOT_S), 1, SLOTS - 1)
	_wheel[(_wheel_slot + slots_ahead) % SLOTS].append(sat)


const CELL_DEG := 5.0
const EL_CELLS := 36
const AZ_CELLS := 72


static func _el_cell(elevation_deg: float) -> int:
	return clampi(int(floor((elevation_deg + 90.0) / CELL_DEG)), 0, EL_CELLS - 1)


static func _az_cell(azimuth_deg: float) -> int:
	return posmod(int(floor(azimuth_deg / CELL_DEG)), AZ_CELLS)


func _bin(sat: Satellite) -> void:
	var key := _el_cell(sat.sampled_elevation_deg) * AZ_CELLS + _az_cell(sat.sampled_azimuth_deg)
	if key == sat.bin_key:
		return
	if sat.bin_key >= 0:
		(_bins[sat.bin_key] as Array).erase(sat)
	if not _bins.has(key):
		_bins[key] = []
	(_bins[key] as Array).append(sat)
	sat.bin_key = key


static func _gmst(unix_s: float) -> float:
	return Sgp4.gstime(Sgp4.unix_to_jd(unix_s))


static func _sun(unix_s: float) -> Vector3:
	return Solar.sun_direction_teme(Sgp4.unix_to_jd(unix_s))
