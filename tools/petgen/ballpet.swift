// ballpet.swift: Mr. Meeseeks as the real face inside a ball.
//
//   swift tools/petgen/ballpet.swift [--out DIR] [--face PNG] [--pets DIR]
//
// The face is the user-supplied image (assets/meeseeks-face.png). It is never redrawn: it is
// wrapped onto the front of a sphere (an orthographic front view, so the rest pose shows the
// image exactly as it is, cropped to a circle) and the sphere is animated by moving, squashing,
// leaning and turning it. Light stays fixed at the top-left, so a turned or leaning face
// keeps believable shading. The only paint added to the face is the eyelids for blinks.
//
// Two variants of the Codex pet atlas (1536x1872, 8 cols x 9 rows of 192x208 cells):
//   smooth  every cell rendered at 192x208, anti-aliased (3x3 samples per pixel). Shading
//           (rim shade, sheen, reflected rim) touches only the blue skin, so the ink, the
//           catch-lights, the teeth and the mouth keep the image's own colours.
//   pixel   the face shrunk once to a fixed 48-scale grid (PX_MOUTH_*, PX_EYES below, made
//           from the image and cleaned up by hand: 5x5 eyes with one catch-light, teeth
//           alternating with mouth-red gaps, brows/cheek lines/chin dropped), placed on a
//           toon-shaded ball drawn at 48x52 with a 1-px outline, then scaled x4 nearest, to
//           sit with the pixel family (cat, robot, ghost). Poses move the fixed face by
//           whole pixels (turn = shift, lean = each eye and the mouth carried to where the
//           roll takes it, squash = drop or repeat a mouth row), in the spirit of STYLE.md's
//           rig, so the features never change shape between frames. No ground shadow, binary
//           alpha, like the family.
// Effect glyphs (! x sweat sparkle dots laptop, and _example.py's dust) are the family's
// petgen glyphs, copied below as pixel grids so this file needs nothing but Apple
// frameworks; they are pasted x4 nearest at the STYLE.md positions.
//
// Writes, for each variant, DIR/<variant>/{pet.json, spritesheet.png, sheet.png,
// frames_dark.png, all.gif, rows/<row>.png}, plus DIR/lineup.png (frame 0 of every row:
// smooth | pixel | cat | robot) and DIR/sizes.png (the app's three display sizes).
// Nothing is written into Sources/.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Contract

let W = 48, H = 52, K = 4            // logical cell, x4 to the atlas
let CW = W * K, CH = H * K           // 192 x 208 atlas cell
let COLS = 8
let GROUND = 47                      // lowest opaque logical row at rest
let ROWS: [(String, Int)] = [
    ("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5),
    ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6),
]
let TIMINGS: [String: [Int]] = [
    "idle": [280, 110, 110, 140, 140, 320],
    "running-right": Array(repeating: 120, count: 7) + [220],
    "running-left": Array(repeating: 120, count: 7) + [220],
    "waving": [140, 140, 140, 280],
    "jumping": [140, 140, 140, 140, 280],
    "failed": Array(repeating: 140, count: 7) + [240],
    "waiting": Array(repeating: 150, count: 5) + [260],
    "running": Array(repeating: 120, count: 5) + [220],
    "review": Array(repeating: 150, count: 5) + [280],
]
let IDLE_LOOP_MULT = 6
let PET_ID = "meeseeks"
let DISPLAY_NAME = "Mr. Meeseeks"
let DESCRIPTION = "Existence is pain until your threads are done."

// MARK: - Arguments

let HERE = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
var facePath = HERE.appendingPathComponent("assets/meeseeks-face.png").path
var outDir = HERE.appendingPathComponent("out/meeseeks-ball").path
var petsDir = HERE.appendingPathComponent("../../Sources/Sidekick/Resources/Pets").standardizedFileURL.path
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out": outDir = it.next() ?? outDir
        case "--face": facePath = it.next() ?? facePath
        case "--pets": petsDir = it.next() ?? petsDir
        case "-h", "--help":
            print("usage: swift tools/petgen/ballpet.swift [--out DIR] [--face PNG] [--pets DIR]")
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}

// MARK: - Colour

struct C: Hashable {
    var r: Double, g: Double, b: Double
}

