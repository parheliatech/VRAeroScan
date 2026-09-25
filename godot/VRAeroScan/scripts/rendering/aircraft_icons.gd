class_name AircraftIcons
extends RefCounted
## Aircraft silhouettes for the markers: outlines only, drawn for an additive display.
##
## Drawn for VRAeroScan (MIT) — deliberately NOT the ADS-B Exchange / tar1090 set, which
## is GPL. Each shape is the top-down planform, which is also what you see from below.
## Unit size: the silhouette fits in a 1×1 square centred on the origin, nose toward +Y,
## so SkyMarker can scale it like the square it replaces and rotate it to show which way
## the aircraft is moving across the sky.
##
## Kept to a few dozen segments each: at ~1.7° on the glasses fine detail only blurs, and
## the outline must frame the real aircraft's light, not cover it.
##
## Each shape is a list of loops. A loop given as a RIGHT half (x ≥ 0, nose to tail) is
## mirrored to close it; a loop marked FULL is used as is (engines are mirrored copies).

enum Icon { AIRLINER, HEAVY, BIZJET, TWIN_PROP, LIGHT, HELICOPTER, FIGHTER, GLIDER, BALLOON, GENERIC }

const HALF := 0
const FULL := 1
const PAIR := 2  # a full loop on the right side, repeated mirrored on the left

static var _meshes: Dictionary = {}


## Line mesh for an icon, built once.
static func mesh(icon: Icon) -> ArrayMesh:
	if not _meshes.has(icon):
		_meshes[icon] = _build(_shape(icon))
	return _meshes[icon]


## Which silhouette an aircraft gets: from the classifier's flags, refined by the ADS-B
## emitter category and the ICAO type designator where the flags cannot tell.
static func icon_for(ac: Aircraft) -> Icon:
	var c := ac.classification
	var t := ac.type_code.to_upper()
	var cat := ac.emitter_category.to_upper()
	if c & AircraftClassifier.ROTORCRAFT or cat == "A7":
		return Icon.HELICOPTER
	if c & AircraftClassifier.GLIDER or cat == "B1":
		return Icon.GLIDER
	if cat == "B2":
		return Icon.BALLOON
	if c & AircraftClassifier.JET:
		if _matches(t, FIGHTER_TYPES) or (c & AircraftClassifier.MILITARY and cat == "A6"):
			return Icon.FIGHTER
		if _matches(t, HEAVY_TYPES) or cat == "A5":
			return Icon.HEAVY
		if _matches(t, BIZJET_TYPES) or (c & AircraftClassifier.PRIVATE and cat in ["A1", "A2"]):
			return Icon.BIZJET
		return Icon.AIRLINER
	if c & (AircraftClassifier.TURBOPROP | AircraftClassifier.PISTON):
		return Icon.TWIN_PROP if _matches(t, TWIN_PROP_TYPES) else Icon.LIGHT
	# No type: the emitter category still says roughly how big it is.
	match cat:
		"A1":
			return Icon.LIGHT
		"A3", "A4":
			return Icon.AIRLINER
		"A5":
			return Icon.HEAVY
	return Icon.GENERIC


## Relative size. Wide-bodies are drawn bigger than narrow-bodies, as they are: at
## actual size on the glasses the extra engine pair alone was too subtle a difference.
static func scale_of(icon: Icon) -> float:
	return 1.25 if icon == Icon.HEAVY else 1.0


## Whether the icon shows direction. A balloon drifts; it has no nose to point.
static func is_directional(icon: Icon) -> bool:
	return icon != Icon.BALLOON


## Type designators by prefix. Not exhaustive — the emitter category covers the rest.
const HEAVY_TYPES := ["B74", "B77", "B78", "B76", "A33", "A34", "A35", "A38", "A30", "A31",
		"MD11", "DC10", "IL96", "K35", "KC10", "C17", "C5", "A400", "E3", "E6", "B52", "B1"]
const BIZJET_TYPES := ["GLF", "GLEX", "GL5", "GL6", "GL7", "C25", "C50", "C51", "C52", "C55",
		"C56", "C650", "C68", "C700", "C750", "CL30", "CL35", "CL60", "LJ", "FA", "F2TH", "F900",
		"E50P", "E55P", "E545", "E550", "PC24", "H25", "HDJT", "BE40", "PRM1", "SF50", "EA50"]
const FIGHTER_TYPES := ["F16", "F15", "F18", "F35", "F22", "F14", "F5", "A10", "AV8", "T38",
		"EUFI", "RFAL", "TOR", "MIR", "HAWK", "L39", "L159", "M346", "T6"]
