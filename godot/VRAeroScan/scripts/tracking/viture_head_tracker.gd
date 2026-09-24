class_name VitureHeadTracker
extends HeadTracker
## Head orientation from the Viture glasses' own IMU, via the VitureGlasses Android plugin
## (godot/plugins/viture_glasses).
##
## The SDK's pose sample is 7 floats, established on hardware on 2026-09-23 by wearing the
## glasses and turning, looking up and tilting (tests/viture_pose_fixture.json):
##
##   [0] roll  deg   right ear down = +
##   [1] pitch deg   looking up     = −
##   [2] yaw   deg   turning right  = −   (counter-clockwise positive)
##   [3..6] quaternion (w, x, y, z) in a frame with x forward, y left, z up
##
## Only the quaternion is used. It is converted to Godot's frame (x right, y up, z back)
## by the axis map (x, y, z)_viture → (−y, z, −x)_godot. That map has determinant +1, a
## proper rotation, so the quaternion's vector part maps the same way and nothing about
## the rotation is approximated. The Euler angles are for humans reading logs.
##
## Yaw is arbitrary, as HeadTracker requires: the IMU's zero is wherever it started.

var _plugin: Object
var _pose := PackedFloat32Array()


func _ready() -> void:
	if Engine.has_singleton("VitureGlasses"):
		_plugin = Engine.get_singleton("VitureGlasses")
		_plugin.startGlasses()


## True when the plugin exists, whether or not the glasses are streaming yet.
static func is_supported() -> bool:
	return Engine.has_singleton("VitureGlasses")


func is_available() -> bool:
	return _pose.size() >= 7


func tick(_delta: float) -> void:
	if _plugin != null:
		_pose = _plugin.getPose()


func raw_basis() -> Basis:
	return basis_from_sample(_pose) if is_available() else Basis.IDENTITY


func raw_yaw_deg() -> float:
	return yaw_from_basis(raw_basis())


## Plugin status string, for the HUD.
func status() -> String:
	return _plugin.getStatus() if _plugin != null else "no plugin"


## The SDK's quaternion (w, x, y, z; x fwd, y left, z up) as a Godot basis.
static func basis_from_sample(p: PackedFloat32Array) -> Basis:
	var w := p[3]
	var x := p[4]
	var y := p[5]
	var z := p[6]
	return Basis(Quaternion(-y, z, -x, w).normalized())


## Compass-sense yaw of a basis's gaze direction, [0, 360). Taken from the basis rather
## than the SDK's Euler yaw so the heading and the camera can never disagree.
static func yaw_from_basis(b: Basis) -> float:
	var forward := -b.z
	return GeoMath.wrap360(rad_to_deg(atan2(forward.x, -forward.z)))
