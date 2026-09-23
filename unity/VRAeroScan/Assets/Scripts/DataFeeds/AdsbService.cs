using System;
using System.Collections;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Networking;
using VRAeroScan.Core;

namespace VRAeroScan.DataFeeds
{
    /// <summary>
    /// Polls adsb.lol for aircraft near the observer.
    ///
    /// Endpoint: GET https://api.adsb.lol/v2/point/{lat}/{lon}/{radius_nm}
    /// Free, no API key, data licensed ODbL 1.0.
    ///
    /// Be a good citizen of a free service: this polls on an interval rather than as
    /// fast as it can, and backs off when the service errors. Smoothness between polls
    /// is the renderer's job via <see cref="Aircraft.PositionAt"/>, not something to
    /// buy with a higher request rate.
    /// </summary>
    public class AdsbService : MonoBehaviour
    {
        [Header("Query")]
        [Tooltip("Search radius in nautical miles. The API caps this at 250.")]
        [Range(1, 250)]
        [SerializeField] private int radiusNauticalMiles = 100;

        [Tooltip("Seconds between polls. Below ~2s is impolite to a free service and " +
                 "buys nothing: dead reckoning covers the gap.")]
        [Range(1f, 30f)]
        [SerializeField] private float pollIntervalSeconds = 3f;

        [Header("Housekeeping")]
        [Tooltip("Drop an aircraft this many seconds after it stops being reported.")]
        [SerializeField] private float staleAfterSeconds = 30f;

        private const string EndpointFormat = "https://api.adsb.lol/v2/point/{0}/{1}/{2}";
        private const int MaxConsecutiveFailures = 5;

        private readonly Dictionary<string, Aircraft> _aircraft =
            new Dictionary<string, Aircraft>();
        private readonly Dictionary<string, float> _lastSeen =
            new Dictionary<string, float>();

        private Func<GeoPoint> _observerProvider;
        private Coroutine _pollLoop;
        private int _consecutiveFailures;

        /// <summary>Raised after each successful poll.</summary>
        public event Action<IReadOnlyCollection<Aircraft>> OnAircraftUpdated;

        /// <summary>Raised when a poll fails, with a human-readable reason.</summary>
        public event Action<string> OnError;

        public IReadOnlyCollection<Aircraft> Aircraft => _aircraft.Values;
        public bool IsPolling => _pollLoop != null;
        public float LastSuccessfulPoll { get; private set; } = float.NegativeInfinity;

        /// <summary>
        /// Start polling around whatever <paramref name="observerProvider"/> returns.
        /// A delegate rather than a fixed point so the query follows the user if the
        /// phone's GPS moves.
        /// </summary>
        public void StartPolling(Func<GeoPoint> observerProvider)
        {
            _observerProvider = observerProvider ??
                throw new ArgumentNullException(nameof(observerProvider));

            StopPolling();
            _pollLoop = StartCoroutine(PollLoop());
        }

        public void StopPolling()
        {
            if (_pollLoop != null)
            {
                StopCoroutine(_pollLoop);
                _pollLoop = null;
            }
        }

        private void OnDisable() => StopPolling();

        private IEnumerator PollLoop()
        {
            while (true)
            {
                yield return PollOnce();
                PruneStale();

                // Back off when the service is unhappy, rather than hammering it.
                float wait = _consecutiveFailures > 0
                    ? pollIntervalSeconds * Mathf.Pow(2f, Mathf.Min(_consecutiveFailures, 4))
                    : pollIntervalSeconds;

                yield return new WaitForSeconds(wait);
            }
        }

        private IEnumerator PollOnce()
        {
            GeoPoint observer = _observerProvider();

            string url = string.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                EndpointFormat,
                observer.LatitudeDeg, observer.LongitudeDeg, radiusNauticalMiles);

            using (UnityWebRequest request = UnityWebRequest.Get(url))
            {
                request.timeout = 20;
                yield return request.SendWebRequest();

                if (request.result != UnityWebRequest.Result.Success)
                {
                    Fail($"adsb.lol request failed: {request.error}");
                    yield break;
                }

                List<Aircraft> parsed;
                try
                {
                    parsed = Parse(request.downloadHandler.text);
                }
                catch (Exception e)
                {
                    // A malformed response should not take the app down; the next poll
                    // is three seconds away.
                    Fail($"adsb.lol response could not be parsed: {e.Message}");
                    yield break;
                }

                Merge(parsed);

                _consecutiveFailures = 0;
                LastSuccessfulPoll = Time.time;
                OnAircraftUpdated?.Invoke(_aircraft.Values);
            }
        }

        private static List<Aircraft> Parse(string json)
        {
            var results = new List<Aircraft>();

            JObject root = JObject.Parse(json);
            if (!(root["ac"] is JArray list)) return results;

            foreach (JToken token in list)
            {
                if (!(token is JObject o)) continue;

                Aircraft ac = DataFeeds.Aircraft.FromJson(o);
                if (ac == null) continue;

                // Ground vehicles and fixed obstructions are filtered here rather than
                // at render time, so nothing downstream has to remember to do it.
                if (!AircraftClassifier.IsRenderable(ac.Class)) continue;

                results.Add(ac);
            }

            return results;
        }

        private void Merge(List<Aircraft> incoming)
        {
            float now = Time.time;
            foreach (Aircraft ac in incoming)
            {
                _aircraft[ac.Icao24] = ac;
                _lastSeen[ac.Icao24] = now;
            }
        }

        /// <summary>
        /// Forget aircraft that have stopped being reported, which happens constantly
        /// as they leave the radius or drop below receiver coverage. Without this the
        /// sky slowly fills with ghosts frozen where they were last seen.
        /// </summary>
        private void PruneStale()
        {
            float cutoff = Time.time - staleAfterSeconds;

            List<string> drop = null;
            foreach (KeyValuePair<string, float> kv in _lastSeen)
            {
                if (kv.Value < cutoff)
                {
                    (drop ??= new List<string>()).Add(kv.Key);
                }
            }

            if (drop == null) return;
            foreach (string key in drop)
            {
                _aircraft.Remove(key);
                _lastSeen.Remove(key);
            }
        }

        private void Fail(string message)
        {
            _consecutiveFailures++;
            OnError?.Invoke(message);

            if (_consecutiveFailures >= MaxConsecutiveFailures)
            {
                Debug.LogWarning($"[AdsbService] {message} " +
                                 $"({_consecutiveFailures} consecutive failures)");
            }
        }
    }
}
