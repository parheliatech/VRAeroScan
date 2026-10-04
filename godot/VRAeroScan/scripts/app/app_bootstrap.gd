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

@export_group("Viewpoint")
## Where you view the sky from. Surface is where you stand (the GPS fix). Earth centre looks
## out from the middle of the planet: no horizon, every satellite and aircraft in view at once,
## north still north. Altitude floats you above your spot, from the ground to geostationary
## orbit; the Earth does not block the view, as at the surface (nothing here is ever hidden for
## being behind it).
enum Viewpoint { SURFACE, CENTRE, ALTITUDE }
@export var viewpoint := Viewpoint.SURFACE
## For Viewpoint.ALTITUDE: height above the WGS84 ellipsoid (≈ sea level), km.
@export_range(0.0, 35786.0) var viewpoint_altitude_km := 400.0

@export_group("Aircraft")
## Which aircraft groups to draw (a bitmask of AIRCRAFT_GROUPS' flags).
@export var aircraft_types := AIRCRAFT_ALL
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

## Remember what is shown and where from between launches (see save_settings). On by
## default on the phone; off on the desktop, where the tests set these freely.
@export var persist_settings := OS.has_feature("mobile")

@export_group("Debug")
## On-screen readout of calibration, heading and feed. Off on the phone: on the
## glasses, text is light in your eyes.
@export var show_debug_hud := true

## Geostationary altitude, km: the top of the altitude range.
const GEO_ALTITUDE_KM := 35786.0
## Aircraft groups: [label, flag]. An aircraft is in a group if the classifier gave it that
## flag; one with none of them (glider, drone, unknown) is in Other.
const AIRCRAFT_OTHER := 1 << 20
const AIRCRAFT_GROUPS := [
	["Commercial", AircraftClassifier.COMMERCIAL],
	["Private", AircraftClassifier.PRIVATE],
	["Military", AircraftClassifier.MILITARY],
	["Helicopters", AircraftClassifier.ROTORCRAFT],
	["Other", AIRCRAFT_OTHER],
]
const AIRCRAFT_ALL := AircraftClassifier.COMMERCIAL | AircraftClassifier.PRIVATE \
		| AircraftClassifier.MILITARY | AircraftClassifier.ROTORCRAFT | AIRCRAFT_OTHER
## Satellite kinds, [label, flag], in the order Satellite's flags are declared.
const SATELLITE_KINDS := [
	["Manned", Satellite.MANNED],
	["Starlink", Satellite.STARLINK],
	["LEO", Satellite.LEO],
	["MEO / HEO", Satellite.MEO],
	["GEO", Satellite.GEO],
]
## Altitude presets for the glasses menu, km above the ellipsoid.
## Three, so the page fits the glasses' view; Higher/Lower reach everything between.
const ALTITUDE_PRESETS_KM := [400.0, 20200.0, GEO_ALTITUDE_KM]
## Label sizes: name -> scale of SkyMarker's text. Medium is the original size.
const LABEL_SIZES := {"small": 0.7, "medium": 1.0, "large": 1.35}
## Where the phone keeps the user's choices between launches.
const SETTINGS_PATH := "user://settings.cfg"

## Where you are: the GPS fix, or the manual position. Feeds and passes use this; what the
## sky is drawn from is view_point().
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
	identify = IdentifyCrosshair.new()
	identify.initialize(rig.camera)

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
		satellite_sky.set_catalogue(list, view_point(), unix_now()))
	if start_satellites:
		celestrak.start()

	load_settings()

	if Engine.has_singleton("VitureGlasses"):
		_android = Engine.get_singleton("VitureGlasses")
		_android.startLocation()
		# On the phone's own screen with the glasses plugged in (they were plugged in after
		# launch, or it was started from a computer), the glasses only mirror the app and the
		# control panel never opens: say how to get it.
		if _android.getCurrentDisplayId() == 0 and _android.getGlassesDisplayId() > 0:
			_notice = "No controls here: open VRAeroScan again from its icon"
			_notice_until = _seconds() + 20.0
		# On the glasses, the phone's screen is free: put the controls there — but not
		# yet. See _open_panel_when_clear().
		if _android.getCurrentDisplayId() > 0:
			_panel_pending = true
			_panel_not_before = _seconds() + 3.0

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


