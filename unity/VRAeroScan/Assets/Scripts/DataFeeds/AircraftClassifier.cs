using System;
using System.Collections.Generic;

namespace VRAeroScan.DataFeeds
{
    /// <summary>
    /// What an aircraft is, for filtering.
    ///
    /// Flags rather than a single value, because these are two orthogonal axes: who
    /// operates it (commercial / private / military) and what it is (jet / piston /
    /// turboprop / rotorcraft). An A321 is Commercial|Jet; a C206 is Private|Piston.
    /// Collapsing them into one enum would force a false choice on the filter UI.
    /// </summary>
    [Flags]
    public enum AircraftClass
    {
        Unknown = 0,
        Commercial = 1 << 0,
        Private = 1 << 1,
        Military = 1 << 2,
        Jet = 1 << 3,
        Piston = 1 << 4,
        Turboprop = 1 << 5,
        Rotorcraft = 1 << 6,
        Glider = 1 << 7,
        Drone = 1 << 8,

        /// <summary>
        /// Positively identified as something that is not an aircraft: a ground vehicle
        /// or a fixed obstruction. Distinct from <see cref="Unknown"/>, which means "an
        /// aircraft we could not classify". The renderer must drop these entirely,
        /// whereas an Unknown aircraft is still worth showing.
        /// </summary>
        NotAnAircraft = 1 << 9,
    }

    /// <summary>
    /// Best-effort classification from what ADS-B actually carries.
    ///
    /// Read this before trusting it: ADS-B has no "military" flag, no operator field
    /// and no engine type. Everything below is inference from the emitter category and
    /// the ICAO type designator. The emitter category is reliable, because it is
    /// transmitted by the aircraft; the type-designator tables are hand-maintained and
    /// will have gaps.
    ///
    /// Military detection in particular is a heuristic and will both miss aircraft and
    /// occasionally mislabel civilian ones — a warbird at an airshow squawks the same
    /// type code as the real thing. Do not present it as authoritative in the UI.
    ///
    /// The honest fix, when it matters, is an aircraft metadata database keyed by ICAO
    /// hex (the registration ranges and operator tables that sites like ADSBexchange
    /// use). That is a data project, not a code change, and is deliberately deferred.
    /// </summary>
    public static class AircraftClassifier
    {
        public static AircraftClass Classify(Aircraft ac)
        {
            if (ac == null) return AircraftClass.Unknown;

            AircraftClass result = AircraftClass.Unknown;
            string type = ac.TypeCode?.ToUpperInvariant();

            // Categories C0-C7 are surface vehicles and obstacles - pushback tugs, fire
            // trucks, tower obstructions. They are not aircraft and must never reach the
            // sky. A live sample over Los Angeles was ~3% of returns, so this matters.
            if (!string.IsNullOrEmpty(ac.EmitterCategory) && ac.EmitterCategory[0] == 'C')
            {
                return AircraftClass.NotAnAircraft;
            }

            // Some fixed obstructions transmit with no category at all and are caught
            // only by their type code. A sample of 892 aircraft across four metros
            // turned up seven "TWR" entries - radio towers. Without this they become
            // markers hanging in the sky that never move, which reads as a bug in the
            // tracking rather than bad input data.
            if (!string.IsNullOrEmpty(type) && NonAircraftTypes.Contains(type))
            {
                return AircraftClass.NotAnAircraft;
            }

            // Emitter category first: it comes off the aircraft itself.
            switch (ac.EmitterCategory)
            {
                case "A7": return AircraftClass.Rotorcraft | OperatorGuess(ac, type);
                case "B1": return AircraftClass.Glider | AircraftClass.Private;
                case "B6": return AircraftClass.Drone;

                case "B2": // Lighter-than-air: balloons and airships.
                case "B3": // Parachutist or skydiver.
                case "B4": // Ultralight, hang-glider, paraglider.
                    result |= AircraftClass.Private;
                    break;

                case "B7": // Space or transatmospheric vehicle - not our satellite path.
                    return AircraftClass.Unknown;

                case "A1":
                    // Light, under ~15,500 lb. Overwhelmingly general aviation.
                    result |= AircraftClass.Private;
                    break;

                case "A2":
                    // Small, 15,500-75,000 lb: regional jets and business jets. The
                    // operator is genuinely ambiguous here, so claim only the airframe
                    // and let the type tables below decide the rest.
                    result |= AircraftClass.Jet;
                    break;

                case "A3":
                case "A4":
                case "A5":
                    // Large through heavy. Airliners and freighters, plus military
                    // transports and tankers, which the type table catches below.
                    result |= AircraftClass.Commercial | AircraftClass.Jet;
                    break;

                case "A6":
                    // High performance: >5g and >400kt. Overwhelmingly military fast jets.
                    result |= AircraftClass.Military | AircraftClass.Jet;
                    break;
            }

            if (!string.IsNullOrEmpty(type))
            {
                if (MilitaryTypes.Contains(type)) result |= AircraftClass.Military;
                if (RotorcraftTypes.Contains(type)) result |= AircraftClass.Rotorcraft;
                if (PistonTypes.Contains(type)) result |= AircraftClass.Piston;
                if (TurbopropTypes.Contains(type)) result |= AircraftClass.Turboprop;
                if (BizjetTypes.Contains(type)) result |= AircraftClass.Jet | AircraftClass.Private;
                if (LooksLikeAirlinerJet(type)) result |= AircraftClass.Jet | AircraftClass.Commercial;
            }

            if (LooksMilitaryByCallsign(ac.Callsign)) result |= AircraftClass.Military;

            // A military aircraft is not "commercial", whatever its size class implied.
            if (result.HasFlag(AircraftClass.Military))
            {
                result &= ~AircraftClass.Commercial;
                result &= ~AircraftClass.Private;
            }

            // Nothing is both a jet and a piston; the type tables win over the
            // size-class guess, which is the weaker signal.
            if (result.HasFlag(AircraftClass.Piston) || result.HasFlag(AircraftClass.Turboprop))
            {
                result &= ~AircraftClass.Jet;
            }

            // An aircraft that matched nothing stays Unknown, which is a real answer:
            // it is still shown, just without a type label. Only NotAnAircraft is
            // dropped, and that is decided above.
            return result;
        }

