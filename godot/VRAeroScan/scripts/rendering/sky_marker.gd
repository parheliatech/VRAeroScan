class_name SkyMarker
extends Node3D
## One aircraft or satellite on the sky: an outline, a label, and nothing else.
##
## Shape says what it is — square for an aircraft, diamond for a satellite — and colour
## says what kind. Both are outlines because the display is additive: a filled shape
## would be a bright patch over the very light the user is trying to identify. The
## label sits beside the outline, never over it, for the same reason.
##
## Markers are pooled by the caller and reconfigured rather than freed, so everything
## here is built once.

## RISE is not an object but a place and a time: where a satellite will come up over
## the horizon, shown shortly before it does (see PassPredictor).
enum Kind { AIRCRAFT, SATELLITE, RISE }

## Degrees of elevation over which a marker fades out as it sinks. A hard cut at 0°
## makes low aircraft blink as dead reckoning and position noise jitter them across
## the horizon.
const HORIZON_FADE_DEG := 1.5

## Marker size as a fraction of dome radius, i.e. roughly radians.
const ANGULAR_SIZE := 0.03

static var _square: ArrayMesh
static var _diamond: ArrayMesh
static var _rise: ArrayMesh

var kind := Kind.AIRCRAFT
## Fade out below the horizon. Aircraft and rise markers do; satellites do not — they are
## drawn below the horizon, through the Earth, like everywhere else.
var fades_at_horizon := true
## Where this marker last was, for decluttering and off-screen hints.
var look: LookAngles

var _rig: SkyRig
var _outline: MeshInstance3D
var _material: StandardMaterial3D
var _label: Label3D
var _color := Color.WHITE
var _alpha := 1.0
var _brightness := 1.0


## Build a marker under the rig's marker root. Called when the pool runs dry, never per
## frame.
static func create(rig: SkyRig, marker_kind: Kind) -> SkyMarker:
	var marker := SkyMarker.new()
	marker.name = Kind.keys()[marker_kind].capitalize()
	marker._build(rig, marker_kind)
	rig.marker_root.add_child(marker)
	return marker


func _build(rig: SkyRig, marker_kind: Kind) -> void:
	_rig = rig
	kind = marker_kind

	# Scale with the dome so the marker subtends a constant angle, like the cardinals.
	var size := rig.sky_radius * ANGULAR_SIZE

	if _square == null:
		_square = ArVisuals.square_outline()
		_diamond = ArVisuals.diamond_outline()
		_rise = ArVisuals.rise_chevron()

	_outline = MeshInstance3D.new()
	_outline.mesh = [_square, _diamond, _rise][kind]
	_outline.scale = Vector3.ONE * size
	# One material per marker, since each has its own colour and fade. The pool keeps
	# the count bounded by what is in the sky at once.
	_material = ArVisuals.additive_material(Color.WHITE)
	_outline.material_override = _material
	add_child(_outline)

	# Beside the outline, left-aligned, so it never paints over the target.
	_label = ArVisuals.create_label(self, "", size * 0.55, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT)
	_label.position = Vector3(size * 0.8, 0, 0)


## Show or hide the outline, leaving the label: for a satellite whose diamond
## SatelliteField already draws.
func set_outline_visible(shown: bool) -> void:
	_outline.visible = shown


## Use an aircraft silhouette instead of the default outline, at its relative size. The
## label moves out with a bigger icon so it never overlaps it.
func set_icon(icon: AircraftIcons.Icon) -> void:
	var size := _rig.sky_radius * ANGULAR_SIZE * AircraftIcons.scale_of(icon)
	_outline.mesh = AircraftIcons.mesh(icon)
	_outline.scale = Vector3.ONE * size
	_label.position = Vector3(size * 0.8, 0, 0)


## Use a satellite silhouette (SatelliteIcons) for the outline, at the standard size.
func set_satellite_icon(icon: SatelliteIcons.Icon) -> void:
	_outline.mesh = SatelliteIcons.mesh(icon)
	_outline.scale = Vector3.ONE * _rig.sky_radius * ANGULAR_SIZE
	_outline.rotation = Vector3.ZERO


## Point the outline's nose along `angle`, radians counter-clockwise from the view's
## right, in the marker's own (camera-facing) plane. Only the outline turns; the label
## stays level.
func set_travel_angle(angle: float) -> void:
	_outline.rotation = Vector3(0.0, 0.0, angle - PI / 2.0)


## Colour and text. Meant for data updates, not every frame.
func configure(color: Color, text: String) -> void:
	_color = color
	if _label.text != text:
		_label.text = text
	_apply_color()


