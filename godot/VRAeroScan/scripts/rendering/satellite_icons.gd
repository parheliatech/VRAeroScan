class_name SatelliteIcons
extends RefCounted
## Satellite silhouettes, in the style of AircraftIcons: outlines only, for an additive
## display, drawn for VRAeroScan (MIT). Unit size, centred on the origin, "up" toward +Y.
##
## Shape says what the object physically is — a station, a Starlink, a spent rocket stage
## — and colour stays with the orbit category (SkyMarker.color_for_satellite), as colour
## says operator and shape says kind for aircraft.
##
## Kept simple: far-side satellites are drawn as small as a third of a tracked marker, and
## a silhouette must still read as a shape at ~25 px.

enum Icon { ISS, STATION, CAPSULE, HUBBLE, STARLINK, COMMS, NAVIGATION, EARTH_OBS,
		ROCKET_BODY, DEBRIS, CUBESAT, GENERIC }

static var _meshes: Dictionary = {}


## Which silhouette a satellite gets. In order: what its name says it is (stations,
## visiting craft, Hubble, Starlink, spent stages, debris), then the CelesTrak purpose
## groups it is listed in, then name patterns, then its orbit (a geostationary satellite
## with nothing else known is almost always a comsat).
static func icon_for(object_name: String, category: int, groups: PackedStringArray) -> Icon:
	var n := object_name.to_upper()
	# Debris and spent stages share names with what they came from ("ISS DEB", "CZ-2F R/B").
	if n.contains(" DEB") or n.begins_with("DEB"):
		return Icon.DEBRIS
	if n.contains("R/B"):
		return Icon.ROCKET_BODY
	# "ISS OBJECT YN": small satellites (mostly CubeSats) released from the station.
	if n.begins_with("ISS OBJECT"):
		return Icon.CUBESAT
	if n.begins_with("ISS") or n.begins_with("POISK"):
		return Icon.ISS
	if n.begins_with("CSS") or n.begins_with("TIANGONG") or n.begins_with("TIANHE"):
		return Icon.STATION
	if _starts(n, CAPSULE_NAMES):
		return Icon.CAPSULE
	if n == "HST" or n.begins_with("HST "):
		return Icon.HUBBLE
	if n.begins_with("STARLINK"):
		return Icon.STARLINK

	if "gnss" in groups:
		# The gnss group also lists comsats carrying a WAAS/EGNOS augmentation payload
		# (Astra, Eutelsat, Galaxy): in geostationary orbit, only BeiDou, QZSS and NavIC
		# are navigation satellites proper.
		if category != Satellite.GEO or _starts(n, ["BEIDOU", "QZS", "IRNSS", "NVS"]):
			return Icon.NAVIGATION
		return Icon.COMMS
	for g in ["weather", "resource", "planet"]:
		if g in groups:
			return Icon.EARTH_OBS
	for g in ["iridium-NEXT", "oneweb", "globalstar", "orbcomm", "intelsat", "ses", "geo"]:
		if g in groups:
			return Icon.COMMS
	for g in ["cubesat", "spire"]:
		if g in groups:
			return Icon.CUBESAT

	if _starts(n, CUBESAT_NAMES):
		return Icon.CUBESAT
	if _starts(n, NAVIGATION_NAMES):
		return Icon.NAVIGATION
	if _starts(n, EARTH_OBS_NAMES):
		return Icon.EARTH_OBS
	if _starts(n, COMMS_NAMES) or category == Satellite.GEO:
		return Icon.COMMS
	return Icon.GENERIC


## Military: CelesTrak's small "military" group, plus names. Most US military satellites
## are not in the public catalogue at all; Chinese Yaogan/TJS and Russian Cosmos are, and
## Cosmos is only military when it is not GLONASS (those are in the gnss group).
static func is_military(object_name: String, groups: PackedStringArray) -> bool:
	if "military" in groups:
		return true
	var n := object_name.to_upper()
	if n.begins_with("COSMOS"):
		return not "gnss" in groups
	return _starts(n, MILITARY_NAMES)


