class_name CompassCalibration
extends RefCounted
## Turns the head tracker's arbitrary yaw into a true-north heading.
##
## This is the crux of the whole app. If the heading is wrong by 10°, every marker is
## wrong by 10° — worse than useless, because it looks authoritative while pointing at
## empty sky.
##
## The glasses' IMU reads pitch and roll off gravity, so those are absolute. Yaw has no
## such reference: it is measured from wherever the device pointed at power-on, and it
## drifts. This class is the bridge, and it is a single number: heading_offset_deg.
##
## Because only yaw is unreferenced, the correction is a rotation about world up alone.
## Never correct pitch or roll here — the IMU already has them right.
##
## Yaw everywhere in this app is COMPASS sense: degrees clockwise seen from above, the
## way headings are measured. Godot's own rotations about +Y run the other way, and
## to_world_basis() is the one place that conversion happens.

enum Source { NONE, PHONE_COMPASS, KNOWN_BEARING, CELESTIAL, MANUAL_NUDGE }

## Degrees added to raw yaw to get true heading.
var heading_offset_deg := 0.0
## False until a fix has been taken. Markers should not be trusted before then.
var is_calibrated := false
## Seconds (engine clock) when the last fix was taken, for drift warnings.
var last_fix_time := -INF
## How the current fix was obtained, for the UI to report honestly.
var source := Source.NONE


## Take a fix from the phone's magnetometer, phone held flat and pointed where the user
## is looking. Passing 0 for declination is a silent error of up to 20° depending on
## where you are, so callers should get a real value rather than defaulting it.
func calibrate_from_phone_compass(magnetic_heading_deg: float, raw_yaw_deg: float,
		declination_deg: float) -> void:
	_set_from_true_heading(magnetic_heading_deg + declination_deg, raw_yaw_deg, Source.PHONE_COMPASS)


## Take a fix by looking at something whose true bearing is known — a landmark, the sun,
## or an aircraft the app is already tracking.
func calibrate_from_known_bearing(true_bearing_deg: float, raw_yaw_deg: float,
		fix_source: Source = Source.KNOWN_BEARING) -> void:
	_set_from_true_heading(true_bearing_deg, raw_yaw_deg, fix_source)


func _set_from_true_heading(true_heading_deg: float, raw_yaw_deg: float, fix_source: Source) -> void:
	heading_offset_deg = GeoMath.wrap360(true_heading_deg - raw_yaw_deg)
	_mark_fixed(fix_source)


## Walk the offset by hand. With manual calibration as the primary interface, this is
## the main way the offset is set: the user drags until the ghost N sits on north.
func nudge(degrees: float) -> void:
	heading_offset_deg = GeoMath.wrap360(heading_offset_deg + degrees)
	# A nudge is a real fix — it is the user asserting what they can see.
	_mark_fixed(source if source != Source.NONE else Source.MANUAL_NUDGE)


func reset() -> void:
	heading_offset_deg = 0.0
	is_calibrated = false
	last_fix_time = -INF
	source = Source.NONE


## Raw tracker yaw to a true-north heading, [0, 360).
func true_heading(raw_yaw_deg: float) -> float:
	return GeoMath.wrap360(raw_yaw_deg + heading_offset_deg)


## Raw tracker orientation to world orientation.
##
## Pre-multiplying by a rotation about WORLD up applies the yaw correction in the world
## frame and leaves the gravity-referenced pitch and roll alone. Post-multiplying would
## rotate about the device's own up axis and corrupt the attitude whenever the head is
## tilted — fine while standing level, broken the moment you look up, which is the
## entire use case.
##
## The minus sign converts compass-clockwise degrees to Godot's counter-clockwise
## rotation about +Y.
func to_world_basis(raw: Basis) -> Basis:
	return Basis(Vector3.UP, -deg_to_rad(heading_offset_deg)) * raw


## Seconds since the last fix, for prompting a re-sync. Drift makes a fix go stale in
## minutes, not hours.
func seconds_since_fix() -> float:
	return _now() - last_fix_time if is_calibrated else INF


func _mark_fixed(fix_source: Source) -> void:
	is_calibrated = true
	last_fix_time = _now()
	source = fix_source


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
