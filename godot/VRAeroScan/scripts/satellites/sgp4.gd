class_name Sgp4
extends RefCounted
## SGP4/SDP4 orbit propagation: turns one satellite's mean elements into a TEME position
## and velocity at any time.
##
## A line-for-line port of python-sgp4's propagation.py (Brandon Rhodes, MIT), itself a
## transcription of David Vallado's reference C++ ("Revisiting Spacetrack Report #3",
## AIAA 2006-6753). Deep space (SDP4) is included, so GEO, GPS and Molniya orbits work.
## Gravity model WGS72 and opsmode 'i', matching Satrec.twoline2rv's defaults.
##
## DO NOT "TIDY" THIS. The variable names, the order of operations and the odd modulo
## calls all mirror the reference, and it passes tests/sgp4_fixture.json (Vallado's
## published verification suite: Molniya resonance, the Lyddane fix, deep space,
## decay) only because of that. SGP4 fails silently — a wrong term gives a plausible
## orbit off by a degree — so any edit here must re-run tests/run.sh.
##
## TLE and OMM elements are MEAN elements fitted by SGP4 itself. Feeding them to plain
## Keplerian maths is silently wrong; they are only meaningful through this.
##
## Python's `x % twopi` (result takes the divisor's sign) is fposmod here; where the
## reference emulates C's fmod explicitly, fmod is used.

const TWOPI := 2.0 * PI
const X2O3 := 2.0 / 3.0
const TEMP4 := 1.5e-12
const XPDOTP := 1440.0 / (2.0 * PI)

# WGS72 gravity constants.
const MU := 398600.8
const RADIUS_EARTH_KM := 6378.135
const J2 := 0.001082616
const J3 := -0.00000253881
const J4 := -0.00000165597
const J3OJ2 := J3 / J2
static var XKE := 60.0 / sqrt(RADIUS_EARTH_KM * RADIUS_EARTH_KM * RADIUS_EARTH_KM / MU)

## Error codes, as the reference numbers them.
enum Fault { NONE, ECCENTRICITY, MEAN_MOTION, PERTURBED_ECCENTRICITY, SEMILATUS_RECTUM,
		UNUSED, DECAYED }

var satnum := 0
## Element epoch as a UTC Julian date.
var jd_epoch := 0.0
## Element epoch in Unix seconds, which is what the app's clock speaks.
var epoch_unix := 0.0

## After propagate(): TEME position (km) and velocity (km/s).
var r := PackedFloat64Array([0.0, 0.0, 0.0])
var v := PackedFloat64Array([0.0, 0.0, 0.0])
var error := Fault.NONE

# Mean elements at epoch (radians, rad/min).
var bstar := 0.0
var ndot := 0.0
var nddot := 0.0
var ecco := 0.0
var argpo := 0.0
var inclo := 0.0
var mo := 0.0
var no_kozai := 0.0
var nodeo := 0.0
var no_unkozai := 0.0

# Near-earth terms.
var isimp := 0
var method := "n"
var aycof := 0.0
var con41 := 0.0
var cc1 := 0.0
var cc4 := 0.0
var cc5 := 0.0
var d2 := 0.0
var d3 := 0.0
var d4 := 0.0
var delmo := 0.0
var eta := 0.0
var argpdot := 0.0
var omgcof := 0.0
var sinmao := 0.0
var t := 0.0
var t2cof := 0.0
var t3cof := 0.0
var t4cof := 0.0
var t5cof := 0.0
var x1mth2 := 0.0
var x7thm1 := 0.0
var mdot := 0.0
var nodedot := 0.0
var xlcof := 0.0
var xmcof := 0.0
var nodecf := 0.0
var gsto := 0.0

# Deep-space terms.
var irez := 0
var d2201 := 0.0
var d2211 := 0.0
var d3210 := 0.0
var d3222 := 0.0
var d4410 := 0.0
var d4422 := 0.0
var d5220 := 0.0
var d5232 := 0.0
var d5421 := 0.0
var d5433 := 0.0
var dedt := 0.0
var del1 := 0.0
var del2 := 0.0
var del3 := 0.0
var didt := 0.0
var dmdt := 0.0
var dnodt := 0.0
var domdt := 0.0
var e3 := 0.0
var ee2 := 0.0
var peo := 0.0
var pgho := 0.0
var pho := 0.0
var pinco := 0.0
var plo := 0.0
var se2 := 0.0
var se3 := 0.0
var sgh2 := 0.0
var sgh3 := 0.0
var sgh4 := 0.0
var sh2 := 0.0
var sh3 := 0.0
var si2 := 0.0
var si3 := 0.0
var sl2 := 0.0
var sl3 := 0.0
var sl4 := 0.0
var xfact := 0.0
var xgh2 := 0.0
var xgh3 := 0.0
var xgh4 := 0.0
var xh2 := 0.0
var xh3 := 0.0
var xi2 := 0.0
var xi3 := 0.0
var xl2 := 0.0
var xl3 := 0.0
var xl4 := 0.0
var xlamo := 0.0
var zmol := 0.0
var zmos := 0.0
var atime := 0.0
var xli := 0.0
var xni := 0.0


# --- Construction -----------------------------------------------------------------

## From the two lines of a TLE. Returns null if the lines are malformed.
static func from_tle(line1: String, line2: String) -> Sgp4:
	line1 = line1.strip_edges(false, true)
	line2 = line2.strip_edges(false, true)
	if line1.length() < 64 or not line1.begins_with("1 ") or line2.length() < 68 \
			or not line2.begins_with("2 ") or line1.substr(2, 5) != line2.substr(2, 5):
		return null

	var two_digit_year := _field(line1, 18, 2)
	var epochdays := _field(line1, 20, 12)
	var ndot_tle := _field(line1, 33, 10)
	# Assumed-decimal fields: " 12345-4" means 0.12345e-4.
	var nddot_tle := _implied_decimal(line1, 44)
	var bstar_tle := _implied_decimal(line1, 53)

	var year := int(two_digit_year) + (2000 if two_digit_year < 57 else 1900)
	var jd := _jday(year, 1, 0, 0, 0, 0.0) + epochdays

	var sat := Sgp4.new()
	sat.init_elements(_alpha5_to_int(line1.substr(2, 5)), jd, bstar_tle,
			ndot_tle / (XPDOTP * 1440.0), nddot_tle / (XPDOTP * 1440.0 * 1440.0),
			("0." + line2.substr(26, 7).replace(" ", "0")).to_float(),
			deg_to_rad(_field(line2, 34, 8)),
			deg_to_rad(_field(line2, 8, 8)),
			deg_to_rad(_field(line2, 43, 8)),
			_field(line2, 52, 11) / XPDOTP,
			deg_to_rad(_field(line2, 17, 8)))
	return sat


