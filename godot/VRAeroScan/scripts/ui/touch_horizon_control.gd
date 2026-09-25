class_name TouchHorizonControl
extends Node
## Drag the phone's touchscreen sideways to rotate the sky until the ghost N sits where
## north really is.
##
## This is the primary calibration interface, not a safety net. A phone magnetometer is
## easily 5–15° off near metal and electronics, while a person looking at a known
## landmark — or at an aircraft the app is already drawing — is good to a degree or
## two. So the control is built for the last few degrees:
##
##   Coarse: one finger, or left mouse. A screen width is coarse_deg_per_screen.
##   Fine:   two fingers, or Shift + left mouse. A screen width is fine_deg_per_screen.
##   Keys:   Left/Right arrows step key_step_deg, a tenth of that with Shift.
##
## The phone screen is a trackpad, not a window: wearing the glasses you look at the
## sky, not the phone. So gain is per screen width, and the sky follows the finger —
## drag right and the N moves right.
##
## Input arrives through _unhandled_input, so a touch that lands on a UI control is
## consumed by the control and never nudges the sky.
##
## When the app runs on the glasses, the phone screen is not the app's window: the drag
## comes instead from the pad on the phone's control panel (ControlPanelActivity), as
## fractions of the pad's width, through pad_drag() — same gain, same sign.

## Degrees for a full-screen-width drag, one finger.
@export var coarse_deg_per_screen := 90.0
## Degrees for a full-screen-width drag in fine mode.
@export var fine_deg_per_screen := 10.0
## Degrees per arrow-key press. Shift steps a tenth of this.
@export var key_step_deg := 1.0
## Pixels a pointer must travel before it counts as a drag, so a tap does not nudge.
@export var drag_threshold_px := 12.0
## How long the ghosts stay bright after a key nudge, seconds.
@export var key_highlight_s := 0.6

var _calibration: CompassCalibration
var _cardinals: CardinalMarkers

## Touch indices currently down that started on the sky, not on a control.
var _touches: Dictionary = {}
var _mouse_down := false
var _dragging := false
var _pending_px := 0.0
var _key_highlight_until := -INF
var _pad_dragging := false


func initialize(calibration: CompassCalibration, cardinals: CardinalMarkers) -> void:
	_calibration = calibration
	_cardinals = cardinals


## True while the user is actively turning the sky.
func is_adjusting() -> bool:
	return _dragging or _pad_dragging or _now() < _key_highlight_until


## A drag on the control panel's pad: `fraction` of the pad's width, with `fingers` down
## (two or more is fine mode). The panel has already told taps from drags.
func pad_drag(fraction: float, fingers: int) -> void:
	_pad_dragging = true
	rotate_sky(fraction * (fine_deg_per_screen if fingers >= 2 else coarse_deg_per_screen))


func pad_release() -> void:
	_pad_dragging = false


## Brighten the ghosts briefly, as after a key nudge — for a nudge from a button.
func highlight() -> void:
	_key_highlight_until = _now() + key_highlight_s


func _process(_delta: float) -> void:
	if _cardinals != null:
		_cardinals.set_adjusting(is_adjusting())


func _unhandled_input(event: InputEvent) -> void:
	if _calibration == null:
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = true
		else:
			_touches.erase(touch.index)
			if _touches.is_empty():
				_end_drag()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _touches.has(drag.index):
			# Each finger reports its own drag event, so dividing by the finger count
			# averages them. Per-event deltas rather than positions mean adding a second
			# finger mid-drag, to drop into fine mode, does not make the sky jump.
			_accumulate(drag.relative.x / _touches.size(), _touches.size() >= 2)

	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_mouse_down = button.pressed
			if not button.pressed:
				_end_drag()

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _mouse_down:
			_accumulate(motion.relative.x, motion.shift_pressed)

	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and key.keycode in [KEY_LEFT, KEY_RIGHT]:
			var step := key_step_deg * (0.1 if key.shift_pressed else 1.0)
			rotate_sky(step if key.keycode == KEY_RIGHT else -step)
			_key_highlight_until = _now() + key_highlight_s


## Pixels into rotation, once the pointer has moved far enough to be a drag.
func _accumulate(dx_px: float, fine: bool) -> void:
	if dx_px == 0.0:
		return

	if not _dragging:
		_pending_px += dx_px
		if absf(_pending_px) < drag_threshold_px:
			return
		# Crossing the threshold starts the drag. The travel used to decide that is
		# discarded, so the sky does not lurch by the threshold distance.
		_dragging = true
		_pending_px = 0.0
		return

	var width := maxf(1.0, get_viewport().get_visible_rect().size.x)
	var deg_per_screen := fine_deg_per_screen if fine else coarse_deg_per_screen
	rotate_sky(dx_px / width * deg_per_screen)


## Move the sky by sky_deg, positive meaning the sky moves RIGHT as the user sees it.
##
## The sign is the thing here easy to get backwards, so it is pinned by a test. The
## offset turns the CAMERA: a larger offset points it further clockwise, which slides
## the sky to the left. Moving the sky right therefore means shrinking the offset.
func rotate_sky(sky_deg: float) -> void:
	_calibration.nudge(-sky_deg)


func _end_drag() -> void:
	_dragging = false
	_pending_px = 0.0


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
