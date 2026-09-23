class_name AdsbService
extends Node
## Polls adsb.lol for aircraft near the observer.
##
## Endpoint: GET https://api.adsb.lol/v2/point/{lat}/{lon}/{radius_nm}
## Free, no API key, data licensed ODbL 1.0.
##
## Be a good citizen of a free service: poll on an interval, back off on errors.
## Smoothness between polls is the renderer's job via Aircraft.position_at(), not
## something to buy with a higher request rate.

signal aircraft_updated(aircraft: Dictionary)
signal poll_failed(message: String)

const ENDPOINT := "https://api.adsb.lol/v2/point/%.5f/%.5f/%d"

## Search radius in nautical miles. The API caps this at 250.
@export_range(1, 250) var radius_nm := 100
## Seconds between polls. Below ~2s is impolite and buys nothing: dead reckoning
## covers the gap.
@export_range(1.0, 30.0) var poll_interval_s := 3.0
## Drop an aircraft this many seconds after it stops being reported.
@export var stale_after_s := 30.0

## icao24 -> Aircraft. Entries are REPLACED on each poll, never mutated, so a changed
## reference means new data — AppBootstrap relies on that to skip label rebuilds.
var aircraft: Dictionary = {}
var last_successful_poll := -INF
var consecutive_failures := 0

var _last_seen: Dictionary = {}
var _observer_provider: Callable
var _http: HTTPRequest
var _polling := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 20.0
	add_child(_http)


## Poll around whatever observer_provider returns. A callable rather than a fixed point
## so the query follows the user if the phone's position moves.
func start_polling(observer_provider: Callable) -> void:
	_observer_provider = observer_provider
	if not _polling:
		_polling = true
		_poll_loop()


func stop_polling() -> void:
	_polling = false


func _poll_loop() -> void:
	while _polling and is_inside_tree():
		await _poll_once()
		_prune_stale()

		# Back off when the service is unhappy, rather than hammering it.
		var wait := poll_interval_s
		if consecutive_failures > 0:
			wait *= pow(2.0, mini(consecutive_failures, 4))
		await get_tree().create_timer(wait).timeout


func _poll_once() -> void:
	var observer: GeoPoint = _observer_provider.call()
	var url := ENDPOINT % [observer.latitude_deg, observer.longitude_deg, radius_nm]

	var err := _http.request(url, ["User-Agent: VRAeroScan/0.1"])
	if err != OK:
		_fail("adsb.lol request could not start: %s" % error_string(err))
		return

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var code: int = response[1]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail("adsb.lol request failed: result %d, HTTP %d" % [result, code])
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		# A malformed response should not take the app down; the next poll is seconds away.
		_fail("adsb.lol response could not be parsed")
		return

	_merge(parse(parsed, _now()))
	consecutive_failures = 0
	last_successful_poll = _now()
	aircraft_updated.emit(aircraft)


## Parse a whole response. Ground vehicles and fixed obstructions are dropped here
## rather than at render time, so nothing downstream has to remember to.
static func parse(root: Dictionary, now: float) -> Array[Aircraft]:
	var results: Array[Aircraft] = []
	var list: Variant = root.get("ac")
	if typeof(list) != TYPE_ARRAY:
		return results

	for entry: Variant in list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var ac := Aircraft.from_json(entry, now)
		if ac != null and AircraftClassifier.is_renderable(ac.classification):
			results.append(ac)
	return results


func _merge(incoming: Array[Aircraft]) -> void:
	var now := _now()
	for ac in incoming:
		aircraft[ac.icao24] = ac
		_last_seen[ac.icao24] = now


## Forget aircraft that stopped being reported, which happens constantly as they leave
## the radius. Without this the sky fills with ghosts frozen where they were last seen.
func _prune_stale() -> void:
	var cutoff := _now() - stale_after_s
	for key: String in _last_seen.keys():
		if _last_seen[key] < cutoff:
			_last_seen.erase(key)
			aircraft.erase(key)


func _fail(message: String) -> void:
	consecutive_failures += 1
	poll_failed.emit(message)
	if consecutive_failures >= 5:
		push_warning("[AdsbService] %s (%d consecutive failures)" % [message, consecutive_failures])


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