## What the sky is drawn from: the observer at the chosen viewpoint. At the surface it is
## the observer itself. Otherwise the same latitude and longitude, so north stays north,
## either raised to the chosen altitude or moved to the Earth's centre.
func view_point() -> GeoPoint:
	if viewpoint == Viewpoint.SURFACE:
		return observer
	if _view_built_from != [observer, viewpoint, viewpoint_altitude_km]:
		_view_built_from = [observer, viewpoint, viewpoint_altitude_km]
		if viewpoint == Viewpoint.CENTRE:
			_view = GeoPoint.earth_centre(observer.latitude_deg, observer.longitude_deg)
		else:
			_view = GeoPoint.new(observer.latitude_deg, observer.longitude_deg,
					viewpoint_altitude_km * 1000.0)
	return _view


var _view: GeoPoint
var _view_built_from := []
## Current label size, a key of LABEL_SIZES.
var label_size := "medium"


func viewpoint_text() -> String:
	match viewpoint:
		Viewpoint.CENTRE:
			return "Earth centre"
		Viewpoint.ALTITUDE:
			return "%s km up" % _thousands(roundi(viewpoint_altitude_km))
	return "Surface"


static func _thousands(n: int) -> String:
	var digits := str(n)
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return out


## Whether an aircraft of this classification is in a group that is switched on.
static func aircraft_shown(classification: int, types: int) -> bool:
	var groups := classification & (AircraftClassifier.COMMERCIAL | AircraftClassifier.PRIVATE \
			| AircraftClassifier.MILITARY | AircraftClassifier.ROTORCRAFT)
	if groups == 0:
		return types & AIRCRAFT_OTHER != 0
	return types & groups != 0


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
		KEY_ESCAPE:
			run_command("cancel")
		KEY_SPACE:
			if not key.echo:
				run_command("tap")
		KEY_M:
			if not key.echo:
				run_command("menu")
		KEY_I:
			if not key.echo:
				run_command("identify")
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
		_open_panel_when_clear()
		_panel_status_timer += delta
		if _panel_status_timer >= 0.25:
			_panel_status_timer = 0.0
			_android.setPanelStatus(panel_status())
			_android.setPanelState(panel_state())
	update_controls()

	update_aircraft_markers()
	update_satellite_markers()
	update_passes()
	update_satellite_pointers()
	# Last: gaze labels fit around everything already placed.
	update_gaze_labels()
	update_identify()
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

## Waiting for a tap with the pole star in the circle (see PoleStar). Finding a star takes
## longer than facing a landmark, so it waits longer.
var capturing_star := false
const STAR_CAPTURE_TIMEOUT_S := 120.0
## Below this the star is in the murk or behind the horizon: not worth trying.
const STAR_MIN_ELEVATION_DEG := 3.0
var _star_ring: MeshInstance3D
var _notice := ""
var _notice_until := 0.0

## The identify crosshair: a circle in the middle of the view and a card describing what is
## centred in it (IdentifyCrosshair). On until turned off.
var identify_on := false
var identify: IdentifyCrosshair
## What the card describes: an Aircraft, a Satellite, or null.
var identified: Object = null

## Waiting for a tap to take "I'm facing north now" (chosen from the glasses menu: you
## cannot aim at a menu item and face north at the same time, so it takes two steps).
var capturing_north := false
var quick_menu: QuickMenu
var _reticle: Node3D
var _prompt: Label3D
var _menu_idle_until := 0.0
var _capture_until := 0.0
var _panel_status_timer := 0.0
## The phone control panel is to be opened once nothing else needs the phone's screen.
var _panel_pending := false
var _panel_not_before := 0.0


