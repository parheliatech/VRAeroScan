class_name OffscreenPointers
extends Node3D
## Edge-of-view chevrons pointing at things outside the 46° field of view.
##
## The glasses show a small window of sky. A satellite you want is usually outside it,
## so each target that is off screen gets a chevron on the edge of the view, aimed at
## it, with its name and how far away it is: "ISS (ZARYA) 58°". Turn toward the chevron
## until the marker itself comes into view, and the chevron goes away.
##
## This node is a child of the CAMERA, not of the sky: a pointer is about where you are
## looking, so it must move with your head. Being 3D in camera space rather than a 2D
## overlay means it is rendered by the same camera into the same eye viewport as the
## sky, so it appears correctly in the glasses' side-by-side stereo — a CanvasLayer
## would span both eyes' halves. Pointers roll with your head, like the view itself.
##
## Outlines and bright colours only, for the additive display (see ArVisuals).

## Distance in front of the camera the pointers are drawn at. Anything between the near
## and far planes works; all that matters optically is that both eyes see the same image,
## which they do (one camera, see SkyRig).
const DISTANCE := 10.0
## Where the chevrons sit, as a fraction of the half-width and half-height of the view:
## far enough in that the label beside the chevron still fits on screen.
const EDGE_INSET := 0.86
## A target this far inside the view edge counts as on screen, and gets no pointer.
const ON_SCREEN_INSET := 0.97
## Chevron size, as a fraction of DISTANCE: about 1.4°.
const SIZE := 0.025

## Most pointers at once, nearest first. More than a few along the edge stops being a
## pointer and becomes clutter.
@export var max_pointers := 4

var _camera: Camera3D
var _pool: Array[Node3D] = []
var _active := 0

static var _chevron: ArrayMesh


## One thing to point at: a world-space unit direction, text and colour.
class Target:
	var direction: Vector3
	var text: String
	var color: Color

	func _init(dir: Vector3, label: String, c: Color) -> void:
		direction = dir
		text = label
		color = c


func initialize(camera: Camera3D) -> void:
	_camera = camera
	name = "OffscreenPointers"
	camera.add_child(self)


## Where to draw a pointer for a target at direction v, given in CAMERA space (the
## camera looks down -Z, +X right, +Y up). tan_half_h and tan_half_v are the tangents of
## the half fields of view. Returns {} if the target is on screen, otherwise
## {"position": Vector2 on the image plane at distance 1, "angle": radians the pointer
## should face, counter-clockwise from screen-right}.
static func place(v: Vector3, tan_half_h: float, tan_half_v: float) -> Dictionary:
	var u: Vector2
	if v.z < 0.0:
		# In front: where it projects on the image plane, which may be far off the edge.
		u = Vector2(v.x, v.y) / -v.z
		if absf(u.x) < tan_half_h * ON_SCREEN_INSET and absf(u.y) < tan_half_v * ON_SCREEN_INSET:
			return {}
	else:
		# Behind or level with the eye: the projection flips, so point the short way
		# round instead — the way you would turn your head.
		u = Vector2(v.x, v.y)
		if u.length_squared() < 1e-12:
			u = Vector2.RIGHT  # directly behind: any way is as good; right, like a turn

	# Slide out along u until the chevron meets the inset rectangle.
	var reach := INF
	if absf(u.x) > 1e-12:
		reach = minf(reach, tan_half_h * EDGE_INSET / absf(u.x))
	if absf(u.y) > 1e-12:
		reach = minf(reach, tan_half_v * EDGE_INSET / absf(u.y))
	return {"position": u * reach, "angle": u.angle()}


## Show pointers for whichever of these targets are off screen, nearest first.
func update_targets(targets: Array[Target], brightness: float = 1.0) -> void:
	var cam_basis := _camera.global_basis
	var inverse := cam_basis.inverse()
	var forward := -cam_basis.z
	var tan_v := tan(deg_to_rad(_camera.fov) / 2.0)
	var size := _camera.get_viewport().get_visible_rect().size
	var tan_h := tan_v * (size.x / size.y if size.y > 0.0 else 16.0 / 9.0)

	# Nearest first: the smallest turn is the most useful thing to offer.
	var sorted := targets.duplicate()
	sorted.sort_custom(func(a: Target, b: Target) -> bool:
		return a.direction.dot(forward) > b.direction.dot(forward))

	_active = 0
	for target: Target in sorted:
		if _active >= max_pointers:
			break
		var where := place(inverse * target.direction, tan_h, tan_v)
		if where.is_empty():
			continue
		var degrees := roundi(rad_to_deg(forward.angle_to(target.direction)))
		_show(_active, where, "%s %d°" % [target.text, degrees], target.color, brightness)
		_active += 1

	for i in range(_active, _pool.size()):
		_pool[i].visible = false


## How many pointers are showing.
func active_count() -> int:
	return _active


## The pointer node at index i, for tests.
func pointer(i: int) -> Node3D:
	return _pool[i]


func _show(i: int, where: Dictionary, text: String, color: Color, brightness: float) -> void:
	while _pool.size() <= i:
		_pool.append(_build_pointer())
	var p := _pool[i]
	var pos: Vector2 = where["position"]
	var angle: float = where["angle"]
	p.position = Vector3(pos.x * DISTANCE, pos.y * DISTANCE, -DISTANCE)
	p.visible = true

	var chevron: MeshInstance3D = p.get_child(0)
	chevron.rotation = Vector3(0.0, 0.0, angle)
	var c := Color(color, brightness)
	(chevron.material_override as StandardMaterial3D).albedo_color = c

	# The label sits on the screen side of the chevron and never rotates: text you tilt
	# your head to read is worse than no text.
	var label: Label3D = p.get_child(1)
	if label.text != text:
		label.text = text
	label.modulate = c
	# Back along the pointing direction, clear of the chevron's body, and aligned so the
	# text runs toward the middle of the view rather than off its edge.
	var back := -Vector2(cos(angle), sin(angle)) * DISTANCE * SIZE * 1.6
	label.position = Vector3(back.x, back.y, 0.0)
	if cos(angle) > 0.3:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	elif cos(angle) < -0.3:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_pointer() -> Node3D:
	if _chevron == null:
		# A ">" in the XY plane, pointing +X, tip at the origin so it sits right on
		# the edge point.
		_chevron = ArVisuals.line_mesh(PackedVector3Array([
			Vector3(-0.6, 0.5, 0), Vector3(0, 0, 0),
			Vector3(0, 0, 0), Vector3(-0.6, -0.5, 0),
			Vector3(-1.1, 0.5, 0), Vector3(-0.5, 0, 0),
			Vector3(-0.5, 0, 0), Vector3(-1.1, -0.5, 0),
		]))

	var p := Node3D.new()
	p.name = "Pointer%d" % _pool.size()
	var chevron := MeshInstance3D.new()
	chevron.mesh = _chevron
	chevron.scale = Vector3.ONE * DISTANCE * SIZE
	chevron.material_override = ArVisuals.additive_material(Color.WHITE)
	p.add_child(chevron)
	ArVisuals.create_label(p, "", DISTANCE * SIZE * 0.6, Color.WHITE)
	add_child(p)
	return p