func hex(_ s: String) -> C {
    let v = UInt64(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
    return C(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
}

func mix(_ a: C, _ b: C, _ t: Double) -> C {
    C(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
}

func lum(_ c: C) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

func q8(_ c: C) -> C {
    C(r: (c.r * 255).rounded() / 255, g: (c.g * 255).rounded() / 255, b: (c.b * 255).rounded() / 255)
}

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

func pmod(_ a: Double, _ m: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

func toHSV(_ c: C) -> (Double, Double, Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
    var h = 0.0
    if d > 0 {
        if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = 2 + (c.b - c.r) / d } else { h = 4 + (c.r - c.g) / d }
        h = pmod(h / 6, 1)
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}

func fromHSV(_ h: Double, _ s: Double, _ v: Double) -> C {
    if s == 0 { return C(r: v, g: v, b: v) }
    let hh = h * 6, i = Int(hh) % 6, f = hh - Double(Int(hh))
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return C(r: v, g: t, b: p)
    case 1: return C(r: q, g: v, b: p)
    case 2: return C(r: p, g: v, b: t)
    case 3: return C(r: p, g: q, b: v)
    case 4: return C(r: t, g: p, b: v)
    default: return C(r: v, g: p, b: q)
    }
}

func hueToward(_ h: Double, _ target: Double, _ deg: Double) -> Double {
    let d = pmod(target - h + 0.5, 1) - 0.5, step = deg / 360
    if abs(d) <= step { return pmod(target, 1) }
    return pmod(h + (d < 0 ? -step : step), 1)
}

/// petgen.shade: darker, a little more saturated, hue nudged toward blue-violet.
func shade(_ c: C, _ amount: Double, hueShift: Double = 12) -> C {
    var (h, s, v) = toHSV(c)
    if s > 0.05 {
        h = hueToward(h, 0.68, hueShift * min(1, amount / 0.3))
        s = min(1, s + (1 - s) * 0.35 * amount + 0.12 * amount)
    }
    v *= 1 - amount
    return q8(fromHSV(h, s, v))
}

/// petgen.tint: lighter, less saturated, hue nudged toward warm yellow.
func tint(_ c: C, _ amount: Double, hueShift: Double = 10) -> C {
    var (h, s, v) = toHSV(c)
    if s > 0.05 { h = hueToward(h, 0.15, hueShift * min(1, amount / 0.3)) }
    s *= 1 - 0.75 * amount
    v += (1 - v) * amount
    return q8(fromHSV(h, s, v))
}

// The face's own colours, sampled from the image.
let BLUE = hex("#0294C3")
let INK = hex("#000000")
let WHITE = hex("#FFFFFF")
let TEETH = hex("#FFF8B0")
let MOUTH = hex("#752D2E")
let TONGUE = hex("#CA353B")
let MATERIALS = [BLUE, INK, WHITE, TEETH, MOUTH, TONGUE]
let M_BLUE = 0, M_INK = 1, M_WHITE = 2, M_TEETH = 3, M_MOUTH = 4, M_TONGUE = 5

let OUTLINE = hex("#1C3157")         // the ball's outline
let SHADOW_INK = hex("#0B1A3A")      // rim shade target (a deep navy, never grey)
let LIT_SKIN = tint(BLUE, 0.42)      // lit side of the skin (petgen's top tone)
let REFLECT = tint(BLUE, 0.30)       // reflected light just inside the bottom-right rim
let GROUND_SHADOW = hex("#0A1530")
let SCREEN = hex("#8FE3FF")          // laptop glow (petgen SCREEN)
let PIXEL_INK = hex("#0B0F1A")       // pixel variant: the family never uses pure black

// MARK: - Image buffer (premultiplied RGBA, Double)

let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!

final class Img {
    let w: Int, h: Int
    var p: [Double]

    init(_ w: Int, _ h: Int, fill: C? = nil) {
        self.w = w
        self.h = h
        p = [Double](repeating: 0, count: w * h * 4)
        if let f = fill {
            for i in 0..<(w * h) { p[i * 4] = f.r; p[i * 4 + 1] = f.g; p[i * 4 + 2] = f.b; p[i * 4 + 3] = 1 }
        }
    }

    func alpha(_ x: Int, _ y: Int) -> Double {
        (x < 0 || y < 0 || x >= w || y >= h) ? 0 : p[(y * w + x) * 4 + 3]
    }

    /// Source-over with a straight colour and coverage a.
    func blend(_ x: Int, _ y: Int, _ c: C, _ a: Double) {
        guard x >= 0, y >= 0, x < w, y < h, a > 0 else { return }
        let i = (y * w + x) * 4, k = 1 - a
        p[i] = c.r * a + p[i] * k
        p[i + 1] = c.g * a + p[i + 1] * k
        p[i + 2] = c.b * a + p[i + 2] * k
        p[i + 3] = a + p[i + 3] * k
    }

    /// Source-over with premultiplied values.
    func blendPre(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        guard x >= 0, y >= 0, x < w, y < h, a > 0 else { return }
        let i = (y * w + x) * 4, k = 1 - a
        p[i] = r + p[i] * k
        p[i + 1] = g + p[i + 1] * k
        p[i + 2] = b + p[i + 2] * k
        p[i + 3] = a + p[i + 3] * k
    }

    func color(_ x: Int, _ y: Int) -> C? {
        let i = (y * w + x) * 4
        let a = p[i + 3]
        return a <= 0 ? nil : C(r: p[i] / a, g: p[i + 1] / a, b: p[i + 2] / a)
    }

    func paste(_ s: Img, _ x: Int, _ y: Int) {
        for j in 0..<s.h {
            for i in 0..<s.w {
                let k = (j * s.w + i) * 4
                if s.p[k + 3] > 0 { blendPre(x + i, y + j, s.p[k], s.p[k + 1], s.p[k + 2], s.p[k + 3]) }
            }
        }
    }

    func scaled(_ k: Int) -> Img {
        let o = Img(w * k, h * k)
        for y in 0..<(h * k) {
            for x in 0..<(w * k) {
                let s = ((y / k) * w + x / k) * 4, d = (y * o.w + x) * 4
                o.p[d] = p[s]; o.p[d + 1] = p[s + 1]; o.p[d + 2] = p[s + 2]; o.p[d + 3] = p[s + 3]
            }
        }
        return o
    }

    func cg() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { bytes[i] = UInt8(max(0, min(255, (p[i] * 255).rounded()))) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: SRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func from(_ cg: CGImage) -> Img {
        let ctx = bitmap(cg.width, cg.height)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let o = Img(cg.width, cg.height)
        let d = ctx.data!.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        for i in 0..<(cg.width * cg.height * 4) { o.p[i] = Double(d[i]) / 255 }
        return o
    }
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: SRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func loadCG(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

func savePNG(_ img: CGImage, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("failed to write \(path)") }
}

func cgColor(_ c: C, _ a: Double = 1) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a) }

// MARK: - Family glyphs (copied from petgen.py: fx_exclaim, fx_sweat, fx_cross, fx_sparkle,
// fx_dots, prop_laptop(i, width=16); colours resolved, outlines included)

struct Glyph {
    let w: Int, h: Int
    let px: [C?]

    init(_ pal: [String], _ rows: [String]) {
        let cols = pal.map(hex)
        h = rows.count
        w = rows[0].count
        var out = [C?]()
        let keys = Array("abcdefghijklmnopqrstuvwxyz")
        for r in rows {
            for ch in r { out.append(ch == "." ? nil : cols[keys.firstIndex(of: ch)!]) }
        }
        px = out
    }

    func flipped() -> Glyph { Glyph(w: w, h: h, px: (0..<h).flatMap { y in (0..<w).map { x in px[y * w + (w - 1 - x)] } }) }

    private init(w: Int, h: Int, px: [C?]) { self.w = w; self.h = h; self.px = px }
}

let LAPTOP_ROWS = ["..aaaaaaaaaaaaaaaa..", ".abbbbbbbbbbbbbbbba.", ".accdddddddddddddea.", ".acddddddddddddddea.",
                   ".acddddddffddddddea.", ".acdddddfggfdddddea.", ".acddddddffddddddea.", ".acddddddddddddddea.",
                   ".acddddddddddddddea.", ".aeeeeeeeeeeeeeeeea.", "ahhhhhhhhhhhhhhhhhha", "aijjjjjjjjjjjjjjjjka",
                   ".aaaaaaaaaaaaaaaaaa."]
let LAPTOP_GLOW = [("9FD1E8", "FFFFFF"), ("A6C9DE", "D8F5FF"), ("A2CEE3", "EEFBFF"), ("A9C6D9", "C7F1FF"),
                   ("A1CFE5", "F4FCFF"), ("A5CADF", "DDF7FF")]
let DOTS_ROWS: (Int) -> [String] = { n in
    let dots = ["abbbbbbbbbbba", "abbccbbbbbbba", "abbccbccbbbba", "abbccbccbccba"][n]
    return ["..aaaaaaaaa..", ".abbbbbbbbba.", "abbbbbbbbbbba", dots, "abbbbbbbbbbba", ".addddddddda.",
            "..abdaaaaaa..", "..ada........", "...a........."]
}

let GLYPHS: [String: Glyph] = {
    var g: [String: Glyph] = [
        "exclaim": Glyph(["622904", "FADC6C", "F5A623", "BF6614"],
                         [".aa.", "abca", "abca", "abca", "acca", "acda", ".aa.", "abca", "acda", ".aa."]),
        "exclaim-small": Glyph(["622904", "FADC6C", "F5A623", "BF6614"],
                               [".aa.", "abca", "abca", "acda", ".aa.", "acda", ".aa."]),
        "sweat": Glyph(["212A5D", "7FA7E8", "C3E0F8", "5D77BE"],
                       ["..a...", ".aba..", ".abba.", "acbbba", "abbbda", ".adda.", "..aa.."]),
        "cross": Glyph(["5C1024", "EE8676", "E5484D", "B73147"],
                       [".aa.aa.", "abcabca", ".accda.", "..aca..", ".accda.", "acdacda", ".aa.aa."]),
        "sparkle0": Glyph(["8C6838", "FFE48A", "FFFFFF"], ["..a..", ".aba.", "abcba", ".aba.", "..a.."]),
        "sparkle1": Glyph(["8C6838", "FFE48A", "FFFFFF"],
                          ["...a...", "..aba..", ".aabaa.", "abbcbba", ".aabaa.", "..aba..", "...a..."]),
        "sparkle2": Glyph(["8C6838", "FFE48A", "FFFFFF"],
                          ["....a....", "...aba...", "...aba...", ".aabcbaa.", "abbcccbba", ".aabcbaa.", "...aba...",
                           "...aba...", "....a...."]),
        // _example.py's DUST puffs (the family copies these): contact, then the trailing wisps
        "dust0": Glyph(["B4ABCF", "E2DDF0"], [".aa.", "abba", ".aa."]),
        "dust1": Glyph(["C3BBDB"], [".a..a", "a....", ".a..."]),
    ]
    for n in 0...3 { g["dots\(n)"] = Glyph(["464364", "FFFFFF", "2A2238", "D9D4E4"], DOTS_ROWS(n)) }
    for (i, (ring, core)) in LAPTOP_GLOW.enumerated() {
        g["laptop\(i)"] = Glyph(["292A45", "DCE2EE", "B3BBCB", "9AA2B5", "7D8599", ring, core, "5A6072", "A9B1C2",
                                 "8890A3", "6E7588"], LAPTOP_ROWS)
    }
    return g
}()

func pasteGlyph(_ img: Img, _ name: String, _ lx: Int, _ ly: Int, scale k: Int, flip: Bool = false) {
    var g = GLYPHS[name]!
    if flip { g = g.flipped() }
    for y in 0..<g.h {
        for x in 0..<g.w {
            guard let c = g.px[y * g.w + x] else { continue }
            for j in 0..<k { for i in 0..<k { img.blend((lx + x) * k + i, (ly + y) * k + j, c, 1) } }
        }
    }
}

// MARK: - The face texture

let FACE = loadCG(facePath)
let FW = FACE.width, FH = FACE.height
// Where the face sits on the ball, in image pixels: centre and the radius that becomes the
// ball's silhouette at rest. Every feature (brows, cheek lines, chin line) lies within
// ~200 px of (223, 235), so 218 leaves a little blue rim around them.
let FCX = 223.0, FCY = 235.0, FR = 218.0
// Eye discs measured from the image: (centre x, centre y, radius).
let EYES: [(Double, Double, Double)] = [(180.5, 132.8, 33.0), (267.0, 132.2, 30.5)]

/// Eye states. Every lid is painted in the face's own blue with a thin dark lid line.
enum Lid: Hashable {
    case open
    case half(Double)      // upper lids down by this fraction; the edge bows down like the eyeball
    case closed            // a relaxed closed eye: a soft downward arc
    case worried(Double)   // upper lids down, the edge slanted ~18 deg so the inner corners sit higher
    case squeeze(Double)   // lower lids pushed up, the edge arched upward (effort or joy)
    var key: String { "\(self)" }
}

func drawLids(_ ctx: CGContext, _ lid: Lid) {
    if lid == .open { return }
    for (k, (ex, ey, er)) in EYES.enumerated() {
        let cover = er + 3.0
        let x0 = ex - cover - 2, x1 = ex + cover + 2
        let top = ey - cover - 2, bottom = ey + cover + 2
        let edge = CGMutablePath(), fill = CGMutablePath()
        var lineWidth = 7.0
        switch lid {
        case .open:
            continue
        case .closed:
            fill.addRect(CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top))
            edge.move(to: CGPoint(x: ex - er, y: ey + er * 0.08))
            edge.addQuadCurve(to: CGPoint(x: ex + er, y: ey + er * 0.08), control: CGPoint(x: ex, y: ey + er * 0.62))
            lineWidth = 9
        case .half(let a), .worried(let a):
            // edge: through (ex, yc) at the middle, bowing down like the eyeball's top; the
            // worried lid also tilts so the inner corner (toward the nose) is higher
            let yc = ey - er + a * 2 * er
            var bow = er * 0.55, slope = 0.0
            if case .worried = lid {
                bow = er * 0.18
                slope = tan(18 * Double.pi / 180) * (k == 0 ? 1 : -1)   // left eye: inner side is +x
            }
            let y0 = yc - bow + slope * (x0 - ex) * -1, y1 = yc - bow + slope * (x1 - ex) * -1
            edge.move(to: CGPoint(x: x0, y: y0))
            edge.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: ex, y: yc + bow))
            fill.move(to: CGPoint(x: x0, y: top))
            fill.addLine(to: CGPoint(x: x1, y: top))
            fill.addLine(to: CGPoint(x: x1, y: y1))
            fill.addQuadCurve(to: CGPoint(x: x0, y: y0), control: CGPoint(x: ex, y: yc + bow))
            fill.closeSubpath()
        case .squeeze(let a):
            let yc = ey + er - a * 2 * er, bow = er * 0.45
            edge.move(to: CGPoint(x: x0, y: yc + bow))
            edge.addQuadCurve(to: CGPoint(x: x1, y: yc + bow), control: CGPoint(x: ex, y: yc - bow))
            fill.move(to: CGPoint(x: x0, y: bottom))
            fill.addLine(to: CGPoint(x: x1, y: bottom))
            fill.addLine(to: CGPoint(x: x1, y: yc + bow))
            fill.addQuadCurve(to: CGPoint(x: x0, y: yc + bow), control: CGPoint(x: ex, y: yc - bow))
            fill.closeSubpath()
        }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: ex - cover, y: ey - cover, width: 2 * cover, height: 2 * cover))
        ctx.clip()
        ctx.setFillColor(cgColor(BLUE))
        ctx.addPath(fill)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        let lr = er + 1.0
        ctx.addEllipse(in: CGRect(x: ex - lr, y: ey - lr, width: 2 * lr, height: 2 * lr))
        ctx.clip()
        ctx.addPath(edge)
        ctx.setStrokeColor(cgColor(INK))
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

