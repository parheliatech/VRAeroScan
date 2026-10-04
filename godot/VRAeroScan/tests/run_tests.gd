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
	test_satellite_icon_choice()
	test_satellite_sky_scheduling()
	test_aircraft_icon_choice()
	await test_app_places_marker_on_aircraft()
	await test_aircraft_icon_points_along_travel()
	await test_app_places_marker_on_satellite()
	await test_app_draws_eclipsed_satellite()
	await test_app_draws_whole_sky()
	await test_gaze_labels_do_not_overlap()
	test_offscreen_pointer_placement()
	test_pass_prediction_matches_skyfield()
	test_pass_predictor_scheduling()
	await test_app_shows_rise_marker()
	await test_pointer_labels_do_not_overlap()
	await test_app_points_at_offscreen_station()
	await test_side_by_side_stereo()
	await test_controls()
	await test_viewpoint_and_groups()
	await test_pole_star()

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
	check(S.classify("ISS OBJECT YN", 15.6, 0.001) == S.LEO, "a small satellite released from the ISS is not manned")
	check(S.classify("CZ-2F R/B", 15.8, 0.01) == S.LEO, "rocket body is not manned")
	check(S.classify("STARLINK-1008", 15.65, 0.0001) == S.STARLINK, "Starlink by name")
	check(S.classify("GOES 16", 1.0027, 0.0001) == S.GEO, "GOES 16 is GEO")
	check(S.classify("NAVSTAR 68 (USA 242)", 2.0056, 0.01) == S.MEO, "GPS is MEO")
	check(S.classify("MERIDIAN 7", 2.0061, 0.7) == S.MEO, "Molniya orbit falls in MEO/HEO")
	check(S.classify("HST", 15.32, 0.0002) == S.LEO, "Hubble is LEO")


## The fixture's eight orbits, each copied round its orbit and across nodes, so the
## catalogue covers the whole sky — above the horizon and below it. The copies are
## ordinary satellites (LEO/MEO/GEO by orbit), never tracked.
func _spread_catalogue(fixture: Dictionary, phase_deg := 0.0) -> Array[Satellite]:
	var out: Array[Satellite] = []
	var id := 900000
	for o: Dictionary in fixture["omm"]:
		for k in range(1, 37):  # not 0: that would sit exactly on the real satellite
			id += 1
			# Renamed so they are classified by orbit: copies named "ISS (ZARYA)" would all
			# be manned, i.e. tracked, and fill the sky with full station markers.
			out.append(Satellite.from_omm(o.merged({"NORAD_CAT_ID": id, "OBJECT_NAME": "COPY-%d" % id,
					"MEAN_ANOMALY": fposmod(float(o["MEAN_ANOMALY"]) + k * 47.0 + phase_deg, 360.0),
					"RA_OF_ASC_NODE": fposmod(float(o["RA_OF_ASC_NODE"]) + k * 83.0, 360.0)}, true)))
	return out


func test_satellite_icon_choice() -> void:
	var I = SatelliteIcons.Icon
	var none := PackedStringArray()
	var cases := [
		["ISS (ZARYA)", Satellite.MANNED, none, I.ISS], ["ISS (NAUKA)", Satellite.MANNED, none, I.ISS],
		["CSS (TIANHE)", Satellite.MANNED, none, I.STATION],
		["CREW DRAGON 12", Satellite.MANNED, none, I.CAPSULE], ["SOYUZ-MS 29", Satellite.MANNED, none, I.CAPSULE],
		["HST", Satellite.LEO, none, I.HUBBLE],
		["STARLINK-1008", Satellite.STARLINK, none, I.STARLINK],
		["ISS DEB", Satellite.LEO, none, I.DEBRIS], ["FREGAT DEB", Satellite.LEO, none, I.DEBRIS],
		["ISS OBJECT YN", Satellite.LEO, none, I.CUBESAT],
		["CZ-2F R/B", Satellite.LEO, none, I.ROCKET_BODY], ["SL-16 R/B", Satellite.LEO, none, I.ROCKET_BODY],
		["NAVSTAR 68 (USA 242)", Satellite.MEO, PackedStringArray(["gnss"]), I.NAVIGATION],
		["BEIDOU-3 G2", Satellite.GEO, PackedStringArray(["gnss"]), I.NAVIGATION],
		# A comsat with a WAAS payload is in gnss, but it is a comsat.
		["GALAXY 30", Satellite.GEO, PackedStringArray(["gnss", "geo", "intelsat"]), I.COMMS],
		["NOAA 20", Satellite.LEO, PackedStringArray(["weather"]), I.EARTH_OBS],
		["GOES 16", Satellite.GEO, PackedStringArray(["weather", "geo"]), I.EARTH_OBS],
		["LANDSAT 9", Satellite.LEO, PackedStringArray(["resource"]), I.EARTH_OBS],
		["FLOCK 4Y-12", Satellite.LEO, PackedStringArray(["planet"]), I.EARTH_OBS],
		["ONEWEB-0012", Satellite.LEO, PackedStringArray(["oneweb"]), I.COMMS],
		["IRIDIUM 106", Satellite.LEO, PackedStringArray(["iridium-NEXT"]), I.COMMS],
		["LEMUR-2-XYZ", Satellite.LEO, PackedStringArray(["spire"]), I.CUBESAT],
		["AEROCUBE 12A", Satellite.LEO, PackedStringArray(["cubesat"]), I.CUBESAT],
		# No groups: names, then the orbit.
		["GPS BIII-6", Satellite.MEO, none, I.NAVIGATION],
		["METEOSAT-12", Satellite.GEO, none, I.EARTH_OBS],
		["INTELSAT 40E", Satellite.GEO, none, I.COMMS],
		["SOME GEO BIRD", Satellite.GEO, none, I.COMMS],
		["TECHSAT 1", Satellite.LEO, none, I.GENERIC],
	]
	for c: Array in cases:
		var got := SatelliteIcons.icon_for(c[0], c[1], c[2])
		check(got == c[3], "%s -> %s (got %s)" % [c[0], I.keys()[c[3]], I.keys()[got]])

	check(SatelliteIcons.is_military("PRAETORIAN SDA", PackedStringArray(["military"])), "military group")
	check(SatelliteIcons.is_military("YAOGAN-41", none), "Yaogan is military")
	check(SatelliteIcons.is_military("USA 326", none), "USA-numbered is military")
	check(SatelliteIcons.is_military("COSMOS 2575", none), "a non-GLONASS Cosmos is military")
	check(not SatelliteIcons.is_military("COSMOS 2569 (GLONASS)", PackedStringArray(["gnss"])), "a GLONASS Cosmos is not")
	check(not SatelliteIcons.is_military("STARLINK-1008", none), "Starlink is not military")
	for icon in I.values():
		var verts: PackedVector3Array = SatelliteIcons.mesh(icon).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(verts.size() >= 8 and Array(verts).all(func(v: Vector3) -> bool:
				return absf(v.x) <= 0.5 + 1e-6 and absf(v.y) <= 0.5 + 1e-6),
				"%s icon: lines inside the unit square" % I.keys()[icon])

	# build_catalogue tags satellites from the purpose groups they appear in.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var gps: Dictionary = fixture["omm"].filter(func(o: Dictionary) -> bool: return int(o["NORAD_CAT_ID"]) == 39166)[0]
	var spy: Dictionary = fixture["omm"][2].merged({"NORAD_CAT_ID": 777001, "OBJECT_NAME": "SECRETSAT 1"}, true)
	var built := CelestrakService.build_catalogue([[gps, spy]], {"gnss": [gps], "military": [spy]})
	check((built[39166] as Satellite).icon == I.NAVIGATION, "gnss membership tags GPS as navigation")
	var unnamed: Dictionary = gps.merged({"NORAD_CAT_ID": 777002, "OBJECT_NAME": "MYSTERY 2"}, true)
	var tagged := CelestrakService.build_catalogue([[unnamed]], {"gnss": [unnamed]})
	check((tagged[777002] as Satellite).icon == I.NAVIGATION, "the gnss group alone, no telling name, gives navigation")
	check((built[777001] as Satellite).military, "military membership tags the unknown satellite military")
	check(SkyMarker.color_for_sat(built[777001]) == SkyMarker.color_for(AircraftClassifier.MILITARY),
			"military satellites drawn amber")
	check(SkyMarker.color_for_sat(built[39166]) == SkyMarker.color_for_satellite(Satellite.MEO),
			"others keep their orbit colour")


