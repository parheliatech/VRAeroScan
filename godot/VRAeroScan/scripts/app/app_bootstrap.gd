class_name AppBootstrap
extends Node3D
## The whole app, wired from one script on one node (main.tscn's root).
##
## Builds the sky rig, the ghost cardinals, the touch calibration, the aircraft and
## satellite feeds and the marker pools, and picks a head tracker: any HeadTracker child already present
## wins (that is where the Viture binding will go), otherwise MockHeadTracker is added
## so the pipeline runs at a desk.
##
## Each frame it dead-reckons every aircraft to now, turns that into look angles from
## the observer, and places a pooled marker there. Per frame rather than per poll,
## because a nearby aircraft's look angle changes by degrees per second. Satellites
## likewise, via SatelliteSky, which keeps a whole catalogue current on a budget.

@export_group("Observer")
## Where you are, when the phone cannot say: the fallback until a GPS fix arrives, and
## the position on the desktop. On the phone, the VitureGlasses plugin's location wins as
## soon as it has a fix within max_fix_accuracy_m.
@export var latitude_deg := 34.0522
@export var longitude_deg := -118.2437
@export var altitude_m := 90.0

## Ignore phone fixes worse than this, metres. At 1 nm an observer error of 100 m is
## already 3° of pointing error, so a coarse cell-tower fix is worse than a good manual one.
@export var max_fix_accuracy_m := 100.0

@export_group("Aircraft")
## Hide aircraft reporting on the ground. Almost always below the local horizon anyway.
@export var hide_on_ground := true
## Hide aircraft further than this, nautical miles. The feed radius decides what is
## fetched; this decides what is drawn.
@export var max_draw_range_nm := 60.0
## Off lets tests drive the app without touching the network.
@export var start_feed := true

@export_group("Satellites")
## CelesTrak groups to load; see CelestrakService. "active" is every working satellite
## (~16,600, Starlink's ~11,000 included — on by default, Kendel 2026-09-24: it is most
## of what is up there); "visual" adds the bright spent rocket stages.
@export var satellite_groups := PackedStringArray(["stations", "visual", "active"])
## Which kinds to draw. Each satellite has exactly one kind: see Satellite.
@export_flags("Manned", "Starlink", "LEO", "MEO / HEO", "GEO") var satellite_types := Satellite.ALL_CATEGORIES
## Off lets tests drive the app without touching the network.
@export var start_satellites := true
## Kinds you are following: they get an edge-of-view pointer when off screen, and pass
## predictions with a rise marker when below the horizon. Manned by default: the
## stations are what people go looking for, and pointing at every satellite would line
## the edge of the view. See OffscreenPointers and PassPredictor.
@export_flags("Manned", "Starlink", "LEO", "MEO / HEO", "GEO") var tracked_types := Satellite.MANNED
## Show a rise marker this many minutes before a tracked satellite comes up.
@export_range(1.0, 120.0) var rise_lead_minutes := 20.0
## Untracked satellites are drawn as bare diamonds (thousands of them); only those near
## the middle of the view get a label — at most gaze_labels, within gaze_label_deg — so
## you can read what you are looking at, even along the crowded horizon.
@export var gaze_labels := 8
@export var gaze_label_deg := 8.0

@export_group("Debug")
## On-screen readout of calibration, heading and feed. Off on the phone: on the
## glasses, text is light in your eyes.
@export var show_debug_hud := true

var observer: GeoPoint
var calibration: CompassCalibration
var rig: SkyRig
var cardinals: CardinalMarkers
var horizon_control: TouchHorizonControl
var adsb: AdsbService
var celestrak: CelestrakService
var satellite_sky: SatelliteSky
var pointers: OffscreenPointers
var pass_predictor: PassPredictor
## norad_id -> SkyMarker at the rise point of an upcoming pass.
var active_rise_markers: Dictionary = {}
var satellite_field: SatelliteField
## Tests pin the clock here so satellite positions are deterministic. NAN = real time.
var fixed_unix_time := NAN

## icao24 -> SkyMarker currently in use.
var active_markers: Dictionary = {}
## icao24 -> the Aircraft object the marker's label was built from.
var _labelled_as: Dictionary = {}
## icao24 -> the AircraftIcons.Icon its marker shows.
var _icon_of: Dictionary = {}
## norad_id -> full SkyMarker for a tracked satellite, above or below the horizon.
var active_satellite_markers: Dictionary = {}
## norad_id -> label-only SkyMarker for an untracked satellite near the gaze.
var active_label_markers: Dictionary = {}
## norad_id -> the sample time the marker's label was built from.
var _satellite_labelled_at: Dictionary = {}
var _field_catalogue: Array[Satellite] = []
var _field_filter := []
## One pool per marker kind, since the outline differs.
var _pools := {SkyMarker.Kind.AIRCRAFT: [], SkyMarker.Kind.SATELLITE: [], SkyMarker.Kind.RISE: []}
var _satellite_error := ""