final class Tex {
    let w = FW, h = FH
    var rgb: [Double]

    init(lid: Lid) {
        let ctx = bitmap(FW, FH)
        ctx.draw(FACE, in: CGRect(x: 0, y: 0, width: FW, height: FH))
        ctx.translateBy(x: 0, y: CGFloat(FH))
        ctx.scaleBy(x: 1, y: -1)                    // top-left origin, matching memory rows
        drawLids(ctx, lid)
        let d = ctx.data!.bindMemory(to: UInt8.self, capacity: FW * FH * 4)
        rgb = [Double](repeating: 0, count: FW * FH * 3)
        for i in 0..<(FW * FH) {
            rgb[i * 3] = Double(d[i * 4]) / 255
            rgb[i * 3 + 1] = Double(d[i * 4 + 1]) / 255
            rgb[i * 3 + 2] = Double(d[i * 4 + 2]) / 255
        }
    }

    /// Bilinear sample at image coordinates (pixel centres at +0.5); outside the image is the face blue.
    func sample(_ x: Double, _ y: Double) -> C {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        if x0 < 0 || y0 < 0 || x0 + 1 >= w || y0 + 1 >= h { return BLUE }   // the image border is face blue
        let i = (y0 * w + x0) * 3, j = i + w * 3
        let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
        return rgb.withUnsafeBufferPointer { d in
            C(r: d[i] * w00 + d[i + 3] * w10 + d[j] * w01 + d[j + 3] * w11,
              g: d[i + 1] * w00 + d[i + 4] * w10 + d[j + 1] * w01 + d[j + 4] * w11,
              b: d[i + 2] * w00 + d[i + 5] * w10 + d[j + 2] * w01 + d[j + 5] * w11)
        }
    }
}

var texCache: [String: Tex] = [:]
func faceTex(_ lid: Lid) -> Tex {
    if let c = texCache[lid.key] { return c }
    let t = Tex(lid: lid)
    texCache[lid.key] = t
    return t
}

