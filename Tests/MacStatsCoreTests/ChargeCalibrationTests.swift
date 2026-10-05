import Testing
import Foundation
@testable import MacStatsCore

/// Time to the charge limit, replayed on real charges of this Mac (M3, ~30 W adapter, 85 %
/// limit). Readings are the battery rows of macOS's powerlog
/// (`/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL` and its `Archives/`,
/// table `PLBatteryAgent_EventBackward_Battery`, one row per gauge update): seconds since the
/// first charging reading, `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, `InstantAmperage`
/// (the same value as the gauge's `Amperage`, which the app reads). `stopSeconds` is when
/// `IsCharging` went to 0 at the limit. These are the four sessions that ran to the limit while
/// awake; four more sessions (21–73 %) were used for the fit but stop before the limit.
@Suite struct ChargeCalibrationTests {
    struct ChargeSession {
        let stopSeconds: Int
        let readings: [(t: Int, mAh: Int, full: Int, mA: Int)]
    }

    static let sessions: [ChargeSession] = [
        // 2026-09-28 21:36: raw 45.8 → 84.01 %, stopped by the 85 % limit
        ChargeSession(stopSeconds: 2898, readings: [
            (0, 2009, 4383, 1096), (43, 2044, 4383, 2278), (117, 2089, 4383, 2269), (141, 2104, 4383, 2223), (198, 2139, 4383, 2263),
            (212, 2148, 4383, 2229), (613, 2396, 4383, 2236), (637, 2411, 4383, 2208), (795, 2507, 4383, 2224), (848, 2539, 4383, 2220),
            (853, 2543, 4383, 2194), (978, 2619, 4383, 2210), (998, 2630, 4383, 2137), (1103, 2692, 4383, 2177), (1146, 2718, 4383, 2078),
            (1204, 2752, 4383, 2196), (1220, 2762, 4383, 2061), (1279, 2797, 4383, 2180), (1294, 2806, 4383, 2174), (1353, 2841, 4383, 2142),
            (1366, 2849, 4383, 2162), (1425, 2884, 4383, 2171), (1440, 2893, 4383, 2169), (1499, 2928, 4383, 2166), (1515, 2937, 4383, 2156),
            (1574, 2972, 4383, 2162), (1588, 2981, 4383, 2121), (1647, 3015, 4383, 2130), (1664, 3025, 4383, 2060), (1723, 3059, 4383, 2138),
            (1739, 3069, 4383, 2149), (1798, 3102, 4383, 2125), (1814, 3112, 4383, 2130), (1873, 3146, 4383, 2100), (1890, 3156, 4383, 2112),
            (1949, 3190, 4383, 2116), (1966, 3200, 4383, 2111), (2025, 3234, 4383, 2133), (2042, 3244, 4383, 2130), (2101, 3277, 4383, 1975),
            (2121, 3288, 4383, 2037), (2180, 3321, 4383, 2025), (2199, 3332, 4383, 2028), (2258, 3365, 4383, 2085), (2275, 3375, 4383, 2094),
            (2334, 3408, 4383, 2009), (2356, 3419, 4383, 2099), (2415, 3453, 4383, 1975), (2433, 3463, 4383, 1936), (2492, 3494, 4383, 1954),
            (2516, 3507, 4383, 1968), (2575, 3539, 4383, 1969), (2597, 3551, 4383, 1968), (2656, 3583, 4383, 1968), (2678, 3595, 4383, 1964),
            (2737, 3627, 4383, 1969), (2757, 3638, 4383, 1969), (2816, 3669, 4383, 1968), (2839, 3682, 4383, 1969),
        ]),
        // 2026-09-30 19:57: raw 62.5 → 84.00 %, stopped by the 85 % limit
        ChargeSession(stopSeconds: 1883, readings: [
            (0, 2762, 4419, 2027), (60, 2795, 4419, 2020), (120, 2829, 4419, 2041), (180, 2862, 4419, 2041), (200, 2873, 4419, 1798),
            (260, 2905, 4419, 1871), (283, 2917, 4419, 1865), (343, 2947, 4419, 2026), (367, 2961, 4419, 2020), (427, 2994, 4419, 2022),
            (446, 3005, 4419, 2023), (506, 3037, 4419, 2018), (528, 3050, 4419, 1994), (588, 3082, 4419, 1962), (610, 3094, 4419, 2002),
            (670, 3127, 4419, 1985), (690, 3138, 4419, 2007), (750, 3171, 4419, 2001), (770, 3182, 4419, 1920), (830, 3215, 4419, 1994),
            (850, 3226, 4419, 2000), (910, 3259, 4419, 1996), (931, 3271, 4419, 1995), (991, 3303, 4419, 1972), (1012, 3315, 4419, 1991),
            (1072, 3348, 4419, 1988), (1093, 3359, 4419, 1985), (1153, 3392, 4419, 1949), (1180, 3403, 4419, 1473), (1240, 3431, 4419, 1906),
            (1273, 3447, 4419, 1899), (1333, 3478, 4419, 1900), (1359, 3492, 4419, 1896), (1419, 3523, 4419, 1918), (1444, 3536, 4419, 1879),
            (1504, 3564, 4419, 1299), (1539, 3580, 4419, 1720), (1599, 3607, 4419, 1819), (1635, 3624, 4419, 1651), (1695, 3651, 4419, 1342),
            (1731, 3668, 4419, 1853), (1791, 3696, 4419, 1880), (1823, 3712, 4419, 1876),
        ]),
        // 2026-10-01 06:51: raw 77.3 → 84.02 %, stopped by the 85 % limit (heavy use mid-charge)
        ChargeSession(stopSeconds: 842, readings: [
            (0, 3405, 4405, 827), (24, 3405, 4405, 827), (60, 3429, 4405, 1894), (120, 3457, 4405, 1877), (180, 3485, 4405, 1901),
            (240, 3515, 4405, 1870), (300, 3543, 4405, 1480), (360, 3564, 4405, 1151), (373, 3569, 4405, 1332), (432, 3575, 4405, 257),
            (492, 3586, 4405, 415), (552, 3608, 4405, 1368), (562, 3613, 4405, 1355), (621, 3631, 4405, 1344), (681, 3656, 4405, 1885),
            (683, 3657, 4405, 1894), (742, 3684, 4405, 1882), (783, 3701, 4405, 1370),
        ]),
        // 2026-10-04 11:11: raw 37.2 → 84.02 %, stopped by the 85 % limit
        ChargeSession(stopSeconds: 4398, readings: [
            (0, 1642, 4411, 2132), (59, 1677, 4411, 2160), (93, 1697, 4411, 2291), (132, 1721, 4411, 2232), (200, 1763, 4411, 2285),
            (202, 1765, 4411, 2231), (271, 1807, 4411, 2281), (273, 1809, 4411, 1712), (424, 1901, 4411, 2272), (483, 1928, 4411, 1761),
            (508, 1941, 4411, 1790), (568, 1968, 4411, 1660), (604, 1985, 4411, 1809), (664, 2014, 4411, 1786), (696, 2030, 4411, 1853),
            (756, 2059, 4411, 1760), (784, 2074, 4411, 1871), (844, 2104, 4411, 1837), (872, 2118, 4411, 1826), (932, 2147, 4411, 1800),
            (961, 2162, 4411, 1639), (1021, 2192, 4411, 1824), (1048, 2206, 4411, 1871), (1108, 2235, 4411, 1409), (1138, 2250, 4411, 1822),
            (1198, 2281, 4411, 1855), (1225, 2294, 4411, 1851), (1285, 2323, 4411, 1862), (1314, 2338, 4411, 1793), (1374, 2367, 4411, 1775),
            (1404, 2382, 4411, 1830), (1464, 2412, 4411, 1849), (1493, 2427, 4411, 1845), (1553, 2457, 4411, 1839), (1580, 2471, 4411, 1845),
            (1640, 2500, 4411, 1842), (1671, 2515, 4411, 1840), (1731, 2545, 4411, 1838), (1759, 2559, 4411, 1830), (1819, 2588, 4411, 1709),
            (1849, 2603, 4411, 1835), (1909, 2630, 4411, 1822), (1944, 2647, 4411, 1802), (2004, 2674, 4411, 1792), (2047, 2691, 4411, 1688),
            (2107, 2720, 4411, 1806), (2138, 2735, 4411, 1820), (2198, 2757, 4411, 1131), (2253, 2779, 4411, 1813), (2313, 2806, 4411, 1784),
            (2353, 2824, 4411, 1685), (2413, 2852, 4411, 1740), (2448, 2868, 4411, 1801), (2508, 2897, 4411, 1801), (2538, 2912, 4411, 1804),
            (2598, 2939, 4411, 1754), (2635, 2956, 4411, 1563), (2695, 2982, 4411, 1795), (2731, 3000, 4411, 1786), (2791, 3027, 4411, 1764),
            (2827, 3044, 4411, 1772), (2887, 3071, 4411, 1757), (2920, 3088, 4411, 1768), (2980, 3117, 4411, 1784), (3011, 3132, 4411, 1498),
            (3071, 3160, 4411, 1765), (3104, 3176, 4411, 1306), (3164, 3204, 4411, 1776), (3200, 3221, 4411, 1715), (3260, 3249, 4411, 1717),
            (3296, 3265, 4411, 1770), (3356, 3294, 4411, 1767), (3387, 3309, 4411, 1740), (3447, 3336, 4411, 1719), (3484, 3353, 4411, 1769),
            (3544, 3381, 4411, 1143), (3578, 3397, 4411, 1759), (3638, 3423, 4411, 1262), (3678, 3441, 4411, 1738), (3738, 3467, 4411, 1757),
            (3777, 3485, 4411, 749), (3837, 3504, 4411, 1707), (3897, 3528, 4411, 1662), (3898, 3529, 4411, 1525), (3958, 3552, 4411, 1168),
            (4018, 3572, 4411, 1153), (4078, 3594, 4411, 1340), (4134, 3618, 4411, 1634), (4194, 3643, 4411, 1610), (4236, 3662, 4411, 1422),
            (4296, 3686, 4411, 1627), (4338, 3706, 4411, 1726),
        ]),
    ]

