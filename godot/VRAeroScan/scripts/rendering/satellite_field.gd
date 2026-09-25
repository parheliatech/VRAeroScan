class_name SatelliteField
extends Node3D
## Every satellite's icon, moved by the GPU: one MultiMesh per icon shape
## (SatelliteIcons), each a single draw call.
##
## Thousands of satellites cannot each be a node that GDScript moves every frame — the
## phone manages a few hundred that way, and the active catalogue is 16,000, most of them
## below the horizon where they are drawn too (see SatelliteSky). So each satellite is
## one instance in the MultiMesh for its icon, holding its last SGP4 sample: position relative to the observer in
## the instance transform's origin, velocity and sample time in its custom data. The
## vertex shader extrapolates to now, projects onto the dome and billboards the diamond.
## GDScript only touches an instance when SatelliteSky resamples it.
##
## DIAMONDS SHRINK WITH DISTANCE, as a depth cue. From the ground, 96% of Starlink is on
## the far side of the Earth, 3,000–13,000 km away and crowded into the lower half of the
## view; a satellite overhead is ~500 km away. Size goes with the square root of range —
## 1× at 1,000 km — clamped to MIN_SCALE..MAX_SCALE, so the far side reads as a fine,
## distant layer and the near sky stands out, and nothing becomes too small to see.
##
## direction_now() is the same arithmetic on the CPU, for tests and anything that needs
## to agree with what is drawn. It reads a CPU copy of what was uploaded: the rendering
## server does not hand MultiMesh data back (and headless, keeps none at all).

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_test_disabled, skip_vertex_transform, fog_disabled;

uniform float now_s;
uniform float dome_radius = 500.0;
uniform float size_rad = 0.03;
uniform float brightness = 1.0;
uniform float reference_range_m = 1.0e6;
uniform float min_scale = 0.3;
uniform float max_scale = 1.4;

varying vec4 tint;

