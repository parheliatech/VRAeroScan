using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using VRAeroScan.Core;
using VRAeroScan.DataFeeds;
using VRAeroScan.Rendering;
using VRAeroScan.Tracking;
using VRAeroScan.UI;

namespace VRAeroScan.App
{
    /// <summary>
    /// The whole app, wired from one component on one empty GameObject.
    ///
    /// Drop this on an empty object in an empty scene and press Play. It builds the
    /// sky rig, the ghost cardinals, the touch calibration, the aircraft feed and the
    /// marker pool, and picks a head tracker: any <see cref="IHeadTracker"/> already on
    /// this GameObject wins (that is where the Viture binding will go), otherwise the
    /// mouse-driven <see cref="MockHeadTracker"/> is added so the pipeline runs at a desk.
    ///
    /// Each frame it dead-reckons every aircraft to now, turns that into look angles
    /// from the observer, and places a pooled marker there. Aircraft positions are
    /// recomputed per frame rather than per poll because the look angle of a nearby
    /// aircraft changes by degrees per second — polling cadence would make it hop.
    /// </summary>
    [DefaultExecutionOrder(-100)]
    public class AppBootstrap : MonoBehaviour
    {
        [Header("Observer")]
        [Tooltip("Use the phone's GPS. Off, or when GPS is unavailable (the editor), " +
                 "the manual position below is used.")]
        [SerializeField] private bool useDeviceGps = true;

        [Tooltip("Manual observer latitude, degrees. Set this to where you are for " +
                 "desk testing — the markers are only checkable against real aircraft " +
                 "if the observer is real.")]
        [SerializeField] private double manualLatitudeDeg = 34.0522;

        [SerializeField] private double manualLongitudeDeg = -118.2437;

        [Tooltip("Manual observer altitude, metres.")]
        [SerializeField] private double manualAltitudeMeters = 90;

        [Header("Aircraft")]
        [Tooltip("Hide aircraft reporting on the ground. They are almost always below " +
                 "the local horizon anyway, and clutter the airport direction when not.")]
        [SerializeField] private bool hideOnGround = true;

        [Tooltip("Hide aircraft further than this, nautical miles. The feed radius " +
                 "decides what is fetched; this decides what is drawn.")]
        [SerializeField] private float maxDrawRangeNm = 60f;

        [Header("Debug")]
        [Tooltip("On-screen readout of calibration, heading and feed status. Off on " +
                 "device by default: on the glasses, text is light in your eyes.")]
        [SerializeField] private bool showDebugHud = true;

        private SkyRig _rig;
        private CompassCalibration _calibration;
        private CardinalMarkers _cardinals;
        private TouchHorizonControl _horizonControl;
        private AdsbService _adsb;

        private GeoPoint _observer;
        private string _observerSource = "manual";
        private string _lastError;

        private readonly Dictionary<string, SkyMarker> _active = new Dictionary<string, SkyMarker>();
        private readonly Dictionary<string, Aircraft> _labelledAs = new Dictionary<string, Aircraft>();
        private readonly Stack<SkyMarker> _pool = new Stack<SkyMarker>();
        private readonly HashSet<string> _seenThisFrame = new HashSet<string>();
        private readonly List<string> _toRelease = new List<string>();

        private void Awake()
        {
            _observer = new GeoPoint(manualLatitudeDeg, manualLongitudeDeg, manualAltitudeMeters);
            if (!Application.isEditor) showDebugHud = false;

            IHeadTracker tracker = FindTracker();
            _calibration = new CompassCalibration();

            _rig = GetOrAdd<SkyRig>(gameObject);
            _rig.Initialize(tracker, _calibration);

            _cardinals = new GameObject("Cardinals").AddComponent<CardinalMarkers>();
            _cardinals.transform.SetParent(_rig.transform, false);

            _horizonControl = GetOrAdd<TouchHorizonControl>(gameObject);
            _horizonControl.Initialize(_calibration, _cardinals);

            _adsb = GetOrAdd<AdsbService>(gameObject);
            _adsb.OnError += message => _lastError = message;
            _adsb.OnAircraftUpdated += _ => _lastError = null;
        }

        private void Start()
        {
            // After SkyRig.Awake has built the camera and marker root.
            _cardinals.Initialize(_rig);

            if (useDeviceGps) StartCoroutine(StartGps());
            _adsb.StartPolling(() => _observer);
        }

        /// <summary>
        /// Prefer a real tracker if one has been added to this GameObject; fall back to
        /// the mock so nothing about the hardware blocks work on the pipeline.
        /// </summary>
        private IHeadTracker FindTracker()
        {
            foreach (MonoBehaviour b in GetComponents<MonoBehaviour>())
            {
                if (b is IHeadTracker t && !(b is MockHeadTracker)) return t;
            }

            if (!Application.isEditor)
            {
                Debug.LogWarning("[AppBootstrap] No head tracker found; using the mouse " +
                                 "mock. On the glasses, markers will not follow your head.");
            }
            return GetOrAdd<MockHeadTracker>(gameObject);
        }