## Run one command. Everything that changes the app's state from outside comes through
## here — the phone's control panel (ControlPanelActivity), the glasses menu and keys:
##   north              I am facing true north now
##   sky:<deg>          move the sky right by deg (negative: left), as a drag would
##   drag:<frac>:<n>    the panel's pad dragged by frac of its width, n fingers
##   drag_end           the pad was released
##   star               sight the pole star (Polaris in the north, Sigma Octantis in the
##                      south) in the circle, then tap: sets north from where it is now
##   identify | identify:on | identify:off   the identify crosshair (bare: toggle)
##   cancel             stop sighting the star, or waiting to take north (Esc does too)
##   tap                the pad was tapped: open the menu, choose in it, or take north
##   menu               open or close the glasses menu
##   view:surface | view:centre | view:<km>   where to view the sky from (km: that high up)
##   view:up | view:down                      raise or lower the altitude by a step (×1.5)
##   sat:<i> | air:<i>                        toggle satellite kind / aircraft group i
##   sat:all | sat:none | air:all | air:none  every group on or off
##   page:<name>                              glasses menu page: main, north, show, sat, air, alt
##   labels:small | labels:medium | labels:large | labels:next   label text size
func run_command(command: String) -> void:
	var parts := command.split(":")
	match parts[0]:
		"north":
			calibrate_facing_north()
			horizon_control.highlight()
		"star":
			# The panel's button reads "Cancel sighting" while one is going: same command.
			if capturing_star:
				run_command("cancel")
			else:
				start_star_capture()
		"identify":
			var what := parts[1] if parts.size() > 1 else ""
			identify_on = (not identify_on) if what.is_empty() else (what == "on")
		"cancel":
			capturing_north = false
			capturing_star = false
			_notice = ""
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
		"view":
			_set_view(parts[1] if parts.size() > 1 else "")
		"sat":
			satellite_types = _toggle_group(satellite_types, SATELLITE_KINDS,
					parts[1] if parts.size() > 1 else "", Satellite.ALL_CATEGORIES)
		"air":
			aircraft_types = _toggle_group(aircraft_types, AIRCRAFT_GROUPS,
					parts[1] if parts.size() > 1 else "", AIRCRAFT_ALL)
		"page":
			_menu_page = parts[1] if parts.size() > 1 else "main"
			quick_menu.set_items(_menu_items())
		"labels":
			set_label_size(parts[1] if parts.size() > 1 else "")
		_:
			push_warning("[AppBootstrap] unknown command: %s" % command)
			return
	# Choices about what to show and from where are kept between launches.
	if parts[0] in ["view", "sat", "air", "labels"]:
		save_settings()


## Switch to a viewpoint, or to an altitude: "surface", "centre", "up", "down", or km.
func _set_view(what: String) -> void:
	match what:
		"surface":
			viewpoint = Viewpoint.SURFACE
		"centre":
			viewpoint = Viewpoint.CENTRE
		"up", "down":
			var factor := 1.5 if what == "up" else 1.0 / 1.5
			viewpoint = Viewpoint.ALTITUDE
			viewpoint_altitude_km = _clamp_altitude(maxf(viewpoint_altitude_km, 1.0) * factor)
		_:
			if not what.is_valid_float():
				push_warning("[AppBootstrap] unknown viewpoint: %s" % what)
				return
			viewpoint = Viewpoint.ALTITUDE
			viewpoint_altitude_km = _clamp_altitude(what.to_float())
	# The feed's circle is centred under you; from higher up, more of the ground is in view.
	# Those aircraft are far off and move slowly across the view, and the wide circle costs
	# adsb.lol more, so it is asked less often.
	adsb.radius_nm = 100 if viewpoint == Viewpoint.SURFACE else 250
	adsb.poll_interval_s = 3.0 if viewpoint == Viewpoint.SURFACE else 10.0
	print("VRAEROSCAN viewpoint: %s" % viewpoint_text())


## Label text size: "small", "medium", "large", or "next" to cycle. Applies to every
## marker at once, pooled ones included, and to the gaze-label layout.
func set_label_size(what: String) -> void:
	var names: Array = LABEL_SIZES.keys()
	if what == "next":
		what = names[(names.find(label_size) + 1) % names.size()]
	if not LABEL_SIZES.has(what):
		push_warning("[AppBootstrap] unknown label size: %s" % what)
		return
	label_size = what
	SkyMarker.label_scale = LABEL_SIZES[what]
	for node in rig.marker_root.get_children():
		if node is SkyMarker:
			(node as SkyMarker).apply_label_scale()


