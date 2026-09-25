class_name SkyRig
extends Node3D
## The world-fixed frame everything in the sky hangs in, and the camera that looks
## around inside it.
##
## The frame IS Godot world space: -Z true north, +X east, +Y up (see GeoMath). This
## node stays at the origin with identity rotation, so GeoMath.sky_direction() output
## is directly a world position with no intermediate transform to get wrong.
##
## Markers never move with your head. The CAMERA rotates inside the fixed frame, which
## is what keeps a marker glued to the real aircraft as you turn. Rotating the sky
## around a fixed camera looks identical on a monitor and falls apart in stereo,
## because the markers would swim against the real world seen through the lenses.
##
## Everything sits on a dome of fixed sky_radius rather than at true distance. At true
## scale a 737 at 30 nm is sub-pixel and a satellite is far beyond any sane far plane.
## A large radius also means near-zero stereo disparity, which is correct: distant sky
## objects should converge at infinity, not fight the Viture's fixed focal plane.
##
## STEREO. In 3D mode the Viture glasses take one 3840x1080 frame, left eye on the left
## half. Every marker is on a 500 m dome, where a 64 mm eye separation is 0.007° of
## disparity — far below a pixel — so both eyes need the same image. The sky is therefore
## rendered ONCE into a per-eye SubViewport and shown in both halves: half the GPU cost,
## and optically correct, since sky objects should converge at infinity.

## Radius of the marker dome, metres.
@export var sky_radius := 500.0

## Vertical field of view. 23.5° is the Viture Pro XR's 46° diagonal at 16:9 — match
## the glasses so a marker's on-screen position means the same thing it will in AR.
@export var vertical_fov_deg := 23.5

## Faint dashed ring at 0° elevation. On by default since satellites are drawn below the
## horizon too (2026-09-24): without it, nothing says which side of it a marker is on —
## the cardinal ticks mark only four points.
@export var show_horizon_ring := true

enum Stereo { AUTO, MONO, SIDE_BY_SIDE }
## AUTO picks side-by-side when the window is 3:1 or wider — the glasses' 3D mode is
## 32:9 — and mono otherwise (the glasses' 2D mode, a desktop monitor).
@export var stereo := Stereo.AUTO

var tracker: HeadTracker
var calibration: CompassCalibration
var camera: Camera3D
## Parent for all sky markers.
var marker_root: Node3D

var _billboard := Basis.IDENTITY
var _horizon_ring: MeshInstance3D
var _eye_viewport: SubViewport
var _eye_views: Array[TextureRect] = []


func _init() -> void:
	# Before markers and cardinals, so they orient against this frame's camera.
	process_priority = -10


func _ready() -> void:
	transform = Transform3D.IDENTITY

	marker_root = Node3D.new()
	marker_root.name = "Markers"
	add_child(marker_root)

	camera = Camera3D.new()
	camera.name = "SkyCamera"
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = vertical_fov_deg
	camera.near = 0.1
	camera.far = sky_radius * 2.0

	if is_side_by_side():
		_build_side_by_side()
	else:
		add_child(camera)
	camera.make_current()

	# Black is invisible on the additive display. The project default is black too;
	# this makes it true even if someone changes that.
	RenderingServer.set_default_clear_color(Color.BLACK)

	_build_horizon_ring()
	set_horizon_ring_visible(show_horizon_ring)


## Supply the tracker and calibration. Kept out of _ready so the app can choose between
## the real device and MockHeadTracker at runtime.
func initialize(head_tracker: HeadTracker, compass: CompassCalibration) -> void:
	tracker = head_tracker
	calibration = compass


func _process(delta: float) -> void:
	if tracker == null or calibration == null:
		return

	tracker.tick(delta)
	if tracker.is_available():
		# Input events are dispatched before _process, so a drag this frame already
		# shows — the sky feels attached to the finger rather than a frame behind.
		camera.basis = calibration.to_world_basis(tracker.raw_basis())

	_billboard = _face_camera_basis()


## Change the rendered vertical FOV. It must equal the glasses' real optical FOV, or
## everything off-centre is scaled: too large and markers crowd toward the middle (the sky
## looks compressed), too small and they spread out. Either way they swim against the
## real world as you nod. Tune it by nodding until markers stay glued to real objects.
func set_vertical_fov(degrees: float) -> void:
	vertical_fov_deg = clampf(degrees, 10.0, 60.0)
	camera.fov = vertical_fov_deg


