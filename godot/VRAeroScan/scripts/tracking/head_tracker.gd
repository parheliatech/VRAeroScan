class_name HeadTracker
extends Node
## A source of head orientation. Subclass it; GDScript has no interfaces.
##
## Everything here is in the DEVICE's own frame, not the world's. Pitch and roll are
## absolute, because an IMU reads them off gravity. Yaw is not: it is measured from
## wherever the device pointed at power-on, and it drifts. Turning that into a true
## heading is CompassCalibration's job, and nothing here should try.
##
## Conventions every implementation must follow, or markers land on empty sky:
##   raw_basis() — Godot basis, -Z forward, +Y up. Identity = looking at raw yaw 0, level.
##   raw_yaw_deg() — COMPASS sense, degrees clockwise from above, [0, 360).
##
## This exists so the whole pipeline can be developed against MockHeadTracker at a
## desk, long before the Viture display path is resolved.


## False when the device is absent or not yet connected.
func is_available() -> bool:
	return false


## Orientation in the device's own frame. Yaw is arbitrary; see above.
func raw_basis() -> Basis:
	return Basis.IDENTITY


## Degrees of yaw in the device's own frame, compass sense, [0, 360).
func raw_yaw_deg() -> float:
	return 0.0


## Pump the underlying device. Called once per frame by SkyRig, before the pose is read.
func tick(_delta: float) -> void:
	pass
