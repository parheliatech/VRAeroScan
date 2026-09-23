class_name MockHeadTracker
extends HeadTracker
## Mouse-and-keyboard head tracking, so the whole pipeline can be flown at a desk.
##
## Hold the right mouse button and move to look around. Point it at a known bearing
## and check the markers land where the real aircraft are.
##
## It deliberately imitates the real device's awkwardness: yaw starts at
## starting_yaw_deg rather than at north, so calibration is exercised on the desktop
## instead of being a surprise on the hardware. Set simulated_drift_deg_per_minute to
## rehearse the drift problem too.

@export var mouse_sensitivity := 0.15

## Yaw reported at startup. Non-zero on purpose: the Viture IMU's yaw origin is
## wherever it powered on, never true north.
@export var starting_yaw_deg := 137.0

## Degrees of yaw drift per minute, to rehearse the drift problem. 0 for a clean rig.
@export var simulated_drift_deg_per_minute := 0.0

var _yaw := 0.0
var _pitch := 0.0
var _drift := 0.0


func _ready() -> void:
	_yaw = starting_yaw_deg


func is_available() -> bool:
	return true


func raw_yaw_deg() -> float:
	return GeoMath.wrap360(_yaw + _drift)


func raw_basis() -> Basis:
	# YXZ order: yaw about world up, then pitch about the turned right axis, which is
	# how a head moves. Compass yaw is clockwise, Godot's +Y rotation is not: hence -.
	return Basis.from_euler(Vector3(deg_to_rad(_pitch), -deg_to_rad(raw_yaw_deg()), 0.0))


func tick(delta: float) -> void:
	_drift += simulated_drift_deg_per_minute * delta / 60.0


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion == null or not (motion.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		return

	# Mouse right turns right (clockwise, so yaw increases); mouse up looks up.
	_yaw += motion.relative.x * mouse_sensitivity
	_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -89.0, 89.0)