func test_satellite_sky_scheduling() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var list := _spread_catalogue(fixture)
	var tucson := GeoPoint.new(32.2226, -110.9747, 730.0)
	var frame := GeoMath.local_frame(tucson)
	var t0: float = fixture["cases"][0]["unix"]

	var sky := SatelliteSky.new()
	sky.set_catalogue(list, tucson, t0)
	var below := list.filter(func(s: Satellite) -> bool: return s.sampled_elevation_deg < 0.0).size()
	check(below > list.size() / 2 and below < list.size(), "catalogue spans above and below the horizon (%d of %d below)" % [below, list.size()])

	# Run a minute at 30 fps. At every frame, what would be drawn — the extrapolation from
	# each satellite's last sample — must match a fresh SGP4 propagation, for every
	# satellite, above the horizon or on the far side of the Earth.
	var worst_deg := 0.0
	var worst_what := ""
	var longest_gap := 0.0
	var last := {}
	for sat in list:
		last[sat.norad_id] = sat.sampled_unix
	for f in 1800:
		var t := t0 + (f + 1) / 30.0
		sky.update(tucson, t)
		for sat in sky.resampled:
			longest_gap = maxf(longest_gap, sat.sampled_unix - last[sat.norad_id])
			last[sat.norad_id] = sat.sampled_unix
		if f % 90 != 89:
			continue  # full comparison every 3 s is plenty
		for sat in list:
			var drawn := sky.look_angles(sat, t)
			var p := sat.ecef_position_at(t)
			var truth := GeoMath.look_angles_in_frame(frame, p[0], p[1], p[2])
			var err := rad_to_deg(GeoMath.sky_direction(drawn.azimuth_deg, drawn.elevation_deg).angle_to(
					GeoMath.sky_direction(truth.azimuth_deg, truth.elevation_deg)))
			if err > worst_deg:
				worst_deg = err
				worst_what = "%s at el %.0f°, range %.0f km" % [sat.name, truth.elevation_deg, truth.range_m / 1000.0]
	check(worst_deg < 0.05, "drawn positions within 0.05° of SGP4 everywhere (worst %.4f°, %s)" % [worst_deg, worst_what])
	# The wheel rounds up to the next slot and processes a slot once it has passed.
	check(longest_gap <= SatelliteSky.MAX_REFRESH_S + 2.0 * SatelliteSky.SLOT_S + 0.1,
			"no satellite waits longer than its refresh (%.1f s)" % longest_gap)
	check(sky.backlog() == 0, "no backlog at steady state")

	# The direction index finds everything a brute-force scan does.
	var t_end := t0 + 60.0
	for gaze: Array in [[0.0, 45.0], [200.0, 2.0], [90.0, -30.0], [10.0, 88.0], [300.0, -89.0]]:
		var got := {}
		for sat in sky.near_direction(gaze[0], gaze[1], 10.0):
			got[sat.norad_id] = true
		var dir := GeoMath.sky_direction(gaze[0], gaze[1])
		var missed := 0
		for sat in list:
			var d := GeoMath.sky_direction(sat.sampled_azimuth_deg, sat.sampled_elevation_deg)
			if rad_to_deg(dir.angle_to(d)) <= 10.0 and not got.has(sat.norad_id):
				missed += 1
		check(missed == 0, "direction index misses nothing near az %s el %s (%d missed)" % [gaze[0], gaze[1], missed])

	# Moving the observer 1 km resamples everything, spread over frames by the budget.
	sky.budget_usec = 200
	var moved := GeoPoint.new(32.2316, -110.9747, 730.0)
	sky.update(moved, t_end + 0.01)
	check(sky.backlog() > 0 and sky.resampled.size() < list.size(), "observer move: resampling spread over frames")
	var frames := 0
	while sky.backlog() > 0 and frames < 1000:
		frames += 1
		sky.update(moved, t_end + 0.01 + frames / 60.0)
	check(sky.backlog() == 0, "observer move: backlog drains (%d frames)" % frames)

	# Between samples, straight-line extrapolation must stay on the true orbit.
	var iss := Satellite.from_omm(fixture["omm"][0])
	var one: Array[Satellite] = [iss]
	sky.set_catalogue(one, tucson, t0)
	var extrapolated := iss.ecef_at(t0 + 2.0)
	var truth := iss.ecef_position_at(t0 + 2.0)
	var err_m := Vector3(extrapolated[0] - truth[0], extrapolated[1] - truth[1],
			extrapolated[2] - truth[2]).length()
	check(err_m < 25.0, "2 s extrapolation within 25 m of SGP4 (%.1f m)" % err_m)


# --- Aircraft icons -----------------------------------------------------------------

func _icon(type: String, category: String, callsign := "") -> AircraftIcons.Icon:
	var ac := Aircraft.new()
	ac.type_code = type
	ac.emitter_category = category
	ac.callsign = callsign
	ac.classification = AircraftClassifier.classify(ac)
	return AircraftIcons.icon_for(ac)


func test_aircraft_icon_choice() -> void:
	var I = AircraftIcons.Icon
	for t in ["A21N", "A320", "B38M", "B738", "E75L"]:
		check(_icon(t, "A3") == I.AIRLINER, "%s is an airliner" % t)
	for t in ["B77W", "B789", "A359", "B744", "A388"]:
		check(_icon(t, "A5") == I.HEAVY, "%s is a heavy" % t)
	check(_icon("B77W", "") == I.HEAVY, "heavy by type alone, no category")
	check(_icon("C17", "A5", "RCH401") == I.HEAVY, "C-17: military, drawn as a heavy")
	check(_icon("GLF5", "A2") == I.BIZJET, "Gulfstream is a business jet")
	check(_icon("C680", "A2") == I.BIZJET, "Citation is a business jet")
	check(_icon("C172", "A1") == I.LIGHT, "C172 is a light single")
	check(_icon("C208", "A1") == I.LIGHT, "Caravan (single turboprop) is a light single")
	check(_icon("BE58", "A1") == I.TWIN_PROP, "Baron is a twin prop")
	check(_icon("DH8D", "A2") == I.TWIN_PROP, "Q400 is a twin prop")
	check(_icon("C130", "A5", "RCH123") == I.TWIN_PROP or _icon("C130", "A5", "RCH123") == I.HEAVY,
			"C-130 is a transport, not a fighter")
	check(_icon("R44", "A7") == I.HELICOPTER, "R44 is a helicopter")
	check(_icon("", "A7") == I.HELICOPTER, "rotorcraft category alone is a helicopter")
	check(_icon("F16", "A6", "VIPER01") == I.FIGHTER, "F-16 is a fighter")
	check(_icon("A10", "", "HAWG01") == I.FIGHTER, "A-10 (Davis-Monthan) is a fighter")
	check(_icon("", "B1") == I.GLIDER, "glider by category")
	check(_icon("", "B2") == I.BALLOON, "balloon by category")
	check(not AircraftIcons.is_directional(I.BALLOON), "a balloon has no nose to point")
	check(_icon("", "A3") == I.AIRLINER, "no type, large category: airliner")
	check(_icon("", "A1") == I.LIGHT, "no type, light category: light single")
	check(_icon("ZZZZ", "") == I.GENERIC, "unknown stays generic")
	check(AircraftIcons.scale_of(I.HEAVY) > AircraftIcons.scale_of(I.AIRLINER), "heavies drawn bigger")
	for icon in I.values():
		var verts: PackedVector3Array = AircraftIcons.mesh(icon).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(verts.size() >= 8 and Array(verts).all(func(v: Vector3) -> bool:
				return absf(v.x) <= 0.5 + 1e-6 and absf(v.y) <= 0.5 + 1e-6 and v.z == 0.0),
				"%s icon: lines inside the unit square" % I.keys()[icon])


func test_aircraft_icon_points_along_travel() -> void:
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	root.add_child(app)
	await process_frame
	var mock: MockHeadTracker = app.rig.tracker
	mock._yaw = 0.0
	mock._pitch = 20.0

	# An airliner due north, well up; the head looks at it.
	var cases := [
		[90.0, 0.0, "eastbound: crosses left to right, nose right"],
		[270.0, PI, "westbound: nose left"],
		[0.0, -PI / 2.0, "flying away (north): sinks toward the horizon, nose down"],
		[180.0, PI / 2.0, "flying toward us: climbs up the sky, nose up"],
	]
	for c: Array in cases:
		var ac := Aircraft.new()
		ac.icao24 = "dir01"
		ac.callsign = "DIR1"
		ac.type_code = "A320"
		ac.emitter_category = "A3"
		ac.latitude_deg = 32.33
		ac.longitude_deg = -110.9747
		ac.altitude_ft = 20000.0
		ac.ground_speed_kt = 250.0
		ac.track_deg = c[0]
		ac.received_at = Time.get_ticks_msec() / 1000.0
		ac.classification = AircraftClassifier.classify(ac)
		app.adsb.aircraft.clear()
		app.adsb.aircraft[ac.icao24] = ac
		await process_frame
		await process_frame
		var marker: SkyMarker = app.active_markers.get("dir01")
		check(marker != null, "marker for the test aircraft")
		if marker == null:
			continue
		# Nose direction on the view: the outline's +Y, through its rotation.
		var nose_angle: float = marker._outline.rotation.z + PI / 2.0
		near(angle_difference(nose_angle, c[1]), 0.0, deg_to_rad(8.0), c[2])
		check(marker._outline.mesh == AircraftIcons.mesh(AircraftIcons.Icon.AIRLINER), "drawn as an airliner")

	# A heavy is drawn bigger than an airliner.
	var heavy := app.adsb.aircraft["dir01"] as Aircraft
	var small_scale: float = app.active_markers["dir01"]._outline.scale.x
	var big := Aircraft.new()
	big.icao24 = "big01"
	big.type_code = "B77W"
	big.emitter_category = "A5"
	big.latitude_deg = heavy.latitude_deg
	big.longitude_deg = heavy.longitude_deg + 0.05
	big.altitude_ft = 30000.0
	big.received_at = heavy.received_at
	big.classification = AircraftClassifier.classify(big)
	app.adsb.aircraft[big.icao24] = big
	await process_frame
	var big_marker: SkyMarker = app.active_markers.get("big01")
	check(big_marker != null and big_marker._outline.scale.x > small_scale * 1.2, "heavy drawn 1.25x")

	# Aircraft labels are claimed space: gaze labels for satellites must not cover them.
	var marker: SkyMarker = app.active_markers["dir01"]
	var v: Vector3 = app.rig.camera.global_basis.inverse() * marker.position
	var own := app.label_rect_deg(v, marker._label.text)
	check(app.occupied_view_rects().any(func(r: Rect2) -> bool: return r.is_equal_approx(own)),
			"an aircraft's label is space gaze labels avoid")

	app.queue_free()
	await process_frame


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
	check(app.active_satellite_markers.has(25544), "the station itself keeps its marker")

	# Filtering by kind removes the marker and returns it to the satellite pool.
	var kind: int = list.filter(func(x: Satellite) -> bool: return x.norad_id == norad)[0].category
	app.satellite_types = Satellite.ALL_CATEGORIES & ~kind
	await process_frame
	check(not app.active_satellite_markers.has(norad), "filtered-out kind loses its marker")
	check(marker != null and not marker.visible, "released satellite marker hidden")

	app.queue_free()
	await process_frame