const CAPSULE_NAMES := ["CREW DRAGON", "DRAGON", "SOYUZ", "PROGRESS", "SHENZHOU", "TIANZHOU",
		"CYGNUS", "STARLINER", "HTV", "ORION"]
const NAVIGATION_NAMES := ["NAVSTAR", "GPS", "GALILEO", "GSAT0", "BEIDOU", "GLONASS", "QZS",
		"IRNSS", "NVS", "CENTISPACE"]
const CUBESAT_NAMES := ["LEMUR", "CUBESAT"]
const EARTH_OBS_NAMES := ["NOAA", "GOES", "METEOSAT", "METOP", "HIMAWARI", "FENGYUN", "FY-",
		"SENTINEL", "LANDSAT", "WORLDVIEW", "TERRA", "AQUA", "FLOCK", "SKYSAT", "JILIN", "GAOFEN",
		"SUOMI", "JPSS", "DMSP", "CARTOSAT", "RESURS", "KANOPUS", "PLEIADES", "SPOT", "RADARSAT",
		"ICEYE", "CAPELLA", "UMBRA",
		# Added from the active catalogue's largest unclassified families, 2026-09-24.
		"YAOGAN", "NUSAT", "SUPERVIEW", "GRUS", "IRIDE", "YUNHAI", "TIANHUI", "PIESAT", "HAWK",
		"TOMORROW", "GAOJING", "BLACKSKY", "PELICAN", "QPS", "STRIX", "GHGSAT", "YUNYAO",
		"HAIYANG", "FORMOSAT", "WILDFIRE"]
const COMMS_NAMES := ["ONEWEB", "IRIDIUM", "GLOBALSTAR", "ORBCOMM", "INTELSAT", "SES", "EUTELSAT",
		"ASTRA", "VIASAT", "ECHOSTAR", "DIRECTV", "SIRIUS", "XM-", "GALAXY", "TDRS", "KUIPER",
		"QIANFAN", "GUOWANG", "O3B", "AMC", "TELSTAR", "THURAYA", "INMARSAT", "ARABSAT", "TURKSAT",
		"CHINASAT", "APSTAR", "JCSAT", "SKYNET", "WGS", "MUOS", "AEHF", "MILSTAR", "TJS",
		# Added from the active catalogue's largest unclassified families, 2026-09-24.
		"HULIANWANG", "RASSVET", "GONETS", "TIANQI", "KINEIS", "GEESAT", "SPACEMOBILE", "BLUEBIRD",
		"CONNECTA", "SITRO", "LYNK", "SWARM", "ASTROCAST", "APRIZESAT", "SAUDICOMSAT"]
const MILITARY_NAMES := ["USA ", "USA-", "NROL", "YAOGAN", "TJS", "SBIRS", "WGS", "MUOS", "AEHF",
		"MILSTAR", "SKYNET", "SICRAL", "SYRACUSE", "OFEQ", "LACROSSE", "NOSS", "GSSAP", "DSP"]


static func _starts(n: String, prefixes: Array) -> bool:
	for p: String in prefixes:
		if n.begins_with(p):
			return true
	return false


static func mesh(icon: Icon) -> ArrayMesh:
	if not _meshes.has(icon):
		var pairs := PackedVector3Array()
		_draw(icon, pairs)
		_meshes[icon] = ArVisuals.line_mesh(pairs)
	return _meshes[icon]


# --- The drawings ------------------------------------------------------------------

