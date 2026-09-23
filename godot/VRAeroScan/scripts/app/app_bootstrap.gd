class_name AppBootstrap
extends Node3D
## The whole app, wired from one script on one node (main.tscn's root).
##
## Builds the sky rig, the ghost cardinals, the touch calibration, the aircraft feed
## and the marker pool, and picks a head tracker: any HeadTracker child already present
## wins (that is where the Viture binding will go), otherwise MockHeadTracker is added
## so the pipeline runs at a desk.
##
## Each frame it dead-reckons every aircraft to now, turns that into look angles from
## the observer, and places a pooled marker there. Per frame rather than per poll,
## because a nearby aircraft's look angle changes by degrees per second.

@export_group("Observer")
## Where you are. Set this to your real position: markers can only be checked against
## real aircraft if the observer is real. Godot has no built-in GPS on Android, so on
## the phone this is also the position until a location plugin exists.
@export var latitude_deg := 34.0522
@export var longitude_deg := -118.2437
@export var altitude_m := 90.0

@export_group("Aircraft")
## Hide aircraft reporting on the ground. Almost always below the local horizon anyway.
@export var hide_on_ground := true
## Hide aircraft further than this, nautical miles. The feed radius decides what is
## fetched; this decides what is drawn.
@export var max_draw_range_nm := 60.0
## Off lets tests drive the app without touching the network.
@export var start_feed := true

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

## icao24 -> SkyMarker currently in use.
var active_markers: Dictionary = {}
## icao24 -> the Aircraft object the marker's label was built from.
var _labelled_as: Dictionary = {}
var _pool: Array[SkyMarker] = []
var _last_error := ""
var _hud: Label


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

	if show_debug_hud:
		_build_hud()


## Prefer a real tracker if one was added as a child; fall back to the mock so nothing
## about the hardware blocks work on the pipeline.
func _find_tracker() -> HeadTracker:
	for child in get_children():
		if child is HeadTracker and not child is MockHeadTracker:
			return child

	if OS.has_feature("mobile"):
		push_warning("[AppBootstrap] No head tracker; using the mouse mock. " +
				"On the glasses, markers will not follow your head.")

	var mock := MockHeadTracker.new()
	mock.name = "MockHeadTracker"
	add_child(mock)
	return mock


func _process(_delta: float) -> void:
	update_aircraft_markers()
	if _hud != null:
		_hud.text = _hud_text()


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


func _acquire(kind: SkyMarker.Kind) -> SkyMarker:
	# One pool for now. Satellites will want their own, since the outline differs.
	var marker: SkyMarker = _pool.pop_back() if not _pool.is_empty() else SkyMarker.create(rig, kind)
	marker.visible = true
	return marker


func _release(marker: SkyMarker) -> void:
	marker.visible = false
	_pool.append(marker)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	layer.add_child(_hud)


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

	return "Heading %.1f°   offset %.1f°\nCalibration: %s\nObserver: %s (manual)\nFeed: %s\n%s" % [
		rig.current_heading_deg(), calibration.heading_offset_deg, cal, observer, feed,
		"Right-drag look · Left-drag turn sky (Shift = fine) · ←/→ nudge"]