## Extra dimming from outside, 0..1 — decluttering, or dimming the whole sky while the
## user calibrates so the ghost N stands out.
func set_brightness(brightness: float) -> void:
	brightness = clampf(brightness, 0.0, 1.0)
	if brightness != _brightness:
		_brightness = brightness
		_apply_color()


## Place the marker in the sky, face the camera, and fade by elevation.
func set_look(angles: LookAngles) -> void:
	look = angles
	position = _rig.position_for_look(angles)
	basis = _rig.billboard_basis()

	# 1 at +HORIZON_FADE_DEG and above, 0 at 0° and below.
	var alpha := clampf(angles.elevation_deg / HORIZON_FADE_DEG, 0.0, 1.0) if fades_at_horizon else 1.0
	if not is_equal_approx(alpha, _alpha):
		_alpha = alpha
		_apply_color()
	visible = _alpha * _brightness > 0.001


func _apply_color() -> void:
	var c := Color(_color, _alpha * _brightness)
	_material.albedo_color = c
	_label.modulate = c


## Colour for an aircraft class. Operator beats airframe, because "is that an airliner
## or a Cessna" is the question people actually ask when they look up.
##
## All bright and fairly desaturated: on an additive display a dark colour is invisible
## and a fully saturated one reads as glare.
static func color_for(c: int) -> Color:
	if c & AircraftClassifier.MILITARY:
		return Color(1.0, 0.62, 0.3)  # amber
	if c & AircraftClassifier.ROTORCRAFT:
		return Color(0.95, 0.5, 0.95)  # magenta
	if c & AircraftClassifier.COMMERCIAL:
		return Color(0.45, 0.85, 1.0)  # cyan
	if c & AircraftClassifier.PRIVATE:
		return Color(0.5, 1.0, 0.55)  # green
	if c & (AircraftClassifier.GLIDER | AircraftClassifier.DRONE):
		return Color(1.0, 1.0, 0.55)  # yellow
	return Color(0.8, 0.8, 0.8)  # unknown


## Two short lines: who it is, then type, altitude and range. Short on purpose — at 46°
## FOV a long label covers the neighbouring aircraft.
static func label_for(ac: Aircraft, angles: LookAngles) -> String:
	var alt: String
	if ac.on_ground:
		alt = "GND"
	elif ac.altitude_ft >= 18000.0:
		alt = "FL%d" % roundi(ac.altitude_ft / 100.0)
	else:
		alt = "%dft" % roundi(ac.altitude_ft)

	var nm := angles.range_m / GeoMath.METERS_PER_NAUTICAL_MILE
	return "%s\n%s %s %dnm" % [ac.display_name(), ac.type_code if ac.type_code else "?", alt, roundi(nm)]


## Colour for a satellite category. Satellites are already told apart from aircraft by
## the diamond, so these can be quieter pastels; the station — the one people go out to
## look for — gets the warm, strong one.
## A satellite's colour: its orbit category's, except military in amber — as for
## aircraft, colour says who, shape says what.
static func color_for_sat(sat: Satellite) -> Color:
	if sat.military:
		return color_for(AircraftClassifier.MILITARY)
	return color_for_satellite(sat.category)


static func color_for_satellite(category: int) -> Color:
	match category:
		Satellite.MANNED:
			return Color(1.0, 0.85, 0.4)  # gold
		Satellite.STARLINK:
			return Color(0.6, 0.7, 1.0)  # periwinkle
		Satellite.MEO:
			return Color(0.85, 0.75, 1.0)  # lavender
		Satellite.GEO:
			return Color(1.0, 0.72, 0.72)  # rose
	return Color(0.75, 0.95, 0.95)  # LEO: pale cyan


## Name, then altitude and range. "shadow" when the satellite is in Earth's shadow, so
## anyone trying to spot it by eye knows not to bother. Information only: the marker is
## drawn the same either way.
static func label_for_satellite(sat: Satellite, angles: LookAngles) -> String:
	return "%s\n%dkm up %dkm%s" % [sat.name, roundi(sat.altitude_km()),
			roundi(angles.range_m / 1000.0), "" if sat.sunlit else " shadow"]


## For a rise marker: who, when, and how high it will get — the height decides whether
## it is worth waiting for.
static func label_for_rise(sat: Satellite, p: PassPredictor.SatellitePass, unix_s: float) -> String:
	return "%s rises %s\nmax %d°" % [sat.name, PassPredictor.countdown(p.rise_unix - unix_s),
			roundi(p.max_elevation_deg)]