var _last_error := ""
var _hud: Label
var _status_log_timer := 0.0
var _android: Object
var _observer_source := "manual"
var _location_poll_timer := 0.0


func _ready() -> void:
	observer = GeoPoint.new(latitude_deg, longitude_deg, altitude_m)
	if OS.has_feature("mobile"):
		show_debug_hud = false

	calibration = CompassCalibration.new()

	rig = SkyRig.new()
	rig.name = "SkyRig"
	add_child(rig)
	rig.initialize(_find_tracker(), calibration)

	cardinals = CardinalMarkers.new()
	cardinals.name = "Cardinals"
	rig.add_child(cardinals)
	cardinals.initialize(rig)

	pointers = OffscreenPointers.new()
	pointers.initialize(rig.camera)
	pass_predictor = PassPredictor.new()
	quick_menu = QuickMenu.new()
	quick_menu.initialize(rig)
	_build_reticle()

	horizon_control = TouchHorizonControl.new()
	horizon_control.name = "TouchHorizonControl"
	add_child(horizon_control)
	horizon_control.initialize(calibration, cardinals)

	adsb = AdsbService.new()
	adsb.name = "AdsbService"
	add_child(adsb)
	adsb.poll_failed.connect(func(message: String) -> void: _last_error = message)
	adsb.aircraft_updated.connect(func(_all: Dictionary) -> void: _last_error = "")
	if start_feed:
		adsb.start_polling(func() -> GeoPoint: return observer)

	satellite_sky = SatelliteSky.new()
	satellite_field = SatelliteField.new()
	satellite_field.initialize(rig, satellite_sky)
	celestrak = CelestrakService.new()
	celestrak.name = "CelestrakService"
	celestrak.groups = satellite_groups
	add_child(celestrak)
	celestrak.fetch_failed.connect(func(message: String) -> void: _satellite_error = message)
	celestrak.catalogue_updated.connect(func(list: Array[Satellite]) -> void:
		satellite_sky.set_catalogue(list, observer, unix_now()))
	if start_satellites:
		celestrak.start()

	if Engine.has_singleton("VitureGlasses"):
		_android = Engine.get_singleton("VitureGlasses")
		_android.startLocation()
		# On the glasses, the phone's screen is free: put the controls there.
		if _android.getCurrentDisplayId() > 0:
			_android.showControlPanel()

	if show_debug_hud:
		_build_hud()


## Take a phone fix [lat, lon, alt m, accuracy m, age s] as the observer if it is usable.
## Returns whether it was applied.
func apply_location_fix(fix: PackedFloat64Array) -> bool:
	if fix.size() < 5:
		return false
	var accuracy := fix[3]
	if accuracy <= 0.0 or accuracy > max_fix_accuracy_m:
		_observer_source = "manual (GPS ±%dm too coarse)" % roundi(accuracy)
		return false
	var first := not _observer_source.begins_with("GPS")
	observer = GeoPoint.new(fix[0], fix[1], fix[2])
	_observer_source = "GPS ±%dm, %ds old" % [roundi(accuracy), roundi(fix[4])]
	if first:
		print("VRAEROSCAN observer from GPS: %s (±%dm)" % [observer, roundi(accuracy)])
	return true


## Prefer a real tracker: one added as a child, else the Viture glasses when the Android
## plugin is present. Fall back to the mock so nothing about the hardware blocks work on
## the pipeline.
func _find_tracker() -> HeadTracker:
	for child in get_children():
		if child is HeadTracker and not child is MockHeadTracker:
			return child

	if VitureHeadTracker.is_supported():
		var viture := VitureHeadTracker.new()
		viture.name = "VitureHeadTracker"
		add_child(viture)
		return viture

	if OS.has_feature("mobile"):
		push_warning("[AppBootstrap] No head tracker; using the mouse mock. " +
				"On the glasses, markers will not follow your head.")

	var mock := MockHeadTracker.new()
	mock.name = "MockHeadTracker"
	add_child(mock)
	return mock


