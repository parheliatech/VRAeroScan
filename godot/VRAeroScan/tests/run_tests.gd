extends SceneTree
## Headless tests. Run from the repo root:
##
##   godot/VRAeroScan/tests/run.sh
##
## Use run.sh rather than calling this directly: a GDScript runtime error aborts only
## the function it happens in, the run carries on, and Godot still exits 0. run.sh
## treats any SCRIPT ERROR as a failure, so a crashed test cannot pass silently.
##
## Exits non-zero on failure. These cover the pieces that fail SILENTLY — plausible
## output, no error, markers on empty sky: the geometry, the world-frame convention,
## the calibration and drag signs, and the classifier.

var _failures := 0
var _checks := 0


func _initialize() -> void:
	test_geomath_matches_validated_fixture()
	test_world_frame_convention()
	test_calibration_points_camera_at_true_heading()
	test_calibration_preserves_pitch()
	test_drag_right_moves_north_right()
	test_destination_point_round_trip()
	test_aircraft_parsing_mixed_altitude()
	test_classifier()
	test_viture_pose_mapping()
	test_ecef_geodetic_round_trip()
	test_sgp4_matches_vallado_suite()
	test_satellite_chain_matches_skyfield()
	test_satellite_classifier()
	test_satellite_sky_scheduling()
	await test_app_places_marker_on_aircraft()
	await test_app_places_marker_on_satellite()
	await test_side_by_side_stereo()

	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", what)


func near(a: float, b: float, tol: float, what: String) -> void:
	check(absf(a - b) <= tol, "%s: got %.9f, want %.9f (tol %s)" % [what, a, b, tol])


func near_vec(a: Vector3, b: Vector3, tol: float, what: String) -> void:
	check(a.distance_to(b) <= tol, "%s: got %s, want %s" % [what, a, b])


# --- Geometry ---------------------------------------------------------------------

func test_geomath_matches_validated_fixture() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/geomath_fixture.json"))
	var cases: Array = fixture["cases"]
	check(cases.size() >= 30, "fixture loaded (%d cases)" % cases.size())

	for c: Dictionary in cases:
		var o: Array = c["observer"]
		var t: Array = c["target"]
		var obs := GeoPoint.new(o[0], o[1], o[2])
		var tgt := GeoPoint.new(t[0], t[1], t[2])
		var look := GeoMath.to_look_angles(obs, tgt)
		var name: String = c["name"]

		# Azimuth is meaningless straight overhead; the fixture keeps those cases
		# near-but-not-at the zenith, where it is still well defined.
		near(GeoMath.bearing_delta(look.azimuth_deg, c["azimuth_deg"]), 0.0, 1e-6, name + " azimuth")
		near(look.elevation_deg, c["elevation_deg"], 1e-6, name + " elevation")
		near(look.range_m, c["range_m"], 1e-3, name + " range")

		var gc := GeoMath.great_circle(obs, tgt)
		near(gc[0], c["gc_distance_m"], 1e-3, name + " gc distance")
		near(GeoMath.bearing_delta(gc[1], c["gc_bearing_deg"]), 0.0, 1e-6, name + " gc bearing")


func test_world_frame_convention() -> void:
	# -Z north, +X east, +Y up. Everything downstream assumes this.
	near_vec(GeoMath.sky_direction(0, 0), Vector3(0, 0, -1), 1e-6, "north is -Z")
	near_vec(GeoMath.sky_direction(90, 0), Vector3(1, 0, 0), 1e-6, "east is +X")
	near_vec(GeoMath.sky_direction(180, 0), Vector3(0, 0, 1), 1e-6, "south is +Z")
	near_vec(GeoMath.sky_direction(270, 0), Vector3(-1, 0, 0), 1e-6, "west is -X")
	near_vec(GeoMath.sky_direction(123, 90), Vector3(0, 1, 0), 1e-6, "zenith is +Y")