func test_app_draws_whole_sky() -> void:
	# Every satellite is drawn wherever it is — below the horizon and on the far side of
	# the Earth included (Kendel, 2026-09-24). Untracked ones are SatelliteField
	# instances; tracked ones are full markers.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	var t0: float = fixture["cases"][0]["unix"]
	app.fixed_unix_time = t0
	root.add_child(app)
	await process_frame

	var list := _spread_catalogue(fixture)
	var named := _fixture_satellites(fixture)
	list.append_array(named.values())
	app.satellite_sky.set_catalogue(list, app.observer, t0)
	app.fixed_unix_time = t0 + 7.3  # mid-way between samples: the GPU is extrapolating
	await process_frame
	var now := app.unix_now()

	var field := app.satellite_field
	check(field.instance_total() == list.size(), "one instance per satellite (%d)" % field.instance_total())
	check(list.all(func(sat: Satellite) -> bool: return field.layer_mesh(sat) == SatelliteIcons.mesh(sat.icon)),
			"each satellite drawn in its own icon's layer")
	var worst := 0.0
	var below := 0
	var far_side := 0
	var drawn := 0
	for sat in list:
		var c := field.instance_color(sat)
		var tracked := app._by_id.has(sat.norad_id)
		check(c.a == (0.0 if tracked else 1.0), "%s: drawn by %s" % [sat.name, "its marker" if tracked else "the field"])
		if tracked:
			continue
		drawn += 1
		var look := app.satellite_sky.look_angles(sat, now)
		var want := GeoMath.sky_direction(look.azimuth_deg, look.elevation_deg)
		worst = maxf(worst, rad_to_deg(field.direction_now(sat, now).angle_to(want)))
		below += 1 if look.elevation_deg < 0.0 else 0
		far_side += 1 if look.elevation_deg < -45.0 else 0
	check(worst < 0.01, "field draws each satellite at its look angles (worst %.5f°)" % worst)

	# Diamonds shrink with range: the far side is a fine, distant layer.
	var near_size := 0.0
	var far_size := INF
	for sat in list:
		if app._by_id.has(sat.norad_id):
			continue
		var look := app.satellite_sky.look_angles(sat, now)
		var size := field.size_now(sat, now)
		near(size, SatelliteField.size_scale(look.range_m), 0.01, "%s: drawn size follows its range" % sat.name)
		if look.range_m < 2.0e6:
			near_size = maxf(near_size, size)
		if look.range_m > 8.0e6:
			far_size = minf(far_size, size)
	check(near_size > 2.0 * far_size, "nearby diamonds well larger than far-side ones (%.2f vs %.2f)" % [near_size, far_size])
	near(SatelliteField.size_scale(1.0e6), 1.0, 1e-9, "1x at 1000 km")
	near(SatelliteField.size_scale(13.0e6), SatelliteField.MIN_SCALE, 1e-9, "far side clamps to the minimum")
	near(SatelliteField.size_scale(200.0e3), SatelliteField.MAX_SCALE, 1e-9, "very close clamps to the maximum")

	# The dashed horizon ring: on by default, at 0°, and switchable.
	var ring: MeshInstance3D = app.rig.find_child("HorizonRing", true, false)
	check(ring != null and ring.visible, "horizon ring shown by default")
	if ring != null:
		var verts: PackedVector3Array = ring.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(verts.size() == 180, "dashed: 90 dashes (%d vertices)" % verts.size())
		check(Array(verts).all(func(v: Vector3) -> bool: return absf(v.y) < 1e-3), "ring lies on the true horizon")
		app.rig.set_horizon_ring_visible(false)
		check(not ring.visible, "horizon ring can be hidden")
		app.rig.set_horizon_ring_visible(true)
	check(below > drawn / 2, "most drawn satellites are below the horizon (%d of %d)" % [below, drawn])
	check(far_side > 20, "including far below it, through the Earth (%d below -45°)" % far_side)

	# A tracked satellite below the horizon keeps its full marker, unfaded.
	var css: Satellite = named[48274]
	var css_look := app.satellite_sky.look_angles(css, now)
	var marker: SkyMarker = app.active_satellite_markers.get(48274)
	check(css_look.elevation_deg < 0.0, "CSS is below the horizon now (%.1f°)" % css_look.elevation_deg)
	check(marker != null and marker.visible and marker._alpha == 1.0, "CSS marker drawn below the horizon, unfaded")
	if marker != null:
		near(rad_to_deg(asin(marker.position.normalized().y)), css_look.elevation_deg, 0.01, "CSS marker at its (negative) elevation")

	# Filtering a kind clears its diamonds.
	app.satellite_types = Satellite.ALL_CATEGORIES & ~Satellite.LEO
	await process_frame
	var hst: Satellite = named[20580]
	check(field.instance_color(hst).a == 0.0, "LEO filtered out: Hubble's diamond cleared")
	app.satellite_types = Satellite.ALL_CATEGORIES
	await process_frame
	check(field.instance_color(hst).a == 1.0, "LEO back: Hubble drawn again")

	# Gaze labels: look at Hubble and it is labelled, without a second diamond. Tracking
	# is off for this: at this moment the ISS happens to pass 2.2° from Hubble, and its
	# label would (rightly) take the spot — test_gaze_labels_do_not_overlap covers that.
	app.tracked_types = 0
	var hst_look := app.satellite_sky.look_angles(hst, app.unix_now())
	var mock: MockHeadTracker = app.rig.tracker
	mock._yaw = hst_look.azimuth_deg
	mock._pitch = hst_look.elevation_deg
	await process_frame
	await process_frame
	var label: SkyMarker = app.active_label_markers.get(20580)
	check(label != null, "looking at Hubble labels it (%.1f°, labelled %s)" % [hst_look.elevation_deg, app.active_label_markers.keys()])
	if label != null:
		check(label._label.text.begins_with("HST"), "Hubble's label (%s)" % label._label.text)
		check(not label._outline.visible, "label only: the field already draws the diamond")
	check(app.active_label_markers.size() <= app.gaze_labels, "at most gaze_labels labels")

	# Labels never overlap: pack many satellites into the gaze and check the placed
	# rectangles, in degrees of view, pairwise.
	for label_marker: SkyMarker in app.active_label_markers.values():
		var dir := label_marker.position.normalized()
		check(rad_to_deg((-app.rig.camera.global_basis.z).angle_to(dir)) <= app.gaze_label_deg + 0.5,
				"labelled satellites are near the gaze")

	# Look away: those labels go.
	mock._yaw = fposmod(hst_look.azimuth_deg + 90.0, 360.0)
	await process_frame
	await process_frame
	check(not app.active_label_markers.has(20580), "looking away drops Hubble's label")

	app.queue_free()
	await process_frame


func test_gaze_labels_do_not_overlap() -> void:
	# Labels are placed nearest the gaze first, and one that would overlap a label already
	# placed is skipped — so a dense band like Starlink along the horizon stays readable.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	var t0: float = fixture["cases"][0]["unix"]
	app.fixed_unix_time = t0
	root.add_child(app)
	await process_frame

	# Three spread catalogues, a sixth of an orbit apart: ~860 satellites all round.
	var list: Array[Satellite] = []
	for shift in 3:
		for sat in _spread_catalogue(fixture, shift * 60.0):
			list.append(sat)
	for i in list.size():
		list[i].norad_id = 700000 + i  # unique ids; the copies share names, not identity
	app.satellite_sky.set_catalogue(list, app.observer, t0)

	var mock: MockHeadTracker = app.rig.tracker
	var most := 0
	var skipped_somewhere := false
	for view: Array in [[0.0, 3.0], [90.0, 3.0], [180.0, 3.0], [270.0, 3.0], [45.0, -40.0], [200.0, 30.0]]:
		mock._yaw = view[0]
		mock._pitch = view[1]
		await process_frame
		await process_frame
		var forward := -app.rig.camera.global_basis.z
		var in_cone := 0
		for sat in list:
			var look := app.satellite_sky.look_angles(sat, app.unix_now())
			if rad_to_deg(forward.angle_to(GeoMath.sky_direction(look.azimuth_deg, look.elevation_deg))) <= app.gaze_label_deg:
				in_cone += 1
		var rects := app.gaze_rects
		var overlaps := 0
		for i in rects.size():
			for j in range(i + 1, rects.size()):
				if rects[i].intersects(rects[j]):
					overlaps += 1
		check(overlaps == 0, "view az %s el %s: no two labels overlap (%d pairs)" % [view[0], view[1], overlaps])
		var clashes := 0
		for r in rects:
			for other in app.occupied_view_rects():
				if r.intersects(other):
					clashes += 1
		check(clashes == 0, "view az %s el %s: no label covers a pointer or marker label (%d)" % [view[0], view[1], clashes])
		check(rects.size() == app.active_label_markers.size(), "a rect per label")
		check(rects.size() <= app.gaze_labels, "view az %s el %s: at most gaze_labels" % view)
		check(in_cone == 0 or rects.size() >= 1, "view az %s el %s: something in view is labelled" % view)
		most = maxi(most, rects.size())
		skipped_somewhere = skipped_somewhere or rects.size() < mini(in_cone, app.gaze_labels)
	check(most >= 2, "some view carries several labels (%d)" % most)
	check(skipped_somewhere, "and overlapping labels were skipped somewhere")

	app.queue_free()
	await process_frame