## N: "I am facing true north right now." A one-step landmark fix — look at something
## you know is due north and press it (or send it: adb shell input keyevent KEYCODE_N).
## Crude but honest, and better than a phone magnetometer near electronics; the drag
## control then trims it.
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.keycode:
		KEY_N:
			if not key.echo:
				run_command("north")
		# Space: the pad's tap; M: the glasses menu. For the desktop, and adb:
		#   adb shell input keyevent KEYCODE_SPACE
		KEY_SPACE:
			if not key.echo:
				run_command("tap")
		KEY_M:
			if not key.echo:
				run_command("menu")
		# [ and ]: step the rendered FOV, to match the glasses' optics by the nod test.
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			var step := 0.5 if key.keycode == KEY_BRACKETRIGHT else -0.5
			rig.set_vertical_fov(rig.vertical_fov_deg + step)
			print("VRAEROSCAN vertical FOV %.1f°" % rig.vertical_fov_deg)


func calibrate_facing_north() -> void:
	calibration.calibrate_from_known_bearing(0.0, rig.tracker.raw_yaw_deg())
	print("VRAEROSCAN calibrated: facing north, offset %.1f°" % calibration.heading_offset_deg)


func _process(delta: float) -> void:
	# The feed reads the observer through a callable, so a new fix moves the query too.
	if _android != null:
		_location_poll_timer += delta
		if _location_poll_timer >= 2.0:
			_location_poll_timer = 0.0
			apply_location_fix(_android.getLocation())
		for command: String in _android.takeCommands():
			run_command(command)
		_panel_status_timer += delta
		if _panel_status_timer >= 0.25:
			_panel_status_timer = 0.0
			_android.setPanelStatus(panel_status())
	update_controls()

	update_aircraft_markers()
	update_satellite_markers()
	update_passes()
	update_satellite_pointers()
	# Last: gaze labels fit around everything already placed.
	update_gaze_labels()
	if _hud != null:
		_hud.text = _hud_text()

	# On the phone there is no HUD, so report to the log instead:
	#   adb logcat -s godot | grep VRAEROSCAN
	if OS.has_feature("mobile"):
		_status_log_timer += delta
		if _status_log_timer >= 5.0:
			_status_log_timer = 0.0
			print("VRAEROSCAN ", _hud_text().replace("\n", " | "))


# --- Controls: one command path for the phone panel, the glasses menu and the keyboard ---

## Close the glasses menu after this long without a tap.
const MENU_IDLE_S := 20.0
## Give up waiting for the "facing north" tap after this long.
const CAPTURE_TIMEOUT_S := 30.0

## Waiting for a tap to take "I'm facing north now" (chosen from the glasses menu: you
## cannot aim at a menu item and face north at the same time, so it takes two steps).
var capturing_north := false
var quick_menu: QuickMenu
var _reticle: Node3D
var _prompt: Label3D
var _menu_idle_until := 0.0
var _capture_until := 0.0
var _panel_status_timer := 0.0


## Run one command. Everything that changes the app's state from outside comes through
## here — the phone's control panel (ControlPanelActivity), the glasses menu and keys:
##   north              I am facing true north now
##   sky:<deg>          move the sky right by deg (negative: left), as a drag would
##   drag:<frac>:<n>    the panel's pad dragged by frac of its width, n fingers
##   drag_end           the pad was released
##   tap                the pad was tapped: open the menu, choose in it, or take north
##   menu               open or close the glasses menu
func run_command(command: String) -> void:
	var parts := command.split(":")
	match parts[0]:
		"north":
			calibrate_facing_north()
			horizon_control.highlight()
		"sky":
			horizon_control.rotate_sky(parts[1].to_float() if parts.size() > 1 else 0.0)
			horizon_control.highlight()
		"drag":
			if parts.size() > 1:
				horizon_control.pad_drag(parts[1].to_float(), parts[2].to_int() if parts.size() > 2 else 1)
		"drag_end":
			horizon_control.pad_release()
		"tap":
			_tap()
		"menu":
			if quick_menu.is_open():
				quick_menu.close()
			else:
				open_menu()
		_:
			push_warning("[AppBootstrap] unknown command: %s" % command)


func open_menu() -> void:
	capturing_north = false
	quick_menu.open(-rig.camera.global_basis.z, _calibration_items())
	_menu_idle_until = _seconds() + MENU_IDLE_S


func _calibration_items() -> Array[QuickMenu.Item]:
	var items: Array[QuickMenu.Item] = []
	items.append(QuickMenu.Item.new(_heading_readout(), ""))
	items.append(QuickMenu.Item.new("Set north…", "set_north"))
	items.append(QuickMenu.Item.new("Sky ← 1°", "sky:-1"))
	items.append(QuickMenu.Item.new("Sky → 1°", "sky:1"))
	items.append(QuickMenu.Item.new("Sky ← 0.1°", "sky:-0.1"))
	items.append(QuickMenu.Item.new("Sky → 0.1°", "sky:0.1"))
	items.append(QuickMenu.Item.new("Close", "close"))
	return items