void vertex() {
	// Instance origin: sampled position, metres from the observer, world axes.
	// INSTANCE_CUSTOM: velocity (m/s) and sample time (s since the time base).
	vec3 rel = MODEL_MATRIX[3].xyz + INSTANCE_CUSTOM.xyz * (now_s - INSTANCE_CUSTOM.w);
	vec3 centre = normalize(rel) * dome_radius;
	float scale = clamp(sqrt(reference_range_m / length(rel)), min_scale, max_scale);

	// Face the camera plane with up taken from the world, like SkyRig.billboard_basis().
	vec3 forward = -INV_VIEW_MATRIX[2].xyz;
	vec3 up_ref = abs(forward.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : INV_VIEW_MATRIX[1].xyz;
	vec3 right = normalize(cross(forward, up_ref));
	vec3 up = cross(right, forward);
	vec3 world = centre + (right * VERTEX.x + up * VERTEX.y) * dome_radius * size_rad * scale;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	tint = COLOR;
}

void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = tint.a * brightness;
}
"""

const REFERENCE_RANGE_M := 1.0e6
const MIN_SCALE := 0.3
const MAX_SCALE := 1.4

var _rig: SkyRig
var _sky: SatelliteSky
var _material: ShaderMaterial
var _satellites: Array[Satellite] = []
## SatelliteIcons.Icon -> MultiMeshInstance3D, created on first use.
var _layers: Dictionary = {}
# CPU copies of the per-instance data, as uploaded, indexed by Satellite.render_index.
var _origins := PackedVector3Array()
var _customs := PackedColorArray()
var _colors := PackedColorArray()


func initialize(rig: SkyRig, sky: SatelliteSky) -> void:
	_rig = rig
	_sky = sky
	name = "SatelliteField"
	var shader := Shader.new()
	shader.code = SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("dome_radius", rig.sky_radius)
	_material.set_shader_parameter("size_rad", SkyMarker.ANGULAR_SIZE)
	_material.set_shader_parameter("reference_range_m", REFERENCE_RANGE_M)
	_material.set_shader_parameter("min_scale", MIN_SCALE)
	_material.set_shader_parameter("max_scale", MAX_SCALE)
	rig.marker_root.add_child(self)


## A new catalogue: one instance per satellite, in its icon's MultiMesh, all uploaded now.
func set_catalogue(list: Array[Satellite], color_of: Callable) -> void:
	_satellites = list
	_origins.resize(list.size())
	_customs.resize(list.size())
	_colors.resize(list.size())
	var counts := {}
	for i in list.size():
		var sat := list[i]
		sat.render_index = i
		sat.render_slot = counts.get(sat.icon, 0)
		counts[sat.icon] = sat.render_slot + 1
	for icon: int in SatelliteIcons.Icon.values():
		var count: int = counts.get(icon, 0)
		if count > 0 or _layers.has(icon):
			_layer(icon).multimesh.instance_count = count
	upload(list)
	recolor(color_of)


## Re-upload satellites SatelliteSky has just resampled.
func upload(list: Array[Satellite]) -> void:
	for sat in list:
		var i := sat.render_index
		if i < 0 or i >= _origins.size():
			continue
		var s := _sky.world_state(sat)
		_origins[i] = Vector3(s[0], s[1], s[2])
		_customs[i] = Color(s[3], s[4], s[5], sat.sampled_unix - _sky.time_base_unix)
		var mm: MultiMesh = _layers[sat.icon].multimesh
		mm.set_instance_transform(sat.render_slot, Transform3D(Basis.IDENTITY, _origins[i]))
		mm.set_instance_custom_data(sat.render_slot, _customs[i])


## Colour every instance: color_of(Satellite) -> Color, with alpha 0 for one not drawn
## here (filtered out, or drawn by a full SkyMarker instead).
func recolor(color_of: Callable) -> void:
	for sat in _satellites:
		if sat.render_index >= 0:
			var c: Color = color_of.call(sat) if sat.ok else Color(0, 0, 0, 0)
			_colors[sat.render_index] = c
			(_layers[sat.icon].multimesh as MultiMesh).set_instance_color(sat.render_slot, c)


## Per frame: the shader's clock and overall brightness (shared by every layer).
func tick(unix_s: float, brightness: float) -> void:
	_material.set_shader_parameter("now_s", unix_s - _sky.time_base_unix)
	_material.set_shader_parameter("brightness", brightness)


## The unit direction the shader draws a satellite at, at unix_s: the same maths, on the
## CPU in float32 like the GPU.
func direction_now(sat: Satellite, unix_s: float) -> Vector3:
	return _position_now(sat, unix_s).normalized()


## Icon size relative to a tracked marker, for a satellite range_m away — the shader's
## formula.
static func size_scale(range_m: float) -> float:
	return clampf(sqrt(REFERENCE_RANGE_M / range_m), MIN_SCALE, MAX_SCALE)


## The size the shader draws a satellite at, at unix_s.
func size_now(sat: Satellite, unix_s: float) -> float:
	return size_scale(_position_now(sat, unix_s).length())


func instance_color(sat: Satellite) -> Color:
	return _colors[sat.render_index]


## Instances across every icon's MultiMesh.
func instance_total() -> int:
	var total := 0
	for layer: MultiMeshInstance3D in _layers.values():
		total += layer.multimesh.instance_count
	return total


## The MultiMesh drawing a satellite's icon, for tests.
func layer_mesh(sat: Satellite) -> Mesh:
	return (_layers[sat.icon] as MultiMeshInstance3D).multimesh.mesh


func _position_now(sat: Satellite, unix_s: float) -> Vector3:
	var i := sat.render_index
	var custom := _customs[i]
	var t := unix_s - _sky.time_base_unix
	return _origins[i] + Vector3(custom.r, custom.g, custom.b) * (t - custom.a)


func _layer(icon: int) -> MultiMeshInstance3D:
	if not _layers.has(icon):
		var layer := MultiMeshInstance3D.new()
		layer.name = SatelliteIcons.Icon.keys()[icon].capitalize()
		layer.multimesh = MultiMesh.new()
		layer.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		layer.multimesh.use_colors = true
		layer.multimesh.use_custom_data = true
		layer.multimesh.mesh = SatelliteIcons.mesh(icon)
		layer.material_override = _material
		# The shader moves vertices anywhere on the dome; never let the engine cull it.
		layer.custom_aabb = AABB(Vector3.ONE * -_rig.sky_radius * 2.0, Vector3.ONE * _rig.sky_radius * 4.0)
		add_child(layer)
		_layers[icon] = layer
	return _layers[icon]