## From one CelesTrak OMM JSON record (FORMAT=json). Returns null if a field is missing
## or the epoch cannot be read. Same unit conversions as python-sgp4's omm.initialize.
static func from_omm(o: Dictionary) -> Sgp4:
	for key in ["EPOCH", "MEAN_MOTION", "ECCENTRICITY", "INCLINATION", "RA_OF_ASC_NODE",
			"ARG_OF_PERICENTER", "MEAN_ANOMALY", "NORAD_CAT_ID", "BSTAR"]:
		if not o.has(key):
			return null
	var jd := omm_epoch_to_jd(str(o["EPOCH"]))
	if is_nan(jd):
		return null

	var sat := Sgp4.new()
	sat.init_elements(int(o["NORAD_CAT_ID"]), jd, float(o["BSTAR"]),
			float(o.get("MEAN_MOTION_DOT", 0.0)) / (1036800.0 / PI),
			float(o.get("MEAN_MOTION_DDOT", 0.0)) / (2985984000.0 / 2.0 / PI),
			float(o["ECCENTRICITY"]),
			deg_to_rad(float(o["ARG_OF_PERICENTER"])),
			deg_to_rad(float(o["INCLINATION"])),
			deg_to_rad(float(o["MEAN_ANOMALY"])),
			float(o["MEAN_MOTION"]) / 720.0 * PI,
			deg_to_rad(float(o["RA_OF_ASC_NODE"])))
	return sat


## "2026-09-23T10:33:57.140352" (UTC) -> Julian date. NAN if unreadable.
static func omm_epoch_to_jd(epoch: String) -> float:
	var parts := epoch.strip_edges().rstrip("Z").split("T")
	if parts.size() != 2:
		return NAN
	var date := parts[0].split("-")
	var time := parts[1].split(":")
	if date.size() != 3 or time.size() != 3:
		return NAN
	return _jday(date[0].to_int(), date[1].to_int(), date[2].to_int(),
			time[0].to_int(), time[1].to_int(), time[2].to_float())


## Unix seconds -> Julian date (UTC).
static func unix_to_jd(unix_s: float) -> float:
	return unix_s / 86400.0 + 2440587.5


## Minutes since the element epoch at a Unix time — propagate()'s argument.
func minutes_since_epoch(unix_s: float) -> float:
	return (unix_s - epoch_unix) / 60.0


## Orbital period in minutes, from the Kozai mean motion.
func period_min() -> float:
	return TWOPI / no_kozai


# --- sgp4init -----------------------------------------------------------------------

## Set up the propagator. Angles in radians, mean motion in rad/min, epoch as a UTC
## Julian date.
func init_elements(p_satnum: int, p_jd_epoch: float, xbstar: float, xndot: float,
		xnddot: float, xecco: float, xargpo: float, xinclo: float, xmo: float,
		xno_kozai: float, xnodeo: float) -> void:
	satnum = p_satnum
	jd_epoch = p_jd_epoch
	epoch_unix = (jd_epoch - 2440587.5) * 86400.0
	var epoch := jd_epoch - 2433281.5  # days since 1949 December 31 00:00 UT

	bstar = xbstar
	ndot = xndot
	nddot = xnddot
	ecco = xecco
	argpo = xargpo
	inclo = xinclo
	mo = xmo
	no_kozai = xno_kozai
	nodeo = xnodeo

	var ss := 78.0 / RADIUS_EARTH_KM + 1.0
	var qzms2ttemp := (120.0 - 78.0) / RADIUS_EARTH_KM
	var qzms2t := qzms2ttemp * qzms2ttemp * qzms2ttemp * qzms2ttemp
	t = 0.0

	# --- initl ---
	var eccsq := ecco * ecco
	var omeosq := 1.0 - eccsq
	var rteosq := sqrt(omeosq)
	var cosio := cos(inclo)
	var cosio2 := cosio * cosio
	var ak := pow(XKE / no_kozai, X2O3)
	var d1 := 0.75 * J2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
	var del_ := d1 / (ak * ak)
	var adel := ak * (1.0 - del_ * del_ - del_ * (1.0 / 3.0 + 134.0 * del_ * del_ / 81.0))
	del_ = d1 / (adel * adel)
	no_unkozai = no_kozai / (1.0 + del_)
	var ao := pow(XKE / no_unkozai, X2O3)
	var sinio := sin(inclo)
	var po := ao * omeosq
	var con42 := 1.0 - 5.0 * cosio2
	con41 = -con42 - cosio2 - cosio2
	var posq := po * po
	var rp := ao * (1.0 - ecco)
	method = "n"
	gsto = gstime(epoch + 2433281.5)

	if omeosq >= 0.0 or no_unkozai >= 0.0:
		isimp = 0
		if rp < 220.0 / RADIUS_EARTH_KM + 1.0:
			isimp = 1
		var sfour := ss
		var qzms24 := qzms2t
		var perige := (rp - 1.0) * RADIUS_EARTH_KM

		# For perigees below 156 km, s and qoms2t are altered.
		if perige < 156.0:
			sfour = perige - 78.0
			if perige < 98.0:
				sfour = 20.0
			var qzms24temp := (120.0 - sfour) / RADIUS_EARTH_KM
			qzms24 = qzms24temp * qzms24temp * qzms24temp * qzms24temp
			sfour = sfour / RADIUS_EARTH_KM + 1.0

		var pinvsq := 1.0 / posq
		var tsi := 1.0 / (ao - sfour)
		eta = ao * ecco * tsi
		var etasq := eta * eta
		var eeta := ecco * eta
		var psisq := absf(1.0 - etasq)
		var coef := qzms24 * pow(tsi, 4.0)
		var coef1 := coef / pow(psisq, 3.5)
		var cc2 := coef1 * no_unkozai * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
				+ 0.375 * J2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
		cc1 = bstar * cc2
		var cc3 := 0.0
		if ecco > 1.0e-4:
			cc3 = -2.0 * coef * tsi * J3OJ2 * no_unkozai * sinio / ecco
		x1mth2 = 1.0 - cosio2
		cc4 = 2.0 * no_unkozai * coef1 * ao * omeosq * (eta * (2.0 + 0.5 * etasq)
				+ ecco * (0.5 + 2.0 * etasq) - J2 * tsi / (ao * psisq)
				* (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
				+ 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
		cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)
		var cosio4 := cosio2 * cosio2
		var temp1 := 1.5 * J2 * pinvsq * no_unkozai
		var temp2 := 0.5 * temp1 * J2 * pinvsq
		var temp3 := -0.46875 * J4 * pinvsq * pinvsq * no_unkozai
		mdot = no_unkozai + 0.5 * temp1 * rteosq * con41 \
				+ 0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
		argpdot = (-0.5 * temp1 * con42 + 0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4)
				+ temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4))
		var xhdot1 := -temp1 * cosio
		nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2) + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosio
		var xpidot := argpdot + nodedot
		omgcof = bstar * cc3 * cos(argpo)
		xmcof = 0.0
		if ecco > 1.0e-4:
			xmcof = -X2O3 * coef * bstar / eeta
		nodecf = 3.5 * omeosq * xhdot1 * cc1
		t2cof = 1.5 * cc1
		# Sgp4fix for divide by zero with xinco = 180 deg.
		if absf(cosio + 1.0) > 1.5e-12:
			xlcof = -0.25 * J3OJ2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
		else:
			xlcof = -0.25 * J3OJ2 * sinio * (3.0 + 5.0 * cosio) / TEMP4
		aycof = -0.5 * J3OJ2 * sinio
		var delmotemp := 1.0 + eta * cos(mo)
		delmo = delmotemp * delmotemp * delmotemp
		sinmao = sin(mo)
		x7thm1 = 7.0 * cosio2 - 1.0

		# Deep space initialisation.
		if TWOPI / no_unkozai >= 225.0:
			method = "d"
			isimp = 1
			_init_deep_space(epoch, eccsq, xpidot)

		# Set variables if not deep space.
		if isimp != 1:
			var cc1sq := cc1 * cc1
			d2 = 4.0 * ao * tsi * cc1sq
			var temp := d2 * tsi * cc1 / 3.0
			d3 = (17.0 * ao + sfour) * temp
			d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
			t3cof = d2 + 2.0 * cc1sq
			t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
			t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2 + 15.0 * cc1sq * (2.0 * d2 + cc1sq))

	propagate(0.0)