const TWIN_PROP_TYPES := ["BE20", "BE30", "BE35", "BE9", "BE10", "B350", "BE55", "BE58", "BE60",
		"BE76", "PA23", "PA27", "PA30", "PA31", "PA34", "PA44", "PA60", "C303", "C310", "C320",
		"C335", "C340", "C402", "C404", "C414", "C421", "C425", "C441", "DA42", "DA62", "P68",
		"AT4", "AT7", "DH8", "SF34", "JS31", "JS32", "JS41", "E120", "B190", "D228", "C212",
		"CN35", "C295", "C130", "C30J", "P3", "DHC6", "SW4", "PC12X", "MU2", "AC90", "AC95"]


static func _matches(type_code: String, prefixes: Array) -> bool:
	for p: String in prefixes:
		if type_code.begins_with(p):
			return true
	return false


# --- The drawings ------------------------------------------------------------------
# Coordinates in the unit square: x right, y toward the nose.

static func _shape(icon: Icon) -> Array:
	match icon:
		Icon.AIRLINER:
			return [[HALF, [
				Vector2(0.0, 0.50), Vector2(0.03, 0.46), Vector2(0.045, 0.40), Vector2(0.045, 0.13),
				Vector2(0.47, -0.10), Vector2(0.47, -0.16), Vector2(0.045, -0.04),
				Vector2(0.045, -0.31), Vector2(0.18, -0.42), Vector2(0.18, -0.46),
				Vector2(0.03, -0.43), Vector2(0.0, -0.50)]],
				# Underwing engines.
				[PAIR, [Vector2(0.15, 0.10), Vector2(0.19, 0.10), Vector2(0.19, -0.01), Vector2(0.15, -0.01)]]]
		Icon.HEAVY:
			return [[HALF, [
				Vector2(0.0, 0.50), Vector2(0.04, 0.46), Vector2(0.06, 0.38), Vector2(0.06, 0.14),
				Vector2(0.50, -0.14), Vector2(0.50, -0.20), Vector2(0.06, -0.05),
				Vector2(0.06, -0.30), Vector2(0.21, -0.42), Vector2(0.21, -0.47),
				Vector2(0.04, -0.43), Vector2(0.0, -0.50)]],
				[PAIR, [Vector2(0.17, 0.09), Vector2(0.22, 0.09), Vector2(0.22, -0.03), Vector2(0.17, -0.03)]],
				[PAIR, [Vector2(0.31, 0.00), Vector2(0.36, 0.00), Vector2(0.36, -0.11), Vector2(0.31, -0.11)]]]
		Icon.BIZJET:
			return [[HALF, [
				Vector2(0.0, 0.50), Vector2(0.03, 0.44), Vector2(0.04, 0.34), Vector2(0.04, 0.06),
				Vector2(0.36, -0.10), Vector2(0.36, -0.14), Vector2(0.04, -0.06),
				Vector2(0.04, -0.36), Vector2(0.03, -0.40),
				# T-tail seen from above: the stabiliser at the very back.
				Vector2(0.16, -0.44), Vector2(0.16, -0.48), Vector2(0.0, -0.48)]],
				# Engines on the rear fuselage.
				[PAIR, [Vector2(0.06, -0.16), Vector2(0.11, -0.16), Vector2(0.11, -0.30), Vector2(0.06, -0.30)]]]
		Icon.TWIN_PROP:
			return [[HALF, [
				Vector2(0.0, 0.46), Vector2(0.035, 0.42), Vector2(0.045, 0.30), Vector2(0.045, 0.12),
				Vector2(0.48, 0.10), Vector2(0.48, 0.02), Vector2(0.045, 0.00),
				Vector2(0.04, -0.34), Vector2(0.17, -0.38), Vector2(0.17, -0.44), Vector2(0.0, -0.44)]],
				# Nacelles reaching ahead of the straight wing, a propeller line across each.
				[PAIR, [Vector2(0.15, 0.24), Vector2(0.21, 0.24), Vector2(0.21, -0.06), Vector2(0.15, -0.06)]],
				[PAIR, [Vector2(0.11, 0.27), Vector2(0.25, 0.27)]]]
		Icon.LIGHT:
			return [[HALF, [
				Vector2(0.0, 0.44), Vector2(0.05, 0.40), Vector2(0.05, 0.26),
				Vector2(0.45, 0.26), Vector2(0.45, 0.14), Vector2(0.05, 0.14),
				Vector2(0.03, -0.30), Vector2(0.15, -0.32), Vector2(0.15, -0.40), Vector2(0.0, -0.40)]],
				# The propeller.
				[FULL, [Vector2(-0.12, 0.47), Vector2(0.12, 0.47)]]]
		Icon.HELICOPTER:
			var pod: Array[Vector2] = []
			for i in 13:
				var a := PI / 2.0 - PI * i / 12.0
				pod.append(Vector2(0.11 * cos(a), 0.10 + 0.16 * sin(a)))
			pod.append(Vector2(0.025, -0.05))
			pod.append(Vector2(0.02, -0.42))
			pod.append(Vector2(0.0, -0.42))
			# Keep only the right side (x >= 0) of the pod, from the nose round to the tail.
			var right: Array[Vector2] = []
			for p in pod:
				if p.x >= -1e-6:
					right.append(p)
			return [[HALF, right],
				# Main rotor, an X across the pod; tail rotor across the end of the boom.
				[FULL, [Vector2(-0.35, 0.45), Vector2(0.35, -0.25)]],
				[FULL, [Vector2(0.35, 0.45), Vector2(-0.35, -0.25)]],
				[FULL, [Vector2(0.0, -0.36), Vector2(0.10, -0.36)]]]
		Icon.FIGHTER:
			return [[HALF, [
				Vector2(0.0, 0.50), Vector2(0.03, 0.36), Vector2(0.05, 0.18), Vector2(0.05, 0.10),
				Vector2(0.38, -0.16), Vector2(0.38, -0.22), Vector2(0.06, -0.18),
				Vector2(0.06, -0.30), Vector2(0.20, -0.42), Vector2(0.20, -0.46),
				Vector2(0.05, -0.44), Vector2(0.04, -0.50), Vector2(0.0, -0.50)]]]
		Icon.GLIDER:
			return [[HALF, [
				Vector2(0.0, 0.40), Vector2(0.03, 0.34), Vector2(0.03, 0.14),
				Vector2(0.50, 0.12), Vector2(0.50, 0.08), Vector2(0.03, 0.06),
				Vector2(0.015, -0.38), Vector2(0.13, -0.40), Vector2(0.13, -0.44), Vector2(0.0, -0.44)]]]
		Icon.BALLOON:
			var envelope: Array[Vector2] = []
			for i in 13:
				var a := PI / 2.0 - PI * i / 12.0
				envelope.append(Vector2(0.32 * cos(a), 0.12 + 0.34 * sin(a)))
			envelope.append(Vector2(0.06, -0.30))
			envelope.append(Vector2(0.0, -0.30))
			var right: Array[Vector2] = []
			for p in envelope:
				if p.x >= -1e-6:
					right.append(p)
			return [[HALF, right],
				[FULL, [Vector2(-0.06, -0.36), Vector2(0.06, -0.36), Vector2(0.06, -0.46), Vector2(-0.06, -0.46), Vector2(-0.06, -0.36)]]]
	# GENERIC: a plain, straight-winged aeroplane.
	return [[HALF, [
		Vector2(0.0, 0.46), Vector2(0.04, 0.40), Vector2(0.04, 0.16),
		Vector2(0.44, 0.08), Vector2(0.44, 0.00), Vector2(0.04, 0.00),
		Vector2(0.035, -0.34), Vector2(0.16, -0.38), Vector2(0.16, -0.44), Vector2(0.0, -0.44)]]]


static func _build(loops: Array) -> ArrayMesh:
	var pairs := PackedVector3Array()
	for loop: Array in loops:
		var kind: int = loop[0]
		var points: Array = loop[1]
		match kind:
			HALF:
				# Right half from nose to tail, then the mirror image back up to the nose.
				var outline: Array = points.duplicate()
				for i in range(points.size() - 2, 0, -1):
					var p: Vector2 = points[i]
					outline.append(Vector2(-p.x, p.y))
				_add_loop(pairs, outline, true)
			FULL:
				_add_loop(pairs, points, points.size() > 2)
			PAIR:
				_add_loop(pairs, points, points.size() > 2)
				var mirrored: Array = []
				for p: Vector2 in points:
					mirrored.append(Vector2(-p.x, p.y))
				_add_loop(pairs, mirrored, points.size() > 2)
	return ArVisuals.line_mesh(pairs)


static func _add_loop(pairs: PackedVector3Array, points: Array, closed: bool) -> void:
	var n := points.size()
	var count := n if closed else n - 1
	for i in count:
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i + 1) % n]
		pairs.append(Vector3(a.x, a.y, 0.0))
		pairs.append(Vector3(b.x, b.y, 0.0))
