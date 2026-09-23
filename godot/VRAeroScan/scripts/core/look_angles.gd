class_name LookAngles
extends RefCounted
## Where a target sits in the observer's sky.

## Degrees clockwise from TRUE north. 0 = N, 90 = E.
var azimuth_deg: float
## Degrees above the observer's horizon. Negative = below it.
var elevation_deg: float
## Straight-line (slant) distance, metres.
var range_m: float


func _init(az: float = 0.0, el: float = 0.0, rng: float = 0.0) -> void:
	azimuth_deg = az
	elevation_deg = el
	range_m = rng


func is_above_horizon() -> bool:
	return elevation_deg > 0.0


func _to_string() -> String:
	return "az %.1f° el %.1f° rng %.1fkm" % [azimuth_deg, elevation_deg, range_m / 1000.0]
