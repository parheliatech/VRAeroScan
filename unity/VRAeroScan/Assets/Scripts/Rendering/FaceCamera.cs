using UnityEngine;

namespace VRAeroScan.Rendering
{
    /// <summary>
    /// Turns a flat marker to face the camera.
    ///
    /// Uses the camera's ROTATION rather than the direction to the camera. On a dome
    /// the two differ near the edges of view, and matching the rotation keeps every
    /// marker co-planar with the screen — so text stays upright and unskewed instead
    /// of subtly leaning as it drifts off-centre.
    /// </summary>
    [DefaultExecutionOrder(100)]
    public class FaceCamera : MonoBehaviour
    {
        [Tooltip("Keep the marker upright in world terms rather than rolling with the " +
                 "head. Labels stay readable when you tilt your head, which you will " +
                 "do constantly while looking up.")]
        [SerializeField] private bool keepUpright = true;

        private Camera _camera;

        public void SetCamera(Camera camera) => _camera = camera;

        private void LateUpdate()
        {
            if (_camera == null)
            {
                _camera = Camera.main;
                if (_camera == null) return;
            }

            Transform cam = _camera.transform;

            if (keepUpright)
            {
                // Face the camera plane, but take "up" from the world so head roll does
                // not tip the text over.
                transform.rotation = Quaternion.LookRotation(cam.forward, Vector3.up);
            }
            else
            {
                transform.rotation = cam.rotation;
            }
        }
    }
}