## dscom, dpper (init) and dsinit, inlined: they run once per satellite.
func _init_deep_space(epoch: float, eccsq: float, xpidot: float) -> void:
	var tc := 0.0
	var inclm := inclo

	# --- dscom ---
	const ZES := 0.01675
	const ZEL := 0.05490
	const C1SS := 2.9864797e-6
	const C1L := 4.7968065e-7
	const ZSINIS := 0.39785416
	const ZCOSIS := 0.91744867
	const ZCOSGS := 0.1945905
	const ZSINGS := -0.98088458

	var nm := no_unkozai
	var em := ecco
	var snodm := sin(nodeo)
	var cnodm := cos(nodeo)
	var sinomm := sin(argpo)
	var cosomm := cos(argpo)
	var sinim := sin(inclo)
	var cosim := cos(inclo)
	var emsq := em * em
	var betasq := 1.0 - emsq
	var rtemsq := sqrt(betasq)

	peo = 0.0
	pinco = 0.0
	plo = 0.0
	pgho = 0.0
	pho = 0.0
	var day := epoch + 18261.5 + tc / 1440.0
	var xnodce := fposmod(4.5236020 - 9.2422029e-4 * day, TWOPI)
	var stem := sin(xnodce)
	var ctem := cos(xnodce)
	var zcosil := 0.91375164 - 0.03568096 * ctem
	var zsinil := sqrt(1.0 - zcosil * zcosil)
	var zsinhl := 0.089683511 * stem / zsinil
	var zcoshl := sqrt(1.0 - zsinhl * zsinhl)
	var gam := 5.8351514 + 0.0019443680 * day
	var zx := 0.39785416 * stem / zsinil
	var zy := zcoshl * ctem + 0.91744867 * zsinhl * stem
	zx = atan2(zx, zy)
	zx = gam + zx - xnodce
	var zcosgl := cos(zx)
	var zsingl := sin(zx)

	# Solar terms first, then lunar.
	var zcosg := ZCOSGS
	var zsing := ZSINGS
	var zcosi := ZCOSIS
	var zsini := ZSINIS
	var zcosh := cnodm
	var zsinh := snodm
	var cc := C1SS
	var xnoi := 1.0 / nm

	var s1 := 0.0; var s2 := 0.0; var s3 := 0.0; var s4 := 0.0
	var s5 := 0.0; var s6 := 0.0; var s7 := 0.0
	var ss1 := 0.0; var ss2 := 0.0; var ss3 := 0.0; var ss4 := 0.0
	var ss5 := 0.0; var ss6 := 0.0; var ss7 := 0.0
	var z1 := 0.0; var z2 := 0.0; var z3 := 0.0
	var z11 := 0.0; var z12 := 0.0; var z13 := 0.0
	var z21 := 0.0; var z22 := 0.0; var z23 := 0.0
	var z31 := 0.0; var z32 := 0.0; var z33 := 0.0
	var sz1 := 0.0; var sz2 := 0.0; var sz3 := 0.0
	var sz11 := 0.0; var sz12 := 0.0; var sz13 := 0.0
	var sz21 := 0.0; var sz22 := 0.0; var sz23 := 0.0
	var sz31 := 0.0; var sz32 := 0.0; var sz33 := 0.0

	for lsflg in [1, 2]:
		var a1 := zcosg * zcosh + zsing * zcosi * zsinh
		var a3 := -zsing * zcosh + zcosg * zcosi * zsinh
		var a7 := -zcosg * zsinh + zsing * zcosi * zcosh
		var a8 := zsing * zsini
		var a9 := zsing * zsinh + zcosg * zcosi * zcosh
		var a10 := zcosg * zsini
		var a2 := cosim * a7 + sinim * a8
		var a4 := cosim * a9 + sinim * a10
		var a5 := -sinim * a7 + cosim * a8
		var a6 := -sinim * a9 + cosim * a10

		var x1 := a1 * cosomm + a2 * sinomm
		var x2 := a3 * cosomm + a4 * sinomm
		var x3 := -a1 * sinomm + a2 * cosomm
		var x4 := -a3 * sinomm + a4 * cosomm
		var x5 := a5 * sinomm
		var x6 := a6 * sinomm
		var x7 := a5 * cosomm
		var x8 := a6 * cosomm

		z31 = 12.0 * x1 * x1 - 3.0 * x3 * x3
		z32 = 24.0 * x1 * x2 - 6.0 * x3 * x4
		z33 = 12.0 * x2 * x2 - 3.0 * x4 * x4
		z1 = 3.0 * (a1 * a1 + a2 * a2) + z31 * emsq
		z2 = 6.0 * (a1 * a3 + a2 * a4) + z32 * emsq
		z3 = 3.0 * (a3 * a3 + a4 * a4) + z33 * emsq
		z11 = -6.0 * a1 * a5 + emsq * (-24.0 * x1 * x7 - 6.0 * x3 * x5)
		z12 = -6.0 * (a1 * a6 + a3 * a5) + emsq * (-24.0 * (x2 * x7 + x1 * x8) - 6.0 * (x3 * x6 + x4 * x5))
		z13 = -6.0 * a3 * a6 + emsq * (-24.0 * x2 * x8 - 6.0 * x4 * x6)
		z21 = 6.0 * a2 * a5 + emsq * (24.0 * x1 * x5 - 6.0 * x3 * x7)
		z22 = 6.0 * (a4 * a5 + a2 * a6) + emsq * (24.0 * (x2 * x5 + x1 * x6) - 6.0 * (x4 * x7 + x3 * x8))
		z23 = 6.0 * a4 * a6 + emsq * (24.0 * x2 * x6 - 6.0 * x4 * x8)
		z1 = z1 + z1 + betasq * z31
		z2 = z2 + z2 + betasq * z32
		z3 = z3 + z3 + betasq * z33
		s3 = cc * xnoi
		s2 = -0.5 * s3 / rtemsq
		s4 = s3 * rtemsq
		s1 = -15.0 * em * s4
		s5 = x1 * x3 + x2 * x4
		s6 = x2 * x3 + x1 * x4
		s7 = x2 * x4 - x1 * x3

		# Do lunar terms on the second pass.
		if lsflg == 1:
			ss1 = s1; ss2 = s2; ss3 = s3; ss4 = s4; ss5 = s5; ss6 = s6; ss7 = s7
			sz1 = z1; sz2 = z2; sz3 = z3
			sz11 = z11; sz12 = z12; sz13 = z13
			sz21 = z21; sz22 = z22; sz23 = z23
			sz31 = z31; sz32 = z32; sz33 = z33
			zcosg = zcosgl
			zsing = zsingl
			zcosi = zcosil
			zsini = zsinil
			zcosh = zcoshl * cnodm + zsinhl * snodm
			zsinh = snodm * zcoshl - cnodm * zsinhl
			cc = C1L

	zmol = fposmod(4.7199672 + 0.22997150 * day - gam, TWOPI)
	zmos = fposmod(6.2565837 + 0.017201977 * day, TWOPI)

	# Solar terms.
	se2 = 2.0 * ss1 * ss6
	se3 = 2.0 * ss1 * ss7
	si2 = 2.0 * ss2 * sz12
	si3 = 2.0 * ss2 * (sz13 - sz11)
	sl2 = -2.0 * ss3 * sz2
	sl3 = -2.0 * ss3 * (sz3 - sz1)
	sl4 = -2.0 * ss3 * (-21.0 - 9.0 * emsq) * ZES
	sgh2 = 2.0 * ss4 * sz32
	sgh3 = 2.0 * ss4 * (sz33 - sz31)
	sgh4 = -18.0 * ss4 * ZES
	sh2 = -2.0 * ss2 * sz22
	sh3 = -2.0 * ss2 * (sz23 - sz21)

	# Lunar terms.
	ee2 = 2.0 * s1 * s6
	e3 = 2.0 * s1 * s7
	xi2 = 2.0 * s2 * z12
	xi3 = 2.0 * s2 * (z13 - z11)
	xl2 = -2.0 * s3 * z2
	xl3 = -2.0 * s3 * (z3 - z1)
	xl4 = -2.0 * s3 * (-21.0 - 9.0 * emsq) * ZEL
	xgh2 = 2.0 * s4 * z32
	xgh3 = 2.0 * s4 * (z33 - z31)
	xgh4 = -18.0 * s4 * ZEL
	xh2 = -2.0 * s2 * z22
	xh3 = -2.0 * s2 * (z23 - z21)

	# --- dpper, init mode ---
	var p := _dpper(inclm, true, ecco, inclo, nodeo, argpo, mo)
	ecco = p[0]
	inclo = p[1]
	nodeo = p[2]
	argpo = p[3]
	mo = p[4]

	var argpm := 0.0
	var nodem := 0.0
	var mm := 0.0

	# --- dsinit ---
	const Q22 := 1.7891679e-6
	const Q31 := 2.1460748e-6
	const Q33 := 2.2123015e-7
	const ROOT22 := 1.7891679e-6
	const ROOT44 := 7.3636953e-9
	const ROOT54 := 2.1765803e-9
	const RPTIM := 4.37526908801129966e-3  # 7.29211514668855e-5 rad/s
	const ROOT32 := 3.7393792e-7
	const ROOT52 := 1.1428639e-7
	const ZNL := 1.5835218e-4
	const ZNS := 1.19459e-5

	# Deep space resonance: 1 = synchronous (GEO), 2 = half-day (Molniya, GPS).
	irez = 0
	if 0.0034906585 < nm and nm < 0.0052359877:
		irez = 1
	if 8.26e-3 <= nm and nm <= 9.24e-3 and em >= 0.5:
		irez = 2

	# Solar terms.
	var ses := ss1 * ZNS * ss5
	var sis := ss2 * ZNS * (sz11 + sz13)
	var sls := -ZNS * ss3 * (sz1 + sz3 - 14.0 - 6.0 * emsq)
	var sghs := ss4 * ZNS * (sz31 + sz33 - 6.0)
	var shs := -ZNS * ss2 * (sz21 + sz23)
	if inclm < 5.2359877e-2 or inclm > PI - 5.2359877e-2:
		shs = 0.0
	if sinim != 0.0:
		shs = shs / sinim
	var sgs := sghs - cosim * shs

	# Lunar terms.
	dedt = ses + s1 * ZNL * s5
	didt = sis + s2 * ZNL * (z11 + z13)
	dmdt = sls - ZNL * s3 * (z1 + z3 - 14.0 - 6.0 * emsq)
	var sghl := s4 * ZNL * (z31 + z33 - 6.0)
	var shll := -ZNL * s2 * (z21 + z23)
	if inclm < 5.2359877e-2 or inclm > PI - 5.2359877e-2:
		shll = 0.0
	domdt = sgs + sghl
	dnodt = shs
	if sinim != 0.0:
		domdt = domdt - cosim / sinim * shll
		dnodt = dnodt + shll / sinim

	# Deep space resonance effects.
	var dndt := 0.0
	var theta := fposmod(gsto + tc * RPTIM, TWOPI)
	em = em + dedt * t
	inclm = inclm + didt * t
	argpm = argpm + domdt * t
	nodem = nodem + dnodt * t
	mm = mm + dmdt * t

	if irez != 0:
		var aonv := pow(nm / XKE, X2O3)

		# Geopotential resonance for 12-hour orbits.
		if irez == 2:
			var cosisq := cosim * cosim
			var emo := em
			em = ecco
			var emsqo := emsq
			emsq = eccsq
			var eoc := em * emsq
			var g201 := -0.306 - (em - 0.64) * 0.440
			var g211: float; var g310: float; var g322: float
			var g410: float; var g422: float; var g520: float
			var g521: float; var g532: float; var g533: float
			if em <= 0.65:
				g211 = 3.616 - 13.2470 * em + 16.2900 * emsq
				g310 = -19.302 + 117.3900 * em - 228.4190 * emsq + 156.5910 * eoc
				g322 = -18.9068 + 109.7927 * em - 214.6334 * emsq + 146.5816 * eoc
				g410 = -41.122 + 242.6940 * em - 471.0940 * emsq + 313.9530 * eoc
				g422 = -146.407 + 841.8800 * em - 1629.014 * emsq + 1083.4350 * eoc
				g520 = -532.114 + 3017.977 * em - 5740.032 * emsq + 3708.2760 * eoc
			else:
				g211 = -72.099 + 331.819 * em - 508.738 * emsq + 266.724 * eoc
				g310 = -346.844 + 1582.851 * em - 2415.925 * emsq + 1246.113 * eoc
				g322 = -342.585 + 1554.908 * em - 2366.899 * emsq + 1215.972 * eoc
				g410 = -1052.797 + 4758.686 * em - 7193.992 * emsq + 3651.957 * eoc
				g422 = -3581.690 + 16178.110 * em - 24462.770 * emsq + 12422.520 * eoc
				if em > 0.715:
					g520 = -5149.66 + 29936.92 * em - 54087.36 * emsq + 31324.56 * eoc
				else:
					g520 = 1464.74 - 4664.75 * em + 3763.64 * emsq
			if em < 0.7:
				g533 = -919.22770 + 4988.6100 * em - 9064.7700 * emsq + 5542.21 * eoc
				g521 = -822.71072 + 4568.6173 * em - 8491.4146 * emsq + 5337.524 * eoc
				g532 = -853.66600 + 4690.2500 * em - 8624.7700 * emsq + 5341.4 * eoc
			else:
				g533 = -37995.780 + 161616.52 * em - 229838.20 * emsq + 109377.94 * eoc
				g521 = -51752.104 + 218913.95 * em - 309468.16 * emsq + 146349.42 * eoc
				g532 = -40023.880 + 170470.89 * em - 242699.48 * emsq + 115605.82 * eoc

			var sini2 := sinim * sinim
			var f220 := 0.75 * (1.0 + 2.0 * cosim + cosisq)
			var f221 := 1.5 * sini2
			var f321 := 1.875 * sinim * (1.0 - 2.0 * cosim - 3.0 * cosisq)
			var f322 := -1.875 * sinim * (1.0 + 2.0 * cosim - 3.0 * cosisq)
			var f441 := 35.0 * sini2 * f220
			var f442 := 39.3750 * sini2 * sini2
			var f522 := 9.84375 * sinim * (sini2 * (1.0 - 2.0 * cosim - 5.0 * cosisq)
					+ 0.33333333 * (-2.0 + 4.0 * cosim + 6.0 * cosisq))
			var f523 := sinim * (4.92187512 * sini2 * (-2.0 - 4.0 * cosim + 10.0 * cosisq)
					+ 6.56250012 * (1.0 + 2.0 * cosim - 3.0 * cosisq))
			var f542 := 29.53125 * sinim * (2.0 - 8.0 * cosim + cosisq * (-12.0 + 8.0 * cosim + 10.0 * cosisq))
			var f543 := 29.53125 * sinim * (-2.0 - 8.0 * cosim + cosisq * (12.0 + 8.0 * cosim - 10.0 * cosisq))
			var xno2 := nm * nm
			var ainv2 := aonv * aonv
			var temp1 := 3.0 * xno2 * ainv2
			var temp := temp1 * ROOT22
			d2201 = temp * f220 * g201
			d2211 = temp * f221 * g211
			temp1 = temp1 * aonv
			temp = temp1 * ROOT32
			d3210 = temp * f321 * g310
			d3222 = temp * f322 * g322
			temp1 = temp1 * aonv
			temp = 2.0 * temp1 * ROOT44
			d4410 = temp * f441 * g410
			d4422 = temp * f442 * g422
			temp1 = temp1 * aonv
			temp = temp1 * ROOT52
			d5220 = temp * f522 * g520
			d5232 = temp * f523 * g532
			temp = 2.0 * temp1 * ROOT54
			d5421 = temp * f542 * g521
			d5433 = temp * f543 * g533
			xlamo = fposmod(mo + nodeo + nodeo - theta - theta, TWOPI)
			xfact = mdot + dmdt + 2.0 * (nodedot + dnodt - RPTIM) - no_unkozai
			em = emo
			emsq = emsqo

		# Synchronous resonance terms.
		if irez == 1:
			var g200 := 1.0 + emsq * (-2.5 + 0.8125 * emsq)
			var g310 := 1.0 + 2.0 * emsq
			var g300 := 1.0 + emsq * (-6.0 + 6.60937 * emsq)
			var f220 := 0.75 * (1.0 + cosim) * (1.0 + cosim)
			var f311 := 0.9375 * sinim * sinim * (1.0 + 3.0 * cosim) - 0.75 * (1.0 + cosim)
			var f330 := 1.0 + cosim
			f330 = 1.875 * f330 * f330 * f330
			del1 = 3.0 * nm * nm * aonv * aonv
			del2 = 2.0 * del1 * f220 * g200 * Q22
			del3 = 3.0 * del1 * f330 * g300 * Q33 * aonv
			del1 = del1 * f311 * g310 * Q31 * aonv
			xlamo = fposmod(mo + nodeo + argpo - theta, TWOPI)
			xfact = mdot + xpidot - RPTIM + dmdt + domdt + dnodt - no_unkozai

		# Initialise the integrator.
		xli = xlamo
		xni = no_unkozai
		atime = 0.0
		nm = no_unkozai + dndt


