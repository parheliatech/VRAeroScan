extends SceneTree
## Live check of the satellite pipeline against an independent tracker. Needs network.
##
##   godot --headless --path godot/VRAeroScan --script res://tests/live_satellite_check.gd
##
## Fetches the ISS's current elements from CelesTrak (the app's real parser and SGP4)
## and its current position from wheretheiss.at, and compares the ground track point.
## The fixtures prove the arithmetic; this catches what they cannot — the live feed's
## format drifting, epoch or time-scale handling, and a wrong system clock. It is the
## GDScript twin of validate_sgp4.py's live check.
##
## Not open-notify.org: it serves positions ~13 minutes stale (see validate_sgp4.py).

const CELESTRAK := "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=json"
const WHERETHEISS := "https://api.wheretheiss.at/v1/satellites/25544"


func _initialize() -> void:
	var http := HTTPRequest.new()
	root.add_child(http)
	await process_frame

	var omm: Variant = await _get_json(http, CELESTRAK)
	var live: Variant = await _get_json(http, WHERETHEISS)
	if typeof(omm) != TYPE_ARRAY or (omm as Array).is_empty() or typeof(live) != TYPE_DICTIONARY:
		printerr("could not fetch both sources")
		quit(2)
		return

	var sat := Satellite.from_omm(omm[0])
	var unix: float = live["timestamp"]
	var jd := Sgp4.unix_to_jd(unix)
	sat.sample(unix, Sgp4.gstime(jd), Solar.sun_direction_teme(jd))
	var sub := GeoMath.ecef_to_geodetic(sat.ecef[0], sat.ecef[1], sat.ecef[2])
	var theirs := GeoPoint.new(live["latitude"], live["longitude"], 0.0)
	var ground_km := GeoMath.great_circle(GeoPoint.new(sub.latitude_deg, sub.longitude_deg, 0.0), theirs)[0] / 1000.0

	var epoch_age_h := (unix - sat.sgp4.epoch_unix) / 3600.0
	var clock_skew := Time.get_unix_time_from_system() - unix
	print("elements %.1f h old; wheretheiss.at timestamp is %.1f s behind this clock" % [epoch_age_h, clock_skew])
	print("ours          %8.3f, %9.3f  alt %.1f km  %s" % [sub.latitude_deg, sub.longitude_deg,
			sub.altitude_m / 1000.0, "sunlit" if sat.sunlit else "in shadow"])
	print("wheretheiss   %8.3f, %9.3f  alt %.1f km  %s" % [theirs.latitude_deg, theirs.longitude_deg,
			float(live["altitude"]), live.get("visibility", "?")])
	print("ground distance %.1f km  (limit 20: both sides propagate their own elements)" % ground_km)
	print("altitude difference %.1f km" % absf(sub.altitude_m / 1000.0 - float(live["altitude"])))

	# wheretheiss.at says "eclipsed" or "daylight"/"visible"; ours must agree.
	var shadow_agrees: bool = sat.sunlit == (live.get("visibility", "") != "eclipsed")
	print("shadow state agrees: %s" % shadow_agrees)

	var ok := ground_km < 20.0 and shadow_agrees
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _get_json(http: HTTPRequest, url: String) -> Variant:
	http.request(url, ["User-Agent: VRAeroScan/0.1"])
	var response: Array = await http.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		printerr("%s: result %d, HTTP %d" % [url, response[0], response[1]])
		return null
	return JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