// MARK: - Pose and ball geometry (logical units; the smooth render multiplies by 4)

struct FX {
    let name: String, x: Int, y: Int
    var flip = false
}

struct Pose {
    var dx = 0.0                 // ball centre offset, logical px (+ right)
    var lift = 0.0               // ball raised off the ground, logical px
    var bw = 32.0, bh = 32.0     // face disc size in logical px (outline adds 1 px each side)
    var roll = 0.0               // degrees, + clockwise (lean right)
    var yaw = 0.0                // degrees, + face turns toward screen right
    var pitch = 0.0              // degrees, + face looks down
    var lid = Lid.open
    var dim = 0.0                // failed: desaturate and darken 0..1
    var glow = 0.0               // working: laptop light on the ball
    var shadow = true            // smooth only: the family's pixel pets have no ground shadow
    var laptop: Int? = nil
    var fx: [FX] = []            // in front, pasted last
    var back: [FX] = []          // behind the ball (dust)
}

func P(_ f: (inout Pose) -> Void = { _ in }) -> Pose {
    var p = Pose()
    f(&p)
    return p
}

struct Geo {
    let bx, by, rx, ry: Double   // atlas px
    let m: [Double]              // face rotation, row-major 3x3
}

func geometry(_ p: Pose) -> Geo {
    let rx = p.bw * Double(K) / 2, ry = p.bh * Double(K) / 2
    let bottom = Double(GROUND) * Double(K) - p.lift * Double(K)   // face disc bottom edge
    let by = bottom - ry, bx = Double(CW) / 2 + p.dx * Double(K)
    let r = p.roll * .pi / 180, y = p.yaw * .pi / 180, x = p.pitch * .pi / 180
    let rz = [cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1]
    let ry3 = [cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)]
    let rx3 = [1, 0, 0, 0, cos(x), sin(x), 0, -sin(x), cos(x)]
    func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { o[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return o
    }
    return Geo(bx: bx, by: by, rx: rx, ry: ry, m: mul(mul(rz, ry3), rx3))
}

let LIGHT: (Double, Double, Double) = {
    let (x, y, z) = (-0.4, -0.55, 0.73)
    let n = (x * x + y * y + z * z).squareRoot()
    return (x / n, y / n, z / n)
}()

/// Face-image coordinates for the sphere point n (world), or nil on the back of the ball.
@inline(__always) func texCoord(_ g: Geo, _ u: Double, _ v: Double, _ z: Double) -> (Double, Double)? {
    let m = g.m   // q = M^T n
    let qx = m[0] * u + m[3] * v + m[6] * z
    let qy = m[1] * u + m[4] * v + m[7] * z
    let qz = m[2] * u + m[5] * v + m[8] * z
    if qz < 0 { return nil }
    return (FCX + qx * FR, FCY + qy * FR)
}

func laptopTop() -> Int { GROUND - 13 + 1 }   // logical row of the lid's top outline

// MARK: - Smooth renderer (192 x 208)

func dimmed(_ c: C, _ dim: Double) -> C {
    guard dim > 0 else { return c }
    let l = lum(c)
    let d = mix(c, C(r: l, g: l, b: l), 0.55 * dim)
    return C(r: d.r * (1 - 0.16 * dim), g: d.g * (1 - 0.16 * dim), b: d.b * (1 - 0.13 * dim))
}

/// How much a colour is the face's blue skin (1) rather than ink, catch-light, teeth or mouth (0).
/// Ball shading is weighted by this, so the features keep the image's colours.
@inline(__always) func skinness(_ c: C) -> Double {
    max(0, 1 - (abs(c.r - BLUE.r) + abs(c.g - BLUE.g) + abs(c.b - BLUE.b)) / 0.45)
}

/// How much screen light a colour takes: none on the black ink or the white catch-lights.
@inline(__always) func litness(_ c: C) -> Double {
    smoothstep(0.04, 0.25, max(c.r, c.g, c.b)) * (1 - smoothstep(0.85, 0.97, min(c.r, c.g, c.b)))
}

// The sheen: a soft white spot on the skin at the top-left, in ball-normalised coordinates.
let SHEEN_U = -0.45, SHEEN_V = -0.5, SHEEN_R = 0.35, SHEEN_PEAK = 0.28

func renderSmooth(_ p: Pose) -> Img {
    let img = Img(CW, CH)
    let g = geometry(p)
    let kk = Double(K)
    let floorY = GROUND * K + K - 1      // 191: nothing may touch rows 192-207
    if p.shadow {   // soft ground shadow, shrinking and fading as the ball lifts; clipped at the floor
        let s = max(0.45, 1 - 0.05 * p.lift)
        let sx = 52 * s * p.bw / 32, sy = 6.0 * s, cx = g.bx, cy = Double(floorY) - 5
        let amax = 0.30 * max(0.35, 1 - 0.06 * p.lift)
        for y in Int(cy - sy - 2)...min(floorY, Int(cy + sy + 2)) {
            for x in Int(cx - sx - 2)...Int(cx + sx + 2) {
                let u = (Double(x) + 0.5 - cx) / sx, v = (Double(y) + 0.5 - cy) / sy
                let r = (u * u + v * v).squareRoot()
                img.blend(x, y, GROUND_SHADOW, amax * (1 - smoothstep(0.35, 1.0, r)))
            }
        }
    }
    for f in p.back { pasteGlyph(img, f.name, f.x, f.y, scale: K, flip: f.flip) }

    let tex = faceTex(p.lid)
    let O = 4.0                                   // outline width, px
    let lapY = Double(laptopTop() + 1) * kk       // the lid's top edge, px
    let x0 = max(0, Int(g.bx - g.rx - O - 2)), x1 = min(CW - 1, Int(g.bx + g.rx + O + 2))
    let y0 = max(0, Int(g.by - g.ry - O - 2)), y1 = min(floorY, Int(g.by + g.ry + O + 2))
    let n = 3, inv = 1.0 / Double(n * n)
    let rx4 = pow(g.rx, 4), ry4 = pow(g.ry, 4), rmin = min(g.rx, g.ry)
    for y in y0...y1 {
        for x in x0...x1 {
            var ar = 0.0, ag = 0.0, ab = 0.0, aa = 0.0
            for j in 0..<n {
                for i in 0..<n {
                    let sx = Double(x) + (Double(i) + 0.5) / Double(n), sy = Double(y) + (Double(j) + 0.5) / Double(n)
                    let u = (sx - g.bx) / g.rx, v = (sy - g.by) / g.ry
                    let r2 = u * u + v * v
                    if r2 <= 1 {
                        let z = (1 - r2).squareRoot()
                        var c = BLUE
                        if let (tx, ty) = texCoord(g, u, v, z) { c = tex.sample(tx, ty) }
                        let skin = skinness(c)
                        // fixed top-left light, on the skin only
                        let d = u * LIGHT.0 + v * LIGHT.1 + z * LIGHT.2
                        let rho = r2.squareRoot()
                        let shadeAmt = smoothstep(0.38, -0.62, d) * 0.36 + smoothstep(0.86, 1.0, rho) * 0.07
                        let edgePx = (1 - rho) * rmin
                        let facing = (u * 0.6 + v * 0.8) / max(rho, 1e-6)
                        let reflect = (1 - smoothstep(0.8, 3.2, edgePx)) * smoothstep(0.25, 0.85, facing) * 0.42
                        let lit = smoothstep(0.55, 0.97, d) * 0.22
                        let sd = ((u - SHEEN_U) * (u - SHEEN_U) + (v - SHEEN_V) * (v - SHEEN_V)).squareRoot() / SHEEN_R
                        let sheen = SHEEN_PEAK * (1 - smoothstep(0, 1, sd))
                        c = mix(c, SHADOW_INK, shadeAmt * skin)
                        c = mix(c, REFLECT, reflect * skin)
                        c = mix(c, LIT_SKIN, lit * skin)
                        c = mix(c, WHITE, sheen * skin)
                        if p.glow > 0 {   // the screen's light on the ball just above the lid
                            let gu = (sx - Double(CW) / 2) / 40, gv = (sy - lapY) / 22
                            let gr = gu * gu + gv * gv
                            let a = 0.4 * p.glow * litness(c) * (1 - smoothstep(0.45, 1.0, gr))
                            if gr < 1 {   // screen blend: lights the colour toward SCREEN without greying the teeth
                                c = C(r: 1 - (1 - c.r) * (1 - a * SCREEN.r), g: 1 - (1 - c.g) * (1 - a * SCREEN.g),
                                      b: 1 - (1 - c.b) * (1 - a * SCREEN.b))
                            }
                        }
                        c = dimmed(c, p.dim)
                        ar += c.r; ag += c.g; ab += c.b; aa += 1
                    } else {
                        let rho = r2.squareRoot()
                        let du = sx - g.bx, dv = sy - g.by
                        let grad = (du * du / rx4 + dv * dv / ry4).squareRoot() / rho
                        if (rho - 1) / grad <= O {
                            let c = dimmed(OUTLINE, p.dim * 0.5)
                            ar += c.r; ag += c.g; ab += c.b; aa += 1
                        }
                    }
                }
            }
            if aa > 0 { img.blendPre(x, y, ar * inv, ag * inv, ab * inv, aa * inv) }
        }
    }
    if let l = p.laptop { pasteGlyph(img, "laptop\(l)", W / 2 - 10, laptopTop(), scale: K) }
    for f in p.fx { pasteGlyph(img, f.name, f.x, f.y, scale: K, flip: f.flip) }
    return img
}

