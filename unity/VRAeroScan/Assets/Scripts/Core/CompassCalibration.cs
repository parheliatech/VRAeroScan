using System;
using UnityEngine;

namespace VRAeroScan.Core
{
    /// <summary>
    /// Turns the head tracker's arbitrary yaw into a true-north heading.
    ///
    /// This is the crux of the whole app. If the heading is wrong by 10°, every marker
    /// is wrong by 10° and the app is useless — worse than useless, because it looks
    /// authoritative while pointing at empty sky.
    ///
    /// The problem, stated exactly: the glasses' IMU reads pitch and roll off gravity,
    /// so those are absolute and need no help. Yaw has no such reference. It is measured
    /// from wherever the device was pointing at power-on and it drifts. Meanwhile the
    /// phone's magnetometer does know true north but is not on your head. This class is
    /// the bridge, and it is a single number: <see cref="HeadingOffsetDeg"/>.
    ///
    /// Because only yaw is unreferenced, the correction is a rotation about world up
    /// alone. Never correct pitch or roll here — the IMU already has them right, and
    /// "fixing" them would introduce error rather than remove it.
    /// </summary>
    [Serializable]
    public class CompassCalibration
    {
        [Tooltip("Degrees added to the tracker's raw yaw to get a true-north heading.")]
        [SerializeField] private float headingOffsetDeg;

        [SerializeField] private bool isCalibrated;

        /// <summary>Degrees added to raw yaw to get true heading.</summary>
        public float HeadingOffsetDeg => headingOffsetDeg;

        /// <summary>False until a fix has been taken. Markers should not be trusted before then.</summary>
        public bool IsCalibrated => isCalibrated;

        /// <summary>When the last fix was taken, for drift warnings. Unity time, seconds.</summary>
        public float LastFixTime { get; private set; } = float.NegativeInfinity;

        /// <summary>How the current fix was obtained, for the UI to report honestly.</summary>
        public CalibrationSource Source { get; private set; } = CalibrationSource.None;

        /// <summary>
        /// Take a fix from the phone's magnetometer, with the phone held flat and
        /// pointed the same way the user is looking.
        ///
        /// <paramref name="magneticHeadingDeg"/> is what the phone reports — magnetic,
        /// not true. <paramref name="declinationDeg"/> converts it, positive east.
        /// Passing 0 for declination is a silent error of up to 20° depending on where
        /// you are, so callers should get a real value rather than defaulting it.
        /// </summary>
        public void CalibrateFromPhoneCompass(float magneticHeadingDeg, float rawYawDeg,
                                              float declinationDeg)
        {
            float trueHeading = (float)GeoMath.Wrap360(magneticHeadingDeg + declinationDeg);
            SetFromTrueHeading(trueHeading, rawYawDeg, CalibrationSource.PhoneCompass);
        }

        /// <summary>
        /// Take a fix by looking at something whose true bearing is known — a landmark,
        /// the sun, or an aircraft the app is already tracking. More accurate than a
        /// magnetometer, which is easily 5–15° off near metal or electronics.
        /// </summary>
        public void CalibrateFromKnownBearing(float trueBearingDeg, float rawYawDeg,
                                              CalibrationSource source = CalibrationSource.KnownBearing)
        {
            SetFromTrueHeading(trueBearingDeg, rawYawDeg, source);
        }

        private void SetFromTrueHeading(float trueHeadingDeg, float rawYawDeg,
                                        CalibrationSource source)
        {
            headingOffsetDeg = (float)GeoMath.Wrap360(trueHeadingDeg - rawYawDeg);
            isCalibrated = true;
            LastFixTime = Time.time;
            Source = source;
        }

        /// <summary>
        /// Walk the offset by hand. This is the safety net for IMU drift: the user
        /// nudges until a marker sits on the aircraft they can actually see. Cheap,
        /// crude, and the thing most likely to rescue a bad magnetometer fix.
        /// </summary>
        public void Nudge(float degrees)
        {
            headingOffsetDeg = (float)GeoMath.Wrap360(headingOffsetDeg + degrees);

            // A nudge is a real fix — it is the user asserting what they can see.
            isCalibrated = true;
            LastFixTime = Time.time;
            if (Source == CalibrationSource.None) Source = CalibrationSource.ManualNudge;
        }

        public void Reset()
        {
            headingOffsetDeg = 0f;
            isCalibrated = false;
            LastFixTime = float.NegativeInfinity;
            Source = CalibrationSource.None;
        }

        /// <summary>Raw tracker yaw to a true-north heading, [0, 360).</summary>
        public float TrueHeading(float rawYawDeg) =>
            (float)GeoMath.Wrap360(rawYawDeg + headingOffsetDeg);

        /// <summary>
        /// Raw tracker orientation to world orientation, where +Z is true north.
        ///
        /// Pre-multiplying by a rotation about world up applies the yaw correction in
        /// the world frame while leaving the gravity-referenced pitch and roll alone,
        /// which is exactly what is wanted. Post-multiplying would rotate about the
        /// device's own up axis and would corrupt the attitude whenever the head is
        /// tilted — a bug that looks fine while you are standing level and falls apart
        /// the moment you look up, which is the entire use case.
        /// </summary>
        public Quaternion ToWorldRotation(Quaternion rawOrientation) =>
            Quaternion.AngleAxis(headingOffsetDeg, Vector3.up) * rawOrientation;

        /// <summary>
        /// Seconds since the last fix, for prompting a re-sync. Drift makes a fix go
        /// stale in minutes, not hours.
        /// </summary>
        public float SecondsSinceFix =>
            isCalibrated ? Time.time - LastFixTime : float.PositiveInfinity;
    }

    public enum CalibrationSource
    {
        None,
        PhoneCompass,
        KnownBearing,
        Celestial,
        ManualNudge,
    }
}
