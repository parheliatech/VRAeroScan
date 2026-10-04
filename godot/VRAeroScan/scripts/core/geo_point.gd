class_name GeoPoint
extends RefCounted
## A WGS84 position. Plain floats, which GDScript stores as 64-bit doubles — never
## pack these into a Vector3, which is 32-bit and loses metres at Earth scale.

var latitude_deg: float
var longitude_deg: float
var altitude_m: float
## The point is the middle of the Earth, not a place on it. Latitude and longitude then
## only say which way is north, so the compass keeps its meaning. See GeoMath.geodetic_to_ecef.
var at_earth_centre := false


func _init(lat_deg: float = 0.0, lon_deg: float = 0.0, alt_m: float = 0.0) -> void:
	latitude_deg = lat_deg
	longitude_deg = lon_deg
	altitude_m = alt_m


func _to_string() -> String:
	if at_earth_centre:
		return "Earth centre (north from %.5f, %.5f)" % [latitude_deg, longitude_deg]
	return "%.5f, %.5f, %.0fm" % [latitude_deg, longitude_deg, altitude_m]


## The middle of the Earth, with the compass orientation of lat/lon.
static func earth_centre(lat_deg: float, lon_deg: float) -> GeoPoint:
	var p := GeoPoint.new(lat_deg, lon_deg, 0.0)
	p.at_earth_centre = true
	return p