## Keep the user's choices (what is shown, where from, label size) for the next launch.
## Phone only: on the desktop the tests drive these settings and must start clean.
func save_settings() -> void:
	if not persist_settings:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("show", "satellite_types", satellite_types)
	cfg.set_value("show", "aircraft_types", aircraft_types)
	cfg.set_value("show", "label_size", label_size)
	cfg.set_value("view", "viewpoint", Viewpoint.keys()[viewpoint].to_lower())
	cfg.set_value("view", "altitude_km", viewpoint_altitude_km)
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	if not persist_settings:
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	satellite_types = int(cfg.get_value("show", "satellite_types", satellite_types)) & Satellite.ALL_CATEGORIES
	aircraft_types = int(cfg.get_value("show", "aircraft_types", aircraft_types)) & AIRCRAFT_ALL
	set_label_size(str(cfg.get_value("show", "label_size", label_size)))
	viewpoint_altitude_km = _clamp_altitude(float(cfg.get_value("view", "altitude_km", viewpoint_altitude_km)))
	var mode := str(cfg.get_value("view", "viewpoint", "surface"))
	_set_view(mode if mode in ["surface", "centre"] else str(viewpoint_altitude_km))


static func _clamp_altitude(km: float) -> float:
	var clamped := clampf(km, 0.0, GEO_ALTITUDE_KM)
	return 0.0 if clamped < 1.0 else clamped


## Flip group i of a bitmask, or set them all ("all") or none ("none").
static func _toggle_group(mask: int, groups: Array, what: String, all: int) -> int:
	if what == "all":
		return all
	if what == "none":
		return 0
	if not what.is_valid_int() or what.to_int() < 0 or what.to_int() >= groups.size():
		push_warning("[AppBootstrap] unknown group: %s" % what)
		return mask
	return mask ^ int(groups[what.to_int()][1])


## "key=value;..." for the phone panel, so its buttons show what is on: view mode and
## altitude, satellite kinds and aircraft groups as bitmasks.
func panel_state() -> String:
	return "view=%s;alt=%d;sat=%d;air=%d;star=%d;labels=%s;identify=%d" % [
		Viewpoint.keys()[viewpoint].to_lower(), roundi(viewpoint_altitude_km),
		satellite_types, aircraft_types, 1 if capturing_star else 0, label_size,
		1 if identify_on else 0]


func open_menu() -> void:
	capturing_north = false
	capturing_star = false
	_menu_page = "main"
	quick_menu.open(-rig.camera.global_basis.z, _menu_items())
	_menu_idle_until = _seconds() + MENU_IDLE_S


var _menu_page := "main"


static func _check(on: bool, label: String) -> String:
	return ("☑ " if on else "☐ ") + label