    /// (predicted − actual, actual) minutes to the limit for every reading, fed the way
    /// `AppModel.refreshBattery` feeds the gauge (gaps over `maxGaugeInterval` count as 0 s).
    /// A row repeating the previous charge and current is the same gauge update logged twice
    /// (Oct 1, 0 s and 24 s: at 1–2 A the charge moves ~10 mAh in that time); the app sees one
    /// update (`UpdateTime` unchanged), so the replay skips it too.
    static func replay(_ session: ChargeSession, settledAfter: TimeInterval) -> [(error: Double, actual: Double)] {
        var current = ChargeCurrent()
        var previous: (t: Int, mAh: Int, full: Int, mA: Int)?
        var out: [(error: Double, actual: Double)] = []
        for r in session.readings {
            if let p = previous, p.mAh == r.mAh, p.mA == r.mA { continue }
            let step = previous.map { TimeInterval(r.t - $0.t) } ?? 0
            current.ingest(milliamps: r.mA, seconds: step <= maxGaugeInterval ? step : 0)
            previous = r
            let actual = Double(session.stopSeconds - r.t) / 60
            guard current.seconds >= settledAfter, actual >= 1, let mA = current.milliamps,
                  let predicted = minutesToTarget(currentMAh: r.mAh, maxMAh: r.full, chargeMA: mA,
                                                  targetPercent: 85) else { continue }
            out.append((Double(predicted) - actual, actual))
        }
        return out
    }

