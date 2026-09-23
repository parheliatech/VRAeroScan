class_name AircraftClassifier
extends RefCounted
## Best-effort classification from what ADS-B actually carries.
##
## Flags rather than one value, because there are two orthogonal axes: who operates it
## (commercial / private / military) and what it is (jet / piston / turboprop /
## rotorcraft). An A321 is COMMERCIAL|JET; a C206 is PRIVATE|PISTON.
##
## ADS-B has no "military" flag, no operator field and no engine type. Everything here
## is inference from the emitter category and the ICAO type designator. The category
## is reliable (the aircraft transmits it); the type tables are hand-maintained and
## will have gaps. Military detection in particular is a heuristic — a warbird at an
## airshow squawks the same type code as the real thing. Do not present it as
## authoritative. The honest fix is an aircraft metadata database keyed by ICAO hex,
## which is a data project, deliberately deferred.
##
## Mirrors tools/validation/validate_classifier.py, which was checked against 892 live
## aircraft. Keep the two in step.

const UNKNOWN := 0
const COMMERCIAL := 1 << 0
const PRIVATE := 1 << 1
const MILITARY := 1 << 2
const JET := 1 << 3
const PISTON := 1 << 4
const TURBOPROP := 1 << 5
const ROTORCRAFT := 1 << 6
const GLIDER := 1 << 7
const DRONE := 1 << 8
## Positively identified as NOT an aircraft: a ground vehicle or fixed obstruction.
## Distinct from UNKNOWN (an aircraft we could not classify, still worth showing).
## The renderer must drop these entirely.
const NOT_AN_AIRCRAFT := 1 << 9


static func classify(ac: Aircraft) -> int:
	if ac == null:
		return UNKNOWN

	var result := UNKNOWN
	var type := ac.type_code.to_upper()
	var category := ac.emitter_category

	# Categories C0-C7 are surface vehicles and obstacles - pushback tugs, fire trucks,
	# tower obstructions. ~3% of a live sample over Los Angeles.
	if category.begins_with("C"):
		return NOT_AN_AIRCRAFT

	# Some fixed obstructions transmit with no category at all and are caught only by
	# type. 892 aircraft across four metros turned up seven "TWR" radio towers, which
	# would otherwise hang motionless in the sky and read as a tracking bug.
	if type in NON_AIRCRAFT_TYPES:
		return NOT_AN_AIRCRAFT

	# Emitter category first: it comes off the aircraft itself.
	match category:
		"A7":
			return ROTORCRAFT | _operator_guess(ac, type)
		"B1":
			return GLIDER | PRIVATE
		"B6":
			return DRONE
		"B2", "B3", "B4":
			# Lighter-than-air, parachutist, ultralight.
			result |= PRIVATE
		"B7":
			# Space or transatmospheric vehicle - not our satellite path.
			return UNKNOWN
		"A1":
			# Light, under ~15,500 lb. Overwhelmingly general aviation.
			result |= PRIVATE
		"A2":
			# Small: regional and business jets. Operator genuinely ambiguous, so claim
			# only the airframe and let the type tables decide the rest.
			result |= JET
		"A3", "A4", "A5":
			# Large through heavy. Airliners and freighters, plus military transports
			# and tankers, which the type table catches below.
			result |= COMMERCIAL | JET
		"A6":
			# High performance: >5g and >400kt. Overwhelmingly military fast jets.
			result |= MILITARY | JET

	if not type.is_empty():
		if type in MILITARY_TYPES:
			result |= MILITARY
		if type in ROTORCRAFT_TYPES:
			result |= ROTORCRAFT
		if type in PISTON_TYPES:
			result |= PISTON
		if type in TURBOPROP_TYPES:
			result |= TURBOPROP
		if type in BIZJET_TYPES:
			result |= JET | PRIVATE
		if _looks_like_airliner_jet(type):
			result |= JET | COMMERCIAL

	if _looks_military_by_callsign(ac.callsign):
		result |= MILITARY

	# A military aircraft is not "commercial", whatever its size class implied.
	if result & MILITARY:
		result &= ~(COMMERCIAL | PRIVATE)

	# Nothing is both a jet and a piston; the type tables beat the size-class guess.
	if result & (PISTON | TURBOPROP):
		result &= ~JET

	return result