static func _draw(icon: Icon, p: PackedVector3Array) -> void:
	match icon:
		Icon.ISS:
			# The integrated truss, end to end, with four solar wing pairs on it.
			_rect(p, 0.0, 0.0, 0.96, 0.05)
			for x in [-0.40, -0.26, 0.26, 0.40]:
				_panel(p, x, 0.17, 0.11, 0.30, 3)
				_panel(p, x, -0.17, 0.11, 0.30, 3)
			# The pressurised modules along the middle, crossing the truss.
			_rect(p, 0.0, 0.16, 0.07, 0.22)
			_rect(p, 0.0, -0.20, 0.07, 0.30)
			_rect(p, 0.0, 0.34, 0.16, 0.05)  # node with the labs either side
			# Radiators, angled off the truss.
			_line(p, -0.12, 0.03, -0.17, 0.12)
			_line(p, 0.12, 0.03, 0.17, 0.12)
		Icon.STATION:
			# Tiangong's T: core module, two lab modules across, big wings on their ends.
			_rect(p, 0.0, -0.08, 0.10, 0.44)
			_rect(p, 0.0, 0.16, 0.56, 0.08)
			_panel(p, -0.38, 0.16, 0.10, 0.44, 3)
			_panel(p, 0.38, 0.16, 0.10, 0.44, 3)
			_panel(p, -0.16, -0.20, 0.20, 0.07, 2)
			_panel(p, 0.16, -0.20, 0.20, 0.07, 2)
		Icon.CAPSULE:
			# Capsule (cone), service module, and a pair of small wings.
			_poly(p, [Vector2(-0.07, 0.40), Vector2(0.07, 0.40), Vector2(0.14, 0.18),
					Vector2(-0.14, 0.18)], true)
			_rect(p, 0.0, 0.0, 0.26, 0.34)
			_panel(p, -0.30, 0.0, 0.30, 0.10, 3)
			_panel(p, 0.30, 0.0, 0.30, 0.10, 3)
			_line(p, 0.0, -0.17, 0.0, -0.30)
			_poly(p, [Vector2(-0.07, -0.30), Vector2(0.07, -0.30), Vector2(0.05, -0.40),
					Vector2(-0.05, -0.40)], true)
		Icon.HUBBLE:
			# The tube, aperture door open at the top, wings on either side.
			_rect(p, 0.0, -0.02, 0.18, 0.72)
			_line(p, -0.09, 0.34, 0.12, 0.48)  # the door, hinged open
			_line(p, -0.09, 0.20, 0.09, 0.20)  # light shield / aft shroud join
			_panel(p, -0.30, -0.02, 0.16, 0.50, 4)
			_panel(p, 0.30, -0.02, 0.16, 0.50, 4)
			_line(p, -0.09, -0.02, -0.22, -0.02)
			_line(p, 0.09, -0.02, 0.22, -0.02)
		Icon.STARLINK:
			# A flat body with ONE long solar array off its end: the lopsided "flag" that
			# makes a Starlink recognisable.
			_rect(p, -0.33, 0.0, 0.28, 0.14)
			_line(p, -0.19, 0.0, -0.14, 0.0)
			_panel(p, 0.17, 0.0, 0.62, 0.20, 6)
		Icon.COMMS:
			# A comsat: box, two long wings, reflector dishes on the body.
			_rect(p, 0.0, 0.0, 0.18, 0.18)
			_panel(p, -0.30, 0.0, 0.36, 0.13, 3)
			_panel(p, 0.30, 0.0, 0.36, 0.13, 3)
			_circle(p, -0.02, 0.21, 0.10, 12)
			_circle(p, 0.02, -0.21, 0.10, 12)
			_line(p, -0.02, 0.09, -0.02, 0.11)
			_line(p, 0.02, -0.09, 0.02, -0.11)
		Icon.NAVIGATION:
			# Box and two wings, with the earth-facing antenna array beneath.
			_rect(p, 0.0, 0.04, 0.18, 0.20)
			_panel(p, -0.29, 0.04, 0.34, 0.16, 2)
			_panel(p, 0.29, 0.04, 0.34, 0.16, 2)
			for x in [-0.06, 0.0, 0.06]:
				_line(p, x, -0.06, x * 1.8, -0.24)
			_line(p, -0.13, -0.24, 0.13, -0.24)
		Icon.EARTH_OBS:
			# A body with a lens looking down at the Earth, and a single wing.
			_rect(p, -0.10, 0.0, 0.26, 0.30)
			_circle(p, -0.10, 0.0, 0.07, 12)
			_line(p, 0.03, 0.0, 0.09, 0.0)
			_panel(p, 0.27, 0.0, 0.36, 0.20, 3)
		Icon.ROCKET_BODY:
			# A spent upper stage: nose, cylinder, engine bell.
			_poly(p, [Vector2(0.0, 0.46), Vector2(0.09, 0.32), Vector2(0.09, -0.20),
					Vector2(-0.09, -0.20), Vector2(-0.09, 0.32)], true)
			_line(p, -0.09, 0.08, 0.09, 0.08)
			_poly(p, [Vector2(-0.04, -0.20), Vector2(0.04, -0.20), Vector2(0.11, -0.40),
					Vector2(-0.11, -0.40)], true)
		Icon.DEBRIS:
			# A torn fragment: irregular, no symmetry, no "up".
			_poly(p, [Vector2(-0.20, 0.10), Vector2(-0.05, 0.24), Vector2(0.04, 0.12),
					Vector2(0.20, 0.18), Vector2(0.14, -0.02), Vector2(0.22, -0.16),
					Vector2(0.02, -0.12), Vector2(-0.10, -0.24), Vector2(-0.12, -0.04)], true)
		Icon.CUBESAT:
			# A small cube with four panels folded out in a cross.
			_rect(p, 0.0, 0.0, 0.16, 0.16)
			_line(p, -0.08, 0.08, 0.08, -0.08)
			_panel(p, 0.0, 0.22, 0.14, 0.26, 2)
			_panel(p, 0.0, -0.22, 0.14, 0.26, 2)
			_panel(p, -0.22, 0.0, 0.26, 0.14, 2)
			_panel(p, 0.22, 0.0, 0.26, 0.14, 2)
		_:
			# Generic: a box with two wings.
			_rect(p, 0.0, 0.0, 0.20, 0.24)
			_panel(p, -0.30, 0.0, 0.36, 0.16, 3)
			_panel(p, 0.30, 0.0, 0.36, 0.16, 3)


