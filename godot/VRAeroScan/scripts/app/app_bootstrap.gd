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
## CelesTrak groups to load; see CelestrakService. Add "starlink" or "geo" for those.
@export var satellite_groups := PackedStringArray(["stations", "visual"])
## Which kinds to draw. Each satellite has exactly one kind: see Satellite.
@export_flags("Manned", "Starlink", "LEO", "MEO / HEO", "GEO") var satellite_types := Satellite.ALL_CATEGORIES
## Off lets tests drive the app without touching the network.
@export var start_satellites := true

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
## Tests pin the clock here so satellite positions are deterministic. NAN = real time.
var fixed_unix_time := NAN

## icao24 -> SkyMarker currently in use.
var active_markers: Dictionary = {}
## icao24 -> the Aircraft object the marker's label was built from.
var _labelled_as: Dictionary = {}
## norad_id -> SkyMarker currently in use.
var active_satellite_markers: Dictionary = {}
## norad_id -> the sample time the marker's label was built from.
var _satellite_labelled_at: Dictionary = {}
## One pool per marker kind, since the outline differs.
var _pools := {SkyMarker.Kind.AIRCRAFT: [], SkyMarker.Kind.SATELLITE: []}
var _satellite_error := ""

## See update_satellite_markers(): off-view markers refresh every this many frames...
const OFF_VIEW_REFRESH_FRAMES := 12
## ...where off-view means more than 45° from where you are looking.
const IN_VIEW_COS := 0.7071
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
				calibrate_facing_north()
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

	update_aircraft_markers()
	update_satellite_markers()
	if _hud != null:
		_hud.text = _hud_text()

	# On the phone there is no HUD, so report to the log instead:
	#   adb logcat -s godot | grep VRAEROSCAN
	if OS.has_feature("mobile"):
		_status_log_timer += delta
		if _status_log_timer >= 5.0:
			_status_log_timer = 0.0
			print("VRAEROSCAN ", _hud_text().replace("\n", " | "))


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

		var look := GeoMath.to_look_angles(observer, ac.position_at(now))
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
			_labelled_as[ac.icao24] = ac

		marker.set_brightness(brightness)
		marker.set_look(look)

	# Return markers whose aircraft left the feed, the range, or the sky.
	for key: String in active_markers.keys():
		if not seen.has(key):
			_release(active_markers[key])
			active_markers.erase(key)
			_labelled_as.erase(key)


## UTC now, in Unix seconds. Satellites need the real wall clock, and an accurate one:
## the ISS moves 1.1° of sky per second of clock error at 400 km range.
func unix_now() -> float:
	return fixed_unix_time if not is_nan(fixed_unix_time) else Time.get_unix_time_from_system()


func update_satellite_markers() -> void:
	var now := unix_now()
	satellite_sky.update(observer, now)
	var brightness := 0.35 if horizon_control.is_adjusting() else 1.0

	# Markers well outside the view are refreshed at ~5 Hz instead of every frame: with
	# Starlink loaded there are hundreds, placing one costs ~10 µs of GDScript, and nobody
	# sees a marker behind them. The cone is the 46° diagonal FOV plus a wide margin, so a
	# fast head turn still finds markers fresh by the time they are on screen.
	var forward := -rig.camera.global_basis.z
	var in_view := IN_VIEW_COS * rig.sky_radius  # markers sit on the dome: no normalize
	var frame := Engine.get_process_frames()

	var seen := {}
	for sat: Satellite in satellite_sky.near.values():
		if not (sat.category & satellite_types):
			continue
		# NEAR includes the 10° band below the horizon; most of those need nothing this
		# frame. The 1 Hz sample's elevation settles it: nothing climbs a degree a second.
		if sat.sampled_elevation_deg < -3.0:
			continue

		var marker: SkyMarker = active_satellite_markers.get(sat.norad_id)
		if marker != null and (sat.norad_id + frame) % OFF_VIEW_REFRESH_FRAMES != 0 \
				and marker.position.dot(forward) < in_view:
			seen[sat.norad_id] = true
			continue

		var look := satellite_sky.look_angles(sat, now)
		if look.elevation_deg < -2.0:
			continue
		if sat.category == Satellite.MANNED and satellite_sky.is_duplicate_of_neighbour(sat, now):
			continue

		seen[sat.norad_id] = true
		if marker == null:
			marker = _acquire(SkyMarker.Kind.SATELLITE)
			active_satellite_markers[sat.norad_id] = marker
			_satellite_labelled_at.erase(sat.norad_id)

		# Relabel once per SGP4 sample (about 1 Hz), not per frame.
		if _satellite_labelled_at.get(sat.norad_id) != sat.sampled_unix:
			marker.configure(SkyMarker.color_for_satellite(sat.category),
					SkyMarker.label_for_satellite(sat, look))
			_satellite_labelled_at[sat.norad_id] = sat.sampled_unix

		# Never dimmed or hidden for being invisible to the eye (Earth's shadow, daylight):
		# showing what you cannot see is the point. The label says "shadow" instead.
		marker.set_brightness(brightness)
		marker.set_look(look)

	for key: int in active_satellite_markers.keys():
		if not seen.has(key):
			_release(active_satellite_markers[key])
			active_satellite_markers.erase(key)
			_satellite_labelled_at.erase(key)


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
	if celestrak.satellites.is_empty():
		if not _satellite_error.is_empty():
			return _satellite_error
		return "loading elements" if start_satellites else "feed off"
	var age_h := (unix_now() - celestrak.median_epoch_unix) / 3600.0
	var text := "%d loaded, %d near, %d drawn, elements ~%.0fh old" % [celestrak.satellites.size(),
			satellite_sky.near.size(), active_satellite_markers.size(), age_h]
	# Stale elements are a pointing error, not just a data-freshness note.
	if age_h > 72.0:
		text += " — STALE, positions drifting"
	return text


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

	return "Heading %.1f°   offset %.1f°   vfov %.1f°   tracker %s\nCalibration: %s\nObserver: %s (%s)\nFeed: %s\nSatellites: %s\n%s" % [
		rig.current_heading_deg(), calibration.heading_offset_deg, rig.vertical_fov_deg, head, cal,
		observer, _observer_source, feed, _satellite_status(),
		"Right-drag look · Left-drag turn sky (Shift = fine) · ←/→ nudge"]