## The rows of the glasses menu's current page. Toggles show their state, and keep the
## menu open to flip several in a row.
func _menu_items() -> Array[QuickMenu.Item]:
	var items: Array[QuickMenu.Item] = []
	# The same three groups as the phone panel's tabs (North, Show, View), with Identify on
	# the top level of both, since it is used while looking around rather than set once.
	match _menu_page:
		"north":
			items.append(QuickMenu.Item.new(_heading_readout(), ""))
			items.append(QuickMenu.Item.new("Face north, then tap…", "set_north"))
			items.append(QuickMenu.Item.new("Sight pole star…", "star"))
			items.append(QuickMenu.Item.new("Sky ← 1°", "sky:-1"))
			items.append(QuickMenu.Item.new("Sky → 1°", "sky:1"))
			items.append(QuickMenu.Item.new("Sky ← 0.1°", "sky:-0.1"))
			items.append(QuickMenu.Item.new("Sky → 0.1°", "sky:0.1"))
			items.append(QuickMenu.Item.new("‹ Back", "page:main"))
		"show":
			items.append(QuickMenu.Item.new("Show", ""))
			items.append(QuickMenu.Item.new("Satellites ›", "page:sat"))
			items.append(QuickMenu.Item.new("Aircraft ›", "page:air"))
			items.append(QuickMenu.Item.new("Labels: %s" % label_size.capitalize(), "labels:next"))
			items.append(QuickMenu.Item.new("‹ Back", "page:main"))
		"sat":
			items.append(QuickMenu.Item.new("Satellites", ""))
			for i in SATELLITE_KINDS.size():
				items.append(QuickMenu.Item.new(_check(satellite_types & SATELLITE_KINDS[i][1] != 0,
						SATELLITE_KINDS[i][0]), "sat:%d" % i))
			items.append(QuickMenu.Item.new("All on", "sat:all"))
			items.append(QuickMenu.Item.new("All off", "sat:none"))
			items.append(QuickMenu.Item.new("‹ Back", "page:show"))
		"air":
			items.append(QuickMenu.Item.new("Aircraft", ""))
			for i in AIRCRAFT_GROUPS.size():
				items.append(QuickMenu.Item.new(_check(aircraft_types & AIRCRAFT_GROUPS[i][1] != 0,
						AIRCRAFT_GROUPS[i][0]), "air:%d" % i))
			items.append(QuickMenu.Item.new("All on", "air:all"))
			items.append(QuickMenu.Item.new("All off", "air:none"))
			items.append(QuickMenu.Item.new("‹ Back", "page:show"))
		"alt":
			items.append(QuickMenu.Item.new("View from: " + viewpoint_text(), ""))
			items.append(QuickMenu.Item.new(_check(viewpoint == Viewpoint.SURFACE, "Surface"), "view:surface"))
			items.append(QuickMenu.Item.new(_check(viewpoint == Viewpoint.CENTRE, "Earth centre"), "view:centre"))
			items.append(QuickMenu.Item.new("Higher ▲", "view:up"))
			items.append(QuickMenu.Item.new("Lower ▼", "view:down"))
			for km: float in ALTITUDE_PRESETS_KM:
				items.append(QuickMenu.Item.new("%s km%s" % [_thousands(roundi(km)),
						" (GEO)" if km == GEO_ALTITUDE_KM else ""], "view:%d" % roundi(km)))
			items.append(QuickMenu.Item.new("‹ Back", "page:main"))
		_:
			items.append(QuickMenu.Item.new(_heading_readout(), ""))
			items.append(QuickMenu.Item.new(_check(identify_on, "Identify"), "identify"))
			items.append(QuickMenu.Item.new("Set north ›", "page:north"))
			items.append(QuickMenu.Item.new("Show ›", "page:show"))
			items.append(QuickMenu.Item.new("View from: %s ›" % viewpoint_text(), "page:alt"))
			items.append(QuickMenu.Item.new("Close", "close"))
	return items


## Begin sighting the pole star. Refuses, with a notice, when it is too low to see from here
## (near the equator the pole star sits on the horizon). Nothing depends on this: north can
## always be set by the other ways.
func start_star_capture() -> void:
	var target := PoleStar.for_latitude(observer.latitude_deg)
	var look := PoleStar.look_angles(target, observer.latitude_deg, observer.longitude_deg, unix_now())
	if look.elevation_deg < STAR_MIN_ELEVATION_DEG:
		_notice = "%s is only %d° up from here: use another way to set north" % [
				target.name, roundi(look.elevation_deg)]
		_notice_until = _seconds() + 6.0
		return
	capturing_north = false
	capturing_star = true
	_capture_until = _seconds() + STAR_CAPTURE_TIMEOUT_S
	quick_menu.close()


## The tap with the star in the circle: face where the star really is.
func calibrate_on_star() -> void:
	capturing_star = false
	var target := PoleStar.for_latitude(observer.latitude_deg)
	var look := PoleStar.look_angles(target, observer.latitude_deg, observer.longitude_deg, unix_now())
	var forward := -rig.camera.global_basis.z
	var gaze_az := GeoMath.wrap360(rad_to_deg(atan2(forward.x, -forward.z)))
	calibration.calibrate_from_gaze(look.azimuth_deg, gaze_az, CompassCalibration.Source.CELESTIAL)
	print("VRAEROSCAN calibrated on %s (az %.2f°, el %.1f°): offset %.1f°" % [
			target.name, look.azimuth_deg, look.elevation_deg, calibration.heading_offset_deg])
	horizon_control.highlight()


