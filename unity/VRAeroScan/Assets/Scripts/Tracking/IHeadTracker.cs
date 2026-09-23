using UnityEngine;

namespace VRAeroScan.Tracking
{
    /// <summary>
    /// A source of head orientation.
    ///
    /// Everything this returns is in the DEVICE's own reference frame, not the world's.
    /// Pitch and roll are absolute, because an IMU reads them off gravity. Yaw is not:
    /// it is measured from wherever the device happened to be pointing at power-on, and
    /// it drifts. Turning that into a true-north heading is
    /// <see cref="Core.CompassCalibration"/>'s job, and nothing here should try to do it.
    ///
    /// This interface exists so the geometry, data and rendering pipeline can be built
    /// and debugged on the desktop against <see cref="MockHeadTracker"/>, long before
    /// the Viture display path is resolved. Unresolved hardware must not block the maths.
    /// </summary>
    public interface IHeadTracker
    {
        /// <summary>False when the device is absent or not yet connected.</summary>
        bool IsAvailable { get; }

        /// <summary>
        /// Orientation in the device's own frame. Yaw is arbitrary; see the note above.
        /// </summary>
        Quaternion RawOrientation { get; }

        /// <summary>Degrees of yaw in the device's own frame, [0, 360).</summary>
        float RawYawDeg { get; }

        /// <summary>Pump the underlying device. Call once per frame.</summary>
        void Tick();
    }
}