func _tap() -> void:
	if capturing_north:
		capturing_north = false
		run_command("north")
		return
	if not quick_menu.is_open():
		open_menu()
		return
	var i := quick_menu.hovered
	if i < 0:
		quick_menu.close()  # a tap looking away from the menu dismisses it
		return
	_menu_idle_until = _seconds() + MENU_IDLE_S
	var command := quick_menu.items[i].command
	match command:
		"close":
			quick_menu.close()
		"set_north":
			quick_menu.close()
			capturing_north = true
			_capture_until = _seconds() + CAPTURE_TIMEOUT_S
		_:
			run_command(command)  # nudges keep the menu open, to press again


## Per frame: what the reticle is on, the live readout, timeouts.
func update_controls() -> void:
	if quick_menu.is_open():
		quick_menu.set_hovered(quick_menu.row_at(-rig.camera.global_basis.z))
		quick_menu.set_text(0, _heading_readout())
		if _seconds() > _menu_idle_until:
			quick_menu.close()
	if capturing_north and _seconds() > _capture_until:
		capturing_north = false
	_reticle.visible = quick_menu.is_open() or capturing_north
	_prompt.visible = capturing_north


func _heading_readout() -> String:
	return "Heading %.1f° · offset %.1f°" % [rig.current_heading_deg(), calibration.heading_offset_deg]


## The status line on the phone's control panel.
func panel_status() -> String:
	var cal := "Not calibrated: face north, press \"I'm facing north\""
	if calibration.is_calibrated:
		cal = "Calibrated %ds ago (%s)" % [roundi(calibration.seconds_since_fix()),
				CompassCalibration.Source.keys()[calibration.source].to_lower().replace("_", " ")]
	var text := "%s\n%s" % [_heading_readout(), cal]
	if capturing_north:
		text += "\nFACE TRUE NORTH, THEN TAP"
	return text


## A small cross in the middle of the view, and the prompt under it: shown while the
## glasses menu is open (it is what you aim with) or while waiting for the north tap.
func _build_reticle() -> void:
	const AT := 10.0
	_reticle = Node3D.new()
	_reticle.name = "Reticle"
	_reticle.position = Vector3(0.0, 0.0, -AT)
	rig.camera.add_child(_reticle)
	var arm := AT * deg_to_rad(0.6)
	var gap := AT * deg_to_rad(0.15)
	var cross := MeshInstance3D.new()
	cross.mesh = ArVisuals.line_mesh(PackedVector3Array([
		Vector3(-arm, 0, 0), Vector3(-gap, 0, 0), Vector3(gap, 0, 0), Vector3(arm, 0, 0),
		Vector3(0, -arm, 0), Vector3(0, -gap, 0), Vector3(0, gap, 0), Vector3(0, arm, 0),
	]))
	cross.material_override = ArVisuals.additive_material(Color(1.0, 0.95, 0.7))
	_reticle.add_child(cross)
	_prompt = ArVisuals.create_label(_reticle, "Face true north, then tap", AT * deg_to_rad(0.9),
			Color(1.0, 0.95, 0.7))
	_prompt.position = Vector3(0.0, -AT * deg_to_rad(2.2), 0.0)
	_reticle.visible = false


static func _seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


## Which way something moving from `from` to `to` goes across the view, as an angle in
## the markers' camera-facing plane (radians, counter-clockwise from right) — so an
## aircraft's nose points where it is actually heading in your sky, not where north is.
## Straight toward or away from you there is no sideways motion: nose up.
func travel_angle(from: LookAngles, to: LookAngles) -> float:
	var d := GeoMath.sky_direction(to.azimuth_deg, to.elevation_deg) \
			- GeoMath.sky_direction(from.azimuth_deg, from.elevation_deg)
	var b := rig.billboard_basis()
	var x := d.dot(b.x)
	var y := d.dot(b.y)
	if x * x + y * y < 1e-14:
		return PI / 2.0
	return atan2(y, x)


