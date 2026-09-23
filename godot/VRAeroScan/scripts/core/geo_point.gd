class_name GeoPoint
extends RefCounted
## A WGS84 position. Plain floats, which GDScript stores as 64-bit doubles — never
## pack these into a Vector3, which is 32-bit and loses metres at Earth scale.

var latitude_deg: float
var longitude_deg: float
var altitude_m: float


func _init(lat_deg: float = 0.0, lon_deg: float = 0.0, alt_m: float = 0.0) -> void:
	latitude_deg = lat_deg
	longitude_deg = lon_deg
	altitude_m = alt_m


func _to_string() -> String:
	return "%.5f, %.5f, %.0fm" % [latitude_deg, longitude_deg, altitude_m]