func test_destination_point_round_trip() -> void:
	var start := GeoPoint.new(47.6, -122.3, 1000)
	var end := GeoMath.destination_point(start, 63.0, 20000.0)
	var gc := GeoMath.great_circle(start, end)
	near(gc[0], 20000.0, 0.01, "destination distance")
	near(gc[1], 63.0, 1e-6, "destination bearing")

	var wrapped := GeoMath.destination_point(GeoPoint.new(0, 179.99, 0), 90.0, 5000.0)
	check(wrapped.longitude_deg < -179.9, "longitude wraps across antimeridian (%f)" % wrapped.longitude_deg)


# --- Calibration ------------------------------------------------------------------

func _forward(b: Basis) -> Vector3:
	return -b.z


func test_calibration_points_camera_at_true_heading() -> void:
	var cal := CompassCalibration.new()
	var mock := MockHeadTracker.new()
	mock.starting_yaw_deg = 137.0
	mock._ready()

	# User looks at something known to be due east (090) and takes a fix.
	cal.calibrate_from_known_bearing(90.0, mock.raw_yaw_deg())
	near(cal.true_heading(mock.raw_yaw_deg()), 90.0, 1e-9, "true heading after fix")
	near_vec(_forward(cal.to_world_basis(mock.raw_basis())), GeoMath.sky_direction(90, 0), 1e-5,
			"camera looks east after an east fix")
	mock.free()


func test_calibration_preserves_pitch() -> void:
	# The pre-multiply must rotate about WORLD up, leaving gravity-referenced pitch
	# alone. Post-multiplying passes a level test and fails as soon as you look up.
	var cal := CompassCalibration.new()
	cal.nudge(30.0)
	var mock := MockHeadTracker.new()
	mock.starting_yaw_deg = 10.0
	mock._ready()
	mock._pitch = 40.0

	near_vec(_forward(cal.to_world_basis(mock.raw_basis())), GeoMath.sky_direction(40, 40), 1e-5,
			"pitched head: heading 10+30, elevation 40")
	mock.free()


func test_drag_right_moves_north_right() -> void:
	# Looking due north, dragging the sky right must move the N to the right of centre.
	var cal := CompassCalibration.new()
	var control := TouchHorizonControl.new()
	control.initialize(cal, null)
	control.rotate_sky(5.0)

	var camera := cal.to_world_basis(Basis.IDENTITY)
	var north_in_camera := camera.inverse() * GeoMath.sky_direction(0, 0)
	check(north_in_camera.x > 0.0, "drag right moves N right (camera-space x = %f)" % north_in_camera.x)
	near(rad_to_deg(atan2(north_in_camera.x, -north_in_camera.z)), 5.0, 1e-4, "by exactly the drag")
	control.free()


# --- Aircraft data ----------------------------------------------------------------

func test_aircraft_parsing_mixed_altitude() -> void:
	var response := {"ac": [
		{"hex": "a1", "flight": "UAL123  ", "t": "B38M", "category": "A3",
			"lat": 34.1, "lon": -118.3, "alt_baro": 35000, "gs": 450, "track": 90},
		{"hex": "a2", "t": "C172", "category": "A1", "lat": 34.0, "lon": -118.4,
			"alt_baro": "ground", "gs": 5, "true_heading": 180},
		{"hex": "a3", "category": "C1", "lat": 34.0, "lon": -118.4, "alt_baro": "ground"},
		{"hex": "a4", "t": "A321"},  # no position
	]}
	var parsed := AdsbService.parse(response, 0.0)
	check(parsed.size() == 2, "ground vehicle and position-less entry dropped (got %d)" % parsed.size())
	if parsed.size() != 2:
		return

	var ual := parsed[0]
	check(ual.callsign == "UAL123", "callsign trimmed")
	near(ual.altitude_ft, 35000.0, 0.0, "numeric alt_baro")
	check(not ual.on_ground, "numeric alt_baro is airborne")

	var cessna := parsed[1]
	check(cessna.on_ground, "\"ground\" alt_baro is on ground")
	near(cessna.track_deg, 180.0, 0.0, "true_heading used when track absent")

	# 450 kt for 4 s eastbound is ~926 m.
	var moved := GeoMath.great_circle(ual.position(), ual.position_at(4.0))
	near(moved[0], 450.0 * 1852.0 / 3600.0 * 4.0, 0.5, "dead reckoning distance")
	near(moved[1], 90.0, 0.01, "dead reckoning bearing")


