using System.Collections.Generic;
using UnityEngine;
using VRAeroScan.Core;

namespace VRAeroScan.Rendering
{
    /// <summary>
    /// The ghost cardinal markers, and above all the ghost N.
    ///
    /// The N is what the user aligns the sky against. Because heading calibration here
    /// is manual — drag the horizon until north is where you know north to be — the N
    /// is not decoration, it is the control surface's readout. If you cannot see it,
    /// you cannot calibrate.
    ///
    /// Two decisions follow from that:
    ///
    /// It climbs. A marker sitting only on the horizon disappears the moment you look
    /// up, and looking up is the entire point of the app. So north carries a faint
    /// vertical guide from the horizon into the sky, which stays in view while you are
    /// craned back looking for a satellite.
    ///
    /// It brightens while you adjust. Ghost-faint is right when you are watching
    /// aircraft and wrong when you are aligning, so <see cref="SetAdjusting"/> lifts
    /// the whole set to full strength during a drag and lets it fade back after.
    /// </summary>
    public class CardinalMarkers : MonoBehaviour
    {
        [Header("What to show")]
        [Tooltip("Show E, S and W as well as N, more faintly.")]
        [SerializeField] private bool showAllCardinals = true;

        [Tooltip("Degrees above the horizon to place the cardinal letters.")]
        [SerializeField] private float labelElevationDeg = 3f;

        [Header("North guide")]
        [Tooltip("Faint vertical line from the horizon up through the sky at due north, " +
                 "so north stays findable when you are looking up.")]
        [SerializeField] private bool showNorthGuide = true;

        [Tooltip("How far up the north guide climbs, degrees. 90 reaches the zenith.")]
        [Range(10f, 90f)]
        [SerializeField] private float northGuideElevationDeg = 75f;

        [Header("Ghost appearance")]
        [SerializeField] private Color northColor = new Color(0.45f, 0.85f, 1f);
        [SerializeField] private Color otherColor = new Color(0.6f, 0.7f, 0.8f);

        [Tooltip("Resting opacity. Deliberately faint: this is a reference mark over " +
                 "the real sky, not something to look at.")]
        [Range(0.02f, 1f)]
        [SerializeField] private float restingAlpha = 0.22f;

        [Tooltip("Opacity while the user is dragging the horizon.")]
        [Range(0.1f, 1f)]
        [SerializeField] private float adjustingAlpha = 0.95f;

        [Tooltip("Seconds to fade back to resting after a drag ends.")]
        [SerializeField] private float fadeSeconds = 1.2f;

        private SkyRig _rig;
        private readonly List<Renderer> _northParts = new List<Renderer>();
        private readonly List<Renderer> _otherParts = new List<Renderer>();
        private readonly List<TextMesh> _northText = new List<TextMesh>();
        private readonly List<TextMesh> _otherText = new List<TextMesh>();

        private float _alpha;
        private bool _adjusting;

        public void Initialize(SkyRig rig)
        {
            _rig = rig;
            _alpha = restingAlpha;
            Build();
            ApplyAlpha(_alpha);
        }

        /// <summary>
        /// Called by the touch control while the user is dragging, to bring the ghosts
        /// up to full strength.
        /// </summary>
        public void SetAdjusting(bool adjusting) => _adjusting = adjusting;

        private void Update()
        {
            float target = _adjusting ? adjustingAlpha : restingAlpha;

            if (!Mathf.Approximately(_alpha, target))
            {
                // Snap up instantly, fade down gently: the user wants the mark the
                // instant they touch, and does not want it yanked away afterwards.
                _alpha = _adjusting
                    ? target
                    : Mathf.MoveTowards(_alpha, target,
                                        (adjustingAlpha - restingAlpha) * Time.deltaTime / fadeSeconds);

                ApplyAlpha(_alpha);
            }
        }

        private void Build()
        {
            BuildCardinal("N", 0.0, northColor, _northParts, _northText, scale: 1f);

            if (showAllCardinals)
            {
                BuildCardinal("E", 90.0, otherColor, _otherParts, _otherText, scale: 0.7f);
                BuildCardinal("S", 180.0, otherColor, _otherParts, _otherText, scale: 0.7f);
                BuildCardinal("W", 270.0, otherColor, _otherParts, _otherText, scale: 0.7f);
            }

            if (showNorthGuide) BuildNorthGuide();
        }

