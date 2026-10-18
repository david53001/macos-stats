import Foundation
// Same noisy series through the old row hold (heldValue) and the new one (HeldReading).
var seed: UInt64 = 7
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
func gauss() -> Double { sqrt(-2 * log(max(rnd(), 1e-12))) * cos(2 * .pi * rnd()) }
func count(_ xs: [Double]) -> (Int, Int) {
    var c = 0, f = 0; var last: Double?, prev: Double?
    for x in xs { if let l = last, abs(l - x) > 1e-9 { c += 1; if let p = prev, abs(p - x) < 1e-9 { f += 1 }; prev = l }; last = x }
    return (c, f)
}
for (name, level, noise) in [("1% ±20%", 1.0, 0.2), ("3% ±15%", 3.0, 0.15), ("6% ±10%", 6.0, 0.10), ("15% ±10%", 15.0, 0.10)] {
    var oldS: Double?, newS: HeldReading?
    var olds: [Double] = [], news: [Double] = [], err0 = 0.0, err1 = 0.0
    var lvl = level
    for i in 0..<3000 {   // 3000 scans = 100 min at 2 s
        if i % 300 == 0 { lvl = level * (0.7 + 0.6 * rnd()) }   // a real level change every 10 min
        let v = max(0, lvl * (1 + noise * gauss()))
        let step = breakdownValueStep(.cpu, v)
        let o = heldValue(shown: oldS, value: v, step: step, band: 0.75, relBand: 0.10, cap: 2)
        oldS = o; olds.append(o); err0 = max(err0, abs(o - v))
        if newS == nil { newS = HeldReading(v, step: step) } else { newS!.update(v, step: step, band: 0.75, relBand: 0.10, cap: 2) }
        news.append(newS!.shown); err1 = max(err1, abs(newS!.shown - v))
    }
    let (c0, f0) = count(olds), (c1, f1) = count(news)
    print(String(format: "%@: per min  old changes %.1f flips %.2f maxerr %.2f | new changes %.1f flips %.2f maxerr %.2f",
                 name, Double(c0) / 100, Double(f0) / 100, err0, Double(c1) / 100, Double(f1) / 100, err1))
}