func _classify(type: String, category: String, callsign := "") -> int:
	var ac := Aircraft.new()
	ac.type_code = type
	ac.emitter_category = category
	ac.callsign = callsign
	return AircraftClassifier.classify(ac)


func test_classifier() -> void:
	var C = AircraftClassifier
	# The live-data regressions: variant-letter airliners with NO category.
	for t in ["A21N", "A20N", "B38M", "B77W", "B788"]:
		check(_classify(t, "") == C.COMMERCIAL | C.JET, "%s is a commercial jet" % t)
	check(_classify("C172", "A1") == C.PRIVATE | C.PISTON, "C172 private piston")
	check(_classify("C208", "A1") == C.PRIVATE | C.TURBOPROP, "C208 private turboprop, not jet")
	check(_classify("", "C3") == C.NOT_AN_AIRCRAFT, "category C is a ground vehicle")
	check(_classify("TWR", "") == C.NOT_AN_AIRCRAFT, "TWR is a radio tower")
	check(_classify("C17", "A5", "RCH401") == C.MILITARY | C.JET, "C-17 military, not commercial")
	check(_classify("R44", "A7") == C.ROTORCRAFT | C.PRIVATE, "R44 private rotorcraft")
	check(_classify("GLF5", "A2") == C.JET | C.PRIVATE, "Gulfstream private jet")
	check(_classify("ZZZZ", "") == C.UNKNOWN, "unmatched stays unknown")


# --- Viture head pose -------------------------------------------------------------

func test_viture_pose_mapping() -> void:
	# Real samples, recorded wearing the glasses. These pin the SDK-to-Godot axis map,
	# which is exactly the kind of sign error that fails silently.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/viture_pose_fixture.json"))
	var samples: Dictionary = fixture["samples"]
	var pose := func(label: String) -> PackedFloat32Array:
		return PackedFloat32Array(samples[label]["pose"])

	var straight := VitureHeadTracker.basis_from_sample(pose.call("straight"))
	var right := VitureHeadTracker.basis_from_sample(pose.call("turned_right"))
	var up := VitureHeadTracker.basis_from_sample(pose.call("looked_up"))
	var tilted := VitureHeadTracker.basis_from_sample(pose.call("right_ear_down"))

	# Turning right must INCREASE compass yaw (clockwise), by the ~58° actually turned.
	var turned := GeoMath.bearing_delta(VitureHeadTracker.yaw_from_basis(right),
			VitureHeadTracker.yaw_from_basis(straight))
	near(turned, 57.7, 1.5, "turning right increases compass yaw")

	# Looking up must raise the gaze by the ~50° logged.
	near(rad_to_deg(asin((-up.z).y)), 50.2, 2.0, "looking up raises gaze elevation")
	near(rad_to_deg(asin((-straight.z).y)), 1.6, 1.0, "straight ahead is level")

	# Right ear down: the head's right axis points down by the ~53° roll.
	near(tilted.x.y, -sin(deg_to_rad(53.1)), 0.05, "right ear down tips the right axis down")

	# Compass yaw from the quaternion must agree with the SDK's own Euler yaw (negated).
	for label: String in samples:
		var p: PackedFloat32Array = pose.call(label)
		if label == "looked_up" or label == "right_ear_down":
			continue  # Euler yaw is entangled with large pitch/roll; compare level poses only.
		near(GeoMath.bearing_delta(VitureHeadTracker.yaw_from_basis(
				VitureHeadTracker.basis_from_sample(p)), -p[2]), 0.0, 1.0,
				"%s: quaternion yaw matches SDK euler yaw" % label)


# --- Satellites -------------------------------------------------------------------