func test_app_draws_eclipsed_satellite() -> void:
	# Showing what the eye cannot see is the point of the app: a satellite in Earth's
	# shadow is drawn exactly like a lit one, just labelled "shadow".
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var eclipsed: Dictionary = {}
	for c: Dictionary in fixture["cases"]:
		if c["observerName"] == "Tucson" and int(c["norad"]) == 25544 and c["elevationDeg"] > 10.0 \
				and not c["sunlit"]:
			eclipsed = c
			break
	check(not eclipsed.is_empty(), "fixture has the ISS up over Tucson in Earth's shadow")
	if eclipsed.is_empty():
		return

	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	app.fixed_unix_time = eclipsed["unix"]
	root.add_child(app)
	await process_frame

	var list: Array[Satellite] = []
	list.assign(_fixture_satellites(fixture).values())
	app.satellite_sky.set_catalogue(list, app.observer, app.unix_now())
	app.update_satellite_markers()

	var marker: SkyMarker = app.active_satellite_markers.get(25544)
	check(marker != null and marker.visible, "ISS in Earth's shadow is drawn")
	if marker != null:
		near(marker._brightness, 1.0, 0.0, "shadowed ISS at full brightness")
		check(marker._label.text.ends_with(" shadow"), "shadowed ISS labelled \"shadow\"")

	app.queue_free()
	await process_frame


func test_pass_prediction_matches_skyfield() -> void:
	# Every pass Skyfield's find_events reports over a day, for four LEO satellites from
	# three observers, walked in order: each prediction starts just after the last set.
	# Measured agreement: rise/set 0.19 s, azimuth 0.02°, peak elevation 0.004°.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var sats := _fixture_satellites(fixture)
	var groups := {}
	for p: Dictionary in fixture["passes"]:
		var key := "%s from %s" % [sats[int(p["norad"])].name, p["observerName"]]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(p)
	check(fixture["passes"].size() >= 50, "fixture passes loaded (%d)" % fixture["passes"].size())

	for key: String in groups:
		var expected: Array = groups[key]
		var sat: Satellite = sats[int(expected[0]["norad"])]
		var o: Array = expected[0]["observer"]
		var observer := GeoPoint.new(o[0], o[1], o[2])
		var from: float = expected[0]["fromUnix"]
		for i in expected.size():
			var want: Dictionary = expected[i]
			var what := "%s pass %d" % [key, i + 1]
			var got := PassPredictor.next_pass(sat, observer, from)
			check(got != null, what + " found")
			if got == null:
				break
			near(got.rise_unix, want["rise"][0], 1.0, what + " rise time")
			near(GeoMath.bearing_delta(got.rise_azimuth_deg, want["rise"][1]), 0.0, 0.1, what + " rise azimuth")
			near(got.max_unix, want["max"][0], 1.0, what + " peak time")
			near(got.max_elevation_deg, want["max"][2], 0.05, what + " peak elevation")
			# Near the peak of a high pass azimuth swings fast, so compare distance on the
			# sky: azimuth difference scaled by cos(elevation).
			near(GeoMath.bearing_delta(got.max_azimuth_deg, want["max"][1]) * cos(deg_to_rad(got.max_elevation_deg)),
					0.0, 0.1, what + " peak azimuth")
			near(got.set_unix, want["set"][0], 1.0, what + " set time")
			near(GeoMath.bearing_delta(got.set_azimuth_deg, want["set"][1]), 0.0, 0.1, what + " set azimuth")
			from = got.set_unix + 1.0
		# After the last pass Skyfield found in its day, none until the day is out.
		var start: float = expected[0]["fromUnix"]
		var tail := PassPredictor.next_pass(sat, observer, from, start + 86400.0 - from)
		check(tail == null, "%s: no pass after the last one in the day" % key)

	# Hubble (28.5°) and the Chinese station (41.5°) never reach Tromso's sky at 69.7° N.
	var tromso := GeoPoint.new(69.65, 18.96, 20.0)
	var t0: float = fixture["passes"][0]["fromUnix"]
	check(PassPredictor.next_pass(sats[20580], tromso, t0) == null, "no Hubble pass over Tromso")
	check(PassPredictor.next_pass(sats[48274], tromso, t0) == null, "no CSS pass over Tromso")

	# Starting mid-pass: already up, so no rise, and the same set.
	var first: Dictionary = groups.values()[0][0]
	var o: Array = first["observer"]
	var mid := PassPredictor.next_pass(sats[int(first["norad"])], GeoPoint.new(o[0], o[1], o[2]),
			float(first["max"][0]))
	check(mid != null and is_nan(mid.rise_unix), "mid-pass start: pass in progress, rise unknown")
	if mid != null:
		near(mid.set_unix, first["set"][0], 1.0, "mid-pass start: set time")
		check(mid.in_progress_at(float(first["max"][0])), "mid-pass start: in progress now")

	check(PassPredictor.countdown(252.4) == "in 4:12", "countdown m:ss (%s)" % PassPredictor.countdown(252.4))
	check(PassPredictor.countdown(37 * 60 + 10) == "in 37m", "countdown minutes")
	check(PassPredictor.countdown(3 * 3600 + 5 * 60) == "in 3h05m", "countdown hours")
	check(PassPredictor.compass_point(247.5) == "WSW", "compass WSW")
	check(PassPredictor.compass_point(359.0) == "N" and PassPredictor.compass_point(11.0) == "N", "compass N wraps")
	check(PassPredictor.compass_point(11.3) == "NNE", "compass NNE")


func test_pass_predictor_scheduling() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var sats := _fixture_satellites(fixture)
	var iss: Satellite = sats[25544]
	var hst: Satellite = sats[20580]
	var tucson := GeoPoint.new(32.2226, -110.9747, 730.0)
	var t0: float = fixture["passes"][0]["fromUnix"]
	var tracked: Array[Satellite] = [iss, hst]

	# Sliced over frames, it reaches the same answer as the one-shot search.
	var predictor := PassPredictor.new()
	var frames := 0
	predictor.update(tracked, tucson, t0)
	while not predictor.is_idle() and frames < 1000:
		predictor.update(tracked, tucson, t0)
		frames += 1
	check(predictor.is_idle(), "predictions finish (%d frames at %d µs)" % [frames, predictor.budget_usec])
	check(frames > 5, "work is spread over frames, not done at once (%d)" % frames)
	var one_shot := PassPredictor.next_pass(iss, tucson, t0)
	var sliced: PassPredictor.SatellitePass = predictor.passes.get(25544)
	check(sliced != null and absf(sliced.rise_unix - one_shot.rise_unix) < 1e-6, "sliced = one-shot")

	# Idle means no work: nothing re-searched while predictions are current.
	predictor.update(tracked, tucson, t0 + 60.0)
	check(predictor.is_idle(), "current predictions are not re-searched")

	# Once the pass has set, the next one is found.
	var after := sliced.set_unix + 1.0
	predictor.update(tracked, tucson, after)
	while not predictor.is_idle():
		predictor.update(tracked, tucson, after)
	var next: PassPredictor.SatellitePass = predictor.passes[25544]
	check(next.rise_unix > sliced.set_unix, "after the pass sets, the next pass is predicted")

	# New elements (a new Satellite object) and a moved observer both force a re-search.
	# (Checked by what was searched, not by is_idle(): a short search can finish within
	# the same frame.)
	var fresh := Satellite.from_omm(fixture["omm"][0])
	predictor.update([fresh, hst] as Array[Satellite], tucson, after)
	check(predictor._searched[25544][0] == fresh, "new elements trigger a re-search")
	while not predictor.is_idle():
		predictor.update([fresh, hst] as Array[Satellite], tucson, after)
	var moved := GeoPoint.new(32.3, -110.9747, 730.0)
	predictor.update([fresh, hst] as Array[Satellite], moved, after)
	check(predictor._searched[25544][2] == GeoMath.geodetic_to_ecef(moved), "observer moving 8 km triggers a re-search")
	while not predictor.is_idle():
		predictor.update([fresh, hst] as Array[Satellite], moved, after)
	var searched_at: float = predictor._searched[25544][1]
	predictor.update([fresh, hst] as Array[Satellite], GeoPoint.new(32.301, -110.9747, 730.0), after + 5.0)
	check(predictor._searched[25544][1] == searched_at, "moving 100 m does not")

	# Untracked satellites are forgotten.
	predictor.update([fresh] as Array[Satellite], tucson, after)
	check(not predictor.passes.has(20580), "untracked satellite's pass dropped")