## Whether this rig renders a side-by-side stereo frame.
func is_side_by_side() -> bool:
	match stereo:
		Stereo.SIDE_BY_SIDE:
			return true
		Stereo.MONO:
			return false
	var size := get_viewport().get_visible_rect().size
	return size.y > 0.0 and size.x / size.y >= 3.0


## The camera renders into one eye-sized SubViewport, which shares this world (a
## SubViewport does unless told otherwise). Two TextureRects then show that single image
## in the left and right halves of the real window.
func _build_side_by_side() -> void:
	_eye_viewport = SubViewport.new()
	_eye_viewport.name = "EyeViewport"
	_eye_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_eye_viewport)
	# Inside a SubViewport (not a Node3D) the camera's transform is effectively global,
	# so _process can keep setting its basis exactly as in mono.
	_eye_viewport.add_child(camera)

	var layer := CanvasLayer.new()
	layer.name = "StereoLayer"
	layer.layer = -1  # beneath any HUD
	add_child(layer)
	for i in 2:
		var view := TextureRect.new()
		view.name = "LeftEye" if i == 0 else "RightEye"
		view.texture = _eye_viewport.get_texture()
		view.stretch_mode = TextureRect.STRETCH_SCALE
		layer.add_child(view)
		_eye_views.append(view)

	get_viewport().size_changed.connect(_layout_side_by_side)
	_layout_side_by_side()


func _layout_side_by_side() -> void:
	var size := get_viewport().get_visible_rect().size
	var eye := Vector2(size.x / 2.0, size.y)
	_eye_viewport.size = Vector2i(eye)
	for i in 2:
		_eye_views[i].position = Vector2(eye.x * i, 0.0)
		_eye_views[i].size = eye


## Where the user is facing, degrees true. Meaningless until calibrated.
func current_heading_deg() -> float:
	if tracker == null or calibration == null:
		return 0.0
	return calibration.true_heading(tracker.raw_yaw_deg())


## World position for a sky direction, on the dome.
func position_for(azimuth_deg: float, elevation_deg: float) -> Vector3:
	return GeoMath.sky_direction(azimuth_deg, elevation_deg) * sky_radius


func position_for_look(look: LookAngles) -> Vector3:
	return position_for(look.azimuth_deg, look.elevation_deg)


## Degrees between gaze and a sky direction, for decluttering and off-screen hints —
## both of which a 46° field of view makes necessary rather than optional.
func angle_from_centre(azimuth_deg: float, elevation_deg: float) -> float:
	var forward := -camera.global_basis.z
	return rad_to_deg(forward.angle_to(GeoMath.sky_direction(azimuth_deg, elevation_deg)))


## The orientation every flat marker should take this frame. Computed once, shared.
func billboard_basis() -> Basis:
	return _billboard


## Face the camera PLANE, with up taken from the world so head roll does not tip the
## text — you tilt your head constantly while looking up. Matching the camera plane
## rather than pointing at the camera keeps every label co-planar with the screen, so
## text stays unskewed as it drifts off-centre.
##
## Straight up, world-up and gaze coincide and "upright" stops meaning anything, so
## near the zenith the camera's own up is used instead.
func _face_camera_basis() -> Basis:
	var cam := camera.global_basis
	var forward := -cam.z
	var up := Vector3.UP if absf(forward.y) < 0.98 else cam.y
	return Basis.looking_at(forward, up)


func set_horizon_ring_visible(shown: bool) -> void:
	show_horizon_ring = shown
	if _horizon_ring != null:
		_horizon_ring.visible = shown


## Dashed, like every long guide here: a solid line all round would paint over the very
## horizon the user is looking at. 2° dashes, 2° gaps.
func _build_horizon_ring() -> void:
	const DASHES := 90
	var pairs := PackedVector3Array()
	for i in DASHES:
		var start := 360.0 * i / DASHES
		pairs.append(position_for(start, 0.0))
		pairs.append(position_for(start + 180.0 / DASHES, 0.0))

	var ring := MeshInstance3D.new()
	_horizon_ring = ring
	ring.name = "HorizonRing"
	ring.mesh = ArVisuals.line_mesh(pairs)
	ring.material_override = ArVisuals.additive_material(Color(0.3, 0.5, 0.6, 0.25))
	add_child(ring)
