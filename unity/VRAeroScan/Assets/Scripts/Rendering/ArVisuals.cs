using UnityEngine;

namespace VRAeroScan.Rendering
{
    /// <summary>
    /// Asset-free visual helpers: procedural meshes, materials and fonts.
    ///
    /// Everything the renderer needs is built at runtime rather than authored as
    /// prefabs and materials. That is a deliberate choice, not laziness — it means a
    /// working scene is one component on one empty GameObject, with nothing to wire up
    /// by hand and nothing that can come unwired.
    ///
    /// On the additive display constraint: the Viture's optical see-through lenses are
    /// transparent, so the panel ADDS light to the real world rather than replacing it.
    /// Black is invisible. That inverts the usual rules — bright thin marks on black
    /// read well, and large filled shapes wash out the sky behind them. Every material
    /// here is unlit and transparent for that reason.
    /// </summary>
    public static class ArVisuals
    {
        private static Material _lineMaterial;
        private static Font _font;

        /// <summary>
        /// An unlit, transparent, vertex-coloured material that works in Built-in and
        /// URP alike.
        ///
        /// The shader is looked up by name with fallbacks because the right one depends
        /// on the render pipeline, which is not settled yet. Sprites/Default is the
        /// most portable: it is always included in a build, respects vertex colour and
        /// alpha, and does not light.
        /// </summary>
        public static Material UnlitTransparent()
        {
            if (_lineMaterial != null) return _lineMaterial;

            Shader shader =
                Shader.Find("Sprites/Default") ??
                Shader.Find("Universal Render Pipeline/Unlit") ??
                Shader.Find("Unlit/Transparent") ??
                Shader.Find("Unlit/Color");

            _lineMaterial = new Material(shader)
            {
                // Hidden and not saved: this is generated, never an asset.
                hideFlags = HideFlags.HideAndDontSave,
            };

            // Additive blending matches how the optics actually work: the panel adds
            // light to whatever is behind it. It also means overlapping markers
            // brighten rather than z-fight, which is the friendlier failure.
            _lineMaterial.SetInt("_SrcBlend", (int)UnityEngine.Rendering.BlendMode.SrcAlpha);
            _lineMaterial.SetInt("_DstBlend", (int)UnityEngine.Rendering.BlendMode.One);
            _lineMaterial.SetInt("_ZWrite", 0);
            _lineMaterial.SetInt("_Cull", (int)UnityEngine.Rendering.CullMode.Off);
            _lineMaterial.renderQueue = (int)UnityEngine.Rendering.RenderQueue.Transparent;

            return _lineMaterial;
        }

        /// <summary>The builtin font, so labels need no imported font asset.</summary>
        public static Font BuiltinFont()
        {
            if (_font != null) return _font;

            // Unity 2022+ renamed the builtin font. Try both rather than pinning a
            // version, since the editor version is not settled yet either.
            _font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf")
                 ?? Resources.GetBuiltinResource<Font>("Arial.ttf");

            return _font;
        }

        /// <summary>
        /// A square outline in the XY plane, drawn as lines rather than a filled quad.
        ///
        /// Outlines on purpose: a filled shape on an additive display is a bright patch
        /// covering the very piece of sky the user is trying to look at. The marker has
        /// to say "here" without hiding what is here.
        /// </summary>
        public static Mesh SquareOutline(float halfSize = 0.5f)
        {
            var mesh = new Mesh { name = "SkyMarkerSquare" };

            mesh.vertices = new[]
            {
                new Vector3(-halfSize, -halfSize, 0f),
                new Vector3( halfSize, -halfSize, 0f),
                new Vector3( halfSize,  halfSize, 0f),
                new Vector3(-halfSize,  halfSize, 0f),
            };

            mesh.SetIndices(new[] { 0, 1, 1, 2, 2, 3, 3, 0 },
                            MeshTopology.Lines, 0);
            mesh.RecalculateBounds();
            return mesh;
        }

        /// <summary>A diamond outline, to distinguish satellites from aircraft by shape.</summary>
        public static Mesh DiamondOutline(float halfSize = 0.5f)
        {
            var mesh = new Mesh { name = "SkyMarkerDiamond" };

            mesh.vertices = new[]
            {
                new Vector3(0f, -halfSize, 0f),
                new Vector3( halfSize, 0f, 0f),
                new Vector3(0f,  halfSize, 0f),
                new Vector3(-halfSize, 0f, 0f),
            };

            mesh.SetIndices(new[] { 0, 1, 1, 2, 2, 3, 3, 0 },
                            MeshTopology.Lines, 0);
            mesh.RecalculateBounds();
            return mesh;
        }

        /// <summary>
        /// A horizontal tick with a vertical stem, for marking a cardinal direction on
        /// the horizon.
        /// </summary>
        public static Mesh CardinalTick(float halfWidth = 0.5f, float stemHeight = 0.35f)
        {
            var mesh = new Mesh { name = "CardinalTick" };

            mesh.vertices = new[]
            {
                new Vector3(-halfWidth, 0f, 0f),
                new Vector3( halfWidth, 0f, 0f),
                new Vector3(0f, 0f, 0f),
                new Vector3(0f, stemHeight, 0f),
            };

            mesh.SetIndices(new[] { 0, 1, 2, 3 }, MeshTopology.Lines, 0);
            mesh.RecalculateBounds();
            return mesh;
        }

        /// <summary>
        /// Build a child GameObject carrying a world-space text label.
        ///
        /// Uses legacy <see cref="TextMesh"/> because it renders with the builtin font
        /// and needs no imported asset. TextMeshPro looks considerably better and is
        /// the obvious upgrade once the project has an asset pipeline worth the name,
        /// but it would mean shipping a font asset to get a first pixel on screen.
        /// </summary>
        public static TextMesh CreateLabel(Transform parent, string text, float size,
                                           Color color, TextAnchor anchor = TextAnchor.MiddleCenter)
        {
            var go = new GameObject("Label");
            go.transform.SetParent(parent, false);

            var tm = go.AddComponent<TextMesh>();
            tm.text = text;
            tm.font = BuiltinFont();
            tm.color = color;
            tm.anchor = anchor;
            tm.alignment = TextAlignment.Center;

            // A large font size scaled down keeps glyphs crisp; setting a small
            // fontSize directly renders them mushy at distance.
            tm.fontSize = 64;
            tm.characterSize = size / 64f * 10f;

            var renderer = go.GetComponent<MeshRenderer>();
            if (tm.font != null) renderer.sharedMaterial = tm.font.material;
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            renderer.receiveShadows = false;

            return tm;
        }
    }
}
