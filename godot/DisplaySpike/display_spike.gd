extends Control
## Hardware spike, build-order step 1: does a Godot APK reach the Viture glasses, and how?
##
## Questions this answers, all by looking:
##   1. Does anything appear on the glasses at all?
##   2. Mirrored (phone and glasses show the same thing) or a separate screen?
##   3. Glasses in 2D mode: one image to both eyes. In 3D mode they expect side-by-side
##      3840x1080. The left and right halves here are deliberately different — an L and
##      an R — so in 3D mode each eye should see only its own letter, and the shared
##      horizon line should fuse into one line at a comfortable depth.
##   4. Letterboxing: the phone's panel is ~2.17:1, side-by-side is 3.56:1. Mirroring
##      one onto the other may leave bars; the green border shows exactly where the app's
##      frame ends.
##
##   5. With the VitureGlasses plugin present: does the glasses' own IMU stream head pose?
##      The pose array layout is undocumented; it is shown raw so it can be read off while
##      turning your head, and a marker moves with the first three values.
##
## Everything reported on screen is also printed with a "SPIKE" prefix, so it can be
## read over adb without anyone copying numbers off the glasses:
##   adb logcat -s godot | grep SPIKE

const BORDER := Color(0.3, 1.0, 0.4)
const LEFT := Color(0.4, 0.8, 1.0)
const RIGHT := Color(1.0, 0.6, 0.3)
const INFO := Color(0.85, 0.85, 0.85)

var _font: Font
var _info := ""
var _sensors := ""
var _touch_count := 0
var _last_screen_count := -1
var _t := 0.0
var _log_timer := 0.0
var _glasses: Object
var _glasses_text := "VitureGlasses plugin: not present"
var _last_pose_count := 0
var _pose_rate := 0.0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	DisplayServer.screen_set_keep_on(true)
	get_viewport().size_changed.connect(_report)
	_report()

	if Engine.has_singleton("VitureGlasses"):
		_glasses = Engine.get_singleton("VitureGlasses")
		_glasses.status_changed.connect(func(s: String) -> void: print("SPIKE glasses status: ", s))
		_glasses.glasses_state_changed.connect(
				func(id: int, value: int) -> void: print("SPIKE glasses state %d = %d" % [id, value]))
		_glasses.startGlasses()


func _process(delta: float) -> void:
	_t += delta
	_log_timer += delta

	# Plugging the glasses in while running should show up here if Android exposes them
	# to Godot as a second screen.
	if DisplayServer.get_screen_count() != _last_screen_count:
		_report()

	_sensors = "gyro %s\naccel %s\nmag %s\ngravity %s\nfps %d   touches %d" % [
		_v(Input.get_gyroscope()), _v(Input.get_accelerometer()),
		_v(Input.get_magnetometer()), _v(Input.get_gravity()),
		Engine.get_frames_per_second(), _touch_count]
	if _glasses != null:
		var pose: PackedFloat32Array = _glasses.getPose()
		_glasses_text = "glasses: %s  type %d  display mode %d\npose[%d] %s\nsamples %d (%.0f/s)" % [
			_glasses.getStatus(), _glasses.getDeviceType(), _glasses.getDisplayMode(), pose.size(),
			_fmt(pose), _glasses.getPoseCount(), _pose_rate]

	if _log_timer >= 2.0:
		if _glasses != null:
			var count: int = _glasses.getPoseCount()
			_pose_rate = (count - _last_pose_count) / _log_timer
			_last_pose_count = count
			print("SPIKE ", _glasses_text.replace("\n", " | "))
		_log_timer = 0.0
		print("SPIKE sensors: ", _sensors.replace("\n", " | "))

	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		_touch_count += 1
		print("SPIKE touch at ", (event as InputEventScreenTouch).position)