## Lunar-solar periodics. Returns [ep, inclp, nodep, argpp, mp].
func _dpper(p_inclo: float, init: bool, ep: float, inclp: float, nodep: float,
		argpp: float, mp: float) -> PackedFloat64Array:
	const ZNS := 1.19459e-5
	const ZES := 0.01675
	const ZNL := 1.5835218e-4
	const ZEL := 0.05490

	# Solar terms.
	var zm := zmos + ZNS * t
	if init:
		zm = zmos
	var zf := zm + 2.0 * ZES * sin(zm)
	var sinzf := sin(zf)
	var f2 := 0.5 * sinzf * sinzf - 0.25
	var f3 := -0.5 * sinzf * cos(zf)
	var ses := se2 * f2 + se3 * f3
	var sis := si2 * f2 + si3 * f3
	var sls := sl2 * f2 + sl3 * f3 + sl4 * sinzf
	var sghs := sgh2 * f2 + sgh3 * f3 + sgh4 * sinzf
	var shs := sh2 * f2 + sh3 * f3

	# Lunar terms.
	zm = zmol + ZNL * t
	if init:
		zm = zmol
	zf = zm + 2.0 * ZEL * sin(zm)
	sinzf = sin(zf)
	f2 = 0.5 * sinzf * sinzf - 0.25
	f3 = -0.5 * sinzf * cos(zf)
	var sel := ee2 * f2 + e3 * f3
	var sil := xi2 * f2 + xi3 * f3
	var sll := xl2 * f2 + xl3 * f3 + xl4 * sinzf
	var sghl := xgh2 * f2 + xgh3 * f3 + xgh4 * sinzf
	var shll := xh2 * f2 + xh3 * f3

	var pe := ses + sel
	var pinc := sis + sil
	var pl := sls + sll
	var pgh := sghs + sghl
	var ph := shs + shll

	if not init:
		pe = pe - peo
		pinc = pinc - pinco
		pl = pl - plo
		pgh = pgh - pgho
		ph = ph - pho
		inclp = inclp + pinc
		ep = ep + pe
		var sinip := sin(inclp)
		var cosip := cos(inclp)

		# Apply periodics directly, or with the Lyddane modification at low inclination.
		if inclp >= 0.2:
			ph /= sinip
			pgh -= cosip * ph
			argpp += pgh
			nodep += ph
			mp += pl
		else:
			var sinop := sin(nodep)
			var cosop := cos(nodep)
			var alfdp := sinip * sinop
			var betdp := sinip * cosop
			var dalf := ph * cosop + pinc * cosip * sinop
			var dbet := -ph * sinop + pinc * cosip * cosop
			alfdp = alfdp + dalf
			betdp = betdp + dbet
			nodep = fmod(nodep, TWOPI)
			var xls := mp + argpp + pl + pgh + (cosip - pinc * sinip) * nodep
			var xnoh := nodep
			nodep = atan2(alfdp, betdp)
			if absf(xnoh - nodep) > PI:
				if nodep < xnoh:
					nodep = nodep + TWOPI
				else:
					nodep = nodep - TWOPI
			mp += pl
			argpp = xls - mp - cosip * nodep

	return PackedFloat64Array([ep, inclp, nodep, argpp, mp])