## Whether this belongs in the sky at all.
static func is_renderable(c: int) -> bool:
	return c != NOT_AN_AIRCRAFT


static func _operator_guess(ac: Aircraft, type: String) -> int:
	if type in MILITARY_TYPES or _looks_military_by_callsign(ac.callsign):
		return MILITARY
	return PRIVATE


## Airliner-style designators: maker letter, two digits, optional third character that
## may be a variant LETTER. A321 and B738, but also A21N, A20N, B38M, B77W, B78X. The
## trailing letter is the whole point: the first version demanded digits to the end and
## missed the five most common types over Los Angeles.
static func _looks_like_airliner_jet(type: String) -> bool:
	if type.length() < 3 or type.length() > 4:
		return false
	if not (type[0] in ["A", "B", "E"]):
		return false
	if not (_is_digit(type[1]) and _is_digit(type[2])):
		return false
	if type.length() == 4 and not (_is_digit(type[3]) or _is_letter(type[3])):
		return false
	return true


static func _looks_military_by_callsign(callsign: String) -> bool:
	var c := callsign.strip_edges().to_upper()
	if c.is_empty():
		return false
	for prefix in MILITARY_CALLSIGN_PREFIXES:
		if c.begins_with(prefix):
			return true
	return false


static func _is_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"