// MARK: - Pixel renderer (48 x 52 logical, then x4)

// The fixed face: the image shrunk once to 48 scale (one logical px is ~13.6 image px) and
// cleaned up by hand. Brows, cheek lines and the chin line are thinner than a pixel there,
// so they are dropped. Strings start at x=8 (the ball's left column at rest) and are
// symmetric about the centre line between x=23 and x=24.
let PX_FACE_X0 = 8
let PX_EYE_X = [18, 25]               // left columns of the two 5x5 eyes (2 px of blue between)
let PX_MOUTH_HEAD = [                 // rows 30-35 at rest: the V of upper teeth, gaps in mouth red
    "....kkk..................kkk....",
    "...kttmkkk............kkkmttk...",
    "...kttmttmkkk......kkkmttmttk...",
    "...kmmmttmttmkk..kkmttmttmmmk...",
    "...kmmmmmmttmttkkttmttmmmmmmk...",
    "...kmmmmmmmmmttmmttmmmmmmmmmk...",
]
let PX_MOUTH_FILL = "....kmmmmmmmmmmmmmmmmmmmmmmk...."   // repeated: 2 rows at rest, fewer when squashed
let PX_MOUTH_FOOT = [                 // tongue, lower teeth, the bottom of the U
    ".....kmtmmmmmrrrrrrmmmmmtmk.....",
    "......kkmtmmrrrrrrrrmmtmkk......",
    "........kkktmtmttmtmtkkk........",
    "...........kkkkkkkkkk...........",
]
let PX_EYES: [String: [String]] = [   // 5x5; the catch-light stays top-left on both eyes
    "open": [".kkk.", "kwkkk", "kkkkk", "kkkkk", ".kkk."],
    "half": [".....", "k...k", "kkkkk", "kkkkk", ".kkk."],      // lid edge bowed like the eyeball
    "closed": [".....", ".....", "k...k", ".kkk.", "....."],
    "worried": ["....k", "..kkk", ".kwkk", "kkkkk", ".kkk."],   // left eye (inner corner high); mirrored for the right
    "squeeze": [".kkk.", "kwkkk", "kkkkk", "k...k", "....."],
]
let PX_PAL: [Character: C] = ["k": PIXEL_INK, "w": WHITE, "t": TEETH, "m": MOUTH, "r": TONGUE]
let PX_TONES = [shade(BLUE, 0.34), shade(BLUE, 0.17), BLUE, tint(BLUE, 0.42)]   // STYLE.md's ramp
let PX_GLOSS = tint(BLUE, 0.8)
// The lit band sits as a crescent high on the top-left rim, so it never touches an eye.
let RIM_LIGHT: (Double, Double, Double) = {
    let (x, y, z) = (-0.65, -0.7, 0.3)
    let n = (x * x + y * y + z * z).squareRoot()
    return (x / n, y / n, z / n)
}()

func eyeKey(_ lid: Lid) -> String {
    switch lid {
    case .open: return "open"
    case .half: return "half"
    case .closed: return "closed"
    case .worried: return "worried"
    case .squeeze: return "squeeze"
    }
}

func pxTurn(_ yaw: Double) -> Int { Int((yaw * 0.13).rounded()) }                        // 20 deg -> 3 px
/// + = down. Capped at 3 px: a flat shift has no foreshortening, so a bigger one slides the
/// mouth off the bottom of the ball instead of rolling it under.
func pxPitch(_ pitch: Double) -> Int { max(-3, min(3, Int((sin(pitch * .pi / 180) * 16).rounded()))) }

