using System;
using UnityEngine;

namespace VRAeroScan.Core
{
    /// <summary>A position on or above the WGS84 ellipsoid.</summary>
    public readonly struct GeoPoint
    {
        public readonly double LatitudeDeg;
        public readonly double LongitudeDeg;
        public readonly double AltitudeMeters;

        public GeoPoint(double latitudeDeg, double longitudeDeg, double altitudeMeters)
        {
            LatitudeDeg = latitudeDeg;
            LongitudeDeg = longitudeDeg;
            AltitudeMeters = altitudeMeters;
        }

        public override string ToString() =>
            $"{LatitudeDeg:F5}, {LongitudeDeg:F5}, {AltitudeMeters:F0}m";
    }

    /// <summary>Where a target sits in the observer's sky.</summary>
    public readonly struct LookAngles
    {
        /// <summary>Degrees clockwise from TRUE north. 0 = N, 90 = E.</summary>
        public readonly double AzimuthDeg;

        /// <summary>Degrees above the observer's horizon. Negative = below it.</summary>
        public readonly double ElevationDeg;

        /// <summary>Straight-line (slant) distance, metres.</summary>
        public readonly double RangeMeters;

        public LookAngles(double azimuthDeg, double elevationDeg, double rangeMeters)
        {
            AzimuthDeg = azimuthDeg;
            ElevationDeg = elevationDeg;
            RangeMeters = rangeMeters;
        }

        public bool IsAboveHorizon => ElevationDeg > 0.0;

        public override string ToString() =>
            $"az {AzimuthDeg:F1}° el {ElevationDeg:F1}° rng {RangeMeters / 1000.0:F1}km";
    }

    /// <summary>
    /// Geodesy for turning an aircraft or satellite position into a direction to look.
    ///
    /// Everything here is double precision on purpose. A float carries ~7 significant
    /// digits, which at an Earth radius of 6.4e6 m leaves under a metre of resolution
    /// before any arithmetic — and ECEF subtraction of two nearby large numbers burns
    /// most of that. Convert to float only at the very end, for the unit direction
    /// vector handed to Unity.
    ///
    /// VALIDATED 2026-09-23 against live adsb.lol data, whose `dst`/`dir` fields give
    /// independent range and bearing from the query point. Across 7 aircraft:
    /// max azimuth error 0.06° (adsb.lol rounds `dir` to one decimal) and max distance
    /// error 0.02 nm. See scratchpad/geomath_proto.py for the harness.
    /// </summary>
    public static class GeoMath
    {
        // WGS84 ellipsoid
        private const double SemiMajorAxis = 6378137.0;
        private const double Flattening = 1.0 / 298.257223563;
        private const double EccentricitySq = Flattening * (2.0 - Flattening);

        /// <summary>Mean Earth radius, for great-circle work only — never for ECEF.</summary>
        private const double MeanRadius = 6371008.8;

        public const double MetersPerNauticalMile = 1852.0;
        public const double FeetToMeters = 0.3048;

        /// <summary>Earth-Centred Earth-Fixed cartesian metres.</summary>
        public static void GeodeticToEcef(in GeoPoint p, out double x, out double y, out double z)
        {
            double lat = p.LatitudeDeg * Math.PI / 180.0;
            double lon = p.LongitudeDeg * Math.PI / 180.0;

            double sinLat = Math.Sin(lat);
            double cosLat = Math.Cos(lat);

            // Radius of curvature in the prime vertical.
            double n = SemiMajorAxis / Math.Sqrt(1.0 - EccentricitySq * sinLat * sinLat);

            x = (n + p.AltitudeMeters) * cosLat * Math.Cos(lon);
            y = (n + p.AltitudeMeters) * cosLat * Math.Sin(lon);
            z = (n * (1.0 - EccentricitySq) + p.AltitudeMeters) * sinLat;
        }

        /// <summary>
        /// Rotate the observer-to-target vector into the observer's local
        /// East/North/Up tangent frame.
        /// </summary>
        public static void ToEnu(in GeoPoint observer, in GeoPoint target,
                                 out double east, out double north, out double up)
        {
            GeodeticToEcef(observer, out double ox, out double oy, out double oz);
            GeodeticToEcef(target, out double tx, out double ty, out double tz);

            double dx = tx - ox;
            double dy = ty - oy;
            double dz = tz - oz;

            double lat = observer.LatitudeDeg * Math.PI / 180.0;
            double lon = observer.LongitudeDeg * Math.PI / 180.0;
            double sinLat = Math.Sin(lat), cosLat = Math.Cos(lat);
            double sinLon = Math.Sin(lon), cosLon = Math.Cos(lon);

            east = -sinLon * dx + cosLon * dy;
            north = -sinLat * cosLon * dx - sinLat * sinLon * dy + cosLat * dz;
            up = cosLat * cosLon * dx + cosLat * sinLon * dy + sinLat * dz;
        }