func test_ecef_geodetic_round_trip() -> void:
	for p: Array in [[32.2226, -110.9747, 730.0], [-33.9, 151.2, 420000.0], [89.9, 10.0, 0.0],
			[0.0, -179.9, 35786000.0], [-70.0, 45.0, 20200000.0]]:
		var e := GeoMath.geodetic_to_ecef(GeoPoint.new(p[0], p[1], p[2]))
		var g := GeoMath.ecef_to_geodetic(e[0], e[1], e[2])
		near(g.latitude_deg, p[0], 1e-9, "round-trip latitude %s" % [p])
		near(GeoMath.bearing_delta(g.longitude_deg, p[1]), 0.0, 1e-9, "round-trip longitude %s" % [p])
		near(g.altitude_m, p[2], 1e-3, "round-trip altitude %s" % [p])


func test_sgp4_matches_vallado_suite() -> void:
	# Vallado's published verification vectors (via tools/validation/validate_sgp4.py):
	# near-earth, deep space, both resonances, Lyddane, and decay cases.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/sgp4_fixture.json"))
	var pos_tol: float = fixture["positionToleranceKm"]
	var vel_tol: float = fixture["velocityToleranceKmPerSec"]
	var sats: Array = fixture["satellites"]
	check(sats.size() == 32, "SGP4 fixture loaded (%d satellites)" % sats.size())

	var deep := 0
	var vectors := 0
	for s: Dictionary in sats:
		var sat := Sgp4.from_tle(s["line1"], s["line2"])
		check(sat != null, "TLE %d parses" % s["satnum"])
		if sat == null:
			continue
		check(sat.satnum == int(s["satnum"]), "catalogue number %d" % s["satnum"])
		deep += 1 if sat.method == "d" else 0
		var worst_r := 0.0
		var worst_v := 0.0
		for sample: Dictionary in s["samples"]:
			var err := sat.propagate(sample["tsinceMin"])
			check(err == Sgp4.Fault.NONE or err == Sgp4.Fault.DECAYED,
					"sat %d t=%s propagates (error %d)" % [s["satnum"], sample["tsinceMin"], err])
			var r: Array = sample["r"]
			var v: Array = sample["v"]
			worst_r = maxf(worst_r, Vector3(sat.r[0] - r[0], sat.r[1] - r[1], sat.r[2] - r[2]).length())
			worst_v = maxf(worst_v, Vector3(sat.v[0] - v[0], sat.v[1] - v[1], sat.v[2] - v[2]).length())
			vectors += 1
		check(worst_r <= pos_tol, "sat %d position within %s km (worst %.9f)" % [s["satnum"], pos_tol, worst_r])
		check(worst_v <= vel_tol, "sat %d velocity within %s km/s (worst %.9f)" % [s["satnum"], vel_tol, worst_v])
	check(deep >= 15, "deep-space (SDP4) cases exercised (%d)" % deep)
	check(vectors >= 350, "state vectors compared (%d)" % vectors)


func _fixture_satellites(fixture: Dictionary) -> Dictionary:
	var out := {}
	for o: Dictionary in fixture["omm"]:
		var sat := Satellite.from_omm(o)
		out[sat.norad_id] = sat
	return out