func renderPixel(_ p: Pose) -> Img {
    let img = Img(W, H)
    for f in p.back { pasteGlyph(img, f.name, f.x, f.y, scale: 1, flip: f.flip) }
    let bw = 2 * Int((p.bw / 2).rounded()), bh = Int(p.bh.rounded())   // even widths stay centred
    let lift = Int(p.lift.rounded()), dx = Int(p.dx.rounded())
    let bx = W / 2 - bw / 2 + dx, by = GROUND - lift - bh            // body box; outline goes around it
    var layer = [C?](repeating: nil, count: W * H)

    // body: petgen.sphere bands from the family LIGHT, the lit crescent and a tiny gloss
    let rx = Double(bw) / 2, ry = Double(bh) / 2, cx = Double(bx) + rx, cy = Double(by) + ry
    for py in by..<(by + bh) {
        for px in bx..<(bx + bw) {
            let u = (Double(px) + 0.5 - cx) / rx, v = (Double(py) + 0.5 - cy) / ry
            if u * u + v * v > 1 { continue }
            let z = max(0, 1 - u * u - v * v).squareRoot()
            let d = u * LIGHT.0 + v * LIGHT.1 + z * LIGHT.2
            let d2 = u * RIM_LIGHT.0 + v * RIM_LIGHT.1 + z * RIM_LIGHT.2
            var c = PX_TONES[[0.15, 0.5].filter { d > $0 }.count]
            if d2 > 0.9 { c = PX_TONES[3] }
            if d2 > 0.996 { c = PX_GLOSS }                    // a 2-3 px gloss inside the crescent
            if px >= 0, px < W, py >= 0, py < H { layer[py * W + px] = c }
        }
    }

    // the fixed face, moved by whole pixels: turn and look shift it, squash and stretch use
    // fewer or more mouth-fill rows, and a lean (roll) carries each feature (each eye, the
    // mouth) to where the roll takes its centre, rounded, so the shapes never deform. The
    // silhouette stays an upright ellipse, as in the smooth variant: shearing it notched the outline.
    let k = Double(bh) / 32
    let th = p.roll * .pi / 180
    func rolled(_ fx: Double, _ fy: Double) -> (Int, Int) {   // whole-pixel shift of a feature centre
        let ox = fx - cx, oy = fy - cy
        return (Int((ox * cos(th) - oy * sin(th) - ox).rounded()), Int((ox * sin(th) + oy * cos(th) - oy).rounded()))
    }
    let tx = pxTurn(p.yaw) + dx, ty = pxPitch(p.pitch)
    // anchored to the ball's bottom and rounded down, so the 1-px idle inhale leaves the face put
    let bottomEdge = by + bh
    let eyeTop = bottomEdge - Int(26 * k) + ty
    let mouthTop = bottomEdge - Int(17 * k) + ty
    let fill = max(1, 2 + Int(floor(Double(bh - 32) / 2)))
    let mouth = PX_MOUTH_HEAD + Array(repeating: PX_MOUTH_FILL, count: fill) + PX_MOUTH_FOOT
    func put(_ rows: [String], _ x0: Int, _ y0: Int, flip: Bool = false, shift: (Int, Int)? = nil) {
        let w = rows[0].count
        let (sx, sy) = shift ?? rolled(Double(x0) + Double(w) / 2, Double(y0) + Double(rows.count) / 2)
        for (j, row) in rows.enumerated() {
            let chars = Array(row)
            for (i, ch) in chars.enumerated() where ch != "." {
                let x = x0 + (flip ? chars.count - 1 - i : i) + sx, y = y0 + j + sy
                guard x >= 0, x < W, y >= 0, y < H, layer[y * W + x] != nil else { continue }   // clipped to the ball
                layer[y * W + x] = PX_PAL[ch]!
            }
        }
    }
    // the eyes move as a pair, with the roll's tilt between them rounded once (1 px at 9 deg)
    let eyes = PX_EYES[eyeKey(p.lid)]!
    let pair = rolled(Double(PX_EYE_X[0] + PX_EYE_X[1] + 5) / 2 + Double(tx), Double(eyeTop) + 2.5)
    let tilt = Int((Double(PX_EYE_X[1] - PX_EYE_X[0]) * sin(th)).rounded())   // + : the right eye sits lower
    put(eyes, PX_EYE_X[0] + tx, eyeTop, shift: (pair.0, pair.1 + max(0, -tilt)))
    put(eyes, PX_EYE_X[1] + tx, eyeTop, flip: eyeKey(p.lid) == "worried", shift: (pair.0, pair.1 + max(0, tilt)))
    put(mouth, PX_FACE_X0 + tx, mouthTop)

    // screen light (STYLE: one SCREEN-tinted tone just above the lid) and the failed dimming
    let lapTop = Double(laptopTop())
    for i in 0..<(W * H) {
        guard var c = layer[i] else { continue }
        if p.glow > 0, p.laptop != nil, c != PIXEL_INK, c != WHITE, c != TEETH {   // teeth stay cream
            let gu = (Double(i % W) + 0.5 - Double(W) / 2) / 9.5, gv = (Double(i / W) + 0.5 - lapTop) / 5
            if gu * gu + gv * gv <= 1 { c = q8(mix(c, SCREEN, 0.38 * p.glow)) }
        }
        if p.dim > 0 { c = q8(dimmed(c, p.dim)) }
        layer[i] = c
    }

    // 1-px outline outside the silhouette, 4-neighbour, drawn at 48 scale
    let outline = q8(dimmed(OUTLINE, p.dim * 0.5))
    var ball = layer
    for y in 0..<H {
        for x in 0..<W where layer[y * W + x] == nil {
            for (ddx, ddy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let xx = x + ddx, yy = y + ddy
                if xx >= 0, yy >= 0, xx < W, yy < H, layer[yy * W + xx] != nil { ball[y * W + x] = outline; break }
            }
        }
    }
    for i in 0..<(W * H) { if let c = ball[i] { img.blend(i % W, i / W, c, 1) } }
    if let l = p.laptop { pasteGlyph(img, "laptop\(l)", W / 2 - 10, laptopTop(), scale: 1) }
    for f in p.fx { pasteGlyph(img, f.name, f.x, f.y, scale: 1, flip: f.flip) }
    return img
}

// MARK: - Rows

func idle() -> [Pose] {
    [
        P(),
        P { $0.lid = .half(0.4) },              // blink on the two 110 ms frames
        P { $0.lid = .closed },
        P { $0.bh = 33 },                       // inhale: the top rises 4 px, the face stays put
        P { $0.bh = 33 },
        P(),
    ]
}

/// _example.py's dust placement: behind the back foot, puff then wisps.
func dust(_ i: Int, _ s: Double) -> FX {
    let name = "dust\(i)"
    return s > 0 ? FX(name: name, x: 6 - 3 * i, y: 42) : FX(name: name, x: 38 + 3 * i, y: 42, flip: true)
}

func run(_ s: Double) -> [Pose] {
    // two hops per loop: land (squash, dust), push off (stretch), peak, fall
    let hop: [(lift: Double, bw: Double, bh: Double, dx: Double, roll: Double, pitch: Double, dust: Int?)] = [
        (0, 36, 28, -1, 4, 4, 0),
        (3, 30, 34, 0, 8, 0, 1),
        (6, 32, 32, 1, 9, -3, nil),
        (3, 30, 33, 1, 8, 0, nil),
    ]
    return (0..<8).map { i in
        let h = hop[i % 4]
        return P {
            $0.lift = h.lift; $0.bw = h.bw; $0.bh = h.bh
            $0.dx = h.dx * s; $0.roll = h.roll * s; $0.yaw = 20 * s; $0.pitch = h.pitch
            if let d = h.dust { $0.back = [dust(d, s)] }
        }
    }
}

func waving() -> [Pose] {
    // a happy rock: roll a little left, bounce, roll a little right, bounce
    [
        P { $0.roll = -9; $0.dx = -2; $0.yaw = -8; $0.bw = 34; $0.bh = 31 },
        P { $0.lift = 3; $0.bh = 33; $0.pitch = -4 },
        P { $0.roll = 9; $0.dx = 2; $0.yaw = 8; $0.bw = 34; $0.bh = 31 },
        P { $0.lift = 3; $0.bh = 33; $0.pitch = -4 },
    ]
}

func jumping() -> [Pose] {
    [
        P { $0.bw = 36; $0.bh = 27; $0.lid = .squeeze(0.38); $0.pitch = 4 },   // anticipation: effort squeeze
        P { $0.lift = 7; $0.bw = 29; $0.bh = 36; $0.pitch = -6 },              // stretch rise
        P { $0.lift = 11; $0.pitch = -10 },                                    // peak
        P { $0.lift = 5; $0.bw = 30; $0.bh = 34; $0.pitch = -4 },              // fall
        P { $0.bw = 36; $0.bh = 28; $0.pitch = 3 },                            // land squash
    ]
}