        /// <summary>
        /// Where to look to see <paramref name="target"/> from <paramref name="observer"/>.
        ///
        /// Earth curvature is handled implicitly and correctly: because this works from
        /// the ECEF difference rotated into a local tangent frame, a distant low target
        /// falls below the horizon on its own. No curvature fudge factor is needed or
        /// wanted.
        /// </summary>
        public static LookAngles ToLookAngles(in GeoPoint observer, in GeoPoint target)
        {
            ToEnu(observer, target, out double e, out double n, out double u);

            double horizontal = Math.Sqrt(e * e + n * n);
            double azimuth = Math.Atan2(e, n) * 180.0 / Math.PI;
            if (azimuth < 0.0) azimuth += 360.0;

            double elevation = Math.Atan2(u, horizontal) * 180.0 / Math.PI;
            double range = Math.Sqrt(e * e + n * n + u * u);

            return new LookAngles(azimuth, elevation, range);
        }

        /// <summary>
        /// Unit direction in VRAeroScan's world frame: +Z is TRUE north, +X is east,
        /// +Y is up. Markers are placed along this; the camera rotates inside the frame.
        /// </summary>
        public static Vector3 SkyDirection(double azimuthDeg, double elevationDeg)
        {
            double az = azimuthDeg * Math.PI / 180.0;
            double el = elevationDeg * Math.PI / 180.0;
            double cosEl = Math.Cos(el);

            return new Vector3(
                (float)(cosEl * Math.Sin(az)),  // east
                (float)Math.Sin(el),            // up
                (float)(cosEl * Math.Cos(az))); // north
        }

        public static Vector3 SkyDirection(in LookAngles look) =>
            SkyDirection(look.AzimuthDeg, look.ElevationDeg);

        /// <summary>
        /// Great-circle distance (metres) and initial bearing (degrees true) along the
        /// surface. Only for cross-checking against feeds that report ground distance,
        /// such as adsb.lol's dst/dir — the renderer wants <see cref="ToLookAngles"/>.
        /// </summary>
        public static void GreatCircle(in GeoPoint observer, in GeoPoint target,
                                       out double distanceMeters, out double bearingDeg)
        {
            double lat1 = observer.LatitudeDeg * Math.PI / 180.0;
            double lon1 = observer.LongitudeDeg * Math.PI / 180.0;
            double lat2 = target.LatitudeDeg * Math.PI / 180.0;
            double lon2 = target.LongitudeDeg * Math.PI / 180.0;

            double dLat = lat2 - lat1;
            double dLon = lon2 - lon1;

            double sinHalfLat = Math.Sin(dLat / 2.0);
            double sinHalfLon = Math.Sin(dLon / 2.0);
            double a = sinHalfLat * sinHalfLat +
                       Math.Cos(lat1) * Math.Cos(lat2) * sinHalfLon * sinHalfLon;
            distanceMeters = 2.0 * MeanRadius * Math.Asin(Math.Sqrt(a));

            double y = Math.Sin(dLon) * Math.Cos(lat2);
            double x = Math.Cos(lat1) * Math.Sin(lat2) -
                       Math.Sin(lat1) * Math.Cos(lat2) * Math.Cos(dLon);
            bearingDeg = Math.Atan2(y, x) * 180.0 / Math.PI;
            if (bearingDeg < 0.0) bearingDeg += 360.0;
        }

        /// <summary>
        /// Move <paramref name="distanceMeters"/> along <paramref name="bearingDeg"/>
        /// from <paramref name="start"/>, keeping altitude. Spherical, which is ample
        /// for dead reckoning an aircraft over the seconds between feed updates.
        ///
        /// This exists because adsb.lol updates on a seconds-scale cadence while the
        /// display runs at frame rate. Without it, markers visibly jump.
        /// </summary>
        public static GeoPoint DestinationPoint(in GeoPoint start, double bearingDeg,
                                                double distanceMeters)
        {
            if (distanceMeters == 0.0) return start;

            double lat1 = start.LatitudeDeg * Math.PI / 180.0;
            double lon1 = start.LongitudeDeg * Math.PI / 180.0;
            double brg = bearingDeg * Math.PI / 180.0;
            double angular = distanceMeters / MeanRadius;

            double sinLat1 = Math.Sin(lat1), cosLat1 = Math.Cos(lat1);
            double sinAng = Math.Sin(angular), cosAng = Math.Cos(angular);

            double sinLat2 = sinLat1 * cosAng + cosLat1 * sinAng * Math.Cos(brg);
            double lat2 = Math.Asin(sinLat2);
            double lon2 = lon1 + Math.Atan2(Math.Sin(brg) * sinAng * cosLat1,
                                            cosAng - sinLat1 * sinLat2);

            double lonDeg = lon2 * 180.0 / Math.PI;
            // Keep longitude in [-180, 180] rather than letting it wind up.
            lonDeg = ((lonDeg + 540.0) % 360.0) - 180.0;

            return new GeoPoint(lat2 * 180.0 / Math.PI, lonDeg, start.AltitudeMeters);
        }

        /// <summary>Smallest signed difference between two bearings, in (-180, 180].</summary>
        public static double BearingDelta(double aDeg, double bDeg)
        {
            double d = (aDeg - bDeg + 180.0) % 360.0;
            if (d < 0.0) d += 360.0;
            return d - 180.0;
        }

        /// <summary>Wrap any angle into [0, 360).</summary>
        public static double Wrap360(double deg)
        {
            double d = deg % 360.0;
            return d < 0.0 ? d + 360.0 : d;
        }
    }
}