## What to say under the circle: where the star is, and how far up the head is now.
func _star_prompt() -> String:
	var target := PoleStar.for_latitude(observer.latitude_deg)
	var look := PoleStar.look_angles(target, observer.latitude_deg, observer.longitude_deg, unix_now())
	var forward := -rig.camera.global_basis.z
	var text := "Put %s in the circle, then tap\n%d° up, towards %s (you: %d° up) · cancel on the phone" % [
			target.name, roundi(look.elevation_deg), PassPredictor.compass_point(look.azimuth_deg),
			roundi(rad_to_deg(asin(clampf(forward.y, -1.0, 1.0))))]
	if target.magnitude > 4.0:
		text += "\nfaint (mag %.1f): needs a dark sky" % target.magnitude
	return text


func _tap() -> void:
	if capturing_star:
		calibrate_on_star()
		return
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
		"identify":
			# Turning it on means "let me look": get the menu out of the way.
			run_command("identify")
			if identify_on:
				quick_menu.close()
			else:
				quick_menu.set_items(_menu_items())
		_:
			run_command(command)  # nudges and toggles keep the menu open, to press again
			if quick_menu.is_open() and not command.begins_with("page:"):
				quick_menu.set_items(_menu_items())


## Per frame: what the reticle is on, the live readout, timeouts.
func update_controls() -> void:
	if quick_menu.is_open():
		quick_menu.set_hovered(quick_menu.row_at(-rig.camera.global_basis.z))
		if _menu_page in ["main", "north"]:
			quick_menu.set_text(0, _heading_readout())
		if _seconds() > _menu_idle_until:
			quick_menu.close()
	if (capturing_north or capturing_star) and _seconds() > _capture_until:
		capturing_north = false
		capturing_star = false
	var noticed := not _notice.is_empty() and _seconds() < _notice_until
	_reticle.visible = quick_menu.is_open() or capturing_north or capturing_star or noticed
	_prompt.visible = capturing_north or capturing_star or noticed
	_star_ring.visible = capturing_star
	if _prompt.visible:
		var text := _star_prompt() if capturing_star else (
				"Face true north, then tap" if capturing_north else _notice)
		if _prompt.text != text:
			_prompt.text = text
		# Under the circle when there is one, else just under the cross.
		_prompt.position.y = -10.0 * deg_to_rad(3.4 if capturing_star else 2.2)


func _heading_readout() -> String:
	return "Heading %.1f° · offset %.1f°" % [rig.current_heading_deg(), calibration.heading_offset_deg]


## The status line on the phone's control panel.
##
## Short lines, at most six: the panel gives the status a fixed height so the buttons under
## it never move (it is used by feel). The last line is for whatever needs doing now.
func panel_status() -> String:
	var cal := "Not calibrated: set north first"
	if calibration.is_calibrated:
		cal = "Calibrated %s ago (%s)" % [_ago(calibration.seconds_since_fix()),
				CompassCalibration.Source.keys()[calibration.source].to_lower().replace("_", " ")]
	var lines := [_heading_readout(), cal, "View from: %s" % viewpoint_text(), _position_line(),
			_feeds_line()]
	if capturing_north:
		lines.append("FACE TRUE NORTH, THEN TAP THE PAD")
	elif capturing_star:
		lines.append("SIGHTING %s: CENTRE IT, TAP THE PAD" % PoleStar.for_latitude(observer.latitude_deg).name.to_upper())
	elif not _notice.is_empty() and _seconds() < _notice_until:
		lines.append(_notice)
	elif identify_on:
		lines.append("IDENTIFY: " + (identify.card_text().get_slice("\n", 0) if identified != null
				else "nothing in the circle"))
	return "\n".join(lines)


static func _ago(seconds: float) -> String:
	if seconds < 120.0:
		return "%ds" % roundi(seconds)
	return "%dm" % roundi(seconds / 60.0)