    @Test func timeToTheLimitMatchesRealCharges() {
        // Once the current average has 3 minutes of readings: every estimate within 3.5 min or
        // 20 % of the real time, 1.5–2 min off on average (python replay: MAE 1.7 min, bias
        // −1.6 min, worst −12 min at 39 % on Oct 4, whose current fell from 2.2 to 1.5 A).
        let results = Self.sessions.flatMap { Self.replay($0, settledAfter: 180) }
        #expect(results.count > 150)
        for r in results {
            #expect(abs(r.error) <= max(3.5, 0.2 * r.actual), "off by \(r.error) of \(r.actual) min")
        }
        let mae = results.map { abs($0.error) }.reduce(0, +) / Double(results.count)
        let bias = results.map(\.error).reduce(0, +) / Double(results.count)
        #expect(mae < 2)
        #expect(abs(bias) < 2)
    }

    @Test func firstMinutesAfterPlugInAreClose() {
        // From the second reading on (the first isn't reported): within 4.5 min or 25 % of the
        // real time. The worst rows (−4.0 of 12–13 min, Oct 1) are heavy use a few minutes
        // later cutting the charge current to 257–415 mA, which no estimate can foresee.
        for session in Self.sessions {
            for r in Self.replay(session, settledAfter: 1) {
                #expect(abs(r.error) <= max(4.5, 0.25 * r.actual), "off by \(r.error) of \(r.actual) min")
            }
        }
    }
}

