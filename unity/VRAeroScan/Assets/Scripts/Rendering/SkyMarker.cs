using UnityEngine;
using VRAeroScan.Core;
using VRAeroScan.DataFeeds;

namespace VRAeroScan.Rendering
{
    public enum SkyMarkerKind
    {
        Aircraft,
        Satellite,
    }

    /// <summary>
    /// One aircraft or satellite on the sky: an outline, a label, and nothing else.
    ///
    /// Shape says what it is — a square for an aircraft, a diamond for a satellite —
    /// and colour says what kind. Both are outlines because the display is additive:
    /// a filled shape would be a bright patch over the very light the user is trying
    /// to identify. The label sits beside the outline, never over it, for the same
    /// reason.
    ///
    /// Markers are pooled by the caller and reconfigured rather than destroyed, so
    /// everything built here is built once. Nothing in <see cref="SetLook"/> allocates.
    /// </summary>
    public class SkyMarker : MonoBehaviour
    {
        /// <summary>
        /// Degrees of elevation over which a marker fades out as it sinks. A hard cut at
        /// exactly 0° makes low aircraft blink on and off as dead reckoning and GPS
        /// noise jitter them across the horizon.
        /// </summary>
        private const float HorizonFadeDeg = 1.5f;

        /// <summary>Marker size as a fraction of the dome radius, i.e. roughly radians.</summary>
        private const float AngularSize = 0.03f;

        private SkyRig _rig;
        private SkyMarkerKind _kind;
        private MeshRenderer _outline;
        private Material _material;
        private TextMesh _label;
        private Color _color = Color.white;
        private float _alpha = 1f;
        private float _brightness = 1f;
        private float _lastAppliedAlpha = -1f;

        public SkyMarkerKind Kind => _kind;

        /// <summary>Where this marker last was, for decluttering and off-screen hints.</summary>
        public LookAngles Look { get; private set; }

        /// <summary>
        /// Build a marker under the rig's marker root. Called by the pool when it runs
        /// dry, never per frame.
        /// </summary>
        public static SkyMarker Create(SkyRig rig, SkyMarkerKind kind)
        {
            var go = new GameObject(kind.ToString());
            go.transform.SetParent(rig.MarkerRoot, false);

            var marker = go.AddComponent<SkyMarker>();
            marker.Build(rig, kind);
            return marker;
        }

        private void Build(SkyRig rig, SkyMarkerKind kind)
        {
            _rig = rig;
            _kind = kind;

            var billboard = gameObject.AddComponent<FaceCamera>();
            billboard.SetCamera(rig.Camera);

            // Scale with the dome so the marker subtends a constant angle however the
            // radius is tuned, matching CardinalMarkers.
            float size = rig.SkyRadius * AngularSize;

            var shape = new GameObject("Outline");
            shape.transform.SetParent(transform, false);
            shape.transform.localScale = Vector3.one * size;
            shape.AddComponent<MeshFilter>().sharedMesh = kind == SkyMarkerKind.Satellite
                ? SharedDiamond
                : SharedSquare;

            // One material per marker, because each carries its own colour and fade.
            // The pool keeps the count bounded by what is on screen at once.
            _material = new Material(ArVisuals.UnlitTransparent())
            {
                hideFlags = HideFlags.HideAndDontSave,
            };
            _outline = shape.AddComponent<MeshRenderer>();
            _outline.sharedMaterial = _material;
            _outline.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            _outline.receiveShadows = false;

            // Beside the outline, left-aligned, so it never paints over the target.
            _label = ArVisuals.CreateLabel(transform, string.Empty, size * 0.55f,
                                           Color.white, TextAnchor.MiddleLeft);
            _label.alignment = TextAlignment.Left;
            _label.transform.localPosition = new Vector3(size * 0.8f, 0f, 0f);
        }

        /// <summary>Set the colour and text. Cheap to call, but meant for data updates, not frames.</summary>
        public void Configure(Color color, string label)
        {
            _color = color;
            if (_label.text != label) _label.text = label;
            _lastAppliedAlpha = -1f;
        }

        /// <summary>
        /// Extra dimming from outside, 0..1 — for decluttering, or for dimming the
        /// whole sky while the user is calibrating so the ghost N stands out.
        /// </summary>
        public void SetBrightness(float brightness)
        {
            _brightness = Mathf.Clamp01(brightness);
        }

        /// <summary>Place the marker at a direction in the sky and fade it by elevation.</summary>
        public void SetLook(in LookAngles look)
        {
            Look = look;
            transform.localPosition = _rig.PositionFor(look);

            // 1 at +HorizonFadeDeg and above, 0 at 0° and below.
            _alpha = Mathf.Clamp01((float)look.ElevationDeg / HorizonFadeDeg);

            bool visible = _alpha * _brightness > 0.001f;
            if (_outline.enabled != visible)
            {
                _outline.enabled = visible;
                _label.gameObject.SetActive(visible);
            }

            if (visible) ApplyColor();
        }

        public void SetActive(bool active)
        {
            if (gameObject.activeSelf != active) gameObject.SetActive(active);
        }

        private void ApplyColor()
        {
            float a = _alpha * _brightness;
            if (Mathf.Abs(a - _lastAppliedAlpha) < 0.004f) return;
            _lastAppliedAlpha = a;

            var c = new Color(_color.r, _color.g, _color.b, a);
            _material.color = c;
            _label.color = c;
        }

        private void OnDestroy()
        {
            if (_material != null) Destroy(_material);
        }

        /// <summary>
        /// Colour for an aircraft class. Operator wins over airframe, since "is that an
        /// airliner or a Cessna" is the question people actually ask when they look up.
        ///
        /// All colours are bright and fairly desaturated: on an additive display a dark
        /// colour is simply invisible, and a fully saturated one reads as glare.
        /// </summary>
        public static Color ColorFor(AircraftClass c)
        {
            if (c.HasFlag(AircraftClass.Military)) return new Color(1f, 0.62f, 0.3f);    // amber
            if (c.HasFlag(AircraftClass.Rotorcraft)) return new Color(0.95f, 0.5f, 0.95f); // magenta
            if (c.HasFlag(AircraftClass.Commercial)) return new Color(0.45f, 0.85f, 1f);  // cyan
            if (c.HasFlag(AircraftClass.Private)) return new Color(0.5f, 1f, 0.55f);      // green
            if (c.HasFlag(AircraftClass.Glider) || c.HasFlag(AircraftClass.Drone))
                return new Color(1f, 1f, 0.55f);                                          // yellow
            return new Color(0.8f, 0.8f, 0.8f);                                           // unknown
        }

        /// <summary>
        /// Two short lines: who it is, then type, altitude and range. Short on purpose —
        /// at 46° FOV a long label covers the neighbouring aircraft.
        /// </summary>
        public static string LabelFor(Aircraft ac, in LookAngles look)
        {
            string alt = ac.OnGround ? "GND"
                : ac.AltitudeFeet >= 18000.0 ? $"FL{ac.AltitudeFeet / 100.0:F0}"
                : $"{ac.AltitudeFeet:N0}ft";

            double nm = look.RangeMeters / GeoMath.MetersPerNauticalMile;
            return $"{ac.DisplayName}\n{ac.TypeCode ?? "?"} {alt} {nm:F0}nm";
        }

        // Meshes are identical for every marker of a kind, so share them.
        private static Mesh _square;
        private static Mesh _diamond;
        private static Mesh SharedSquare => _square != null ? _square : (_square = ArVisuals.SquareOutline());
        private static Mesh SharedDiamond => _diamond != null ? _diamond : (_diamond = ArVisuals.DiamondOutline());
    }
}
