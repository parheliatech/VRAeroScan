class_name Aircraft
extends RefCounted
## One aircraft as adsb.lol reports it, plus what VRAeroScan needs on top.
##
## `alt_baro` is mixed-type — a number when airborne, the string "ground" when not.
## Godot's JSON parser hands back a Variant either way, so it is checked with typeof()
## below rather than assumed.

## ICAO 24-bit address. The stable identity across updates.
var icao24 := ""
var callsign := ""
var registration := ""
## ICAO type designator, e.g. "A321", "C206". Empty when unknown.
var type_code := ""
## ADS-B emitter category, e.g. "A1".."A7". Empty when unknown.
var emitter_category := ""

var latitude_deg := 0.0
var longitude_deg := 0.0
## Barometric altitude in feet. Zero when on_ground.
var altitude_ft := 0.0
var on_ground := false
var ground_speed_kt := 0.0
## Direction of travel, degrees true.
var track_deg := 0.0
## Seconds since this position was actually observed, per the feed.
var position_age_s := 0.0

## AircraftClassifier flags.
var classification := 0

## Engine clock (seconds) when this update was received, for dead reckoning.
var received_at := 0.0


func position() -> GeoPoint:
	return GeoPoint.new(latitude_deg, longitude_deg, altitude_ft * GeoMath.FEET_TO_METERS)


## Where the aircraft probably is at time `now`, given where it was and how it moved.
##
## The feed arrives every few seconds; the display runs at frame rate. Without this,
## markers teleport. Straight constant-velocity extrapolation — no turn or climb rate —
## which is honest for a few seconds and increasingly wrong past that, hence the cap.
##
## The position was already position_age_s old when the feed sent it (adsb.lol's
## seen_pos: 16% of aircraft near the test site were over 5 s, up to 58 s, on 2026-10-04). At
## 450 kt that is 230 m a second, so the age is extrapolated too.
func position_at(now: float, max_extrapolation_s: float = 30.0) -> GeoPoint:
	if on_ground or ground_speed_kt <= 0.0:
		return position()

	var dt := minf(now - received_at + position_age_s, max_extrapolation_s)
	if dt <= 0.0:
		return position()

	var meters_per_second := ground_speed_kt * GeoMath.METERS_PER_NAUTICAL_MILE / 3600.0
	return GeoMath.destination_point(position(), track_deg, meters_per_second * dt)


## Parse one element of the feed's "ac" array. Returns null for entries with no usable
## position, which the feed does emit.
static func from_json(o: Dictionary, now: float) -> Aircraft:
	if not (o.has("lat") and o.has("lon")):
		return null

	var ac := Aircraft.new()
	ac.icao24 = _str(o.get("hex"))
	if ac.icao24.is_empty():
		return null

	ac.callsign = _str(o.get("flight")).strip_edges()
	ac.registration = _str(o.get("r"))
	ac.type_code = _str(o.get("t"))
	ac.emitter_category = _str(o.get("category"))
	ac.latitude_deg = _num(o.get("lat"))
	ac.longitude_deg = _num(o.get("lon"))
	ac.ground_speed_kt = _num(o.get("gs"))
	ac.position_age_s = _num(o.get("seen_pos"))
	ac.received_at = now

	# "track" is absent for aircraft on the ground, which report "true_heading".
	ac.track_deg = _num(o.get("track")) if o.has("track") else _num(o.get("true_heading"))

	# The mixed-type field.
	var alt: Variant = o.get("alt_baro")
	if typeof(alt) == TYPE_STRING:
		ac.on_ground = (alt as String).to_lower() == "ground"
	elif typeof(alt) == TYPE_FLOAT or typeof(alt) == TYPE_INT:
		ac.altitude_ft = float(alt)

	ac.classification = AircraftClassifier.classify(ac)
	return ac


func display_name() -> String:
	if not callsign.is_empty():
		return callsign
	if not registration.is_empty():
		return registration
	return icao24


func _to_string() -> String:
	return "%s [%s] %.0fft %s" % [display_name(), type_code if type_code else "?",
		altitude_ft, AircraftClassifier.describe(classification)]


static func _str(v: Variant) -> String:
	return v if typeof(v) == TYPE_STRING else ""


static func _num(v: Variant) -> float:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v)
		TYPE_STRING:
			return (v as String).to_float()
	return 0.0