        private IEnumerator StartGps()
        {
#if UNITY_ANDROID
            if (!UnityEngine.Android.Permission.HasUserAuthorizedPermission(
                    UnityEngine.Android.Permission.FineLocation))
            {
                UnityEngine.Android.Permission.RequestUserPermission(
                    UnityEngine.Android.Permission.FineLocation);

                // The permission dialog is asynchronous; give the user time to answer.
                float until = Time.realtimeSinceStartup + 30f;
                while (!UnityEngine.Android.Permission.HasUserAuthorizedPermission(
                           UnityEngine.Android.Permission.FineLocation)
                       && Time.realtimeSinceStartup < until)
                {
                    yield return new WaitForSecondsRealtime(0.5f);
                }
            }
#endif
            if (!Input.location.isEnabledByUser)
            {
                _observerSource = "manual (location off)";
                yield break;
            }

            // Ten metres is far better than the pointing needs: at 1 nm an observer
            // error of 10 m is a third of a degree, and most aircraft are further.
            Input.location.Start(10f, 10f);

            float timeout = Time.realtimeSinceStartup + 20f;
            while (Input.location.status == LocationServiceStatus.Initializing
                   && Time.realtimeSinceStartup < timeout)
            {
                yield return new WaitForSecondsRealtime(0.5f);
            }

            if (Input.location.status != LocationServiceStatus.Running)
            {
                _observerSource = $"manual (GPS {Input.location.status})";
                yield break;
            }

            // Keep following the fix. The feed query reads _observer through a
            // delegate, so it follows too.
            while (Input.location.status == LocationServiceStatus.Running)
            {
                LocationInfo fix = Input.location.lastData;
                _observer = new GeoPoint(fix.latitude, fix.longitude, fix.altitude);
                _observerSource = $"GPS ±{fix.horizontalAccuracy:F0}m";
                yield return new WaitForSecondsRealtime(2f);
            }

            _observerSource = "manual (GPS lost)";
        }

        private void Update()
        {
            UpdateAircraftMarkers();
        }

        private void UpdateAircraftMarkers()
        {
            float now = Time.time;
            double maxRangeMeters = maxDrawRangeNm * GeoMath.MetersPerNauticalMile;

            // While the user is dragging the sky, dim the aircraft so the ghost N is
            // the brightest thing in view — it is what they are lining up.
            float brightness = _horizonControl.IsAdjusting ? 0.35f : 1f;

            _seenThisFrame.Clear();
            foreach (Aircraft ac in _adsb.Aircraft)
            {
                if (hideOnGround && ac.OnGround) continue;

                LookAngles look = GeoMath.ToLookAngles(_observer, ac.PositionAt(now));
                if (look.RangeMeters > maxRangeMeters) continue;

                // Below the horizon is kept, not skipped: SkyMarker fades it out over
                // the last degree and a half, so a climbing aircraft rises into view
                // instead of popping.
                if (look.ElevationDeg < -2.0) continue;

                _seenThisFrame.Add(ac.Icao24);

                if (!_active.TryGetValue(ac.Icao24, out SkyMarker marker))
                {
                    marker = Acquire(SkyMarkerKind.Aircraft);
                    _active[ac.Icao24] = marker;
                    _labelledAs.Remove(ac.Icao24);
                }

                // AdsbService replaces the Aircraft object on every poll, so a new
                // reference means new data and the label needs rebuilding. Comparing
                // references keeps string formatting out of the per-frame path.
                if (!_labelledAs.TryGetValue(ac.Icao24, out Aircraft labelled) || labelled != ac)
                {
                    marker.Configure(SkyMarker.ColorFor(ac.Class), SkyMarker.LabelFor(ac, look));
                    _labelledAs[ac.Icao24] = ac;
                }

                marker.SetBrightness(brightness);
                marker.SetLook(look);
            }

            // Return markers whose aircraft left the feed, the range, or the sky.
            _toRelease.Clear();
            foreach (string key in _active.Keys)
            {
                if (!_seenThisFrame.Contains(key)) _toRelease.Add(key);
            }
            foreach (string key in _toRelease)
            {
                Release(_active[key]);
                _active.Remove(key);
                _labelledAs.Remove(key);
            }
        }

        private SkyMarker Acquire(SkyMarkerKind kind)
        {
            // One pool for now; satellites will want their own once they exist, since
            // the outline mesh differs by kind.
            SkyMarker marker = _pool.Count > 0 ? _pool.Pop() : SkyMarker.Create(_rig, kind);
            marker.SetActive(true);
            return marker;
        }

        private void Release(SkyMarker marker)
        {
            marker.SetActive(false);
            _pool.Push(marker);
        }

        private void OnDestroy()
        {
            if (Input.location.status == LocationServiceStatus.Running) Input.location.Stop();
        }

        private void OnGUI()
        {
            if (!showDebugHud) return;

            string cal = _calibration.IsCalibrated
                ? $"{_calibration.Source}, {_calibration.SecondsSinceFix:F0}s ago"
                : "NOT CALIBRATED — drag until the N sits on true north";

            string feed = _lastError ?? (_adsb.LastSuccessfulPoll > 0f
                ? $"{_adsb.Aircraft.Count} aircraft, {_active.Count} drawn, " +
                  $"polled {Time.time - _adsb.LastSuccessfulPoll:F0}s ago"
                : "waiting for first poll");

            GUI.Label(new Rect(10, 10, 900, 110),
                $"Heading {_rig.CurrentHeadingDeg:F1}°   offset {_calibration.HeadingOffsetDeg:F1}°\n" +
                $"Calibration: {cal}\n" +
                $"Observer: {_observer} ({_observerSource})\n" +
                $"Feed: {feed}\n" +
                "Right-drag look · Left-drag turn sky (Shift = fine) · ←/→ nudge");
        }

        private static T GetOrAdd<T>(GameObject go) where T : Component =>
            go.TryGetComponent(out T existing) ? existing : go.AddComponent<T>();
    }
}
