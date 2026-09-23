using UnityEngine;
using UnityEngine.EventSystems;
using VRAeroScan.Core;
using VRAeroScan.Rendering;

namespace VRAeroScan.UI
{
    /// <summary>
    /// Drag the phone's touchscreen sideways to rotate the sky until the ghost N sits
    /// where north really is.
    ///
    /// This is the primary calibration interface, not a safety net. A phone
    /// magnetometer is easily 5–15° off near metal and electronics, while a human
    /// looking at a known landmark — or at an aircraft the app is already drawing — is
    /// good to a degree or two. So the control is built for the last few degrees:
    ///
    /// Coarse: one finger (or left mouse), a screen width is <see cref="coarseDegPerScreen"/>.
    /// Fine: two fingers (or Shift + left mouse), a screen width is <see cref="fineDegPerScreen"/>.
    /// Keys: arrow keys step by <see cref="keyStepDeg"/>, a tenth of that with Shift.
    ///
    /// The phone screen is a trackpad here, not a window: while wearing the glasses you
    /// are looking at the sky, not the phone. So the gain is per screen width rather
    /// than tied to anything drawn on the phone, and the direction is chosen so the
    /// sky follows the finger — drag right and the N moves right.
    ///
    /// Only yaw is touched. Pitch and roll come off gravity and are already right;
    /// see <see cref="CompassCalibration"/>.
    /// </summary>
    public class TouchHorizonControl : MonoBehaviour
    {
        [Header("Gain")]
        [Tooltip("Degrees of rotation for a full-screen-width drag, one finger.")]
        [SerializeField] private float coarseDegPerScreen = 90f;

        [Tooltip("Degrees of rotation for a full-screen-width drag in fine mode " +
                 "(two fingers, or Shift with the mouse).")]
        [SerializeField] private float fineDegPerScreen = 10f;

        [Tooltip("Degrees per arrow-key press. Shift steps a tenth of this.")]
        [SerializeField] private float keyStepDeg = 1f;

        [Header("Feel")]
        [Tooltip("Pixels a touch must travel before it counts as a drag, so a tap " +
                 "meant for a button does not nudge the sky.")]
        [SerializeField] private float dragThresholdPixels = 12f;

        [Tooltip("How long the ghosts stay bright after a key nudge, seconds.")]
        [SerializeField] private float keyHighlightSeconds = 0.6f;

        private CompassCalibration _calibration;
        private CardinalMarkers _cardinals;

        private bool _dragging;
        private bool _pointerDown;
        private float _pendingPixels;
        private Vector2 _lastMouse;
        private int _lastTouchCount;
        private bool _touchOwnedByUi;
        private float _keyHighlightUntil = float.NegativeInfinity;

        /// <summary>True while the user is actively turning the sky.</summary>
        public bool IsAdjusting => _dragging || Time.time < _keyHighlightUntil;

        public void Initialize(CompassCalibration calibration, CardinalMarkers cardinals)
        {
            _calibration = calibration;
            _cardinals = cardinals;
        }

        private void Awake()
        {
            // Unity turns touches into fake mouse events by default. Touch is handled
            // directly below, so leaving that on would count every drag twice.
            Input.simulateMouseWithTouches = false;
        }

        private void Update()
        {
            if (_calibration == null) return;

            // Runs in Update and SkyRig applies the pose in LateUpdate, so a drag takes
            // effect the same frame and the sky feels attached to the finger.
            if (Input.touchSupported && Input.touchCount > 0)
            {
                HandleTouches();
            }
            else
            {
                if (_lastTouchCount > 0) EndPointer();
                HandleMouse();
            }

            HandleKeys();

            if (_cardinals != null) _cardinals.SetAdjusting(IsAdjusting);
        }

        private void HandleTouches()
        {
            int count = Input.touchCount;

            // A gesture that starts on a filter button belongs to the button for its
            // whole life, not just its first frame, or a slightly sloppy tap would
            // also nudge the sky.
            if (_lastTouchCount == 0)
            {
                Touch first = Input.GetTouch(0);
                _touchOwnedByUi = IsOverUi(first.fingerId);
            }
            _lastTouchCount = count;
            if (_touchOwnedByUi) return;

            // Average the horizontal motion of every finger down. Using per-frame
            // deltas rather than positions means going from one finger to two (to drop
            // into fine mode mid-drag) does not make the sky jump. The drag ends on
            // the first frame with no touches, which Update handles.
            float dx = 0f;
            for (int i = 0; i < count; i++)
            {
                Touch t = Input.GetTouch(i);
                if (t.phase == TouchPhase.Moved) dx += t.deltaPosition.x;
            }

            _pointerDown = true;
            Accumulate(dx / count, fine: count >= 2);
        }

        private void HandleMouse()
        {
            Vector2 mouse = Input.mousePosition;

            if (Input.GetMouseButtonDown(0))
            {
                if (IsOverUi(-1)) return;
                _pointerDown = true;
                _lastMouse = mouse;
                return;
            }

            if (!_pointerDown) return;

            if (Input.GetMouseButton(0))
            {
                bool fine = Input.GetKey(KeyCode.LeftShift) || Input.GetKey(KeyCode.RightShift);
                Accumulate(mouse.x - _lastMouse.x, fine);
                _lastMouse = mouse;
            }
            else
            {
                EndPointer();
            }
        }

        private void HandleKeys()
        {
            float step = 0f;
            if (Input.GetKeyDown(KeyCode.RightArrow)) step += 1f;
            if (Input.GetKeyDown(KeyCode.LeftArrow)) step -= 1f;
            if (step == 0f) return;

            bool fine = Input.GetKey(KeyCode.LeftShift) || Input.GetKey(KeyCode.RightShift);
            Rotate(step * keyStepDeg * (fine ? 0.1f : 1f));
            _keyHighlightUntil = Time.time + keyHighlightSeconds;
        }

        /// <summary>
        /// Turn pixels into rotation, once the pointer has moved far enough to be a
        /// drag rather than a tap.
        /// </summary>
        private void Accumulate(float dxPixels, bool fine)
        {
            if (dxPixels == 0f) return;

            if (!_dragging)
            {
                _pendingPixels += dxPixels;
                if (Mathf.Abs(_pendingPixels) < dragThresholdPixels) return;

                // Crossing the threshold starts the drag. Discard the travel used to
                // decide that, so the sky does not lurch by the threshold distance.
                _dragging = true;
                _pendingPixels = 0f;
                return;
            }

            float degPerScreen = fine ? fineDegPerScreen : coarseDegPerScreen;
            Rotate(dxPixels / Mathf.Max(1, Screen.width) * degPerScreen);
        }

        /// <summary>
        /// Move the sky by <paramref name="skyDeg"/>, positive meaning the sky moves
        /// right as seen by the user.
        ///
        /// The sign flip is the one thing here easy to get backwards. The offset turns
        /// the CAMERA: a larger offset points it further clockwise, which slides the
        /// sky to the left. Moving the sky right with the finger therefore means
        /// shrinking the offset.
        /// </summary>
        private void Rotate(float skyDeg)
        {
            _calibration.Nudge(-skyDeg);
        }

        private void EndPointer()
        {
            _pointerDown = false;
            _dragging = false;
            _pendingPixels = 0f;
            _lastTouchCount = 0;
        }

        private static bool IsOverUi(int pointerId)
        {
            EventSystem es = EventSystem.current;
            if (es == null) return false;
            return pointerId < 0 ? es.IsPointerOverGameObject() : es.IsPointerOverGameObject(pointerId);
        }
    }
}