        /// <summary>
        /// Whether this belongs in the sky at all. Ground vehicles and fixed
        /// obstructions do not; an unclassified aircraft does.
        /// </summary>
        public static bool IsRenderable(AircraftClass c) => c != AircraftClass.NotAnAircraft;

        private static AircraftClass OperatorGuess(Aircraft ac, string type)
        {
            if (type != null && MilitaryTypes.Contains(type)) return AircraftClass.Military;
            if (LooksMilitaryByCallsign(ac.Callsign)) return AircraftClass.Military;
            return AircraftClass.Private;
        }

        /// <summary>
        /// Airliner-style designators: a maker letter, then two or three digits, then an
        /// optional variant letter. A321, B738, A359 — but also A21N (A321neo), A20N,
        /// B38M and B39M (737 MAX), B77L and B77W (777-200LR / -300ER), B78X.
        ///
        /// The trailing variant letter is the whole point. A first version of this
        /// required digits all the way to the end, and a live sample over Los Angeles
        /// showed the five most common aircraft in the sky were A21N, A20N, A321, B38M
        /// and B788 — so the rule missed most of the traffic it existed to catch. The
        /// emitter category usually rescues those, but roughly a tenth of aircraft
        /// report no category at all, and for those this rule is all there is.
        /// </summary>
        private static bool LooksLikeAirlinerJet(string type)
        {
            if (type.Length < 3 || type.Length > 4) return false;
            if (type[0] != 'A' && type[0] != 'B' && type[0] != 'E') return false;

            // Positions 1 and 2 are always digits.
            if (!char.IsDigit(type[1]) || !char.IsDigit(type[2])) return false;

            // A fourth character, when present, may be a digit or a variant letter.
            if (type.Length == 4 && !char.IsLetterOrDigit(type[3])) return false;

            return true;
        }

        /// <summary>
        /// US military callsign prefixes. Deliberately short: these are distinctive
        /// enough to be worth having and vague enough that a longer list would start
        /// generating false positives on airline callsigns.
        /// </summary>
        private static bool LooksMilitaryByCallsign(string callsign)
        {
            if (string.IsNullOrEmpty(callsign)) return false;
            string c = callsign.Trim().ToUpperInvariant();

            foreach (string prefix in MilitaryCallsignPrefixes)
            {
                if (c.StartsWith(prefix, StringComparison.Ordinal)) return true;
            }
            return false;
        }

        private static readonly string[] MilitaryCallsignPrefixes =
        {
            "RCH",   // Reach - USAF Air Mobility Command
            "EVAC",  // Aeromedical evacuation
            "CNV",   // US Navy logistics
            "SENTRY",
            "DOOM",
            "POLO",
            "SPAR",  // Special Air Resources
        };

        private static readonly HashSet<string> MilitaryTypes = new HashSet<string>
        {
            // Fast jets
            "F16", "F15", "F18", "F22", "F35", "A10", "EUFI", "RFAL", "GR4", "HAWK",
            // Transports and tankers
            "C130", "C30J", "C17", "C5M", "K35R", "KC46", "A400", "C27J",
            // Maritime, surveillance, command
            "P8", "E3TF", "E3CF", "E6", "RC35", "U2", "P3",
            // Trainers and support
            "T6", "T38", "T45", "B52", "B1", "B2",
        };

