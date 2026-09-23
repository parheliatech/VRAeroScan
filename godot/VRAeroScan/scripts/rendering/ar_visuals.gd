class_name ArVisuals
extends RefCounted
## Asset-free visual helpers: procedural line meshes, materials and labels.
##
## Everything is built at runtime rather than authored as scenes or resources, so a
## working app is one script on one node, with nothing to wire by hand and nothing
## that can come unwired.
##
## THE ADDITIVE DISPLAY CONSTRAINT. The Viture's optical see-through lenses ADD light
## to the real world rather than replacing it. Black is invisible. So bright thin marks
## on black read well, and large filled shapes wash out the very sky the user is trying
## to see. Every material here is unshaded and additive; every shape is an outline.


## An unshaded, additive, always-on-top material in one colour.
##
## Additive matches how the optics actually work, and means overlapping markers
## brighten rather than z-fight — the friendlier failure. No depth test because the
## dome has nothing to occlude anything: all markers sit at the same radius.
static func additive_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.albedo_color = color
	return m


## Line segments from pairs of points: [a0, b0, a1, b1, ...]. Godot's PRIMITIVE_LINES
## draws disjoint segments natively, so dashes are just omitted pairs.
static func line_mesh(pairs: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pairs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Square outline in the XY plane, unit size. Aircraft.
##
## Outlines on purpose: a filled shape on an additive display is a bright patch over
## the very piece of sky the user is looking at. Say "here" without hiding what is here.
static func square_outline(half := 0.5) -> ArrayMesh:
	var a := Vector3(-half, -half, 0)
	var b := Vector3(half, -half, 0)
	var c := Vector3(half, half, 0)
	var d := Vector3(-half, half, 0)
	return line_mesh(PackedVector3Array([a, b, b, c, c, d, d, a]))


## Diamond outline, to tell satellites from aircraft by shape.
static func diamond_outline(half := 0.5) -> ArrayMesh:
	var a := Vector3(0, -half, 0)
	var b := Vector3(half, 0, 0)
	var c := Vector3(0, half, 0)
	var d := Vector3(-half, 0, 0)
	return line_mesh(PackedVector3Array([a, b, b, c, c, d, d, a]))


## Horizontal tick with a vertical stem, marking a cardinal direction on the horizon.
static func cardinal_tick(half_width := 0.5, stem_height := 0.35) -> ArrayMesh:
	return line_mesh(PackedVector3Array([
		Vector3(-half_width, 0, 0), Vector3(half_width, 0, 0),
		Vector3.ZERO, Vector3(0, stem_height, 0),
	]))


## A world-space text label. Its FRONT faces +Z, the same way the outline meshes do,
## so orienting the parent to face the camera orients both.
static func create_label(parent: Node3D, text: String, height: float, color: Color,
		alignment := HORIZONTAL_ALIGNMENT_CENTER) -> Label3D:
	var label := Label3D.new()
	label.text = text
	# A large font size scaled down keeps glyphs crisp at distance.
	label.font_size = 64
	label.pixel_size = height / 64.0
	label.modulate = color
	label.outline_size = 0  # A black outline is invisible on this display anyway.
	label.horizontal_alignment = alignment
	label.shaded = false
	label.double_sided = true
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED  # the parent faces the camera
	parent.add_child(label)
	return label
