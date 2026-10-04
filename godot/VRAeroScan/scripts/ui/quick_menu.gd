class_name QuickMenu
extends Node3D
## A small menu floating in the glasses, driven by head gaze: a reticle sits in the middle
## of the view, you turn your head to put it on an item, and tap the phone's pad to
## choose it.
##
## The menu is anchored in the WORLD where you were looking when it opened, not to your
## head — so turning your head moves the reticle across the items, which is what makes
## pointing possible at all. It faces you, upright to the world like every label here.
##
## Rows are text on a dark (invisible, on this additive display) background; the row under
## the reticle is boxed and bright. Pure presentation: AppBootstrap decides what an item
## does.

## Height of one row, degrees of view.
const ROW_DEG := 2.6
## Width of the menu, degrees of view.
const WIDTH_DEG := 16.0

## One row: text shown, and the command AppBootstrap runs. An empty command is a title.
class Item:
	var text: String
	var command: String

	func _init(t: String, c: String) -> void:
		text = t
		command = c


var items: Array[Item] = []
## Index of the row under the reticle, or -1.
var hovered := -1

var _rig: SkyRig
var _labels: Array[Label3D] = []
var _box: MeshInstance3D
var _box_material: StandardMaterial3D
var _row_h := 1.0
var _width := 1.0


func initialize(rig: SkyRig) -> void:
	_rig = rig
	name = "QuickMenu"
	visible = false
	rig.marker_root.add_child(self)
	_row_h = rig.sky_radius * deg_to_rad(ROW_DEG)
	_width = rig.sky_radius * deg_to_rad(WIDTH_DEG)

	# One box, moved to whichever row is hovered: an outline, never a fill.
	_box = MeshInstance3D.new()
	_box.mesh = ArVisuals.square_outline()
	_box_material = ArVisuals.additive_material(Color(1.0, 0.95, 0.7))
	_box.material_override = _box_material
	_box.scale = Vector3(_width, _row_h * 0.9, 1.0)
	add_child(_box)


## Open centred on a world direction (where the user is looking), facing them.
func open(direction: Vector3, menu_items: Array[Item]) -> void:
	items = menu_items
	position = direction.normalized() * _rig.sky_radius
	var up := Vector3.UP if absf(direction.normalized().y) < 0.98 else Vector3.BACK
	basis = Basis.looking_at(direction, up)
	_build_rows()
	visible = true
	set_hovered(-1)


## Swap the rows for another page, staying where the menu is.
func set_items(menu_items: Array[Item]) -> void:
	items = menu_items
	_build_rows()
	set_hovered(-1)


func close() -> void:
	visible = false
	hovered = -1


func is_open() -> bool:
	return visible


## Replace the text of row i (e.g. a live readout in the title).
func set_text(i: int, text: String) -> void:
	if i < _labels.size() and _labels[i].text != text:
		items[i].text = text
		_labels[i].text = text


## The selectable row a gaze direction points at, or -1: the ray from the eye along
## `forward`, met with the menu's plane.
func row_at(forward: Vector3) -> int:
	if not visible:
		return -1
	var normal := basis.z  # toward the viewer
	var along := forward.dot(normal)
	if along >= -1e-6:
		return -1  # looking away from the menu entirely
	var t := position.dot(normal) / along
	var local := basis.inverse() * (forward * t - position)
	if absf(local.x) > _width / 2.0:
		return -1
	var i := int(floor((_top() - local.y) / _row_h))
	if i < 0 or i >= items.size() or items[i].command.is_empty():
		return -1
	return i


func set_hovered(i: int) -> void:
	hovered = i
	_box.visible = i >= 0
	if i >= 0:
		_box.position = Vector3(0.0, _row_y(i), 0.0)
	for j in _labels.size():
		var title := items[j].command.is_empty()
		_labels[j].modulate = Color(1.0, 0.95, 0.7) if j == i else (
				Color(0.55, 0.75, 0.9) if title else Color(0.7, 0.85, 1.0, 0.8))


func _build_rows() -> void:
	for label in _labels:
		label.queue_free()
	_labels.clear()
	for i in items.size():
		var label := ArVisuals.create_label(self, items[i].text, _row_h * 0.5, Color.WHITE,
				HORIZONTAL_ALIGNMENT_CENTER)
		label.position = Vector3(0.0, _row_y(i), 0.0)
		_labels.append(label)


func _top() -> float:
	return items.size() * _row_h / 2.0


func _row_y(i: int) -> float:
	return _top() - (i + 0.5) * _row_h