func update_aircraft_markers() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var max_range_m := max_draw_range_nm * GeoMath.METERS_PER_NAUTICAL_MILE

	# While the user drags the sky, dim the aircraft so the ghost N is the brightest
	# thing in view — it is what they are lining up.
	var brightness := 0.35 if horizon_control.is_adjusting() else 1.0

	var seen := {}
	for ac: Aircraft in adsb.aircraft.values():
		if hide_on_ground and ac.on_ground:
			continue

		var position := ac.position_at(now)
		var look := GeoMath.to_look_angles(observer, position)
		if look.range_m > max_range_m:
			continue
		# Just below the horizon is kept, not skipped: SkyMarker fades it over the last
		# degree and a half, so a climbing aircraft rises into view instead of popping.
		if look.elevation_deg < -2.0:
			continue

		seen[ac.icao24] = true

		var marker: SkyMarker = active_markers.get(ac.icao24)
		if marker == null:
			marker = _acquire(SkyMarker.Kind.AIRCRAFT)
			active_markers[ac.icao24] = marker
			_labelled_as.erase(ac.icao24)

		# AdsbService replaces the Aircraft object on every poll, so a new reference
		# means new data. Comparing references keeps string formatting off the per-frame
		# path.
		if _labelled_as.get(ac.icao24) != ac:
			marker.configure(SkyMarker.color_for(ac.classification), SkyMarker.label_for(ac, look))
			var icon := AircraftIcons.icon_for(ac)
			marker.set_icon(icon)
			_icon_of[ac.icao24] = icon
			_labelled_as[ac.icao24] = ac

		marker.set_brightness(brightness)
		marker.set_look(look)
		var directional := AircraftIcons.is_directional(_icon_of.get(ac.icao24, AircraftIcons.Icon.GENERIC))
		marker.set_travel_angle(travel_angle(look, GeoMath.to_look_angles(observer,
				GeoMath.destination_point(position, ac.track_deg, 500.0))) if directional else PI / 2.0)

	# Return markers whose aircraft left the feed, the range, or the sky.
	for key: String in active_markers.keys():
		if not seen.has(key):
			_release(active_markers[key])
			active_markers.erase(key)
			_labelled_as.erase(key)
			_icon_of.erase(key)


## UTC now, in Unix seconds. Satellites need the real wall clock, and an accurate one:
## the ISS moves 1.1° of sky per second of clock error at 400 km range.
func unix_now() -> float:
	return fixed_unix_time if not is_nan(fixed_unix_time) else Time.get_unix_time_from_system()


## Pointers for tracked satellites that are off screen, and for rise markers of ones
## about to come up.
func update_satellite_pointers() -> void:
	var targets: Array[OffscreenPointers.Target] = []
	var now := unix_now()
	for id: int in active_rise_markers:
		var rise_marker: SkyMarker = active_rise_markers[id]
		var p: PassPredictor.SatellitePass = pass_predictor.passes.get(id)
		var rising := _satellite_by_id(id)
		if p == null or rising == null:
			continue
		targets.append(OffscreenPointers.Target.new(rise_marker.position.normalized(),
				"%s rises %s" % [rising.name, PassPredictor.countdown(p.rise_unix - now)],
				SkyMarker.color_for_sat(rising)))
	for id: int in active_satellite_markers:
		var sat := _satellite_by_id(id)
		if sat == null:
			continue
		var marker: SkyMarker = active_satellite_markers[id]
		targets.append(OffscreenPointers.Target.new(marker.position.normalized(), sat.name,
				SkyMarker.color_for_sat(sat)))
	pointers.update_targets(targets, 0.35 if horizon_control.is_adjusting() else 1.0)


## Keep pass predictions current for tracked satellites, and place a rise marker on the
## horizon where each is about to come up. The satellite's own marker is drawn too,
## below the horizon: the chevron says where it will appear, the diamond where it is.
func update_passes() -> void:
	var now := unix_now()
	_tracked_satellites()
	pass_predictor.update(_tracked_for_passes, observer, now)
	var lead_s := rise_lead_minutes * 60.0

	var shown := {}
	for p: PassPredictor.SatellitePass in upcoming_passes(now):
		if p.rise_unix - now > lead_s:
			continue
		var sat := _satellite_by_id(p.norad_id)
		if sat == null or not (sat.category & satellite_types):
			continue
		shown[p.norad_id] = true
		var marker: SkyMarker = active_rise_markers.get(p.norad_id)
		if marker == null:
			marker = _acquire(SkyMarker.Kind.RISE)
			marker.fades_at_horizon = true
			active_rise_markers[p.norad_id] = marker
		marker.configure(SkyMarker.color_for_sat(sat), SkyMarker.label_for_rise(sat, p, now))
		marker.set_brightness(0.35 if horizon_control.is_adjusting() else 1.0)
		# On the horizon, lifted just enough to clear SkyMarker's horizon fade.
		marker.set_look(LookAngles.new(p.rise_azimuth_deg, SkyMarker.HORIZON_FADE_DEG, 0.0))

	for key: int in active_rise_markers.keys():
		if not shown.has(key):
			_release(active_rise_markers[key])
			active_rise_markers.erase(key)