        private void BuildCardinal(string letter, double azimuthDeg, Color color,
                                   List<Renderer> parts, List<TextMesh> texts, float scale)
        {
            float radius = _rig.SkyRadius;

            var root = new GameObject($"Cardinal_{letter}");
            root.transform.SetParent(transform, false);
            root.transform.position = _rig.PositionFor(azimuthDeg, labelElevationDeg);

            var billboard = root.AddComponent<FaceCamera>();
            billboard.SetCamera(_rig.Camera);

            // Scale with dome radius so the marker subtends a constant angle however
            // the radius is tuned - what matters is how big it looks, not how big it is.
            float markSize = radius * 0.05f * scale;

            var tick = new GameObject("Tick");
            tick.transform.SetParent(root.transform, false);
            var filter = tick.AddComponent<MeshFilter>();
            filter.sharedMesh = ArVisuals.CardinalTick();
            tick.transform.localScale = Vector3.one * markSize;

            var meshRenderer = tick.AddComponent<MeshRenderer>();
            meshRenderer.sharedMaterial = new Material(ArVisuals.UnlitTransparent())
            {
                hideFlags = HideFlags.HideAndDontSave,
                color = color,
            };
            meshRenderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            parts.Add(meshRenderer);

            TextMesh label = ArVisuals.CreateLabel(root.transform, letter, markSize * 1.6f, color);
            label.transform.localPosition = new Vector3(0f, markSize * 0.95f, 0f);
            texts.Add(label);
        }

        /// <summary>
        /// The vertical guide at due north. Drawn as a dotted climb rather than a solid
        /// line: on an additive display a continuous bright line across the sky is
        /// genuinely obstructive, while a broken one still reads as "that way" without
        /// painting over the stars.
        /// </summary>
        private void BuildNorthGuide()
        {
            const int dashes = 14;
            float radius = _rig.SkyRadius;

            var go = new GameObject("NorthGuide");
            go.transform.SetParent(transform, false);

            var line = go.AddComponent<LineRenderer>();
            line.useWorldSpace = true;
            line.widthMultiplier = radius * 0.0035f;
            line.material = new Material(ArVisuals.UnlitTransparent())
            {
                hideFlags = HideFlags.HideAndDontSave,
            };
            line.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            line.startColor = line.endColor = northColor;

            // Two points per dash, with the gaps left out by only emitting the lit
            // segments. LineRenderer has no dash mode, so the dashes are the geometry.
            var points = new List<Vector3>();
            for (int i = 0; i < dashes; i++)
            {
                float t0 = (float)i / dashes;
                float t1 = t0 + 0.55f / dashes;

                points.Add(GeoMath.SkyDirection(0.0, Mathf.Lerp(labelElevationDeg,
                                                               northGuideElevationDeg, t0)) * radius);
                points.Add(GeoMath.SkyDirection(0.0, Mathf.Lerp(labelElevationDeg,
                                                               northGuideElevationDeg, t1)) * radius);
            }

            // A single LineRenderer draws one polyline, so the connecting segments are
            // collapsed to zero length by repeating points - cheaper than one
            // GameObject per dash, and the zero-length links draw nothing.
            var polyline = new List<Vector3>();
            for (int i = 0; i < points.Count; i += 2)
            {
                polyline.Add(points[i]);
                polyline.Add(points[i + 1]);
                if (i + 2 < points.Count) polyline.Add(points[i + 1]);
            }

            line.positionCount = polyline.Count;
            line.SetPositions(polyline.ToArray());

            _northParts.Add(line);
        }

        private void ApplyAlpha(float alpha)
        {
            ApplyTo(_northParts, northColor, alpha);
            ApplyTo(_otherParts, otherColor, alpha * 0.65f);
            ApplyTextTo(_northText, northColor, alpha);
            ApplyTextTo(_otherText, otherColor, alpha * 0.65f);
        }

        private static void ApplyTo(List<Renderer> parts, Color color, float alpha)
        {
            var c = new Color(color.r, color.g, color.b, alpha);
            foreach (Renderer r in parts)
            {
                if (r == null) continue;

                if (r is LineRenderer line)
                {
                    line.startColor = line.endColor = c;
                }
                else
                {
                    r.sharedMaterial.color = c;
                }
            }
        }

        private static void ApplyTextTo(List<TextMesh> texts, Color color, float alpha)
        {
            var c = new Color(color.r, color.g, color.b, alpha);
            foreach (TextMesh t in texts)
            {
                if (t != null) t.color = c;
            }
        }
    }
}