# --- sgp4 ---------------------------------------------------------------------------

## Propagate to tsince minutes from epoch. Fills r (km) and v (km/s) in TEME and returns
## the error code; on an error other than DECAYED, r and v are NAN.
func propagate(tsince: float) -> int:
	var vkmpersec := RADIUS_EARTH_KM * XKE / 60.0

	t = tsince
	error = Fault.NONE

	# Secular gravity and atmospheric drag.
	var xmdf := mo + mdot * t
	var argpdf := argpo + argpdot * t
	var nodedf := nodeo + nodedot * t
	var argpm := argpdf
	var mm := xmdf
	var t2 := t * t
	var nodem := nodedf + nodecf * t2
	var tempa := 1.0 - cc1 * t
	var tempe := bstar * cc4 * t
	var templ := t2cof * t2

	if isimp != 1:
		var delomg := omgcof * t
		var delmtemp := 1.0 + eta * cos(xmdf)
		var delm := xmcof * (delmtemp * delmtemp * delmtemp - delmo)
		var temp := delomg + delm
		mm = xmdf + temp
		argpm = argpdf - temp
		var t3 := t2 * t
		var t4 := t3 * t
		tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
		tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
		templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)

	var nm := no_unkozai
	var em := ecco
	var inclm := inclo
	if method == "d":
		var ds := _dspace(t, em, argpm, inclm, mm, nodem, nm)
		em = ds[0]
		argpm = ds[1]
		inclm = ds[2]
		mm = ds[3]
		nodem = ds[4]
		nm = ds[5]

	if nm <= 0.0:
		return _fail(Fault.MEAN_MOTION)

	var am := pow(XKE / nm, X2O3) * tempa * tempa
	nm = XKE / pow(am, 1.5)
	em = em - tempe

	if em >= 1.0 or em < -0.001:
		return _fail(Fault.ECCENTRICITY)
	# Avoid a divide by zero.
	if em < 1.0e-6:
		em = 1.0e-6
	mm = mm + no_unkozai * templ
	var xlm := mm + argpm + nodem
	nodem = fmod(nodem, TWOPI)
	argpm = fposmod(argpm, TWOPI)
	xlm = fposmod(xlm, TWOPI)
	mm = fposmod(xlm - argpm - nodem, TWOPI)

	# Lunar-solar periodics.
	var sinim := sin(inclm)
	var cosim := cos(inclm)
	var ep := em
	var xincp := inclm
	var argpp := argpm
	var nodep := nodem
	var mp := mm
	var sinip := sinim
	var cosip := cosim
	if method == "d":
		var p := _dpper(inclo, false, ep, xincp, nodep, argpp, mp)
		ep = p[0]
		xincp = p[1]
		nodep = p[2]
		argpp = p[3]
		mp = p[4]
		if xincp < 0.0:
			xincp = -xincp
			nodep = nodep + PI
			argpp = argpp - PI
		if ep < 0.0 or ep > 1.0:
			return _fail(Fault.PERTURBED_ECCENTRICITY)

	# Long period periodics.
	if method == "d":
		sinip = sin(xincp)
		cosip = cos(xincp)
		aycof = -0.5 * J3OJ2 * sinip
		if absf(cosip + 1.0) > 1.5e-12:
			xlcof = -0.25 * J3OJ2 * sinip * (3.0 + 5.0 * cosip) / (1.0 + cosip)
		else:
			xlcof = -0.25 * J3OJ2 * sinip * (3.0 + 5.0 * cosip) / TEMP4

	var axnl := ep * cos(argpp)
	var temp := 1.0 / (am * (1.0 - ep * ep))
	var aynl := ep * sin(argpp) + temp * aycof
	var xl := mp + argpp + nodep + temp * xlcof * axnl

	# Solve Kepler's equation.
	var u := fposmod(xl - nodep, TWOPI)
	var eo1 := u
	var tem5 := 9999.9
	var ktr := 1
	var sineo1 := 0.0
	var coseo1 := 0.0
	while absf(tem5) >= 1.0e-12 and ktr <= 10:
		sineo1 = sin(eo1)
		coseo1 = cos(eo1)
		tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
		tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
		if absf(tem5) >= 0.95:
			tem5 = 0.95 if tem5 > 0.0 else -0.95
		eo1 = eo1 + tem5
		ktr += 1

	# Short period preliminary quantities.
	var ecose := axnl * coseo1 + aynl * sineo1
	var esine := axnl * sineo1 - aynl * coseo1
	var el2 := axnl * axnl + aynl * aynl
	var pl := am * (1.0 - el2)
	if pl < 0.0:
		return _fail(Fault.SEMILATUS_RECTUM)

	var rl := am * (1.0 - ecose)
	var rdotl := sqrt(am) * esine / rl
	var rvdotl := sqrt(pl) / rl
	var betal := sqrt(1.0 - el2)
	temp = esine / (1.0 + betal)
	var sinu := am / rl * (sineo1 - aynl - axnl * temp)
	var cosu := am / rl * (coseo1 - axnl + aynl * temp)
	var su := atan2(sinu, cosu)
	var sin2u := (cosu + cosu) * sinu
	var cos2u := 1.0 - 2.0 * sinu * sinu
	temp = 1.0 / pl
	var temp1 := 0.5 * J2 * temp
	var temp2 := temp1 * temp

	# Update for short period periodics.
	if method == "d":
		var cosisq := cosip * cosip
		con41 = 3.0 * cosisq - 1.0
		x1mth2 = 1.0 - cosisq
		x7thm1 = 7.0 * cosisq - 1.0

	var mrt := rl * (1.0 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
	su = su - 0.25 * temp2 * x7thm1 * sin2u
	var xnode := nodep + 1.5 * temp2 * cosip * sin2u
	var xinc := xincp + 1.5 * temp2 * cosip * sinip * cos2u
	var mvt := rdotl - nm * temp1 * x1mth2 * sin2u / XKE
	var rvdot := rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / XKE

	# Orientation vectors.
	var sinsu := sin(su)
	var cossu := cos(su)
	var snod := sin(xnode)
	var cnod := cos(xnode)
	var sini := sin(xinc)
	var cosi := cos(xinc)
	var xmx := -snod * cosi
	var xmy := cnod * cosi
	var ux := xmx * sinsu + cnod * cossu
	var uy := xmy * sinsu + snod * cossu
	var uz := sini * sinsu
	var vx := xmx * cossu - cnod * sinsu
	var vy := xmy * cossu - snod * sinsu
	var vz := sini * cossu

	var mr := mrt * RADIUS_EARTH_KM
	r[0] = mr * ux
	r[1] = mr * uy
	r[2] = mr * uz
	v[0] = (mvt * ux + rvdot * vx) * vkmpersec
	v[1] = (mvt * uy + rvdot * vy) * vkmpersec
	v[2] = (mvt * uz + rvdot * vz) * vkmpersec

	# Still a position, but below the surface: the satellite has decayed.
	if mrt < 1.0:
		error = Fault.DECAYED
	return error


## Deep space secular effects and the resonance integrator. Returns
## [em, argpm, inclm, mm, nodem, nm]. Like python-sgp4 (and unlike the C++), the
## integrator state is not carried between calls: it always restarts from epoch, which
## is deterministic and cheap — 720-minute steps, so ~20 for a ten-day-old element set.
func _dspace(p_t: float, em: float, argpm: float, inclm: float, mm: float, nodem: float,
		nm: float) -> PackedFloat64Array:
	const FASX2 := 0.13130908
	const FASX4 := 2.8843198
	const FASX6 := 0.37448087
	const G22 := 5.7686396
	const G32 := 0.95240898
	const G44 := 1.8014998
	const G52 := 1.0508330
	const G54 := 4.4108898
	const RPTIM := 4.37526908801129966e-3
	const STEPP := 720.0
	const STEPN := -720.0
	const STEP2 := 259200.0

	var theta := fposmod(gsto + p_t * RPTIM, TWOPI)
	em = em + dedt * p_t
	inclm = inclm + didt * p_t
	argpm = argpm + domdt * p_t
	nodem = nodem + dnodt * p_t
	mm = mm + dmdt * p_t

	if irez != 0:
		var l_atime := 0.0
		var l_xni := no_unkozai
		var l_xli := xlamo
		var delt := STEPP if p_t > 0.0 else STEPN
		var ft := 0.0
		var xndt := 0.0
		var xldot := 0.0
		var xnddt := 0.0

		while true:
			if irez != 2:
				# Near-synchronous resonance terms.
				xndt = del1 * sin(l_xli - FASX2) + del2 * sin(2.0 * (l_xli - FASX4)) \
						+ del3 * sin(3.0 * (l_xli - FASX6))
				xldot = l_xni + xfact
				xnddt = del1 * cos(l_xli - FASX2) + 2.0 * del2 * cos(2.0 * (l_xli - FASX4)) \
						+ 3.0 * del3 * cos(3.0 * (l_xli - FASX6))
				xnddt = xnddt * xldot
			else:
				# Near half-day resonance terms.
				var xomi := argpo + argpdot * l_atime
				var x2omi := xomi + xomi
				var x2li := l_xli + l_xli
				xndt = (d2201 * sin(x2omi + l_xli - G22) + d2211 * sin(l_xli - G22)
						+ d3210 * sin(xomi + l_xli - G32) + d3222 * sin(-xomi + l_xli - G32)
						+ d4410 * sin(x2omi + x2li - G44) + d4422 * sin(x2li - G44)
						+ d5220 * sin(xomi + l_xli - G52) + d5232 * sin(-xomi + l_xli - G52)
						+ d5421 * sin(xomi + x2li - G54) + d5433 * sin(-xomi + x2li - G54))
				xldot = l_xni + xfact
				xnddt = (d2201 * cos(x2omi + l_xli - G22) + d2211 * cos(l_xli - G22)
						+ d3210 * cos(xomi + l_xli - G32) + d3222 * cos(-xomi + l_xli - G32)
						+ d5220 * cos(xomi + l_xli - G52) + d5232 * cos(-xomi + l_xli - G52)
						+ 2.0 * (d4410 * cos(x2omi + x2li - G44)
						+ d4422 * cos(x2li - G44) + d5421 * cos(xomi + x2li - G54)
						+ d5433 * cos(-xomi + x2li - G54)))
				xnddt = xnddt * xldot

			if absf(p_t - l_atime) >= STEPP:
				l_xli = l_xli + xldot * delt + xndt * STEP2
				l_xni = l_xni + xndt * delt + xnddt * STEP2
				l_atime = l_atime + delt
			else:
				ft = p_t - l_atime
				break

		nm = l_xni + xndt * ft + xnddt * ft * ft * 0.5
		var xl := l_xli + xldot * ft + xndt * ft * ft * 0.5
		if irez != 1:
			mm = xl - 2.0 * nodem + 2.0 * theta
		else:
			mm = xl - nodem - argpm + theta
		# dndt = nm - no_unkozai; nm = no_unkozai + dndt — a round trip, kept out.

	return PackedFloat64Array([em, argpm, inclm, mm, nodem, nm])


func _fail(code: Fault) -> int:
	error = code
	for i in 3:
		r[i] = NAN
		v[i] = NAN
	return error


# --- Time -----------------------------------------------------------------------------

## Greenwich Mean Sidereal Time (IAU 1982), radians, from a UT1 Julian date. UTC is
## within 0.9 s of UT1, which is 0.004° of Earth rotation — well inside the budget.
static func gstime(jdut1: float) -> float:
	var tut1 := (jdut1 - 2451545.0) / 36525.0
	var temp := -6.2e-6 * tut1 * tut1 * tut1 + 0.093104 * tut1 * tut1 \
			+ (876600.0 * 3600.0 + 8640184.812866) * tut1 + 67310.54841  # seconds
	return fposmod(temp * deg_to_rad(1.0) / 240.0, TWOPI)


static func _jday(year: int, mon: int, day: int, hr: int, minute: int, sec: float) -> float:
	return (367.0 * year
			- floorf(7.0 * (year + floorf((mon + 9.0) / 12.0)) * 0.25)
			+ floorf(275.0 * mon / 9.0)
			+ day + 1721013.5
			+ ((sec / 60.0 + minute) / 60.0 + hr) / 24.0)


static func _field(line: String, from: int, length: int) -> float:
	return line.substr(from, length).strip_edges().to_float()


## TLE's sign, five digits with an implied leading decimal point, then a signed exponent.
static func _implied_decimal(line: String, from: int) -> float:
	var mantissa := (line[from] + "." + line.substr(from + 1, 5)).strip_edges().to_float()
	return mantissa * pow(10.0, line.substr(from + 6, 2).strip_edges().to_int())


## Catalogue numbers past 99999 use "Alpha-5": a leading letter (I and O skipped).
static func _alpha5_to_int(s: String) -> int:
	s = s.strip_edges()
	if s.is_empty():
		return 0
	var c := s.unicode_at(0)
	if c >= 65 and c <= 90:  # A-Z
		var n := c - 55
		if c > 73:  # I
			n -= 1
		if c > 79:  # O
			n -= 1
		return n * 10000 + s.substr(1).to_int()
	return s.to_int()