func test_app_shows_rise_marker() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var iss_pass: Dictionary = {}
	for p: Dictionary in fixture["passes"]:
		if int(p["norad"]) == 25544 and p["observerName"] == "Tucson":
			iss_pass = p
			break
	var rise_unix: float = iss_pass["rise"][0]

	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	app.fixed_unix_time = rise_unix - 300.0  # five minutes before the ISS rises
	root.add_child(app)
	await process_frame
	app.pass_predictor.budget_usec = 10_000_000

	var list: Array[Satellite] = []
	list.assign(_fixture_satellites(fixture).values())
	# A docked vehicle shares the station's pass; it must not get a second rise marker.
	list.append(Satellite.from_omm(fixture["omm"][0].merged({"NORAD_CAT_ID": 99001,
			"OBJECT_NAME": "SOYUZ-MS 99"}, true)))
	app.satellite_sky.set_catalogue(list, app.observer, app.unix_now())
	var mock: MockHeadTracker = app.rig.tracker
	mock._yaw = fposmod(float(iss_pass["rise"][1]) + 180.0, 360.0)  # facing away
	mock._pitch = 0.0
	await process_frame
	await process_frame

	check(app.active_rise_markers.keys() == [25544], "one rise marker, the station's (got %s)" % [app.active_rise_markers.keys()])
	var rise_marker: SkyMarker = app.active_rise_markers.get(25544)
	if rise_marker != null:
		check(rise_marker.kind == SkyMarker.Kind.RISE, "rise marker is a chevron")
		var want := app.rig.position_for(iss_pass["rise"][1], SkyMarker.HORIZON_FADE_DEG)
		check(rad_to_deg(rise_marker.global_position.angle_to(want)) < 0.1, "rise marker at the rise azimuth")
		var text: String = rise_marker._label.text
		check(text.begins_with("ISS (ZARYA) rises in 5:00") and text.ends_with("max %d°" % roundi(iss_pass["max"][2])),
				"rise label (%s)" % text.replace("\n", " / "))
		check(rise_marker.visible, "rise marker visible")

	var pointer_texts := []
	for i in app.pointers.active_count():
		pointer_texts.append((app.pointers.pointer(i).get_child(1) as Label3D).text)
	check(pointer_texts.any(func(t: String) -> bool: return t.begins_with("ISS (ZARYA) rises in 5:00")),
			"pointer leads to the rise point (%s)" % [pointer_texts])
	check(app._passes_status().begins_with("ISS (ZARYA) in 5:00 from %s" %
			PassPredictor.compass_point(iss_pass["rise"][1])), "HUD lists the pass (%s)" % app._passes_status())

	# Half a minute after the rise, the satellite's own marker takes over.
	app.fixed_unix_time = rise_unix + 30.0
	app.satellite_sky.set_catalogue(list, app.observer, app.unix_now())
	await process_frame
	await process_frame
	check(not app.active_rise_markers.has(25544), "rise marker gone once risen")
	check(app.active_satellite_markers.has(25544), "satellite marker there instead")

	app.queue_free()
	await process_frame


func test_offscreen_pointer_placement() -> void:
	var P = OffscreenPointers
	var th := tan(deg_to_rad(40.0) / 2.0)  # 40° x 23.5° view
	var tv := tan(deg_to_rad(23.5) / 2.0)
	var edge_x: float = th * OffscreenPointers.EDGE_INSET
	var edge_y: float = tv * OffscreenPointers.EDGE_INSET
	# Positions come back as Vector2, which is 32-bit: 1e-6 is float precision here, and
	# still ~0.00006° on screen.

	check(P.place(Vector3(0, 0, -1), th, tv).is_empty(), "straight ahead: no pointer")
	check(P.place(Vector3(th * 0.9, tv * 0.9, -1), th, tv).is_empty(), "inside the corner: no pointer")
	check(not P.place(Vector3(th * 1.02, 0, -1), th, tv).is_empty(), "just past the right edge: pointer")

	var right := P.place(Vector3(1, 0, -0.2), th, tv)
	near_vec(Vector3(right["position"].x, right["position"].y, 0), Vector3(edge_x, 0, 0), 1e-6, "right: on the right edge")
	near(right["angle"], 0.0, 1e-6, "right: points right")

	var up := P.place(Vector3(0, 1, -0.2), th, tv)
	near_vec(Vector3(up["position"].x, up["position"].y, 0), Vector3(0, edge_y, 0), 1e-6, "up: on the top edge")
	near(up["angle"], PI / 2.0, 1e-6, "up: points up")

	# Behind and to the left: turn left, the short way round.
	var behind_left := P.place(Vector3(-1, 0.1, 1), th, tv)
	check(behind_left["position"].x < 0.0 and cos(behind_left["angle"]) < 0.0, "behind-left: left edge, pointing left")
	var behind := P.place(Vector3(0, 0, 1), th, tv)
	check(not behind.is_empty(), "directly behind: still a pointer")

	# Always on the inset rectangle, whatever the direction.
	for d: Vector3 in [Vector3(3, 2, -1), Vector3(-0.2, -5, -1), Vector3(0.7, -0.7, 0.1), Vector3(-2, 1, 0.5)]:
		var w := P.place(d, th, tv)
		var pos: Vector2 = w["position"]
		check(absf(pos.x) <= edge_x + 1e-6 and absf(pos.y) <= edge_y + 1e-6, "%s: pointer inside the view" % d)
		check(is_equal_approx(absf(pos.x), edge_x) or is_equal_approx(absf(pos.y), edge_y), "%s: pointer on the edge" % d)
		# In front, the pointer lies on the line from centre to the target's projection.
		if d.z < 0.0:
			near(pos.angle(), Vector2(d.x, d.y).angle(), 1e-6, "%s: pointer aims at the target" % d)


func _pointer_texts(app: AppBootstrap) -> Array:
	var texts := []
	for i in app.pointers.active_count():
		texts.append((app.pointers.pointer(i).get_child(1) as Label3D).text)
	return texts


func _pointer_labelled(app: AppBootstrap, prefix: String) -> Node3D:
	for i in app.pointers.active_count():
		if (app.pointers.pointer(i).get_child(1) as Label3D).text.begins_with(prefix):
			return app.pointers.pointer(i)
	return null


func test_pointer_labels_do_not_overlap() -> void:
	# Three targets almost on top of each other, off the bottom of the view, like the ISS,
	# the CSS and a rise point all below the horizon: all three pointers show, none of
	# their labels overlap, and each still aims the way to turn.
	# The glasses' per-eye view is 16:9; the headless window is a 64 px square, with no
	# room along the bottom for three labels.
	var window_size := root.size
	root.size = Vector2i(1920, 1080)
	var rig := SkyRig.new()
	rig.stereo = SkyRig.Stereo.MONO
	root.add_child(rig)
	await process_frame
	var pointers := OffscreenPointers.new()
	pointers.initialize(rig.camera)
	var targets: Array[OffscreenPointers.Target] = []
	for i in 3:
		var dir := GeoMath.sky_direction(1.0 + i * 0.5, -40.0 - i * 0.3)
		targets.append(OffscreenPointers.Target.new(dir, ["ISS (ZARYA)", "CSS (TIANHE)", "CSS (TIANHE) rises in 16m"][i], Color.WHITE))
	pointers.update_targets(targets)
	check(pointers.active_count() == 3, "all three pointers shown (%d)" % pointers.active_count())
	var rects := pointers.footprints()
	var overlaps := 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				overlaps += 1
	check(overlaps == 0, "no two pointer footprints overlap (%d pairs)" % overlaps)
	for i in pointers.active_count():
		var chevron: MeshInstance3D = pointers.pointer(i).get_child(0)
		check(sin(chevron.rotation.z) < -0.9, "pointer %d still aims down" % i)
		var bottom := -OffscreenPointers.DISTANCE * tan(deg_to_rad(rig.camera.fov) / 2.0) * OffscreenPointers.EDGE_INSET
		near(pointers.pointer(i).position.y, bottom, 1e-3, "pointer %d stays on the bottom edge, sliding sideways" % i)
	root.size = window_size
	rig.queue_free()
	await process_frame