func _report() -> void:
	_last_screen_count = DisplayServer.get_screen_count()
	var lines: PackedStringArray = []
	lines.append("%s  Android %s  Godot %s" % [OS.get_model_name(), OS.get_version(),
			Engine.get_version_info()["string"]])
	lines.append("screens: %d   window screen: %d" % [_last_screen_count,
			DisplayServer.window_get_current_screen()])
	for i in _last_screen_count:
		lines.append("  screen %d: %s px, %d dpi, %.0f Hz, scale %.2f" % [i,
				DisplayServer.screen_get_size(i), DisplayServer.screen_get_dpi(i),
				DisplayServer.screen_get_refresh_rate(i), DisplayServer.screen_get_scale(i)])
	lines.append("window %s   viewport %s" % [DisplayServer.window_get_size(),
			get_viewport_rect().size])
	_info = "\n".join(lines)
	for line in lines:
		print("SPIKE ", line)


func _draw() -> void:
	var size := get_viewport_rect().size
	var half := Vector2(size.x / 2.0, size.y)

	_draw_eye(Rect2(Vector2.ZERO, half), "L", LEFT)
	_draw_eye(Rect2(Vector2(half.x, 0), half), "R", RIGHT)

	# The frame's true edge. Bars outside this green line are letterboxing.
	draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), BORDER, false, 4.0)


func _draw_eye(r: Rect2, letter: String, color: Color) -> void:
	var c := r.get_center()

	draw_rect(r.grow(-12), Color(color, 0.5), false, 2.0)

	# Crosshair at the eye's centre.
	draw_line(c - Vector2(60, 0), c + Vector2(60, 0), color, 2.0)
	draw_line(c - Vector2(0, 60), c + Vector2(0, 60), color, 2.0)

	# Shared horizon, same height in both halves: in 3D mode it should fuse into one.
	draw_line(Vector2(r.position.x + 40, c.y + 120), Vector2(r.end.x - 40, c.y + 120), INFO, 2.0)

	# Grid ticks every tenth of the eye's width, to judge scaling and cropping.
	for i in range(1, 10):
		var x := r.position.x + r.size.x * i / 10.0
		draw_line(Vector2(x, r.end.y - 50), Vector2(x, r.end.y - 20), Color(color, 0.7), 2.0)

	# Head pose marker, assuming SpaceWalker's reading of data[0..2] as roll, pitch, yaw:
	# offset by yaw and pitch, with a spoke at the roll angle. If turning your head moves
	# it along the wrong axis, that assumption is what is wrong. Scale is a guess until the
	# units (degrees?) are confirmed.
	if _glasses != null:
		var pose: PackedFloat32Array = _glasses.getPose()
		if pose.size() >= 3:
			var p := c + Vector2(pose[2], -pose[1]) * 4.0
			draw_arc(p, 30.0, 0.0, TAU, 32, Color(1, 1, 0.4), 3.0)
			draw_line(p, p + Vector2(cos(deg_to_rad(pose[0])), sin(deg_to_rad(pose[0]))) * 30.0,
					Color(1, 1, 0.4), 3.0)

	# A dot orbiting the crosshair: smoothness and frame pacing at a glance.
	draw_circle(c + Vector2(cos(_t * 2.0), sin(_t * 2.0)) * 90.0, 8.0, color)

	draw_string(_font, c + Vector2(-40, -110), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 120, color)
	_draw_text(r.position + Vector2(28, 44), _info, 22)
	_draw_text(r.position + Vector2(28, r.size.y - 210), _sensors, 22)
	_draw_text(r.position + Vector2(28, r.size.y - 330), _glasses_text, 22)


func _draw_text(pos: Vector2, text: String, font_size: int) -> void:
	for i in text.split("\n").size():
		draw_string(_font, pos + Vector2(0, i * (font_size + 6)), text.split("\n")[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, INFO)


static func _fmt(a: PackedFloat32Array) -> String:
	var parts: PackedStringArray = []
	for x in a:
		parts.append("%.2f" % x)
	return "[" + ", ".join(parts) + "]"


static func _v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