static func _is_letter(ch: String) -> bool:
	return (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z")


## Human-readable label for the UI.
static func describe(c: int) -> String:
	if c == NOT_AN_AIRCRAFT:
		return "Not an aircraft"
	var parts: PackedStringArray = []
	if c & MILITARY: parts.append("Military")
	if c & COMMERCIAL: parts.append("Commercial")
	if c & PRIVATE: parts.append("Private")
	if c & ROTORCRAFT: parts.append("Rotorcraft")
	elif c & GLIDER: parts.append("Glider")
	elif c & DRONE: parts.append("Drone")
	elif c & JET: parts.append("Jet")
	elif c & TURBOPROP: parts.append("Turboprop")
	elif c & PISTON: parts.append("Piston")
	return " ".join(parts) if parts.size() > 0 else "Unknown"


## US military callsign prefixes. Deliberately short: distinctive enough to be worth
## having, vague enough that a longer list would false-positive on airlines.
const MILITARY_CALLSIGN_PREFIXES: Array[String] = [
	"RCH",  # Reach - USAF Air Mobility Command
	"EVAC",  # Aeromedical evacuation
	"CNV",  # US Navy logistics
	"SENTRY", "DOOM", "POLO",
	"SPAR",  # Special Air Resources
]

const MILITARY_TYPES := {
	# Fast jets
	"F16": 1, "F15": 1, "F18": 1, "F22": 1, "F35": 1, "A10": 1, "EUFI": 1, "RFAL": 1,
	"GR4": 1, "HAWK": 1,
	# Transports and tankers
	"C130": 1, "C30J": 1, "C17": 1, "C5M": 1, "K35R": 1, "KC46": 1, "A400": 1, "C27J": 1,
	# Maritime, surveillance, command
	"P8": 1, "E3TF": 1, "E3CF": 1, "E6": 1, "RC35": 1, "U2": 1, "P3": 1,
	# Trainers and support
	"T6": 1, "T38": 1, "T45": 1, "B52": 1, "B1": 1, "B2": 1,
}

## Type codes that are not aircraft. Found by sampling live data; expect it to grow.
const NON_AIRCRAFT_TYPES := {
	"TWR": 1,  # Radio or control tower
	"OBST": 1,  # Generic obstruction
	"GRND": 1,  # Ground station
}

const ROTORCRAFT_TYPES := {
	"R44": 1, "R22": 1, "R66": 1, "B06": 1, "B407": 1, "B429": 1, "B412": 1, "B430": 1,
	"EC20": 1, "EC25": 1, "EC30": 1, "EC35": 1, "EC45": 1, "EC55": 1, "EC75": 1,
	"AS50": 1, "AS55": 1, "AS65": 1, "A109": 1, "A119": 1, "A139": 1, "A169": 1, "A189": 1,
	"S76": 1, "S92": 1, "H60": 1, "UH60": 1, "CH47": 1, "AH64": 1, "H500": 1, "MD52": 1,
	"MD90": 1, "GAZL": 1, "LYNX": 1, "PUMA": 1, "R22B": 1, "S300": 1, "H269": 1,
}

## Business jets: PRIVATE, not COMMERCIAL. Their designators start with letters the
## airliner rule deliberately excludes (C collides with Cessna singles, F is Falcon).
const BIZJET_TYPES := {
	# Cessna Citation
	"C25A": 1, "C25B": 1, "C25C": 1, "C25M": 1, "C500": 1, "C510": 1, "C525": 1, "C550": 1,
	"C551": 1, "C560": 1, "C56X": 1, "C650": 1, "C680": 1, "C68A": 1, "C700": 1, "C750": 1,
	# Dassault Falcon
	"F900": 1, "F2TH": 1, "F7X": 1, "F8X": 1, "FA10": 1, "FA20": 1, "FA50": 1,
	# Bombardier Learjet / Challenger / Global
	"LJ31": 1, "LJ35": 1, "LJ40": 1, "LJ45": 1, "LJ55": 1, "LJ60": 1, "LJ70": 1, "LJ75": 1,
	"CL30": 1, "CL35": 1, "CL60": 1, "CL64": 1, "GLEX": 1, "GL5T": 1, "GL7T": 1,
	# Gulfstream
	"GLF3": 1, "GLF4": 1, "GLF5": 1, "GLF6": 1, "G150": 1, "G280": 1,
	# Embraer / Honda / Pilatus / Beech jets
	"E50P": 1, "E55P": 1, "E545": 1, "E550": 1, "HDJT": 1, "PRM1": 1, "BE40": 1, "H25B": 1,
	"HA4T": 1,
}

const PISTON_TYPES := {
	"C150": 1, "C152": 1, "C162": 1, "C172": 1, "C177": 1, "C182": 1, "C185": 1, "C206": 1,
	"C207": 1, "C210": 1, "C310": 1, "C337": 1, "C402": 1, "C404": 1, "C414": 1, "C421": 1,
	"P28A": 1, "P28B": 1, "P28R": 1, "P28T": 1, "PA18": 1, "PA22": 1, "PA24": 1, "PA27": 1,
	"PA28": 1, "PA30": 1, "PA31": 1, "PA32": 1, "PA34": 1, "PA44": 1, "PA46": 1,
	"BE33": 1, "BE35": 1, "BE36": 1, "BE55": 1, "BE58": 1, "BE76": 1,
	"SR20": 1, "SR22": 1, "S22T": 1, "SR2T": 1, "DA20": 1, "DA40": 1, "DA42": 1, "DA62": 1,
	"M20P": 1, "M20T": 1, "AA5": 1, "GA7": 1, "RV6": 1, "RV7": 1, "RV8": 1, "RV9": 1,
	"RV10": 1, "RV14": 1, "J3": 1, "CH7B": 1, "BL8": 1, "C82R": 1, "COL4": 1, "LNC2": 1,
}

const TURBOPROP_TYPES := {
	"PC12": 1, "PC24": 1, "TBM7": 1, "TBM8": 1, "TBM9": 1, "B350": 1, "BE20": 1, "BE9L": 1,
	"C208": 1, "DH8A": 1, "DH8B": 1, "DH8C": 1, "DH8D": 1, "AT72": 1, "AT75": 1, "AT76": 1,
	"AT43": 1, "AT45": 1, "SF34": 1, "E120": 1, "SW4": 1, "D228": 1, "L410": 1,
}