func test_app_points_at_offscreen_station() -> void:
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var pass_: Dictionary = {}
	for c: Dictionary in fixture["cases"]:
		if c["observerName"] == "Tucson" and int(c["norad"]) == 25544 and c["elevationDeg"] > 10.0:
			pass_ = c
			break
	check(not pass_.is_empty(), "fixture has the ISS up over Tucson")
	if pass_.is_empty():
		return

	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	app.fixed_unix_time = pass_["unix"]
	root.add_child(app)
	await process_frame
	var list: Array[Satellite] = []
	list.assign(_fixture_satellites(fixture).values())
	app.satellite_sky.set_catalogue(list, app.observer, app.unix_now())

	check(app.pointers.get_parent() == app.rig.camera, "pointers ride on the camera")

	# Face directly away from the ISS, level.
	var mock: MockHeadTracker = app.rig.tracker
	mock._yaw = fposmod(pass_["azimuthDeg"] + 180.0, 360.0)
	mock._pitch = 0.0
	await process_frame
	await process_frame

	# The manned satellites get pointers (the CSS too, though it is below the horizon
	# now — it is drawn through the Earth like everything else); Hubble and the rest,
	# not tracked, get none.
	var iss_pointer := _pointer_labelled(app, "ISS (ZARYA) ")
	check(iss_pointer != null, "pointer for the ISS (got %s)" % [_pointer_texts(app)])
	check(_pointer_texts(app).all(func(t: String) -> bool:
			return t.begins_with("ISS (ZARYA) ") or t.begins_with("CSS (TIANHE) ")),
			"pointers only for tracked (manned) satellites (got %s)" % [_pointer_texts(app)])
	if iss_pointer != null:
		# Straight behind and up by the pass elevation: 180 - elevation degrees of turn.
		var text: String = (iss_pointer.get_child(1) as Label3D).text
		var want := roundi(180.0 - pass_["elevationDeg"])
		check(absi(text.trim_prefix("ISS (ZARYA) ").trim_suffix("°").to_int() - want) <= 1,
				"pointer says %s, want ~%d°" % [text, want])
		check(iss_pointer.visible and iss_pointer.position.z < 0.0, "pointer drawn in front of the camera")
		check(iss_pointer.position.y > 0.0, "pointer on the upper side: the ISS is above the horizon")

	# Turn to face the ISS: the marker is on screen, its pointer goes.
	mock._yaw = pass_["azimuthDeg"]
	mock._pitch = pass_["elevationDeg"]
	await process_frame
	await process_frame
	check(_pointer_labelled(app, "ISS (ZARYA) ") == null, "facing the ISS: no ISS pointer (got %s)" % [_pointer_texts(app)])

	# Kinds outside tracked_types get none: with every kind on, more pointers appear.
	app.tracked_types = Satellite.ALL_CATEGORIES
	mock._yaw = fposmod(pass_["azimuthDeg"] + 180.0, 360.0)
	mock._pitch = 0.0
	await process_frame
	await process_frame
	check(app.pointers.active_count() > 1, "all kinds: more than the ISS pointed at (%d)" % app.pointers.active_count())
	check(app.pointers.active_count() <= app.pointers.max_pointers, "capped at max_pointers")

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


# --- Controls ---------------------------------------------------------------------

## Stands in for the VitureGlasses plugin: the control panel's command queue and status.
class FakePanelPlugin:
	extends RefCounted
	var queued: Array[String] = []
	var status := ""

	func takeCommands() -> PackedStringArray:
		var out := PackedStringArray(queued)
		queued.clear()
		return out

	func setPanelStatus(text: String) -> void:
		status = text

	var state := ""

	func setPanelState(text: String) -> void:
		state = text

	func getLocation() -> PackedFloat64Array:
		return PackedFloat64Array()

	var panels_opened := 0

	func showControlPanel() -> void:
		panels_opened += 1


func _north_x_deg(app: AppBootstrap) -> float:
	# Where true north on the horizon appears, degrees right of the view centre.
	var v := app.rig.camera.global_basis.inverse() * GeoMath.sky_direction(0.0, 0.0)
	return rad_to_deg(atan2(v.x, -v.z))


## Turn the (mock) head to look along a world direction: the raw yaw the glasses would
## report is the true heading minus the calibration offset.
func _face(app: AppBootstrap, mock: MockHeadTracker, dir: Vector3) -> void:
	var heading := rad_to_deg(atan2(dir.x, -dir.z))
	mock._yaw = fposmod(heading - app.calibration.heading_offset_deg, 360.0)
	mock._pitch = rad_to_deg(asin(clampf(dir.normalized().y, -1.0, 1.0)))


## Commands apply after the camera has moved this frame, so their effect shows next frame.
func _settle() -> void:
	await process_frame
	await process_frame


func test_controls() -> void:
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	root.add_child(app)
	await _settle()
	var fake := FakePanelPlugin.new()
	app._android = fake
	var mock: MockHeadTracker = app.rig.tracker
	mock._yaw = 0.0  # facing north, uncalibrated: offset 0
	mock._pitch = 0.0
	await _settle()
	near(_north_x_deg(app), 0.0, 1e-3, "starts looking at north")

	# Panel buttons: sky:+1 moves the sky (and so the N) right by 1°, like a drag.
	fake.queued.append("sky:1")
	await _settle()
	near(_north_x_deg(app), 1.0, 1e-3, "panel 'sky 1° →' moves the N right 1°")
	check(app.horizon_control.is_adjusting(), "a nudge brightens the ghosts")
	fake.queued.append("sky:-1")
	await _settle()
	near(_north_x_deg(app), 0.0, 1e-3, "and '← 1°' moves it back")

	# The pad: a drag of 10% of its width is 10% of coarse_deg_per_screen; two fingers
	# are fine mode. The ghosts stay bright until the finger lifts.
	var coarse := app.horizon_control.coarse_deg_per_screen
	var fine := app.horizon_control.fine_deg_per_screen
	fake.queued.append_array(["drag:0.05000:1", "drag:0.05000:1"])
	await _settle()
	near(_north_x_deg(app), 0.1 * coarse, 1e-3, "pad drag right turns the sky right, coarse")
	check(app.horizon_control.is_adjusting(), "adjusting while the pad is held")
	fake.queued.append_array(["drag:-0.10000:2", "drag_end"])
	await _settle()
	near(_north_x_deg(app), 0.1 * coarse - 0.1 * fine, 1e-3, "two fingers: fine")
	app.horizon_control._key_highlight_until = -INF
	check(not app.horizon_control.is_adjusting(), "released pad: not adjusting")

	# "I'm facing north" from the panel: whatever the offset, heading now reads 0.
	mock._yaw = 73.0
	fake.queued.append("north")
	await _settle()
	near(GeoMath.bearing_delta(app.rig.current_heading_deg(), 0.0), 0.0, 1e-6, "panel north calibrates")
	app._panel_status_timer = 1.0  # due now: it goes out four times a second
	await process_frame
	check(fake.status.begins_with("Heading 0.0°"), "status reaches the panel (%s)" % fake.status.replace("\n", " / "))
	check(fake.status.contains("Calibrated"), "status says calibrated")

	# Glasses menu: a tap opens it where you look, facing you.
	fake.queued.append("tap")
	await _settle()
	check(app.quick_menu.is_open(), "tap opens the glasses menu")
	check(app._reticle.visible, "reticle shown with the menu")
	var menu := app.quick_menu
	var forward := -app.rig.camera.global_basis.z
	near(rad_to_deg(forward.angle_to(menu.position.normalized())), 0.0, 1e-3, "menu opens where you look")
	check(menu.row_at(forward) >= 0 or menu.items[menu.items.size() / 2].command.is_empty(), "looking at the middle hits a row")

	# Aim at "Sky → 1°" by turning the head, tap: the sky moves, the menu stays.
	var target := -1
	for i in menu.items.size():
		if menu.items[i].command == "sky:1":
			target = i
	var row_dir := (menu.global_transform * Vector3(0.0, menu._row_y(target), 0.0)).normalized()
	_face(app, mock, row_dir)
	await _settle()
	check(menu.hovered == target, "aiming at a row hovers it (hovered %d, want %d)" % [menu.hovered, target])
	var before := app.calibration.heading_offset_deg
	fake.queued.append("tap")
	await _settle()
	near(GeoMath.bearing_delta(app.calibration.heading_offset_deg, before), -1.0, 1e-6, "menu 'Sky → 1°' nudges")
	check(menu.is_open(), "the menu stays open to press again")

	# Rows are told apart: the row above and the title are not the same target.
	var above := (menu.global_transform * Vector3(0.0, menu._row_y(target - 1), 0.0)).normalized()
	check(menu.row_at(above) == target - 1 or menu.items[target - 1].command.is_empty(), "the row above is its own row")
	var title := (menu.global_transform * Vector3(0.0, menu._row_y(0), 0.0)).normalized()
	check(menu.row_at(title) == -1, "the title is not selectable")
	var beside := (menu.global_transform * Vector3(menu._width, menu._row_y(target), 0.0)).normalized()
	check(menu.row_at(beside) == -1, "beside the menu hits nothing")
	check(menu.row_at(-row_dir) == -1, "looking the other way hits nothing")

	# "Set north…" is two steps: choose it (menu closes, prompt shows), face north, tap.
	var set_north := -1
	for i in menu.items.size():
		if menu.items[i].command == "set_north":
			set_north = i
	row_dir = (menu.global_transform * Vector3(0.0, menu._row_y(set_north), 0.0)).normalized()
	_face(app, mock, row_dir)
	await _settle()
	fake.queued.append("tap")
	await _settle()
	check(not menu.is_open() and app.capturing_north, "Set north closes the menu and waits")
	check(app._prompt.visible, "prompt shown: face north, then tap")
	mock._yaw = 211.0  # the user turns to face north; the glasses happen to say 211
	mock._pitch = 0.0
	fake.queued.append("tap")
	await _settle()
	check(not app.capturing_north and not app._prompt.visible, "the tap takes it")
	near(GeoMath.bearing_delta(app.rig.current_heading_deg(), 0.0), 0.0, 1e-6, "north is where they faced at the tap")

	# A tap looking away from an open menu dismisses it; M toggles it.
	fake.queued.append("tap")
	await _settle()
	_face(app, mock, GeoMath.sky_direction(120.0, 0.0))
	await _settle()
	fake.queued.append("tap")
	await _settle()
	check(not menu.is_open(), "tap looking away closes the menu")
	var m := InputEventKey.new()
	m.keycode = KEY_M
	m.pressed = true
	app._unhandled_input(m)
	check(menu.is_open(), "M opens the menu")
	app._unhandled_input(m)
	check(not menu.is_open(), "M closes it")

	# The phone panel waits its turn: not before its start delay, then exactly once.
	app._panel_pending = true
	app._panel_not_before = AppBootstrap._seconds() + 60.0
	await _settle()
	check(fake.panels_opened == 0, "panel not opened before its delay")
	app._panel_not_before = 0.0
	await _settle()
	await _settle()
	check(fake.panels_opened == 1, "panel opened once when clear (%d)" % fake.panels_opened)

	app._android = null
	app.queue_free()
	await _settle()