        /// <summary>
        /// Type codes that are not aircraft at all. ADS-B ground stations transmit
        /// fixed obstructions using these, often with no emitter category to give them
        /// away. Found by sampling live data, so expect this list to grow.
        /// </summary>
        private static readonly HashSet<string> NonAircraftTypes = new HashSet<string>
        {
            "TWR",   // Radio or control tower
            "OBST",  // Generic obstruction
            "GRND",  // Ground station
        };

        private static readonly HashSet<string> RotorcraftTypes = new HashSet<string>
        {
            "R44", "R22", "R66", "B06", "B407", "B429", "B412", "B430",
            "EC20", "EC25", "EC30", "EC35", "EC45", "EC55", "EC75",
            "AS50", "AS55", "AS65", "A109", "A119", "A139", "A169", "A189",
            "S76", "S92", "H60", "UH60", "CH47", "AH64", "H500", "MD52", "MD90",
            "GAZL", "LYNX", "PUMA", "R22B", "S300", "H269",
        };

        /// <summary>
        /// Business jets. Separated from airliners because the operator differs: these
        /// are Private, not Commercial. Their designators also start with letters the
        /// airliner rule deliberately excludes (C for Cessna Citation collides with
        /// Cessna's piston singles, F for Dassault Falcon), so they need naming.
        /// </summary>
        private static readonly HashSet<string> BizjetTypes = new HashSet<string>
        {
            // Cessna Citation
            "C25A", "C25B", "C25C", "C25M", "C500", "C510", "C525", "C550", "C551",
            "C560", "C56X", "C650", "C680", "C68A", "C700", "C750",
            // Dassault Falcon
            "F900", "F2TH", "F7X", "F8X", "FA10", "FA20", "FA50",
            // Bombardier Learjet / Challenger / Global
            "LJ31", "LJ35", "LJ40", "LJ45", "LJ55", "LJ60", "LJ70", "LJ75",
            "CL30", "CL35", "CL60", "CL64", "GLEX", "GL5T", "GL7T",
            // Gulfstream
            "GLF3", "GLF4", "GLF5", "GLF6", "G150", "G280",
            // Embraer / Honda / Pilatus / Beech jets
            "E50P", "E55P", "E545", "E550", "HDJT", "PRM1", "BE40", "H25B", "HA4T",
        };

        private static readonly HashSet<string> PistonTypes = new HashSet<string>
        {
            "C150", "C152", "C162", "C172", "C177", "C182", "C185", "C206", "C207",
            "C210", "C310", "C337", "C402", "C404", "C414", "C421",
            "P28A", "P28B", "P28R", "P28T", "PA18", "PA22", "PA24", "PA27", "PA28",
            "PA30", "PA31", "PA32", "PA34", "PA44", "PA46",
            "BE33", "BE35", "BE36", "BE55", "BE58", "BE76",
            "SR20", "SR22", "S22T", "SR2T", "DA20", "DA40", "DA42", "DA62",
            "M20P", "M20T", "AA5", "GA7", "RV6", "RV7", "RV8", "RV9", "RV10", "RV14",
            "J3", "CH7B", "BL8", "C82R", "COL4", "LNC2",
        };

        private static readonly HashSet<string> TurbopropTypes = new HashSet<string>
        {
            "PC12", "PC24", "TBM7", "TBM8", "TBM9", "B350", "BE20", "BE9L", "C208",
            "DH8A", "DH8B", "DH8C", "DH8D", "AT72", "AT75", "AT76", "AT43", "AT45",
            "SF34", "E120", "SW4", "D228", "L410",
        };

        /// <summary>Human-readable label for the UI.</summary>
        public static string Describe(AircraftClass c)
        {
            if (c == AircraftClass.NotAnAircraft) return "Not an aircraft";
            if (c == AircraftClass.Unknown) return "Unknown";

            var parts = new List<string>();
            if (c.HasFlag(AircraftClass.Military)) parts.Add("Military");
            if (c.HasFlag(AircraftClass.Commercial)) parts.Add("Commercial");
            if (c.HasFlag(AircraftClass.Private)) parts.Add("Private");
            if (c.HasFlag(AircraftClass.Rotorcraft)) parts.Add("Rotorcraft");
            else if (c.HasFlag(AircraftClass.Glider)) parts.Add("Glider");
            else if (c.HasFlag(AircraftClass.Drone)) parts.Add("Drone");
            else if (c.HasFlag(AircraftClass.Jet)) parts.Add("Jet");
            else if (c.HasFlag(AircraftClass.Turboprop)) parts.Add("Turboprop");
            else if (c.HasFlag(AircraftClass.Piston)) parts.Add("Piston");

            return parts.Count > 0 ? string.Join(" ", parts) : "Unknown";
        }
    }
}