func test_satellite_chain_matches_skyfield() -> void:
	# CelesTrak OMM -> SGP4 -> TEME -> ECEF -> observer's sky, plus sun and shadow, against
	# Skyfield's independent implementation (tools/validation/export_satellite_fixture.py).
	# Measured agreement: 0.0006° az, 0.0004° el, 40 m range, sun 0.007°. The tolerances
	# leave headroom while still catching any real frame or time error, which is degrees.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var sats := _fixture_satellites(fixture)
	check(sats.size() == 8, "fixture satellites parse from OMM (%d)" % sats.size())

	var above := 0
	for c: Dictionary in fixture["cases"]:
		var sat: Satellite = sats[int(c["norad"])]
		var unix: float = c["unix"]
		var jd := Sgp4.unix_to_jd(unix)
		var what := "%s from %s" % [sat.name, c["observerName"]]
		check(sat.sample(unix, Sgp4.gstime(jd), Solar.sun_direction_teme(jd)), what + " samples")

		var o: Array = c["observer"]
		var frame := GeoMath.local_frame(GeoPoint.new(o[0], o[1], o[2]))
		var look := GeoMath.look_angles_in_frame(frame, sat.ecef[0], sat.ecef[1], sat.ecef[2])
		# Azimuth scaled by cos(elevation): near the zenith a large azimuth difference is a
		# tiny angle on the sky.
		near(GeoMath.bearing_delta(look.azimuth_deg, c["azimuthDeg"]) * cos(deg_to_rad(look.elevation_deg)),
				0.0, 0.005, what + " azimuth")
		near(look.elevation_deg, c["elevationDeg"], 0.005, what + " elevation")
		near(look.range_m / 1000.0, c["rangeKm"], 0.2, what + " range km")
		above += 1 if look.elevation_deg > 0.0 else 0

		var sub := GeoMath.ecef_to_geodetic(sat.ecef[0], sat.ecef[1], sat.ecef[2])
		near(sub.latitude_deg, c["subLatDeg"], 0.005, what + " sub-latitude")
		near(GeoMath.bearing_delta(sub.longitude_deg, c["subLonDeg"]), 0.0, 0.005, what + " sub-longitude")
		near(sub.altitude_m / 1000.0, c["altitudeKm"], 0.2, what + " altitude km")

		check(sat.sunlit == bool(c["sunlit"]), what + " sunlit is %s" % c["sunlit"])
		var sun := Solar.sun_look_angles(frame, jd)
		near(GeoMath.bearing_delta(sun.azimuth_deg, c["sunAzimuthDeg"]), 0.0, 0.03, what + " sun azimuth")
		near(sun.elevation_deg, c["sunElevationDeg"], 0.03, what + " sun elevation")
	check(above >= 10, "fixture includes satellites above the horizon (%d)" % above)

	# The satellites chosen to exercise each SDP4 path really do.
	check(sats[41866].sgp4.irez == 1, "GOES 16 takes the synchronous resonance path")
	check(sats[40296].sgp4.irez == 2, "Meridian 7 takes the 12-hour resonance path")


func test_satellite_classifier() -> void:
	var S = Satellite
	check(S.classify("ISS (ZARYA)", 15.49, 0.0004) == S.MANNED, "ISS is manned")
	check(S.classify("CREW DRAGON 12", 15.49, 0.0004) == S.MANNED, "visiting Dragon is manned")
	check(S.classify("ISS DEB", 15.6, 0.001) == S.LEO, "ISS debris is not manned")
	check(S.classify("CZ-2F R/B", 15.8, 0.01) == S.LEO, "rocket body is not manned")
	check(S.classify("STARLINK-1008", 15.65, 0.0001) == S.STARLINK, "Starlink by name")
	check(S.classify("GOES 16", 1.0027, 0.0001) == S.GEO, "GOES 16 is GEO")
	check(S.classify("NAVSTAR 68 (USA 242)", 2.0056, 0.01) == S.MEO, "GPS is MEO")
	check(S.classify("MERIDIAN 7", 2.0061, 0.7) == S.MEO, "Molniya orbit falls in MEO/HEO")
	check(S.classify("HST", 15.32, 0.0002) == S.LEO, "Hubble is LEO")