func test_viewpoint_geometry() -> void:
	# From the middle of the Earth, north is still north, and "up" is out through the
	# observer's latitude and longitude. At 0°, 0° geodetic and geocentric agree.
	var centre := GeoPoint.earth_centre(0.0, 0.0)
	var zero := GeoMath.geodetic_to_ecef(centre)
	check(zero[0] == 0.0 and zero[1] == 0.0 and zero[2] == 0.0, "Earth centre is the ECEF origin")
	var overhead := GeoMath.to_look_angles(centre, GeoPoint.new(0.0, 0.0, 400000.0))
	near(overhead.elevation_deg, 90.0, 1e-9, "centre: the point over the observer is straight up")
	near(overhead.range_m, GeoMath.SEMI_MAJOR_AXIS + 400000.0, 1e-3, "centre: range is the geocentric distance")
	var east := GeoMath.to_look_angles(centre, GeoPoint.new(0.0, 90.0, 0.0))
	near(east.azimuth_deg, 90.0, 1e-9, "centre: 90° of longitude east is due east")
	near(east.elevation_deg, 0.0, 1e-9, "centre: ...and level")
	var north := GeoMath.to_look_angles(GeoPoint.earth_centre(0.0, 0.0), GeoPoint.new(60.0, 0.0, 0.0))
	near(north.azimuth_deg, 0.0, 1e-9, "centre: a point further north is due north")
	# Up is out through lat/lon 0,0; a point 60° of latitude away is 30° above that "level".
	near(north.elevation_deg, 30.0, 0.2, "centre: ...30° up (60° round the Earth from straight up)")

	# From 400 km up the ground below is straight down, and a point on the far side of the
	# Earth is below the horizon by nearly 90°.
	var high := GeoPoint.new(10.0, 20.0, 400000.0)
	near(GeoMath.to_look_angles(high, GeoPoint.new(10.0, 20.0, 0.0)).elevation_deg, -90.0, 1e-6,
			"400 km: the ground below is straight down")
	check(GeoMath.to_look_angles(high, GeoPoint.new(-10.0, -160.0, 0.0)).elevation_deg < -60.0,
			"400 km: the antipode is far below")
	# Geostationary: the sub-satellite point on the equator is straight down.
	var geo := GeoPoint.new(0.0, 100.0, AppBootstrap.GEO_ALTITUDE_KM * 1000.0)
	near(GeoMath.to_look_angles(geo, GeoPoint.new(0.0, 100.0, 0.0)).elevation_deg, -90.0, 1e-6, "GEO: ground is down")


func test_viewpoint_and_groups() -> void:
	test_viewpoint_geometry()
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/satellite_fixture.json"))
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 47.6
	app.longitude_deg = -122.3
	app.altitude_m = 100.0
	var t0: float = fixture["cases"][0]["unix"]
	app.fixed_unix_time = t0
	root.add_child(app)
	await process_frame
	var fake := FakePanelPlugin.new()
	app._android = fake

	# Two airliners: one overhead-ish, one on the far side of the Earth.
	var near_ac := Aircraft.new()
	near_ac.icao24 = "near01"
	near_ac.latitude_deg = 47.65
	near_ac.longitude_deg = -122.22
	near_ac.altitude_ft = 12000.0
	near_ac.classification = AircraftClassifier.COMMERCIAL | AircraftClassifier.JET
	var far_ac := Aircraft.new()
	far_ac.icao24 = "far01"
	far_ac.latitude_deg = -47.6
	far_ac.longitude_deg = 57.7
	far_ac.altitude_ft = 35000.0
	far_ac.classification = AircraftClassifier.MILITARY | AircraftClassifier.JET
	app.adsb.aircraft = {"near01": near_ac, "far01": far_ac}
	await _settle()
	check(app.view_point() == app.observer, "default view is the observer's own position")
	check(app.active_markers.has("near01") and not app.active_markers.has("far01"),
			"surface: only the aircraft above the horizon and in range")

	# Earth centre: nothing is hidden by the horizon or the range, and the far side shows.
	fake.queued.append("view:centre")
	await _settle()
	check(app.viewpoint == AppBootstrap.Viewpoint.CENTRE and app.view_point().at_earth_centre, "view:centre")
	check(app.active_markers.has("far01"), "centre: the far side's aircraft is drawn")
	var far_marker: SkyMarker = app.active_markers.get("far01")
	if far_marker != null:
		var look := GeoMath.to_look_angles(app.view_point(), far_ac.position())
		check(look.elevation_deg < -30.0, "centre: it is well below the local level (%.1f°)" % look.elevation_deg)
		near_vec(far_marker.global_position, app.rig.position_for_look(look), 1e-3, "centre: it sits at its direction from the middle")
		check(far_marker.visible and not far_marker.fades_at_horizon, "centre: not faded for being 'below the horizon'")
	check(app.adsb.radius_nm == 250, "off the ground the feed asks for its widest circle")
	check(app.active_rise_markers.is_empty(), "no rise markers without a horizon")

	# Altitude: any km, clamped to the ground ... GEO; the panel is told.
	fake.queued.append("view:400")
	await _settle()
	check(app.viewpoint == AppBootstrap.Viewpoint.ALTITUDE and app.viewpoint_altitude_km == 400.0, "view:400")
	near(app.view_point().altitude_m, 400000.0, 1e-6, "400 km is 400,000 m above the observer's lat/lon")
	near(app.view_point().latitude_deg, 47.6, 1e-12, "...at the observer's latitude")
	fake.queued.append("view:up")
	await _settle()
	near(app.viewpoint_altitude_km, 600.0, 1e-9, "higher is x1.5")
	fake.queued.append("view:down")
	fake.queued.append("view:down")
	await _settle()
	near(app.viewpoint_altitude_km, 266.666667, 1e-3, "lower is /1.5")
	app.run_command("view:99999")
	near(app.viewpoint_altitude_km, AppBootstrap.GEO_ALTITUDE_KM, 1e-9, "clamped at GEO")
	app.run_command("view:0.4")
	near(app.viewpoint_altitude_km, 0.0, 1e-9, "under a km is the ground")
	app.run_command("view:-5")
	near(app.viewpoint_altitude_km, 0.0, 1e-9, "never below the ground")
	app.run_command("view:banana")
	near(app.viewpoint_altitude_km, 0.0, 1e-9, "garbage is ignored")
	app.run_command("view:400")
	app._panel_status_timer = 1.0
	await process_frame
	check(fake.state == "view=altitude;alt=400;sat=%d;air=%d;star=0" % [Satellite.ALL_CATEGORIES, AppBootstrap.AIRCRAFT_ALL],
			"panel state (%s)" % fake.state)
	check(fake.status.contains("400 km up"), "panel status names the viewpoint")

	app.run_command("view:surface")
	await _settle()
	check(app.view_point() == app.observer and app.adsb.radius_nm == 100, "back on the ground")
	check(not app.active_markers.has("far01"), "...the far side's aircraft is hidden again")

	# Aircraft groups.
	check(AppBootstrap.aircraft_shown(AircraftClassifier.COMMERCIAL | AircraftClassifier.JET, AppBootstrap.AIRCRAFT_ALL), "all: airliner")
	check(AppBootstrap.aircraft_shown(AircraftClassifier.UNKNOWN, AppBootstrap.AIRCRAFT_ALL), "all: unclassified")
	check(not AppBootstrap.aircraft_shown(AircraftClassifier.UNKNOWN, AppBootstrap.AIRCRAFT_ALL & ~AppBootstrap.AIRCRAFT_OTHER),
			"no Other: unclassified hidden")
	check(not AppBootstrap.aircraft_shown(AircraftClassifier.GLIDER | AircraftClassifier.PRIVATE, AircraftClassifier.COMMERCIAL), "commercial only: private glider hidden")
	check(AppBootstrap.aircraft_shown(AircraftClassifier.MILITARY | AircraftClassifier.ROTORCRAFT, AircraftClassifier.ROTORCRAFT),
			"a military helicopter is in Helicopters too")
	check(not AppBootstrap.aircraft_shown(AircraftClassifier.COMMERCIAL, 0), "none: nothing")
	app.run_command("air:0")  # Commercial off
	await _settle()
	check(not (app.aircraft_types & AircraftClassifier.COMMERCIAL) and not app.active_markers.has("near01"),
			"air:0 hides commercial aircraft")
	app.run_command("air:0")
	await _settle()
	check(app.active_markers.has("near01"), "and flips back")
	app.run_command("air:none")
	await _settle()
	check(app.active_markers.is_empty(), "air:none hides them all")
	app.run_command("air:all")
	app.run_command("air:99")
	check(app.aircraft_types == AppBootstrap.AIRCRAFT_ALL, "all on; a bad group index changes nothing")

	# Satellite kinds follow the same commands...
	app.run_command("sat:1")
	check(not (app.satellite_types & Satellite.STARLINK) and app.satellite_types & Satellite.MANNED, "sat:1 is Starlink")
	app.run_command("sat:all")
	check(app.satellite_types == Satellite.ALL_CATEGORIES, "sat:all")

	# ...and the satellites' directions are measured from wherever you view them from.
	var list := _spread_catalogue(fixture)
	app.satellite_sky.set_catalogue(list, app.view_point(), t0)
	app.run_command("view:centre")
	app.fixed_unix_time = t0 + 3.0
	for i in 400:  # the re-frame is spread over frames by SatelliteSky's budget
		await process_frame
		if app.satellite_sky.backlog() == 0:
			break
	var checked := 0
	for sat in list.slice(0, 40):
		var p: PackedFloat64Array = sat.ecef_at(app.unix_now())
		var want := GeoMath.look_angles_in_frame(GeoMath.local_frame(app.view_point()), p[0], p[1], p[2])
		var got := app.satellite_sky.look_angles(sat, app.unix_now())
		if absf(want.elevation_deg - got.elevation_deg) > 1e-6 or absf(want.range_m - got.range_m) > 1e-3:
			check(false, "%s: look from the centre is %.4f° / %.0f m, want %.4f° / %.0f m" % [
					sat.name, got.elevation_deg, got.range_m, want.elevation_deg, want.range_m])
		checked += 1
	check(checked == 40, "satellites measured from the Earth's centre")
	var ranges := list.slice(0, 40).map(func(sat: Satellite) -> float:
		return app.satellite_sky.look_angles(sat, app.unix_now()).range_m)
	check(ranges.all(func(r: float) -> bool: return r > 6.3e6), "centre: every range is geocentric (>6,300 km)")

	# Glasses menu pages: toggles show their state and the menu stays open.
	app.run_command("view:surface")
	app.open_menu()
	check(app._menu_items().size() >= 8, "main menu has the new pages")
	app.run_command("page:sat")
	check(app.quick_menu.items.size() == 9 and app.quick_menu.items[2].text.begins_with("☑"), "satellite page lists kinds, all on")
	app.run_command("sat:1")
	app.quick_menu.set_items(app._menu_items())
	check(app.quick_menu.items[2].text.begins_with("☐ Starlink"), "the Starlink row shows it is off (%s)" % app.quick_menu.items[2].text)
	app.run_command("page:alt")
	check(app.quick_menu.items[0].text == "View from: Surface", "altitude page title")
	app.run_command("page:main")
	check(app.quick_menu.items[0].text.begins_with("Heading"), "back to the main page")

	app._android = null
	app.queue_free()
	await _settle()