/// Out of sample: a charge logged live on 2026-10-05 22:03–22:42 (after the model was fitted),
/// sampled every 30 s from `ioreg -rn AppleSmartBattery`: seconds before charging stopped,
/// `AppleRawCurrentCapacity` (of 4407 mAh), `Amperage`. Raw 52.6 → 79.0 %, stopped by
/// Optimized Charging's 80 % hold (powerd listed it next to the 85 % limit). Seconds carry the
/// 30 s sampling, so the stop is known to ±30 s.
@Suite struct LiveChargeTests {
    static let readings: [(t: Int, mAh: Int, mA: Int)] = [
        (-2285, 2340, 1209), (-2225, 2366, 2002), (-2165, 2400, 2044), (-2135, 2424, 2081), (-2075, 2452, 1452), (-2045, 2468, 2067),
        (-1985, 2494, 1439), (-1925, 2512, 2059), (-1865, 2538, 1425), (-1835, 2557, 2034), (-1774, 2590, 2020), (-1744, 2601, 1987),
        (-1684, 2630, 1999), (-1654, 2645, 2001), (-1624, 2671, 2036), (-1564, 2689, 1981), (-1504, 2720, 1879), (-1474, 2733, 1998),
        (-1444, 2761, 1489), (-1383, 2777, 1255), (-1323, 2806, 1937), (-1293, 2821, 1936), (-1233, 2850, 1914), (-1203, 2865, 1957),
        (-1143, 2909, 1950), (-1083, 2937, 1537), (-1053, 2953, 1992), (-992, 2983, 1447), (-962, 2997, 1426), (-902, 3029, 2014),
        (-872, 3041, 2009), (-812, 3073, 2001), (-782, 3085, 1977), (-722, 3129, 2001), (-662, 3162, 1996), (-632, 3174, 1992),
        (-571, 3206, 1987), (-541, 3218, 1967), (-481, 3262, 1992), (-421, 3295, 1987), (-391, 3306, 1988), (-331, 3338, 1982),
        (-301, 3350, 1979), (-241, 3394, 1970), (-180, 3426, 1954), (-150, 3438, 1952), (-90, 3470, 1945), (-60, 3482, 1951),
    ]

    /// (predicted − actual) minutes at each reading with an estimate, toward `target` %.
    private func errors(target: Int) -> [Double] {
        var current = ChargeCurrent()
        var previous: Int?
        var out: [Double] = []
        for r in Self.readings {
            current.ingest(milliamps: r.mA, seconds: previous.map { Double(r.t - $0) } ?? 0)
            previous = r.t
            if let mA = current.milliamps,
               let m = minutesToTarget(currentMAh: r.mAh, maxMAh: 4407, chargeMA: mA, targetPercent: target) {
                out.append(Double(m) - Double(-r.t) / 60)
            }
        }
        return out
    }

    @Test func timeToTheHoldMatchesWhereChargingStopped() {
        let e = errors(target: 80)
        let mean = e.map(abs).reduce(0, +) / Double(e.count)
        #expect(e.count >= 40)
        #expect(mean < 2)                        // 1.1 min
        #expect(e.map(abs).max()! < 5)           // 3.9 min, at 2 minutes of current average
    }

    @Test func targetingTheWrongStopIsWhatGoesWrong() {
        // The same charge aimed at the 85 % limit, or at 100 % (round 2's "limit unknown").
        let to85 = errors(target: 85), to100 = errors(target: 100)
        #expect(to85.reduce(0, +) / Double(to85.count) > 6)      // +8.5 min
        #expect(to100.reduce(0, +) / Double(to100.count) > 50)   // +65 min
    }
}