## A solar panel: an outline divided into `cells` along its long side, with the stub
## that joins it to the body implied by the caller's layout.
static func _panel(p: PackedVector3Array, cx: float, cy: float, w: float, h: float, cells: int) -> void:
	_rect(p, cx, cy, w, h)
	for i in range(1, cells):
		var f := float(i) / cells
		if w >= h:
			var x := cx - w / 2.0 + w * f
			_line(p, x, cy - h / 2.0, x, cy + h / 2.0)
		else:
			var y := cy - h / 2.0 + h * f
			_line(p, cx - w / 2.0, y, cx + w / 2.0, y)


static func _rect(p: PackedVector3Array, cx: float, cy: float, w: float, h: float) -> void:
	_poly(p, [Vector2(cx - w / 2.0, cy - h / 2.0), Vector2(cx + w / 2.0, cy - h / 2.0),
			Vector2(cx + w / 2.0, cy + h / 2.0), Vector2(cx - w / 2.0, cy + h / 2.0)], true)


static func _circle(p: PackedVector3Array, cx: float, cy: float, r: float, segments: int) -> void:
	var pts: Array = []
	for i in segments:
		var a := TAU * i / segments
		pts.append(Vector2(cx + r * cos(a), cy + r * sin(a)))
	_poly(p, pts, true)


static func _line(p: PackedVector3Array, x0: float, y0: float, x1: float, y1: float) -> void:
	p.append(Vector3(x0, y0, 0.0))
	p.append(Vector3(x1, y1, 0.0))


static func _poly(p: PackedVector3Array, pts: Array, closed: bool) -> void:
	var n := pts.size()
	for i in (n if closed else n - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		p.append(Vector3(a.x, a.y, 0.0))
		p.append(Vector3(b.x, b.y, 0.0))