func test_pole_star() -> void:
	# The star finder against Skyfield, both stars from observers north and south.
	var fixture: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://tests/star_fixture.json"))
	var worst := 0.0
	var count := 0
	for c: Dictionary in fixture["cases"]:
		var target := PoleStar.POLARIS if c["star"] == "Polaris" else PoleStar.SIGMA_OCTANTIS
		var o: Array = c["observer"]
		var look := PoleStar.look_angles(target, o[0], o[1], c["unix"])
		# Atmospheric refraction is not in either: compare geometric directions.
		var d_az := absf(GeoMath.bearing_delta(look.azimuth_deg, c["azimuthDeg"]))
		var d_el := absf(look.elevation_deg - c["elevationDeg"])
		# Azimuth is only well defined away from the zenith: scale by cos(el).
		var err := maxf(d_az * cos(deg_to_rad(c["elevationDeg"])), d_el)
		worst = maxf(worst, err)
		count += 1
		if err > 0.02:
			check(false, "%s from %s at %s: %.3f°/%.3f° vs Skyfield %.3f°/%.3f°" % [c["star"], c["observerName"],
					Time.get_datetime_string_from_unix_time(int(c["unix"])), look.azimuth_deg, look.elevation_deg,
					c["azimuthDeg"], c["elevationDeg"]])
	check(count == 84, "star fixture loaded (%d cases)" % count)
	print("pole star vs Skyfield: worst %.4f° over %d cases" % [worst, count])
	check(worst < 0.02, "pole star matches Skyfield to 0.02° (worst %.4f°)" % worst)

	check(PoleStar.for_latitude(32.0) == PoleStar.POLARIS and PoleStar.for_latitude(-33.0) == PoleStar.SIGMA_OCTANTIS,
			"Polaris in the north, Sigma Octantis in the south")
	# Polaris is up by about your latitude, and never far from north.
	var t0: float = fixture["cases"][0]["unix"]
	for i in 24:
		var look := PoleStar.look_angles(PoleStar.POLARIS, 32.2226, -110.9747, t0 + i * 3600.0)
		check(absf(look.elevation_deg - 32.2226) < 1.0, "Polaris is %.1f° up at hour %d" % [look.elevation_deg, i])
		check(absf(GeoMath.bearing_delta(look.azimuth_deg, 0.0)) < 1.5, "...and within 1.5° of north (%.2f°)" % look.azimuth_deg)

	# Calibrating from the gaze: whatever the head's yaw, pitched up, the offset makes it
	# face the star's true azimuth.
	var cal := CompassCalibration.new()
	cal.calibrate_from_gaze(0.7, 200.0)
	near(cal.heading_offset_deg, GeoMath.wrap360(0.7 - 200.0), 1e-9, "gaze fix sets the offset")
	check(cal.is_calibrated and cal.source == CompassCalibration.Source.CELESTIAL, "...as a celestial fix")
	cal.calibrate_from_gaze(10.0, 10.0)
	near(cal.heading_offset_deg, GeoMath.wrap360(0.7 - 200.0), 1e-9, "a gaze already right changes nothing")

	# In the app: sight the star with the head pitched up, tap, and north is where it should be.
	var app: AppBootstrap = load("res://main.tscn").instantiate()
	app.start_feed = false
	app.start_satellites = false
	app.show_debug_hud = false
	app.latitude_deg = 32.2226
	app.longitude_deg = -110.9747
	app.altitude_m = 730.0
	app.fixed_unix_time = t0
	root.add_child(app)
	await _settle()
	var fake := FakePanelPlugin.new()
	app._android = fake
	var mock: MockHeadTracker = app.rig.tracker
	var want := PoleStar.look_angles(PoleStar.POLARIS, 32.2226, -110.9747, t0)

	fake.queued.append("star")
	await _settle()
	check(app.capturing_star and app._star_ring.visible and app._prompt.visible, "star: circle and prompt shown")
	check(app._prompt.text.begins_with("Put Polaris in the circle"), "prompt names the star (%s)" % app._prompt.text.replace("\n", " / "))
	check(fake.status.length() >= 0 and app.panel_status().contains("POLARIS"), "the panel says so too")
	mock._yaw = 137.0  # whatever the glasses think
	mock._pitch = want.elevation_deg
	await _settle()
	fake.queued.append("tap")
	await _settle()
	check(not app.capturing_star and not app._star_ring.visible, "the tap takes the sighting")
	var fwd := -app.rig.camera.global_basis.z
	var gaze_az := GeoMath.wrap360(rad_to_deg(atan2(fwd.x, -fwd.z)))
	near(absf(GeoMath.bearing_delta(gaze_az, want.azimuth_deg)), 0.0, 1e-3, "now facing the star's azimuth")
	check(app.calibration.source == CompassCalibration.Source.CELESTIAL, "recorded as a star fix")
	# Turn to true north (the star is ~0.5° off it): the heading reads that.
	mock._yaw = fposmod(137.0 - want.azimuth_deg, 360.0)
	await _settle()
	near(absf(GeoMath.bearing_delta(app.rig.current_heading_deg(), 0.0)), 0.0, 1e-2, "so north is north")

	# Cancelling: the star command again (the panel's button is a toggle), "cancel", or Escape.
	app.run_command("star")
	check(app.capturing_star and app.panel_state().ends_with("star=1"), "sighting on; the panel is told")
	app.run_command("star")
	check(not app.capturing_star and app.panel_state().ends_with("star=0"), "star again cancels")
	app.run_command("star")
	app.run_command("cancel")
	check(not app.capturing_star, "cancel ends a sighting")
	app.run_command("star")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	app._unhandled_input(esc)
	check(not app.capturing_star, "Escape ends a sighting")
	app.capturing_north = true
	app.run_command("cancel")
	check(not app.capturing_north, "cancel also ends waiting to take north")
	await _settle()
	check(not app._prompt.visible and not app._star_ring.visible, "the circle and prompt are gone")

	# Not required: other ways still work, a menu open cancels it, and it times out.
	fake.queued.append("star")
	await _settle()
	app.open_menu()
	check(not app.capturing_star, "opening the menu cancels the sighting")
	app.quick_menu.close()
	app.run_command("star")
	app._capture_until = 0.0
	await _settle()
	check(not app.capturing_star, "a sighting nobody finishes times out")
	check(app._menu_items().any(func(i: QuickMenu.Item) -> bool: return i.command == "star"), "the glasses menu offers it")

	# Too low to use near the equator: a notice, not a sighting.
	app.observer = GeoPoint.new(0.5, -78.0, 2800.0)
	app.run_command("star")
	await _settle()
	check(not app.capturing_star and app._prompt.visible and app._prompt.text.contains("Polaris is only"),
			"near the equator it says the star is too low (%s)" % app._prompt.text)
	# South: Sigma Octantis, and it warns that it is faint.
	app._notice_until = 0.0
	app.observer = GeoPoint.new(-33.9, 18.4, 20.0)
	app.run_command("star")
	await _settle()
	check(app.capturing_star and app._prompt.text.begins_with("Put Sigma Octantis") and app._prompt.text.contains("faint"),
			"south: Sigma Octantis, with the faint warning (%s)" % app._prompt.text.replace("\n", " / "))

	app._android = null
	app.queue_free()
	await _settle()