## Passes that have not yet risen, soonest first, one per physical object: docked
## vehicles and station modules share the station's pass, and the lowest catalogue
## number (the station) stands for all of them.
func upcoming_passes(unix_s: float) -> Array[PassPredictor.SatellitePass]:
	var found: Array[PassPredictor.SatellitePass] = []
	for p: PassPredictor.SatellitePass in pass_predictor.passes.values():
		if p != null and not is_nan(p.rise_unix) and p.rise_unix > unix_s:
			found.append(p)
	found.sort_custom(func(a: PassPredictor.SatellitePass, b: PassPredictor.SatellitePass) -> bool:
		return a.norad_id < b.norad_id)
	var out: Array[PassPredictor.SatellitePass] = []
	for p in found:
		var duplicate := out.any(func(q: PassPredictor.SatellitePass) -> bool:
			return absf(q.rise_unix - p.rise_unix) < 10.0 \
					and absf(GeoMath.bearing_delta(q.rise_azimuth_deg, p.rise_azimuth_deg)) < 1.0)
		if not duplicate:
			out.append(p)
	out.sort_custom(func(a: PassPredictor.SatellitePass, b: PassPredictor.SatellitePass) -> bool:
		return a.rise_unix < b.rise_unix)
	return out


## Most tracked satellites: each gets a full marker node, and tracking all of Starlink
## would mean 11,000 of them.
const MAX_TRACKED := 50

var _tracked: Array[Satellite] = []
var _tracked_for_passes: Array[Satellite] = []
var _tracked_manned: Array[Satellite] = []
var _tracked_from: Array[Satellite] = []
var _tracked_types_built := -1
var _by_id: Dictionary = {}


## Satellites of tracked_types, by catalogue number, at most MAX_TRACKED. Rebuilt only
## when the catalogue or tracked_types changes, not per frame. Passes leave out GEO,
## which never rises or sets.
func _tracked_satellites() -> Array[Satellite]:
	if not is_same(_tracked_from, satellite_sky.satellites) or _tracked_types_built != tracked_types:
		_tracked_from = satellite_sky.satellites
		_tracked_types_built = tracked_types
		_tracked = satellite_sky.satellites.filter(func(s: Satellite) -> bool:
			return s.category & tracked_types)
		_tracked.sort_custom(func(a: Satellite, b: Satellite) -> bool: return a.norad_id < b.norad_id)
		_tracked = _tracked.slice(0, MAX_TRACKED)
		_tracked_for_passes = _tracked.filter(func(s: Satellite) -> bool: return s.category != Satellite.GEO)
		_tracked_manned = _tracked.filter(func(s: Satellite) -> bool: return s.category == Satellite.MANNED)
		_by_id.clear()
		for sat in _tracked:
			_by_id[sat.norad_id] = sat
	return _tracked


func _satellite_by_id(id: int) -> Satellite:
	_tracked_satellites()
	return _by_id.get(id)


## The diamond colour SatelliteField uses; clear for satellites it does not draw.
func _field_color(sat: Satellite) -> Color:
	if not (sat.category & satellite_types) or _by_id.has(sat.norad_id):
		return Color(0, 0, 0, 0)  # filtered out, or a tracked satellite's own marker
	return SkyMarker.color_for_sat(sat)


## Every satellite, every frame, wherever it is — below the horizon and through the
## Earth included. The GPU draws the diamonds (SatelliteField); GDScript only handles
## the tracked satellites' full markers and the few labels near the gaze.
func update_satellite_markers() -> void:
	var now := unix_now()
	satellite_sky.update(observer, now)
	var brightness := 0.35 if horizon_control.is_adjusting() else 1.0

	_tracked_satellites()
	var filter := [satellite_types, tracked_types]
	if not is_same(_field_catalogue, satellite_sky.satellites):
		_field_catalogue = satellite_sky.satellites
		_field_filter = filter
		satellite_field.set_catalogue(satellite_sky.satellites, _field_color)
	else:
		satellite_field.upload(satellite_sky.resampled)
		if _field_filter != filter:
			_field_filter = filter
			satellite_field.recolor(_field_color)
	satellite_field.tick(now, brightness)

	var seen := {}
	for sat in _tracked:
		if not sat.ok or not (sat.category & satellite_types):
			continue
		if sat.category == Satellite.MANNED \
				and satellite_sky.is_duplicate_of_neighbour(sat, _tracked_manned, now):
			continue
		seen[sat.norad_id] = true
		var look := satellite_sky.look_angles(sat, now)
		var marker: SkyMarker = active_satellite_markers.get(sat.norad_id)
		if marker == null:
			marker = _acquire_satellite_marker(true)
			active_satellite_markers[sat.norad_id] = marker
			_satellite_labelled_at.erase(sat.norad_id)
		_label_satellite(marker, sat, look)
		marker.set_satellite_icon(sat.icon)
		# Never dimmed or hidden for being invisible to the eye (Earth's shadow, daylight,
		# below the horizon): showing what you cannot see is the point.
		marker.set_brightness(brightness)
		marker.set_look(look)

	for key: int in active_satellite_markers.keys():
		if not seen.has(key):
			_release(active_satellite_markers[key])
			active_satellite_markers.erase(key)
			_satellite_labelled_at.erase(key)


