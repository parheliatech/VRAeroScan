class_name CardinalMarkers
extends Node3D
## The ghost cardinal markers, and above all the ghost N.
##
## The N is what the user aligns the sky against. Heading calibration here is manual —
## drag the horizon until north is where you know north to be — so the N is not
## decoration, it is the control's readout. If you cannot see it, you cannot calibrate.
##
## It climbs: a mark only on the horizon vanishes the moment you look up, and looking
## up is the entire point. So north carries a dashed vertical guide into the sky.
##
## It brightens while you adjust: ghost-faint is right while watching aircraft and
## wrong while aligning, so set_adjusting() lifts the set to full strength during a
## drag — instantly — and lets it fade back gently afterwards.

## Show E, S and W as well as N, more faintly.
@export var show_all_cardinals := true
## Degrees above the horizon to place the letters.
@export var label_elevation_deg := 3.0
## Dashed vertical line at due north, so north stays findable when looking up.
@export var show_north_guide := true
## How far up the north guide climbs, degrees. 90 reaches the zenith.
@export_range(10.0, 90.0) var north_guide_elevation_deg := 75.0

@export var north_color := Color(0.45, 0.85, 1.0)
@export var other_color := Color(0.6, 0.7, 0.8)
## Resting opacity. Deliberately faint: a reference mark over the real sky.
@export_range(0.02, 1.0) var resting_alpha := 0.22
## Opacity while the user is dragging the horizon.
@export_range(0.1, 1.0) var adjusting_alpha := 0.95
## Seconds to fade back to resting after a drag ends.
@export var fade_seconds := 1.2

var _rig: SkyRig
var _billboards: Array[Node3D] = []
var _north_materials: Array[StandardMaterial3D] = []
var _other_materials: Array[StandardMaterial3D] = []
var _north_labels: Array[Label3D] = []
var _other_labels: Array[Label3D] = []
var _alpha := 0.0
var _adjusting := false


func initialize(rig: SkyRig) -> void:
	_rig = rig
	_alpha = resting_alpha
	_build()
	_apply_alpha(_alpha)


## Called by the touch control while the user is dragging.
func set_adjusting(adjusting: bool) -> void:
	_adjusting = adjusting


func _process(delta: float) -> void:
	if _rig == null:
		return

	var face := _rig.billboard_basis()
	for b in _billboards:
		b.basis = face

	var target := adjusting_alpha if _adjusting else resting_alpha
	if not is_equal_approx(_alpha, target):
		# Snap up instantly, fade down gently: the user wants the mark the instant they
		# touch, and does not want it yanked away afterwards.
		_alpha = target if _adjusting else move_toward(_alpha, target,
				(adjusting_alpha - resting_alpha) * delta / fade_seconds)
		_apply_alpha(_alpha)


func _build() -> void:
	_build_cardinal("N", 0.0, north_color, _north_materials, _north_labels, 1.0)
	if show_all_cardinals:
		_build_cardinal("E", 90.0, other_color, _other_materials, _other_labels, 0.7)
		_build_cardinal("S", 180.0, other_color, _other_materials, _other_labels, 0.7)
		_build_cardinal("W", 270.0, other_color, _other_materials, _other_labels, 0.7)
	if show_north_guide:
		_build_north_guide()


func _build_cardinal(letter: String, azimuth_deg: float, color: Color,
		materials: Array[StandardMaterial3D], labels: Array[Label3D], scale_factor: float) -> void:
	var root := Node3D.new()
	root.name = "Cardinal_" + letter
	root.position = _rig.position_for(azimuth_deg, label_elevation_deg)
	add_child(root)
	_billboards.append(root)

	# Scale with the dome so the mark subtends a constant angle however it is tuned.
	var mark_size := _rig.sky_radius * 0.05 * scale_factor

	var tick := MeshInstance3D.new()
	tick.mesh = ArVisuals.cardinal_tick()
	tick.scale = Vector3.ONE * mark_size
	var material := ArVisuals.additive_material(color)
	tick.material_override = material
	root.add_child(tick)
	materials.append(material)

	var label := ArVisuals.create_label(root, letter, mark_size * 1.6, color)
	label.position = Vector3(0, mark_size * 0.95, 0)
	labels.append(label)


## Dashed rather than solid: on an additive display a continuous bright line across the
## sky is genuinely obstructive, while a broken one still reads as "that way".
func _build_north_guide() -> void:
	const DASHES := 14
	var pairs := PackedVector3Array()
	for i in DASHES:
		var t0 := float(i) / DASHES
		var t1 := t0 + 0.55 / DASHES
		pairs.append(_rig.position_for(0.0, lerpf(label_elevation_deg, north_guide_elevation_deg, t0)))
		pairs.append(_rig.position_for(0.0, lerpf(label_elevation_deg, north_guide_elevation_deg, t1)))

	var guide := MeshInstance3D.new()
	guide.name = "NorthGuide"
	guide.mesh = ArVisuals.line_mesh(pairs)
	var material := ArVisuals.additive_material(north_color)
	guide.material_override = material
	add_child(guide)
	_north_materials.append(material)


func _apply_alpha(alpha: float) -> void:
	for m in _north_materials:
		m.albedo_color = Color(north_color, alpha)
	for m in _other_materials:
		m.albedo_color = Color(other_color, alpha * 0.65)
	for l in _north_labels:
		l.modulate = Color(north_color, alpha)
	for l in _other_labels:
		l.modulate = Color(other_color, alpha * 0.65)
