class_name CelestrakService
extends Node
## Fetches satellite orbital elements from CelesTrak and caches them on disk.
##
## Endpoint: GET https://celestrak.org/NORAD/elements/gp.php?GROUP={group}&FORMAT=json
## Free, no key. Returns OMM records — mean elements for SGP4, not positions.
##
## Elements change slowly and CelesTrak updates them roughly every two hours; it blocks
## clients that download the same data more often. So: each group is cached under
## user://celestrak/, the cache is used immediately on start (the app works offline),
## and a group is refetched only when its cache is older than refresh_hours.
##
## Stale elements degrade gracefully — a LEO position drifts a few km per day — but they
## do degrade, and Starlink manoeuvres constantly, so the HUD shows element age.

signal catalogue_updated(satellites: Array[Satellite])
signal fetch_failed(message: String)

const ENDPOINT := "https://celestrak.org/NORAD/elements/gp.php?GROUP=%s&FORMAT=json"
const CACHE_DIR := "user://celestrak"

## CelesTrak groups to load. "stations" (ISS, CSS and visitors) and "visual" (~150
## naked-eye objects) are small and the most useful. "starlink" is ~11,000 objects,
## "geo" ~600 — both far more than fit in a 46° view, so opt-in.
@export var groups := PackedStringArray(["stations", "visual"])
## Hours before a cached group is refetched. CelesTrak asks for no more than every two.
@export_range(2.0, 72.0) var refresh_hours := 4.0

## norad_id -> Satellite, all groups merged.
var satellites: Dictionary = {}
## Unix time of the median element epoch. Median, not oldest: a catalogue always holds
## a few objects with days-old elements (decaying, or just not re-observed), and one of
## those should not make the whole catalogue look stale.
var median_epoch_unix := INF
## Unix time each group's data was fetched (the cache file's time), by group name.
var fetched_unix: Dictionary = {}

var _http: HTTPRequest
var _raw: Dictionary = {}  # group -> Array of OMM records


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	# Starlink's JSON is ~5 MB; the default body limit would cut it off.
	_http.body_size_limit = -1
	add_child(_http)


## Load caches now, then refresh stale groups in the background.
func start() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	for group in groups:
		var records := _load_cache(group)
		if not records.is_empty():
			_raw[group] = records
	_rebuild()
	_refresh_stale()


func _refresh_stale() -> void:
	while is_inside_tree():
		var changed := false
		for group in groups:
			var age_h: float = (Time.get_unix_time_from_system() - fetched_unix.get(group, 0.0)) / 3600.0
			if age_h < refresh_hours:
				continue
			var records: Array = await _fetch(group)
			if not records.is_empty():
				_raw[group] = records
				changed = true
		if changed:
			_rebuild()

		# Check again later; the app may run for hours.
		await get_tree().create_timer(refresh_hours * 3600.0 / 4.0).timeout


func _fetch(group: String) -> Array:
	var err := _http.request(ENDPOINT % group.uri_encode(), ["User-Agent: VRAeroScan/0.1"])
	if err != OK:
		_fail("CelesTrak request could not start: %s" % error_string(err))
		return []

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var code: int = response[1]
	var body: PackedByteArray = response[3]
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# 403 is CelesTrak saying "too often" — the cache carries on.
		_fail("CelesTrak %s: result %d, HTTP %d" % [group, result, code])
		return []

	var text := body.get_string_from_utf8()
	var records := parse(text)
	if records.is_empty():
		# Unknown groups and throttling both come back as a line of plain text.
		_fail("CelesTrak %s: %s" % [group, text.left(80).strip_edges()])
		return []

	var file := FileAccess.open(_cache_path(group), FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	fetched_unix[group] = Time.get_unix_time_from_system()
	print("VRAEROSCAN CelesTrak %s: %d objects" % [group, records.size()])
	return records


## OMM JSON text -> records. Empty for anything that is not a JSON array.
static func parse(text: String) -> Array:
	var parsed: Variant = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_ARRAY else []


## Merge record lists into Satellites, one per catalogue number: the ISS is in both
## "stations" and "visual".
static func build_catalogue(record_lists: Array) -> Dictionary:
	var out := {}
	for records: Array in record_lists:
		for o: Variant in records:
			if typeof(o) != TYPE_DICTIONARY:
				continue
			var sat := Satellite.from_omm(o)
			if sat != null and not out.has(sat.norad_id):
				out[sat.norad_id] = sat
	return out


func _rebuild() -> void:
	satellites = build_catalogue(_raw.values())
	var epochs := PackedFloat64Array()
	for sat: Satellite in satellites.values():
		epochs.append(sat.sgp4.epoch_unix)
	epochs.sort()
	median_epoch_unix = epochs[epochs.size() / 2] if not epochs.is_empty() else INF
	var list: Array[Satellite] = []
	list.assign(satellites.values())
	catalogue_updated.emit(list)


func _load_cache(group: String) -> Array:
	var path := _cache_path(group)
	if not FileAccess.file_exists(path):
		return []
	fetched_unix[group] = float(FileAccess.get_modified_time(path))
	return parse(FileAccess.get_file_as_string(path))


func _cache_path(group: String) -> String:
	return "%s/%s.json" % [CACHE_DIR, group.validate_filename()]


func _fail(message: String) -> void:
	fetch_failed.emit(message)
	push_warning("[CelestrakService] " + message)