## Labels for the untracked satellites nearest the middle of the view. Their diamonds
## are already drawn; these add the text. Placed last each frame and nearest the gaze
## first, skipping any label that would overlap one already there — another gaze label,
## a tracked satellite's or rise marker's label, or an edge pointer — so the dense band
## along the horizon stays readable.
func update_gaze_labels() -> void:
	var now := unix_now()
	var brightness := 0.35 if horizon_control.is_adjusting() else 1.0
	var cam := rig.camera.global_basis
	var forward := -cam.z
	var gaze_el := rad_to_deg(asin(clampf(forward.y, -1.0, 1.0)))
	var gaze_az := fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)
	var to_camera := cam.inverse()

	# A few degrees of margin: a satellite moves between samples.
	var picks := []
	for sat in satellite_sky.near_direction(gaze_az, gaze_el, gaze_label_deg + 3.0):
		if not sat.ok or not (sat.category & satellite_types) or _by_id.has(sat.norad_id):
			continue
		var look := satellite_sky.look_angles(sat, now)
		var dir := GeoMath.sky_direction(look.azimuth_deg, look.elevation_deg)
		var angle := rad_to_deg(forward.angle_to(dir))
		if angle <= gaze_label_deg:
			picks.append([angle, sat, look, to_camera * dir])
	picks.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	var taken := occupied_view_rects()
	gaze_rects.clear()
	var seen := {}
	for pick: Array in picks:
		if seen.size() >= gaze_labels:
			break
		var sat: Satellite = pick[1]
		var look: LookAngles = pick[2]
		var rect := label_rect_deg(pick[3], SkyMarker.label_for_satellite(sat, look))
		if taken.any(func(r: Rect2) -> bool: return r.intersects(rect)):
			continue
		taken.append(rect)
		gaze_rects.append(rect)
		seen[sat.norad_id] = true
		var marker: SkyMarker = active_label_markers.get(sat.norad_id)
		if marker == null:
			marker = _acquire_satellite_marker(false)
			active_label_markers[sat.norad_id] = marker
			_satellite_labelled_at.erase(sat.norad_id)
		_label_satellite(marker, sat, look)
		marker.set_brightness(brightness)
		marker.set_look(look)

	for key: int in active_label_markers.keys():
		if not seen.has(key):
			_release(active_label_markers[key])
			active_label_markers.erase(key)
			_satellite_labelled_at.erase(key)


## The gaze labels placed this frame, in view degrees (see label_rect_deg), for tests.
var gaze_rects: Array[Rect2] = []

## One line of marker label in degrees of view (SkyMarker's text is ~0.95° tall), with a
## little clearance.
const LINE_HEIGHT_DEG := 1.2


## Where a marker's label sits on the view, in degrees from the centre (x right, y up):
## beside the marker at camera-space direction v, as SkyMarker places it, sized from the
## text.
func label_rect_deg(v: Vector3, text: String) -> Rect2:
	var x := rad_to_deg(atan2(v.x, -v.z))
	var y := rad_to_deg(atan2(v.y, -v.z))
	var lines := text.split("\n")
	var longest := 0
	for line in lines:
		longest = maxi(longest, line.length())
	var glyph := rad_to_deg(SkyMarker.ANGULAR_SIZE * 0.55)
	var height := lines.size() * LINE_HEIGHT_DEG
	# The label starts 0.8 of a marker right of the marker's centre.
	var start := x + rad_to_deg(SkyMarker.ANGULAR_SIZE) * 0.8
	# 0.56 glyph widths per character, measured from a rendered frame (a 15-character line
	# spans 7.8°), plus a degree of clearance.
	return Rect2(start, y - height / 2.0, longest * glyph * 0.56 + 1.0, height)