func test_satellite_sky_scheduling() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var list: Array[Satellite] = []
	list.assign(_fixture_satellites(fixture).values())
	var tucson := GeoPoint.new(32.2226, -110.9747, 730.0)
	var t0: float = fixture["cases"][0]["unix"]

	var sky := SatelliteSky.new()
	sky.set_catalogue(list, tucson, t0)
	var frame := GeoMath.local_frame(tucson)
	for sat in list:
		var el := GeoMath.look_angles_in_frame(frame, sat.ecef[0], sat.ecef[1], sat.ecef[2]).elevation_deg
		check(sky.near.has(sat.norad_id) == (el > SatelliteSky.NEAR_ELEVATION_DEG),
				"%s NEAR matches its elevation %.1f°" % [sat.name, el])
	# GEO satellites never set: GOES 16 is always in Tucson's sky.
	check(sky.near.has(41866), "GOES 16 is near from Tucson")

	# Between samples, straight-line extrapolation must stay on the true orbit.
	var iss: Satellite = list.filter(func(s: Satellite) -> bool: return s.norad_id == 25544)[0]
	var extrapolated := iss.ecef_at(t0 + 0.9)
	var truth := Satellite.from_omm(fixture["omm"][0])
	var jd := Sgp4.unix_to_jd(t0 + 0.9)
	truth.sample(t0 + 0.9, Sgp4.gstime(jd), Solar.sun_direction_teme(jd))
	var err_m := Vector3(extrapolated[0] - truth.ecef[0], extrapolated[1] - truth.ecef[1],
			extrapolated[2] - truth.ecef[2]).length()
	check(err_m < 10.0, "0.9 s extrapolation within 10 m of SGP4 (%.1f m)" % err_m)

	# The round-robin reaches the whole catalogue within one scan period.
	var before := {}
	for sat in list:
		before[sat.norad_id] = sat.sampled_unix
	for i in 60:
		sky.update(tucson, t0 + sky.scan_period_s * (i + 1) / 60.0)
	var stale := list.filter(func(s: Satellite) -> bool: return s.sampled_unix == before[s.norad_id])
	check(stale.is_empty(), "every satellite resampled within a scan period (%d stale)" % stale.size())


# --- Whole app ----------------------------------------------------------------------

func test_app_places_marker_on_aircraft() -> void:
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.show_debug_hud = false
	app.latitude_deg = 47.6
	app.longitude_deg = -122.3
	app.altitude_m = 100.0
	root.add_child(app)
	# Under a SceneTree script the root enters the tree after _initialize, so the
	# app's _ready runs a frame later.
	await process_frame

	# One stationary aircraft, due north-east and well above the horizon.
	var ac := Aircraft.new()
	ac.icao24 = "test01"
	ac.callsign = "TEST1"
	ac.type_code = "A320"
	ac.latitude_deg = 47.65
	ac.longitude_deg = -122.22
	ac.altitude_ft = 12000.0
	ac.classification = AircraftClassifier.COMMERCIAL | AircraftClassifier.JET
	app.adsb.aircraft[ac.icao24] = ac

	await process_frame
	await process_frame

	var marker: SkyMarker = app.active_markers.get("test01")
	check(marker != null, "marker created for aircraft")
	if marker != null:
		var look := GeoMath.to_look_angles(app.observer, ac.position())
		near_vec(marker.global_position, app.rig.position_for_look(look), 1e-3,
				"marker sits at the aircraft's look angle")
		check(marker.visible, "marker above horizon is visible")

	# The cardinal bars read as "the horizon", so they must sit at exactly 0° elevation.
	var n_bar: Node3D = app.cardinals.find_child("Cardinal_N", false, false)
	check(n_bar != null, "cardinal N exists")
	if n_bar != null:
		near(rad_to_deg(asin(n_bar.position.normalized().y)), 0.0, 1e-4, "N bar is on the true horizon")

	# Phone location: a good fix becomes the observer; coarse or malformed ones do not.
	var manual := app.observer
	check(not app.apply_location_fix(PackedFloat64Array([1.0, 2.0])), "short fix rejected")
	check(not app.apply_location_fix(PackedFloat64Array([32.3, -110.9, 800.0, 1500.0, 1.0])),
			"1.5 km cell fix rejected")
	check(app.observer == manual, "rejected fixes leave the manual observer")
	check(app.apply_location_fix(PackedFloat64Array([32.3, -110.9, 800.0, 6.0, 1.0])), "6 m GPS fix accepted")
	near(app.observer.latitude_deg, 32.3, 1e-9, "GPS fix becomes the observer")
	app.observer = manual  # the marker checks below were computed for the manual position

	# The N key declares "facing north now": heading must read 0 afterwards.
	var press := InputEventKey.new()
	press.keycode = KEY_N
	press.pressed = true
	app._unhandled_input(press)
	near(GeoMath.bearing_delta(app.rig.current_heading_deg(), 0.0), 0.0, 1e-6, "N key calibrates to north")
	check(app.calibration.is_calibrated, "N key marks calibration taken")

	var bracket := InputEventKey.new()
	bracket.keycode = KEY_BRACKETRIGHT
	bracket.pressed = true
	var fov_before := app.rig.vertical_fov_deg
	app._unhandled_input(bracket)
	near(app.rig.camera.fov, fov_before + 0.5, 1e-6, "] widens the rendered FOV by 0.5°")

	# Aircraft leaves the feed: marker goes back to the pool.
	app.adsb.aircraft.clear()
	await process_frame
	check(app.active_markers.is_empty(), "marker released when aircraft leaves")
	check(marker != null and not marker.visible, "released marker hidden")

	app.queue_free()
	await process_frame


