extends SceneTree
## Live check of the Godot pipeline against adsb.lol's own ground truth. Needs network.
##
##   godot --headless --path godot/VRAeroScan --script res://tests/live_check.gd
##
## adsb.lol reports `dst` (nm) and `dir` (deg) from the query point for every aircraft.
## This runs the real request, the real parser and the real GeoMath, and checks they
## reproduce both — the GDScript twin of tools/validation/validate_geomath.py.
##
## Compare like with like. `dir` is a SPHERICAL great-circle bearing rounded to 0.1°,
## so it is checked against great_circle(), to the ±0.05° rounding bound. The app's
## pointing azimuth comes from to_look_angles(), which is ellipsoidal (WGS84) and
## legitimately differs from the spherical bearing by ~0.1° at mid-latitudes — that is
## reported, not asserted. (Found 2026-09-23 over 72 aircraft: sphere-vs-dir max 0.049°
## with zero mean bias; ellipsoid-vs-dir max 0.126°.) `dst` jitters by up to ~0.1 nm
## with zero mean, consistent with it being computed from a slightly different
## position snapshot than the lat/lon sent alongside it.

const LAT := 47.6
const LON := -122.3


func _initialize() -> void:
	var http := HTTPRequest.new()
	root.add_child(http)
	await process_frame

	http.request("https://api.adsb.lol/v2/point/%s/%s/50" % [LAT, LON], ["User-Agent: VRAeroScan/0.1"])
	var response: Array = await http.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		printerr("request failed: result %d, HTTP %d" % [response[0], response[1]])
		quit(2)
		return

	var body: Dictionary = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	var raw: Array = body.get("ac", [])
	var parsed := AdsbService.parse(body, 0.0)
	var observer := GeoPoint.new(LAT, LON, 100.0)

	var by_hex := {}
	for entry: Dictionary in raw:
		by_hex[entry.get("hex", "")] = entry

	var worst_bearing := 0.0
	var worst_az := 0.0
	var worst_dist_nm := 0.0
	var compared := 0
	for ac in parsed:
		var entry: Dictionary = by_hex.get(ac.icao24, {})
		if not (entry.has("dst") and entry.has("dir")):
			continue
		var look := GeoMath.to_look_angles(observer, ac.position())
		var gc := GeoMath.great_circle(observer, ac.position())
		worst_bearing = maxf(worst_bearing, absf(GeoMath.bearing_delta(gc[1], entry["dir"])))
		worst_az = maxf(worst_az, absf(GeoMath.bearing_delta(look.azimuth_deg, entry["dir"])))
		worst_dist_nm = maxf(worst_dist_nm, absf(gc[0] / GeoMath.METERS_PER_NAUTICAL_MILE - float(entry["dst"])))
		compared += 1

	print("%d in feed, %d renderable, %d compared" % [raw.size(), parsed.size(), compared])
	print("max |gc bearing - api dir|  = %.3f deg  (limit 0.051: dir is rounded to 0.1)" % worst_bearing)
	print("max |gc dist    - api dst|  = %.3f nm   (limit 0.25: dst snapshot jitter)" % worst_dist_nm)
	print("max |ENU azimuth - api dir| = %.3f deg  (info: ellipsoid vs sphere)" % worst_az)

	var ok := compared > 0 and worst_bearing < 0.051 and worst_dist_nm < 0.25 and worst_az < 0.3
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)