## Everything already on the view that a gaze label must not cover: aircraft labels,
## tracked satellites' and rise markers' labels, and the edge pointers.
func occupied_view_rects() -> Array[Rect2]:
	var to_camera := rig.camera.global_basis.inverse()
	var rects: Array[Rect2] = []
	for marker: SkyMarker in active_markers.values() + active_satellite_markers.values() \
			+ active_rise_markers.values():
		var v: Vector3 = to_camera * marker.position
		if v.z < 0.0 and marker.visible:
			rects.append(label_rect_deg(v, marker._label.text))
	# Pointer footprints are on the image plane at distance 1; convert to degrees.
	for r: Rect2 in pointers.footprints():
		var a := Vector2(rad_to_deg(atan(r.position.x)), rad_to_deg(atan(r.position.y)))
		var b := Vector2(rad_to_deg(atan(r.end.x)), rad_to_deg(atan(r.end.y)))
		rects.append(Rect2(a, b - a))
	return rects


## Relabel once per SGP4 sample, not per frame.
func _label_satellite(marker: SkyMarker, sat: Satellite, look: LookAngles) -> void:
	if _satellite_labelled_at.get(sat.norad_id) != sat.sampled_unix:
		marker.configure(SkyMarker.color_for_sat(sat), SkyMarker.label_for_satellite(sat, look))
		_satellite_labelled_at[sat.norad_id] = sat.sampled_unix


func _acquire_satellite_marker(with_outline: bool) -> SkyMarker:
	var marker := _acquire(SkyMarker.Kind.SATELLITE)
	marker.fades_at_horizon = false
	marker.set_outline_visible(with_outline)
	return marker


func _acquire(kind: SkyMarker.Kind) -> SkyMarker:
	var pool: Array = _pools[kind]
	var marker: SkyMarker = pool.pop_back() if not pool.is_empty() else SkyMarker.create(rig, kind)
	marker.visible = true
	return marker


func _release(marker: SkyMarker) -> void:
	marker.visible = false
	_pools[marker.kind].append(marker)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	layer.add_child(_hud)


func _satellite_status() -> String:
	# What is being tracked, not what the feed holds: they differ only in tests, which
	# hand SatelliteSky a catalogue directly.
	if satellite_sky.satellites.is_empty():
		if not _satellite_error.is_empty():
			return _satellite_error
		return "loading elements" if start_satellites else "feed off"
	var text := "%d drawn, %d labelled" % [satellite_sky.satellites.size(),
			active_satellite_markers.size() + active_label_markers.size()]
	if satellite_sky.backlog() > 0:
		text += ", %d catching up" % satellite_sky.backlog()
	var age_h := (unix_now() - celestrak.median_epoch_unix) / 3600.0
	if is_finite(age_h):
		text += ", elements ~%.0fh old" % age_h
	# Stale elements are a pointing error, not just a data-freshness note.
	if age_h > 72.0:
		text += " — STALE, positions drifting"
	return text


## The next few passes: "ISS (ZARYA) in 4:12 from WSW, max 67° · ...".
func _passes_status() -> String:
	if _tracked.is_empty():
		return "none tracked"
	var now := unix_now()
	var parts := []
	for p in upcoming_passes(now).slice(0, 3):
		var sat := _satellite_by_id(p.norad_id)
		parts.append("%s %s from %s, max %d°" % [sat.name, PassPredictor.countdown(p.rise_unix - now),
				PassPredictor.compass_point(p.rise_azimuth_deg), roundi(p.max_elevation_deg)])
	if parts.is_empty():
		return "predicting…" if not pass_predictor.is_idle() else "none in the next day"
	return " · ".join(parts)


func _hud_text() -> String:
	var cal := "NOT CALIBRATED — drag until the N sits on true north"
	if calibration.is_calibrated:
		cal = "%s, %ds ago" % [CompassCalibration.Source.keys()[calibration.source],
				roundi(calibration.seconds_since_fix())]

	var feed := _last_error
	if feed.is_empty():
		if adsb.last_successful_poll > 0.0:
			feed = "%d aircraft, %d drawn, polled %ds ago" % [adsb.aircraft.size(),
					active_markers.size(), roundi(Time.get_ticks_msec() / 1000.0 - adsb.last_successful_poll)]
		else:
			feed = "waiting for first poll" if start_feed else "feed off"

	var tracker := rig.tracker
	var head := "%s%s" % [tracker.name, " (" + (tracker as VitureHeadTracker).status() + ")"
			if tracker is VitureHeadTracker else ""]

	return "%d fps   Heading %.1f°   offset %.1f°   vfov %.1f°   tracker %s\nCalibration: %s\nObserver: %s (%s)\nFeed: %s\nSatellites: %s\nPasses: %s\n%s" % [
		Engine.get_frames_per_second(), rig.current_heading_deg(), calibration.heading_offset_deg,
		rig.vertical_fov_deg, head, cal,
		observer, _observer_source, feed, _satellite_status(), _passes_status(),
		"Right-drag look · Left-drag turn sky (Shift = fine) · ←/→ nudge · N north · Space tap · M menu"]