func failed() -> [Pose] {
    var out: [Pose] = []
    // the shake: worried from the first frame, already a little darker
    for (i, (dx, bh, roll)) in [(-1.0, 32.0, -4.0), (1, 31, 4), (-1, 30, -4), (0, 30, 0)].enumerated() {
        out.append(P {
            $0.dx = dx; $0.bh = bh; $0.bw = bh < 31 ? 34 : 32; $0.roll = roll; $0.pitch = 4
            $0.lid = .worried(0.3)
            $0.dim = 0.22 + 0.04 * Double(i)
            $0.fx = [FX(name: "cross", x: 36 + Int(dx), y: 5 + i % 2)]
        })
    }
    // the droop: slumped, tilted, looking at the floor, sweat sliding down
    for k in 0..<4 {
        out.append(P {
            $0.bw = 36; $0.bh = 29; $0.roll = -9; $0.dx = -1; $0.pitch = 20; $0.lid = .worried(0.5); $0.dim = 0.34
            $0.fx = [FX(name: "sweat", x: 35, y: 15 + 2 * k)]
        })
    }
    return out
}

func waiting() -> [Pose] {
    let bx = W / 2 - 2
    return [
        P { $0.pitch = -5; $0.fx = [FX(name: "exclaim-small", x: bx, y: 5)] },
        P { $0.pitch = -7; $0.bw = 30; $0.bh = 33; $0.fx = [FX(name: "exclaim", x: bx, y: 1)] },   // the pop
        // then a calm 4-px bob, the ! riding along
        P { $0.pitch = -5; $0.lift = 1; $0.fx = [FX(name: "exclaim", x: bx, y: 1)] },
        P { $0.pitch = -5; $0.fx = [FX(name: "exclaim", x: bx, y: 2)] },
        P { $0.pitch = -5; $0.lift = 1; $0.fx = [FX(name: "exclaim", x: bx, y: 1)] },
        P { $0.pitch = -5; $0.fx = [FX(name: "exclaim", x: bx, y: 2)] },
    ]
}

func working() -> [Pose] {
    // grounded behind the laptop, the face rolled up so the grin clears the lid; it nods
    // toward the screen on a two-frame cadence (4 px smooth, 1 px pixel), the body still
    (0..<6).map { i in
        P {
            $0.laptop = i; $0.glow = 1
            $0.pitch = (i == 2 || i == 3) ? -4.5 : -8
            $0.fx = [FX(name: "dots\(1 + i / 2)", x: 33, y: 4)]
        }
    }
}

func review() -> [Pose] {
    let hop: [(lift: Double, bw: Double, bh: Double, roll: Double)] = [
        (0, 34, 29, 0), (3, 30, 34, -5), (5, 32, 32, 0), (3, 30, 33, 5), (0, 34, 29, 0), (0, 32, 32, 0),
    ]
    let sparkles: [(Int, Int, [Int?])] = [
        (7, 11, [0, 1, 2, 1, 0, nil]),
        (41, 7, [nil, 0, 1, 2, 1, 0]),
        (43, 22, [1, 0, nil, 0, 1, 1]),
    ]
    return (0..<6).map { i in
        let h = hop[i]
        return P {
            $0.lift = h.lift; $0.bw = h.bw; $0.bh = h.bh; $0.roll = h.roll; $0.pitch = -5
            $0.fx = sparkles.compactMap { (x, y, sizes) in
                guard let s = sizes[i] else { return nil }
                let gl = GLYPHS["sparkle\(s)"]!
                return FX(name: "sparkle\(s)", x: x - gl.w / 2, y: y - gl.h / 2)
            }
        }
    }
}

let POSES: [String: [Pose]] = [
    "idle": idle(), "running-right": run(1), "running-left": run(-1), "waving": waving(),
    "jumping": jumping(), "failed": failed(), "waiting": waiting(), "running": working(), "review": review(),
]

// MARK: - Previews

let CHECK_A = hex("#F4F4F6"), CHECK_B = hex("#E7E7EB"), GUIDE = hex("#F2B8B8")
let LABEL = hex("#3B3B45"), LABEL_DIM = hex("#8C8C99"), UNUSED = hex("#D3D3DA"), DARK_BG = hex("#1E1E1E")

final class Canvas {
    let ctx: CGContext
    let w: Int, h: Int
    init(_ w: Int, _ h: Int, _ bg: C) {
        self.w = w; self.h = h
        ctx = bitmap(w, h)
        ctx.interpolationQuality = .none
        ctx.setFillColor(cgColor(bg))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, _ c: C) {
        ctx.setFillColor(cgColor(c))
        ctx.fill(CGRect(x: x, y: Double(h) - y - rh, width: rw, height: rh))
    }
    func checker(_ x: Int, _ y: Int, _ cw: Int, _ chh: Int, _ sq: Int = 8) {
        for j in stride(from: 0, to: chh, by: sq) {
            for i in stride(from: 0, to: cw, by: sq) {
                rect(Double(x + i), Double(y + j), Double(min(sq, cw - i)), Double(min(sq, chh - j)),
                     ((i / sq + j / sq) % 2 == 0) ? CHECK_A : CHECK_B)
            }
        }
    }
    func image(_ img: CGImage, _ x: Int, _ y: Int, scale: Double = 1) {
        let iw = Double(img.width) * scale, ih = Double(img.height) * scale
        ctx.draw(img, in: CGRect(x: Double(x), y: Double(h) - Double(y) - ih, width: iw, height: ih))
    }
    func text(_ s: String, _ x: Double, _ y: Double, size: Double = 13, color: C = LABEL, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(color),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: Double(h) - y - size)
        CTLineDraw(line, ctx)
    }
    func save(_ path: String) { savePNG(ctx.makeImage()!, path) }
}

func sheet(_ title: String, _ frames: [String: [Img]]) -> Canvas {
    let labelW = 190, gap = 8, top = 48, rowH = CH + 30
    let cv = Canvas(labelW + COLS * (CW + gap) + 12, top + ROWS.count * rowH + 8, hex("#FFFFFF"))
    cv.text(title, 14, 14, size: 16, bold: true)
    for (r, (name, n)) in ROWS.enumerated() {
        let y = top + r * rowH
        cv.text("\(r) \(name)", 14, Double(y + CH / 2 - 12), size: 14, bold: true)
        cv.text("\(n) frames", 14, Double(y + CH / 2 + 8), size: 12, color: LABEL_DIM)
        for i in 0..<COLS {
            let x = labelW + i * (CW + gap)
            if i >= n { cv.rect(Double(x), Double(y), Double(CW), Double(CH), UNUSED); continue }
            cv.checker(x, y, CW, CH)
            cv.rect(Double(x), Double(y + (GROUND + 1) * K), Double(CW), 1, GUIDE)     // ground guide
            cv.rect(Double(x + CW / 2), Double(y), 1, 4, GUIDE)
            cv.rect(Double(x + CW / 2), Double(y + CH - 4), 1, 4, GUIDE)
            cv.image(frames[name]![i].cg(), x, y)
            cv.text("\(i)", Double(x + 2), Double(y + CH + 4), size: 11, color: LABEL_DIM)
            let ms = "\(TIMINGS[name]![i])"
            cv.text(ms, Double(x + CW - 8 * ms.count - 2), Double(y + CH + 4), size: 11, color: LABEL_DIM)
        }
    }
    return cv
}

func darkStrip(_ frames: [String: [Img]]) -> Canvas {
    let gap = 12
    let cv = Canvas(ROWS.count * (CW + gap) + gap, CH + 2 * gap + 18, DARK_BG)
    for (r, (name, _)) in ROWS.enumerated() {
        let x = gap + r * (CW + gap)
        cv.image(frames[name]![0].cg(), x, gap)
        cv.text(name, Double(x + CW / 2 - 4 * name.count), Double(gap + CH + 2), size: 12, color: hex("#8A8A8A"))
    }
    return cv
}