func test_app_places_marker_on_satellite() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	# A fixture case with a satellite well up in Tucson's sky.
	var case_: Dictionary = {}
	for c: Dictionary in fixture["cases"]:
		if c["observerName"] == "Tucson" and c["elevationDeg"] > 15.0 and int(c["norad"]) != 41866:
			case_ = c
			break
	check(not case_.is_empty(), "fixture has a satellite high over Tucson")
	if case_.is_empty():
		return

	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	app.fixed_unix_time = case_["unix"]
	root.add_child(app)
	await process_frame

	var list: Array[Satellite] = []
	list.assign(_fixture_satellites(fixture).values())
	# A docked vehicle: the same orbit as the ISS under a higher catalogue number. It must
	# not get a second marker on top of the station.
	var docked := Satellite.from_omm(fixture["omm"][0].merged({"NORAD_CAT_ID": 99001,
			"OBJECT_NAME": "SOYUZ-MS 99"}, true))
	list.append(docked)
	app.satellite_sky.set_catalogue(list, app.observer, app.unix_now())
	await process_frame

	var norad := int(case_["norad"])
	var marker: SkyMarker = app.active_satellite_markers.get(norad)
	check(marker != null, "marker created for satellite %d" % norad)
	if marker != null:
		check(marker.kind == SkyMarker.Kind.SATELLITE, "satellite marker is a diamond")
		var want := app.rig.position_for(case_["azimuthDeg"], case_["elevationDeg"])
		check(rad_to_deg(marker.global_position.angle_to(want)) < 0.01,
				"marker sits where Skyfield says (%.4f° off)" % rad_to_deg(marker.global_position.angle_to(want)))

	check(not app.active_satellite_markers.has(99001), "docked vehicle folded into the station")
	var iss_up: bool = app.satellite_sky.near.has(25544) and \
			app.satellite_sky.look_angles(app.satellite_sky.near[25544], app.unix_now()).elevation_deg > 0.0
	if iss_up:
		check(app.active_satellite_markers.has(25544), "the station itself keeps its marker")

	# Filtering by kind removes the marker and returns it to the satellite pool.
	var kind: int = list.filter(func(x: Satellite) -> bool: return x.norad_id == norad)[0].category
	app.satellite_types = Satellite.ALL_CATEGORIES & ~kind
	await process_frame
	check(not app.active_satellite_markers.has(norad), "filtered-out kind loses its marker")
	check(marker != null and not marker.visible, "released satellite marker hidden")

	app.queue_free()
	await process_frame


func test_side_by_side_stereo() -> void:
	var rig := SkyRig.new()
	rig.stereo = SkyRig.Stereo.SIDE_BY_SIDE
	root.add_child(rig)
	await process_frame

	check(rig.is_side_by_side(), "forced side-by-side is honoured")
	check(rig.camera.get_parent() is SubViewport, "camera renders into the eye viewport")
	var views := rig.find_children("*Eye", "TextureRect", true, false)
	check(views.size() == 2, "two eye views (got %d)" % views.size())
	if views.size() == 2:
		var l: TextureRect = views[0]
		var r: TextureRect = views[1]
		check(l.texture == r.texture, "both eyes show the same rendered sky")
		near(r.position.x, l.size.x, 0.5, "right eye starts where the left ends")

	var mono := SkyRig.new()
	mono.stereo = SkyRig.Stereo.MONO
	root.add_child(mono)
	await process_frame
	check(mono.camera.get_parent() == mono, "mono camera sits directly in the rig")

	rig.queue_free()
	mono.queue_free()
	await process_frame
