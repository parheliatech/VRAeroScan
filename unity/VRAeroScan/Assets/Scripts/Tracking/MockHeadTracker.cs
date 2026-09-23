using UnityEngine;

namespace VRAeroScan.Tracking
{
    /// <summary>
    /// Mouse-and-keyboard head tracking, so the whole pipeline can be flown at a desk.
    ///
    /// Hold right mouse button and move to look around; scroll to zoom the field of
    /// view. This is the tracker the aircraft pipeline is developed against — point it
    /// at a known bearing and check the markers land where the real aircraft are.
    ///
    /// It deliberately imitates the real device's awkwardness: <see cref="RawYawDeg"/>
    /// starts at <see cref="startingYawDeg"/> rather than at north, so calibration is
    /// exercised on the desktop instead of being a surprise on the hardware. Set
    /// <see cref="simulatedDriftDegPerMinute"/> to rehearse the drift problem too.
    /// </summary>
    public class MockHeadTracker : MonoBehaviour, IHeadTracker
    {
        [Header("Look")]
        [SerializeField] private float mouseSensitivity = 3f;
        [SerializeField] private bool requireRightMouseButton = true;

        [Header("Imitate the real device")]
        [Tooltip("Yaw the tracker reports at startup. Non-zero on purpose: the Viture " +
                 "IMU's yaw origin is wherever it powered on, never true north.")]
        [SerializeField] private float startingYawDeg = 137f;

        [Tooltip("Degrees of yaw drift per minute, to rehearse the drift problem. " +
                 "Set 0 for a clean rig.")]
        [SerializeField] private float simulatedDriftDegPerMinute = 0f;

        private float _yaw;
        private float _pitch;
        private float _accumulatedDrift;

        public bool IsAvailable => true;

        public Quaternion RawOrientation => Quaternion.Euler(_pitch, _yaw + _accumulatedDrift, 0f);

        public float RawYawDeg
        {
            get
            {
                float y = (_yaw + _accumulatedDrift) % 360f;
                return y < 0f ? y + 360f : y;
            }
        }

        private void Awake()
        {
            _yaw = startingYawDeg;
        }

        public void Tick()
        {
            if (simulatedDriftDegPerMinute != 0f)
            {
                _accumulatedDrift += simulatedDriftDegPerMinute * Time.deltaTime / 60f;
            }

            if (requireRightMouseButton && !Input.GetMouseButton(1))
            {
                return;
            }

            _yaw += Input.GetAxis("Mouse X") * mouseSensitivity;

            // Subtracting gives the conventional "mouse up looks up".
            _pitch -= Input.GetAxis("Mouse Y") * mouseSensitivity;

            // Real heads do not go past straight up or straight down.
            _pitch = Mathf.Clamp(_pitch, -89f, 89f);
        }
    }
}