func rowStrip(_ fs: [Img]) -> Canvas {
    let gap = 4
    let cv = Canvas(fs.count * (CW + gap) - gap, CH, hex("#FFFFFF"))
    for (i, f) in fs.enumerated() {
        let x = i * (CW + gap)
        cv.checker(x, 0, CW, CH)
        cv.rect(Double(x), Double((GROUND + 1) * K), Double(CW), 1, GUIDE)
        cv.image(f.cg(), x, 0)
    }
    return cv
}

func writeGIF(_ frames: [String: [Img]], _ path: String) {
    var seq: [(CGImage, Int)] = []
    for (name, n) in ROWS {
        let loops = name == "idle" ? 1 : (name == "jumping" ? 1 : 2)
        let mult = name == "idle" ? IDLE_LOOP_MULT : 1
        let labelled: [CGImage] = (0..<n).map { i in
            let cv = Canvas(CW, CH + 22, hex("#D6D6D6"))
            cv.image(frames[name]![i].cg(), 0, 0)
            cv.text(name, 6, Double(CH + 4), size: 12, color: LABEL)
            return cv.ctx.makeImage()!
        }
        for _ in 0..<loops { for i in 0..<n { seq.append((labelled[i], TIMINGS[name]![i] * mult)) } }
    }
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, seq.count, nil)!
    CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    for (img, ms) in seq {
        let t = Double(ms) / 1000
        CGImageDestinationAddImage(dst, img, [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: t, kCGImagePropertyGIFUnclampedDelayTime as String: t]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dst) else { fatalError("failed to write \(path)") }
}

// MARK: - Pack

func jsonString(_ s: String) -> String {
    let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
    let a = String(data: d, encoding: .utf8)!
    return String(a.dropFirst().dropLast())
}

func petJSON() -> String {
    var lines = [
        "  \"id\": \(jsonString(PET_ID))",
        "  \"displayName\": \(jsonString(DISPLAY_NAME))",
        "  \"description\": \(jsonString(DESCRIPTION))",
        "  \"spriteVersionNumber\": 1",
        "  \"spritesheetPath\": \"spritesheet.png\"",
    ]
    // keep the app pack's Sidekick-only "quips" exactly as they are
    let current = (petsDir as NSString).appendingPathComponent("\(PET_ID)/pet.json")
    if let d = FileManager.default.contents(atPath: current),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let quips = obj["quips"] as? [String: String] {
        let body = quips.keys.sorted().map { "    \(jsonString($0)): \(jsonString(quips[$0]!))" }.joined(separator: ",\n")
        lines.append("  \"quips\": {\n\(body)\n  }")
    }
    return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
}

func writePack(_ frames: [String: [Img]], _ dir: String) {
    let atlas = Img(CW * COLS, CH * ROWS.count)
    for (r, (name, n)) in ROWS.enumerated() {
        precondition(frames[name]!.count == n, "\(name) has \(frames[name]!.count) frames, wants \(n)")
        for i in 0..<n {
            let f = frames[name]![i]
            precondition(f.w == CW && f.h == CH)
            atlas.paste(f, i * CW, r * CH)
        }
    }
    savePNG(atlas.cg(), dir + "/spritesheet.png")
    try! petJSON().write(toFile: dir + "/pet.json", atomically: true, encoding: .utf8)
    let check = loadCG(dir + "/spritesheet.png")
    precondition(check.width == 1536 && check.height == 1872, "spritesheet is \(check.width)x\(check.height)")
}

// MARK: - Main

let t0 = Date()
var variants: [(String, [String: [Img]])] = []
for variant in ["smooth", "pixel"] {
    var frames: [String: [Img]] = [:]
    for (name, _) in ROWS {
        frames[name] = POSES[name]!.map { variant == "smooth" ? renderSmooth($0) : renderPixel($0).scaled(K) }
    }
    let dir = outDir + "/" + variant
    try? FileManager.default.createDirectory(atPath: dir + "/rows", withIntermediateDirectories: true)
    writePack(frames, dir)
    sheet("\(DISPLAY_NAME.uppercased())  (\(PET_ID), \(variant))", frames).save(dir + "/sheet.png")
    darkStrip(frames).save(dir + "/frames_dark.png")
    for (name, _) in ROWS { rowStrip(frames[name]!).save(dir + "/rows/\(name).png") }
    writeGIF(frames, dir + "/all.gif")
    variants.append((variant, frames))
    print("\(variant): \(dir)  (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
}

// lineup: frame 0 of every row, smooth | pixel | cat | robot
do {
    var family: [(String, [String: [Img]])] = variants
    for pet in ["cat", "robot"] {
        let atlas = loadCG(petsDir + "/\(pet)/spritesheet.png")
        var fr: [String: [Img]] = [:]
        for (r, (name, _)) in ROWS.enumerated() {
            fr[name] = [Img.from(atlas.cropping(to: CGRect(x: 0, y: r * CH, width: CW, height: CH))!)]
        }
        family.append((pet, fr))
    }
    let labelW = 170, gap = 10, top = 40
    let cv = Canvas(labelW + family.count * (CW + gap) + 6, top + ROWS.count * (CH + gap) + 6, hex("#FFFFFF"))
    for (k, (title, _)) in family.enumerated() {
        cv.text(title, Double(labelW + k * (CW + gap) + 4), 14, size: 15, bold: true)
    }
    for (r, (name, _)) in ROWS.enumerated() {
        let y = top + r * (CH + gap)
        cv.text(name, 12, Double(y + CH / 2 - 8), size: 14, bold: true)
        for (k, (_, fr)) in family.enumerated() {
            let x = labelW + k * (CW + gap)
            cv.checker(x, y, CW, CH)
            cv.rect(Double(x), Double(y + (GROUND + 1) * K), Double(CW), 1, GUIDE)
            cv.image(fr[name]![0].cg(), x, y)
        }
    }
    cv.save(outDir + "/lineup.png")
}

// sizes: idle frame 0 at the app's Small (48x52 pt), Medium (96x104 pt) and Large (144x156 pt)
// on a Retina screen (2 px per pt), over light and dark
do {
    let scales = [0.5, 1.0, 1.5]
    let cv = Canvas(2 * (12 + Int(Double(CW) * 3.0) + 36) + 12, 40 + 2 * (Int(Double(CH) * 1.5) + 16), hex("#FFFFFF"))
    for (k, (variant, fr)) in variants.enumerated() {
        let x0 = 12 + k * (Int(Double(CW) * 3.0) + 48)
        cv.text(variant, Double(x0), 12, size: 14, bold: true)
        for (j, bg) in [hex("#F4F4F6"), DARK_BG].enumerated() {
            var x = x0
            let y = 40 + j * (Int(Double(CH) * 1.5) + 16)
            for s in scales {
                let w = Int(Double(CW) * s), h = Int(Double(CH) * s)
                let yy = y + Int(Double(CH) * 1.5) - h          // bottoms aligned
                cv.rect(Double(x), Double(yy), Double(w), Double(h), bg)
                cv.ctx.interpolationQuality = variant == "pixel" ? .none : .high
                cv.image(fr["idle"]![0].cg(), x, yy, scale: s)
                x += w + 12
            }
        }
    }
    cv.save(outDir + "/sizes.png")
}
print("lineup: \(outDir)/lineup.png")
print("done in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
