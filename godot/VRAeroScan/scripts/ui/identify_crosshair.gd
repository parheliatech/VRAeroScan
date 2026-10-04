class_name IdentifyCrosshair
extends Node3D
## "What is that?": a circle crosshair fixed in the middle of the view, and a card beside it
## with the details of whatever aircraft or satellite is centred in it.
##
## Pure presentation, like QuickMenu: AppBootstrap decides what is in the circle and hands
## over the text. The describe_* functions build that text and are static so the tests can
## check them without a scene.
##
## Outlines and pale text only, for the additive display. The card sits to the right of
## the circle, never over it, so it does not cover the very light being identified.

## Radius of the circle, degrees of view. The object nearest the middle, within this, is
## the one described. About the size of a thumbnail at arm's length: easy to put a moving
## light in, small enough to pick one out of a crowd.
const RADIUS_DEG := 2.5
## Distance in front of the camera it is drawn at (any distance looks the same).
const AT := 10.0
## Height of one line of the card, degrees of view.
const LINE_DEG := 0.85

const IDLE_COLOR := Color(0.7, 0.85, 1.0, 0.75)
const LOCKED_COLOR := Color(1.0, 0.95, 0.7)

var _ring: MeshInstance3D
var _ring_material: StandardMaterial3D
var _card: Label3D


func initialize(camera: Camera3D) -> void:
	name = "IdentifyCrosshair"
	position = Vector3(0.0, 0.0, -AT)
	camera.add_child(self)
	visible = false

	# The circle, with four short ticks pointing in at its centre: a crosshair that leaves
	# the middle itself clear, so the light being identified is not covered.
	var r := AT * deg_to_rad(RADIUS_DEG)
	var lines: PackedVector3Array = []
	for i in 64:
		var a0 := TAU * i / 64.0
		var a1 := TAU * (i + 1) / 64.0
		lines.append(Vector3(cos(a0) * r, sin(a0) * r, 0.0))
		lines.append(Vector3(cos(a1) * r, sin(a1) * r, 0.0))
	for d: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN]:
		lines.append(d * r)
		lines.append(d * r * 0.7)
	_ring = MeshInstance3D.new()
	_ring.mesh = ArVisuals.line_mesh(lines)
	_ring_material = ArVisuals.additive_material(IDLE_COLOR)
	_ring.material_override = _ring_material
	add_child(_ring)

	_card = ArVisuals.create_label(self, "", AT * deg_to_rad(LINE_DEG), LOCKED_COLOR,
			HORIZONTAL_ALIGNMENT_LEFT)
	_card.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_card.position = Vector3(r * 1.25, r, 0.0)


## Show the card. `locked`: something is in the circle (brighter ring, brighter text).
func set_card(text: String, locked: bool) -> void:
	if _card.text != text:
		_card.text = text
	var color := LOCKED_COLOR if locked else IDLE_COLOR
	_ring_material.albedo_color = color
	_card.modulate = color


func card_text() -> String:
	return _card.text


## What the card says when nothing is centred.
const HINT := "Centre an aircraft or a satellite\nin the circle"


## An aircraft's card: who, what, how high and fast, where in your sky, how fresh.
static func describe_aircraft(ac: Aircraft, look: LookAngles, now: float, at_surface: bool) -> String:
	var who := ac.display_name()
	if not ac.registration.is_empty() and ac.registration != who:
		who += " · " + ac.registration
	var what := "%s · %s" % [ac.type_code if not ac.type_code.is_empty() else "type unknown",
			AircraftClassifier.describe(ac.classification)]
	var alt := "on the ground"
	if not ac.on_ground:
		alt = "FL%d" % roundi(ac.altitude_ft / 100.0) if ac.altitude_ft >= 18000.0 \
				else "%s ft" % _thousands(roundi(ac.altitude_ft))
	var motion := "%s · %d kt · heading %s" % [alt, roundi(ac.ground_speed_kt),
			PassPredictor.compass_point(ac.track_deg)]
	var age := maxf(now - ac.received_at, 0.0) + ac.position_age_s
	return "\n".join([who, what, motion,
			"%s nm away · %s" % [_thousands(roundi(look.range_m / GeoMath.METERS_PER_NAUTICAL_MILE)),
					_where(look, at_surface)],
			"ICAO %s · position %ds old" % [ac.icao24.to_upper(), roundi(age)]])


## A satellite's card: who, what kind, its orbit, where in your sky, lit or not.
static func describe_satellite(sat: Satellite, look: LookAngles, at_surface: bool) -> String:
	var kind: String = ICON_NAMES.get(sat.icon, "Satellite")
	var group := ""
	for k: Array in AppBootstrap.SATELLITE_KINDS:
		if sat.category == k[1]:
			group = k[0]
	var what := "%s · %s%s" % [kind, group, " · military" if sat.military else ""]
	var orbit := "%s km up · orbit %s min, %.0f° incl." % [_thousands(roundi(sat.altitude_km())),
			_thousands(roundi(sat.sgp4.period_min())), rad_to_deg(sat.sgp4.inclo)]
	return "\n".join(["%s · #%d" % [sat.name, sat.norad_id], what, orbit,
			"%s km away · %s" % [_thousands(roundi(look.range_m / 1000.0)), _where(look, at_surface)],
			"in sunlight" if sat.sunlit else "in Earth's shadow: not lit"])


## What each satellite icon is, for the card.
const ICON_NAMES := {
	SatelliteIcons.Icon.ISS: "Space station",
	SatelliteIcons.Icon.STATION: "Space station",
	SatelliteIcons.Icon.CAPSULE: "Spacecraft",
	SatelliteIcons.Icon.HUBBLE: "Space telescope",
	SatelliteIcons.Icon.STARLINK: "Starlink",
	SatelliteIcons.Icon.COMMS: "Communications",
	SatelliteIcons.Icon.NAVIGATION: "Navigation",
	SatelliteIcons.Icon.EARTH_OBS: "Earth observation",
	SatelliteIcons.Icon.ROCKET_BODY: "Rocket body",
	SatelliteIcons.Icon.DEBRIS: "Debris",
	SatelliteIcons.Icon.CUBESAT: "CubeSat",
	SatelliteIcons.Icon.GENERIC: "Satellite",
}


## "34° up · NW (312°)", or "below the horizon" from the ground.
static func _where(look: LookAngles, at_surface: bool) -> String:
	var height := "%d° up" % roundi(look.elevation_deg)
	if look.elevation_deg < 0.0:
		height = "%d° %s" % [roundi(-look.elevation_deg),
				"below the horizon" if at_surface else "down"]
	return "%s · %s (%d°)" % [height, PassPredictor.compass_point(look.azimuth_deg),
			roundi(look.azimuth_deg) % 360]


static func _thousands(n: int) -> String:
	return AppBootstrap._thousands(n)
