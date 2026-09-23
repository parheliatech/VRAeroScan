using UnityEngine;
using VRAeroScan.Core;
using VRAeroScan.Tracking;

namespace VRAeroScan.Rendering
{
    /// <summary>
    /// The world-fixed frame everything in the sky hangs in, and the camera that looks
    /// around inside it.
    ///
    /// The frame IS Unity world space, deliberately: +Z is true north, +X is east,
    /// +Y is up, and this transform stays at the origin with identity rotation. That
    /// keeps <see cref="GeoMath.SkyDirection"/>'s output directly usable as a world
    /// position with no intermediate transform to get wrong.
    ///
    /// Markers never move with your head. The CAMERA rotates inside the fixed frame,
    /// which is what makes a marker stay glued to the real aircraft as you turn. The
    /// inverse arrangement — rotating the sky around a fixed camera — looks identical
    /// on a monitor and falls apart in stereo, because the markers would swim against
    /// the real world seen through the lenses.
    ///
    /// Everything sits on a dome of fixed <see cref="skyRadius"/> rather than at true
    /// distance. At true scale a 737 at 30 nm is sub-pixel, and a satellite at 400 km
    /// is far beyond any sane far-plane. Range is communicated by the label, not by
    /// depth. A large radius also means near-zero stereo disparity, which is correct:
    /// distant sky objects should converge at infinity, and anything closer would
    /// fight the Viture's fixed focal plane and be uncomfortable to look at.
    /// </summary>
    [DefaultExecutionOrder(-50)]
    public class SkyRig : MonoBehaviour
    {
        [Header("Sky")]
        [Tooltip("Radius of the marker dome, metres. Large enough that stereo disparity " +
                 "is effectively zero, small enough to sit inside the far plane.")]
        [SerializeField] private float skyRadius = 500f;

        [Header("Camera")]
        [Tooltip("Left empty, the main camera is used, or one is created.")]
        [SerializeField] private Camera targetCamera;

        [Tooltip("Configure the camera for additive see-through AR: clear to black, " +
                 "no skybox. Black is invisible on the Viture's optics, so anything " +
                 "other than black clears the real world to a grey haze.")]
        [SerializeField] private bool configureCameraForAr = true;

        [Header("Debug")]
        [Tooltip("Draw a faint horizon ring. Useful on the desktop, usually noise in AR.")]
        [SerializeField] private bool showHorizonRing;

        private IHeadTracker _tracker;
        private CompassCalibration _calibration;
        private Transform _markerRoot;
        private LineRenderer _horizonRing;

        /// <summary>The calibration bridging tracker yaw to true north.</summary>
        public CompassCalibration Calibration => _calibration;

        public IHeadTracker HeadTracker => _tracker;
        public float SkyRadius => skyRadius;

        /// <summary>Parent for all sky markers, so they can be cleared in one go.</summary>
        public Transform MarkerRoot => _markerRoot;

        /// <summary>The camera looking around inside the frame.</summary>
        public Camera Camera => targetCamera;

        /// <summary>
        /// Where the user is currently facing, degrees true. Meaningless until
        /// calibration has happened, which <see cref="CompassCalibration.IsCalibrated"/>
        /// reports.
        /// </summary>
        public float CurrentHeadingDeg =>
            _tracker != null && _calibration != null
                ? _calibration.TrueHeading(_tracker.RawYawDeg)
                : 0f;

        private void Awake()
        {
            // The frame must be the identity, or SkyDirection's output stops being a
            // world position and every marker lands somewhere subtly wrong.
            transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            transform.localScale = Vector3.one;

            _markerRoot = new GameObject("Markers").transform;
            _markerRoot.SetParent(transform, false);

            EnsureCamera();
        }

        private void Start()
        {
            if (showHorizonRing) BuildHorizonRing();
        }

        /// <summary>
        /// Supply the head tracker and calibration. Kept out of Awake so the app can
        /// choose between the real device and <see cref="MockHeadTracker"/> at runtime.
        /// </summary>
        public void Initialize(IHeadTracker tracker, CompassCalibration calibration)
        {
            _tracker = tracker;
            _calibration = calibration ?? new CompassCalibration();
        }

        private void EnsureCamera()
        {
            if (targetCamera == null) targetCamera = Camera.main;

            if (targetCamera == null)
            {
                var go = new GameObject("SkyCamera");
                go.transform.SetParent(transform, false);
                targetCamera = go.AddComponent<Camera>();
                go.tag = "MainCamera";
            }

            targetCamera.transform.position = Vector3.zero;

            if (!configureCameraForAr) return;

            // Black, not a skybox. On an additive see-through display every non-black
            // pixel is light added over the real world, so a skybox would paint the
            // actual sky out.
            targetCamera.clearFlags = CameraClearFlags.SolidColor;
            targetCamera.backgroundColor = Color.black;

            // The dome is the only thing in the scene; the far plane just has to clear it.
            targetCamera.nearClipPlane = 0.1f;
            targetCamera.farClipPlane = skyRadius * 2f;
        }

        private void LateUpdate()
        {
            if (_tracker == null || _calibration == null) return;

            _tracker.Tick();
            if (!_tracker.IsAvailable) return;

            // LateUpdate so the pose is applied after any input that adjusted the
            // calibration this frame, which keeps dragging the horizon feeling direct
            // rather than a frame behind.
            targetCamera.transform.rotation =
                _calibration.ToWorldRotation(_tracker.RawOrientation);
        }

        /// <summary>World position for a sky direction, on the marker dome.</summary>
        public Vector3 PositionFor(double azimuthDeg, double elevationDeg) =>
            GeoMath.SkyDirection(azimuthDeg, elevationDeg) * skyRadius;

        public Vector3 PositionFor(in LookAngles look) =>
            GeoMath.SkyDirection(look.AzimuthDeg, look.ElevationDeg) * skyRadius;

        /// <summary>
        /// Angle between where the user is looking and a sky direction, in degrees.
        /// Used for decluttering and for off-screen indicators, both of which the 46°
        /// field of view makes necessary rather than optional.
        /// </summary>
        public float AngleFromCentre(double azimuthDeg, double elevationDeg)
        {
            Vector3 dir = GeoMath.SkyDirection(azimuthDeg, elevationDeg);
            return Vector3.Angle(targetCamera.transform.forward, dir);
        }

        private void BuildHorizonRing()
        {
            const int segments = 72;

            var go = new GameObject("HorizonRing");
            go.transform.SetParent(transform, false);

            _horizonRing = go.AddComponent<LineRenderer>();
            _horizonRing.useWorldSpace = false;
            _horizonRing.loop = true;
            _horizonRing.positionCount = segments;
            _horizonRing.widthMultiplier = skyRadius * 0.002f;
            _horizonRing.material = ArVisuals.UnlitTransparent();
            _horizonRing.startColor = _horizonRing.endColor = new Color(0.3f, 0.5f, 0.6f, 0.25f);
            _horizonRing.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;

            for (int i = 0; i < segments; i++)
            {
                float az = 360f * i / segments;
                _horizonRing.SetPosition(i, GeoMath.SkyDirection(az, 0.0) * skyRadius);
            }
        }
    }
}