## Where the sky is drawn from, and loudly when it is not a real fix: without one, every
## direction is computed for the built-in default position, and nothing else would say so.
func _position_line() -> String:
	if _observer_source.begins_with("GPS"):
		# A fix can be Android's last-known one, minutes old and from somewhere else.
		var age := _observer_source.get_slice(", ", 1).to_int()
		return "Position: %s%s" % [_observer_source.split(",")[0],
				" (%s old)" % _ago(age) if age > 60 else ""]
	var why := ""
	if _android != null:
		why = " (%s)" % _android.getLocationStatus()
	return "NO GPS FIX%s: sky is for %.1f, %.1f" % [why, observer.latitude_deg, observer.longitude_deg]


## The two feeds in one line; a problem replaces the count.
func _feeds_line() -> String:
	var air := "%d aircraft" % active_markers.size()
	if not _last_error.is_empty():
		air = "aircraft " + _last_error
	var sats := "%s satellites" % _thousands(satellite_sky.satellites.size())
	if satellite_sky.satellites.is_empty():
		sats = "satellites loading" if start_satellites else "satellites off"
	elif (unix_now() - celestrak.median_epoch_unix) / 3600.0 > 72.0:
		sats += " (STALE)"
	return "%s · %s" % [air, sats]


## Open the control panel once the phone's screen is free. After a reboot Android asks
## "Allow VRAeroScan to access the VITURE glasses?" on the phone's screen; a panel opened
## straight away covered that prompt, nobody could answer it, and head tracking never
## started (2026-09-24). So: wait a moment for the prompt to appear, then until it has
## been answered.
func _open_panel_when_clear() -> void:
	if not _panel_pending or _seconds() < _panel_not_before:
		return
	var tracker := rig.tracker
	if tracker is VitureHeadTracker and (tracker as VitureHeadTracker).status() == "waiting for USB permission":
		return
	_panel_pending = false
	_android.showControlPanel()


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
	var ring: PackedVector3Array = []
	var ring_r := AT * deg_to_rad(1.5)
	for i in 48:
		var a0 := TAU * i / 48.0
		var a1 := TAU * (i + 1) / 48.0
		ring.append(Vector3(cos(a0) * ring_r, sin(a0) * ring_r, 0.0))
		ring.append(Vector3(cos(a1) * ring_r, sin(a1) * ring_r, 0.0))
	_star_ring = MeshInstance3D.new()
	_star_ring.mesh = ArVisuals.line_mesh(ring)
	_star_ring.material_override = ArVisuals.additive_material(Color(1.0, 0.95, 0.7))
	_star_ring.visible = false
	_reticle.add_child(_star_ring)
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
	# Off the ground, the Earth is not in the way and the feed's own radius bounds the
	# set: nothing is culled for range or for being below the (now meaningless) horizon.
	var at_surface := viewpoint == Viewpoint.SURFACE
	var view := view_point()

	# While the user drags the sky, dim the aircraft so the ghost N is the brightest
	# thing in view — it is what they are lining up.
	var brightness := 0.35 if horizon_control.is_adjusting() else 1.0

	var seen := {}
	for ac: Aircraft in adsb.aircraft.values():
		if hide_on_ground and ac.on_ground:
			continue

		if not aircraft_shown(ac.classification, aircraft_types):
			continue

		var position := ac.position_at(now)
		var look := GeoMath.to_look_angles(view, position)
		if at_surface and look.range_m > max_range_m:
			continue
		# Just below the horizon is kept, not skipped: SkyMarker fades it over the last
		# degree and a half, so a climbing aircraft rises into view instead of popping.
		if at_surface and look.elevation_deg < -2.0:
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

		marker.fades_at_horizon = at_surface
		marker.set_brightness(brightness)
		marker.set_look(look)
		var directional := AircraftIcons.is_directional(_icon_of.get(ac.icao24, AircraftIcons.Icon.GENERIC))
		marker.set_travel_angle(travel_angle(look, GeoMath.to_look_angles(view,
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
	# Not while the glasses menu is up: a pointer's label landed on its rows.
	if quick_menu.is_open():
		targets.clear()
	pointers.update_targets(targets, 0.35 if horizon_control.is_adjusting() else 1.0)


## Keep pass predictions current for tracked satellites, and place a rise marker on the
## horizon where each is about to come up. The satellite's own marker is drawn too,
## below the horizon: the chevron says where it will appear, the diamond where it is.
func update_passes() -> void:
	var now := unix_now()
	# Rise and set mean nothing without a horizon.
	if viewpoint != Viewpoint.SURFACE:
		for key: int in active_rise_markers.keys():
			_release(active_rise_markers[key])
			active_rise_markers.erase(key)
		return
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
	satellite_sky.update(view_point(), now)
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


## The identify crosshair: find the aircraft or satellite nearest the middle of the view,
## within IdentifyCrosshair.RADIUS_DEG, and describe it. Hidden while the menu or a north
## sighting has the middle of the view.
func update_identify() -> void:
	identify.visible = identify_on and not quick_menu.is_open() and not capturing_star \
			and not capturing_north
	if not identify.visible:
		identified = null
		return
	var now := unix_now()
	var forward := -rig.camera.global_basis.z
	var best_angle := IdentifyCrosshair.RADIUS_DEG
	var best: Object = null
	var best_look: LookAngles = null

	for key: String in active_markers:
		var marker: SkyMarker = active_markers[key]
		var ac: Aircraft = adsb.aircraft.get(key)
		if ac == null or marker.look == null:
			continue
		var angle := rad_to_deg(forward.angle_to(GeoMath.sky_direction(marker.look.azimuth_deg, marker.look.elevation_deg)))
		if angle < best_angle:
			best_angle = angle
			best = ac
			best_look = marker.look

	var gaze_el := rad_to_deg(asin(clampf(forward.y, -1.0, 1.0)))
	var gaze_az := fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)
	# A few degrees of margin: a satellite moves between samples.
	for sat in satellite_sky.near_direction(gaze_az, gaze_el, IdentifyCrosshair.RADIUS_DEG + 3.0):
		if not sat.ok or not (sat.category & satellite_types):
			continue
		var look := satellite_sky.look_angles(sat, now)
		var angle := rad_to_deg(forward.angle_to(GeoMath.sky_direction(look.azimuth_deg, look.elevation_deg)))
		if angle < best_angle:
			best_angle = angle
			best = sat
			best_look = look

	identified = best
	var at_surface := viewpoint == Viewpoint.SURFACE
	if best is Aircraft:
		identify.set_card(IdentifyCrosshair.describe_aircraft(best, best_look, _seconds(), at_surface), true)
	elif best is Satellite:
		identify.set_card(IdentifyCrosshair.describe_satellite(best, best_look, at_surface), true)
	else:
		identify.set_card(IdentifyCrosshair.HINT, false)


## Labels for the untracked satellites nearest the middle of the view. Their diamonds
## are already drawn; these add the text. Placed last each frame and nearest the gaze
## first, skipping any label that would overlap one already there — another gaze label,
## a tracked satellite's or rise marker's label, or an edge pointer — so the dense band
## along the horizon stays readable.
func update_gaze_labels() -> void:
	# The middle of the view belongs to the glasses menu, the pole-star circle or the identify
	# crosshair while they are up: labels there were drawn straight over the menu's rows
	# (seen on the glasses), and the identify card says more than a label would.
	if quick_menu.is_open() or capturing_star or identify_on:
		for key: int in active_label_markers.keys():
			_release(active_label_markers[key])
			active_label_markers.erase(key)
			_satellite_labelled_at.erase(key)
		gaze_rects.clear()
		return
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
	var glyph := rad_to_deg(SkyMarker.ANGULAR_SIZE * 0.55) * SkyMarker.label_scale
	var height := lines.size() * LINE_HEIGHT_DEG * SkyMarker.label_scale
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

	return "%d fps   Heading %.1f°   offset %.1f°   vfov %.1f°   tracker %s\nCalibration: %s\nObserver: %s (%s)   View: %s\nFeed: %s\nSatellites: %s\nPasses: %s\n%s" % [
		Engine.get_frames_per_second(), rig.current_heading_deg(), calibration.heading_offset_deg,
		rig.vertical_fov_deg, head, cal,
		observer, _observer_source, viewpoint_text(), feed, _satellite_status(), _passes_status(),
		"Right-drag look · Left-drag turn sky (Shift = fine) · ←/→ nudge · N north · Space tap · M menu"]
