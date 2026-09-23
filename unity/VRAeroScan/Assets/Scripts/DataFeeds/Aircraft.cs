using System;
using Newtonsoft.Json.Linq;
using UnityEngine;
using VRAeroScan.Core;

namespace VRAeroScan.DataFeeds
{
    /// <summary>
    /// One aircraft as adsb.lol reports it, plus what VRAeroScan needs on top.
    ///
    /// Parsed with Newtonsoft rather than Unity's JsonUtility, because `alt_baro` is
    /// mixed-type — a number when airborne, the string "ground" when not. JsonUtility
    /// cannot express that, and fails quietly rather than loudly, which is worse.
    /// </summary>
    public class Aircraft
    {
        /// <summary>ICAO 24-bit address. The stable identity across updates.</summary>
        public string Icao24 { get; private set; }

        public string Callsign { get; private set; }
        public string Registration { get; private set; }

        /// <summary>ICAO type designator, e.g. "A321", "C206". May be null.</summary>
        public string TypeCode { get; private set; }

        /// <summary>ADS-B emitter category, e.g. "A1".."A7". May be null.</summary>
        public string EmitterCategory { get; private set; }

        public double LatitudeDeg { get; private set; }
        public double LongitudeDeg { get; private set; }

        /// <summary>Barometric altitude in feet. Zero when <see cref="OnGround"/>.</summary>
        public double AltitudeFeet { get; private set; }

        public bool OnGround { get; private set; }

        public double GroundSpeedKnots { get; private set; }

        /// <summary>Direction of travel, degrees true.</summary>
        public double TrackDeg { get; private set; }

        /// <summary>Seconds since this position was actually observed, per the feed.</summary>
        public double PositionAgeSeconds { get; private set; }

        public AircraftClass Class { get; internal set; } = AircraftClass.Unknown;

        /// <summary>Unity time when this update was received, for dead reckoning.</summary>
        public float ReceivedAt { get; private set; }

        public GeoPoint Position =>
            new GeoPoint(LatitudeDeg, LongitudeDeg, AltitudeFeet * GeoMath.FeetToMeters);

        /// <summary>
        /// Where the aircraft probably is now, given where it was and how it was moving.
        ///
        /// The feed arrives every few seconds; the display runs at frame rate. Without
        /// this, markers teleport. This is a straight constant-velocity extrapolation —
        /// no turn rate, no vertical rate — which is honest for a few seconds and
        /// increasingly wrong past that, hence <paramref name="maxExtrapolationSeconds"/>.
        /// </summary>
        public GeoPoint PositionAt(float unityTime, float maxExtrapolationSeconds = 10f)
        {
            if (OnGround || GroundSpeedKnots <= 0.0) return Position;

            float dt = unityTime - ReceivedAt;
            if (dt <= 0f) return Position;
            dt = Mathf.Min(dt, maxExtrapolationSeconds);

            double metersPerSecond = GroundSpeedKnots * GeoMath.MetersPerNauticalMile / 3600.0;
            return GeoMath.DestinationPoint(Position, TrackDeg, metersPerSecond * dt);
        }

        /// <summary>
        /// Parse one element of the feed's "ac" array. Returns null for entries with no
        /// usable position, which the feed does emit.
        /// </summary>
        public static Aircraft FromJson(JObject o)
        {
            if (o == null) return null;

            JToken lat = o["lat"], lon = o["lon"];
            if (lat == null || lon == null) return null;

            var ac = new Aircraft
            {
                Icao24 = (string)o["hex"],
                Callsign = ((string)o["flight"])?.Trim(),
                Registration = (string)o["r"],
                TypeCode = (string)o["t"],
                EmitterCategory = (string)o["category"],
                LatitudeDeg = (double)lat,
                LongitudeDeg = (double)lon,
                GroundSpeedKnots = ToDouble(o["gs"]),
                PositionAgeSeconds = ToDouble(o["seen_pos"]),
                ReceivedAt = Time.time,
            };

            if (string.IsNullOrEmpty(ac.Icao24)) return null;

            // "track" is absent for aircraft on the ground, which report "true_heading".
            ac.TrackDeg = o["track"] != null ? ToDouble(o["track"]) : ToDouble(o["true_heading"]);

            // The mixed-type field. A number when airborne, the string "ground" when not.
            JToken alt = o["alt_baro"];
            if (alt == null || alt.Type == JTokenType.Null)
            {
                ac.OnGround = false;
                ac.AltitudeFeet = 0.0;
            }
            else if (alt.Type == JTokenType.String)
            {
                ac.OnGround = string.Equals((string)alt, "ground", StringComparison.OrdinalIgnoreCase);
                ac.AltitudeFeet = 0.0;
            }
            else
            {
                ac.AltitudeFeet = (double)alt;
                ac.OnGround = false;
            }

            ac.Class = AircraftClassifier.Classify(ac);
            return ac;
        }

        private static double ToDouble(JToken t)
        {
            if (t == null || t.Type == JTokenType.Null) return 0.0;
            if (t.Type == JTokenType.String)
                return double.TryParse((string)t, out double parsed) ? parsed : 0.0;
            return (double)t;
        }

        public string DisplayName =>
            !string.IsNullOrEmpty(Callsign) ? Callsign
            : !string.IsNullOrEmpty(Registration) ? Registration
            : Icao24;

        public override string ToString() =>
            $"{DisplayName} [{TypeCode ?? "?"}] {AltitudeFeet:F0}ft {Class}";
    }
}
