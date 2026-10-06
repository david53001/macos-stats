import AppKit
struct P { let w: Int, h: Int; var d: [UInt8]
  init(_ path: String) { let img = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    w = img.width; h = img.height; d = [UInt8](repeating: 0, count: w*h*4)
    let c = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
  func rgb(_ x: Int, _ y: Int) -> (Int,Int,Int) { let i = (y*w+x)*4; return (Int(d[i]),Int(d[i+1]),Int(d[i+2])) }
  func ok(_ x: Int, _ y: Int) -> Bool { x>=0 && y>=0 && x<w && y<h }
}
func dist(_ a: (Int,Int,Int), _ b: (Int,Int,Int)) -> Int { max(abs(a.0-b.0),abs(a.1-b.1),abs(a.2-b.2)) }
func isAccent(_ c: (Int,Int,Int)) -> Bool { c.2 > 150 && c.2 - c.0 > 80 }
let dir = CommandLine.arguments[1]
let targets: [(String, CGRect)] = [("cpu", CGRect(x:8,y:36,width:304,height:67)),("memory",CGRect(x:8,y:109,width:304,height:67)),("network",CGRect(x:8,y:182,width:304,height:67)),("battery",CGRect(x:8,y:255,width:304,height:67)),("footer",CGRect(x:234,y:372,width:78,height:24))]
for look in ["light","dark"] {
  let base = P("\(dir)/overview-\(look).png"); let s = Double(base.w)/320
  for (i,(name,r)) in targets.enumerated() {
    let t = P("\(dir)/tour-step\(i+1)-\(look).png")
    func walk(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int) -> String {
      var x = sx, y = sy, inner = 0
      while t.ok(x,y), dist(base.rgb(x,y), t.rgb(x,y)) <= 10 { inner += 1; x += dx; y += dy }
      var ring = 0
      while t.ok(x,y), isAccent(t.rgb(x,y)) { ring += 1; x += dx; y += dy }
      return String(format: "%.1f(gap %.1f+ring %.1f)", Double(inner+ring)/s, Double(inner)/s, Double(ring)/s)
    }
    func px(_ v: CGFloat) -> Int { Int((Double(v)*s).rounded()) }
    let my = px(r.midY), mx = px(r.midX)
    let L = walk(px(r.minX)-1, my, -1, 0), R = walk(px(r.maxX), my, 1, 0)
    let T = walk(mx, px(r.minY)-1, 0, -1), B = walk(mx, px(r.maxY), 0, 1)
    // corners: diagonal from the point on the card's corner arc at 45 deg (centre + r/sqrt2), outward
    var cs: [String] = []
    for (cx, cy, dx, dy) in [(r.minX+8, r.minY+8, -1, -1),(r.maxX-8, r.minY+8, 1, -1),(r.minX+8, r.maxY-8, -1, 1),(r.maxX-8, r.maxY-8, 1, 1)] {
      // start 2 px inside the arc and step outward until unchanged-run then ring
      let k = 8/sqrt(2.0)
      var x = px(cx + CGFloat(Double(dx)*k)) - dx*2, y = px(cy + CGFloat(Double(dy)*k)) - dy*2
      var n = 0; while t.ok(x,y), dist(base.rgb(x,y), t.rgb(x,y)) <= 10 { x += dx; y += dy; n += 1 }
      var ring = 0; while t.ok(x,y), isAccent(t.rgb(x,y)) { ring += 1; x += dx; y += dy }
      cs.append(String(format: "%.1f", Double(n - 2 + ring) * sqrt(2.0) / s))
    }
    print("\(look) \(name): L=\(L) R=\(R) T=\(T) B=\(B) cornersDiag(pt)=\(cs.joined(separator: ","))")
  }
  // welcome: column at x = 30 pt; find the welcome card's top/bottom by the largest luminance step vs the base
  let wimg = P("\(dir)/welcome-\(look).png")
  let x = Int(30*s); var rows: [Int] = []
  for y in 0..<wimg.h { let c = wimg.rgb(x,y); let b = base.rgb(x,y); rows.append(dist(c,b)) }
  print("welcome \(look) diff profile at x=30pt (every 4px):", stride(from: 0, to: rows.count, by: 8).map { "\($0/Int(s)):\(rows[$0])" }.joined(separator: " "))
}
