/// Offscreen-render conformance for the hand-rolled icon renderer.
///
/// Renders a handful of toolbar icons through `WorkspaceIcon`
/// (SwiftUI `ImageRenderer` -> `CGImage`) on a dark background with the
/// same `#cccccc` tint the toolbar uses, then compares a coarse
/// ink-coverage grid against the `rsvg-convert` reference renders that
/// the OTHER three apps' real SVG engines effectively produce.
///
/// We do NOT assert pixel-exact parity: two different rasterizers
/// (CoreGraphics vs cairo/librsvg) anti-alias differently. Instead we
/// downsample each render to an 8x8 ink/no-ink grid (a cell is "ink"
/// when it differs meaningfully from the background) and require the
/// Swift grid to MATCH the reference grid within a small tolerance.
/// That is enough to catch the paint-default bugs this work fixes:
///   - `pen` body (no `fill` attr) must be INK, not blank.
///   - `star` center must be a HOLE (even-odd), not solid ink.
///   - faded `opacity` regions still read as ink at this granularity.
///
/// If `ImageRenderer` cannot produce an image in this headless harness,
/// the test records that as a skip-style note (via Issue.record with a
/// known marker) rather than a hard failure — the parse/paint unit
/// tests in WorkspaceIconParseTest then carry the correctness proof.

import Foundation
import Testing
import SwiftUI
import AppKit
@testable import JasLib

@MainActor
private func renderSwiftIcon(_ name: String, size: CGFloat) -> CGImage? {
    let tint = NSColor(srgbRed: 0xcc / 255.0, green: 0xcc / 255.0, blue: 0xcc / 255.0, alpha: 1)
    let bg = NSColor(srgbRed: 0x2b / 255.0, green: 0x2b / 255.0, blue: 0x2b / 255.0, alpha: 1)
    let view = ZStack {
        Rectangle().fill(Color(nsColor: bg))
        WorkspaceIcon(name: name, size: size, tint: tint)
    }
    .frame(width: size, height: size)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    return renderer.cgImage
}

/// Load a CGImage from a PNG file path.
private func loadPNG(_ path: String) -> CGImage? {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else { return nil }
    return rep.cgImage
}

/// Sample a CGImage into row-major RGBA bytes at its native size.
private func rgbaBytes(_ img: CGImage) -> (px: [UInt8], w: Int, h: Int)? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &buf, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

/// Downsample to an NxN ink grid. A cell is "ink" if the mean absolute
/// per-channel difference from the dark background exceeds `thresh`.
private func inkGrid(_ img: CGImage, n: Int, thresh: Double) -> [[Bool]]? {
    guard let (px, w, h) = rgbaBytes(img) else { return nil }
    let bgR = 0x2b, bgG = 0x2b, bgB = 0x2b
    var grid = Array(repeating: Array(repeating: false, count: n), count: n)
    for gy in 0..<n {
        for gx in 0..<n {
            let x0 = gx * w / n, x1 = (gx + 1) * w / n
            let y0 = gy * h / n, y1 = (gy + 1) * h / n
            var acc = 0.0, count = 0
            for y in y0..<max(y0 + 1, y1) {
                for x in x0..<max(x0 + 1, x1) {
                    let i = (y * w + x) * 4
                    // Un-premultiply not needed for a coarse delta vs an
                    // opaque background — compare composited bytes.
                    let dr = abs(Int(px[i]) - bgR)
                    let dg = abs(Int(px[i + 1]) - bgG)
                    let db = abs(Int(px[i + 2]) - bgB)
                    acc += Double(dr + dg + db) / 3.0
                    count += 1
                }
            }
            if count > 0 && acc / Double(count) > thresh { grid[gy][gx] = true }
        }
    }
    return grid
}

private func gridMismatch(_ a: [[Bool]], _ b: [[Bool]]) -> Int {
    var diff = 0
    for y in 0..<a.count { for x in 0..<a[y].count where a[y][x] != b[y][x] { diff += 1 } }
    return diff
}

/// Downsample to an NxN mean-RGB grid (composited bytes vs the opaque
/// background). Used to catch COLOR divergences the ink grid misses —
/// e.g. a `#fff` facet that rendered blue instead of white.
private func colorGrid(_ img: CGImage, n: Int) -> [[(Double, Double, Double)]]? {
    guard let (px, w, h) = rgbaBytes(img) else { return nil }
    var grid = Array(repeating: Array(repeating: (0.0, 0.0, 0.0), count: n), count: n)
    for gy in 0..<n {
        for gx in 0..<n {
            let x0 = gx * w / n, x1 = max(gx * w / n + 1, (gx + 1) * w / n)
            let y0 = gy * h / n, y1 = max(gy * h / n + 1, (gy + 1) * h / n)
            var r = 0.0, g = 0.0, b = 0.0, c = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * w + x) * 4
                    r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); c += 1
                }
            }
            if c > 0 { grid[gy][gx] = (r / c, g / c, b / c) }
        }
    }
    return grid
}

/// Max per-cell mean-channel distance between two color grids.
private func maxColorDistance(_ a: [[(Double, Double, Double)]],
                              _ b: [[(Double, Double, Double)]]) -> Double {
    var worst = 0.0
    for y in 0..<a.count {
        for x in 0..<a[y].count {
            let d = (abs(a[y][x].0 - b[y][x].0)
                     + abs(a[y][x].1 - b[y][x].1)
                     + abs(a[y][x].2 - b[y][x].2)) / 3.0
            worst = max(worst, d)
        }
    }
    return worst
}

@MainActor
@Test func swiftIconsMatchRsvgReferences() throws {
    // The references are produced by the validation step
    // (rsvg-convert of each icons.yaml svg at 64x64 on #2b2b2b). If they
    // are not present, this render-comparison is a no-op note: the
    // parse/paint unit tests carry correctness.
    let refDir = "/tmp/iconref"
    guard FileManager.default.fileExists(atPath: "\(refDir)/pen.png") else {
        Issue.record("rsvg references not present at \(refDir) — skipping pixel compare (parse tests cover correctness)")
        return
    }
    // Probe ImageRenderer once; if headless rendering yields nil, note + skip.
    guard renderSwiftIcon("pen", size: 64) != nil else {
        Issue.record("ImageRenderer produced no image in this harness — skipping pixel compare (parse tests cover correctness)")
        return
    }

    let names = ["pen", "star", "panel_layers", "anchor_point",
                 "boolean_exclude", "eye_invisible", "rotate", "scale",
                 "eyedropper", "lasso", "line", "hand", "pencil", "type",
                 "paintbrush", "blob_brush", "magic_wand",
                 "add_anchor", "delete_anchor"]
    let n = 8                 // 8x8 ink grid
    let inkThresh = 18.0      // mean channel delta vs background to count as ink
    let maxCellDiff = 8       // tolerate up to 8 / 64 cells of AA disagreement

    var reportable: [String] = []
    for name in names {
        guard let ref = loadPNG("\(refDir)/\(name).png") else {
            Issue.record("missing reference png for \(name)"); continue
        }
        guard let sw = renderSwiftIcon(name, size: 64) else {
            Issue.record("Swift render nil for \(name)"); continue
        }
        guard let refGrid = inkGrid(ref, n: n, thresh: inkThresh),
              let swGrid = inkGrid(sw, n: n, thresh: inkThresh) else {
            Issue.record("grid sample failed for \(name)"); continue
        }
        let diff = gridMismatch(refGrid, swGrid)
        if diff > maxCellDiff {
            reportable.append("\(name): \(diff) ink cells differ (> \(maxCellDiff))")
        }
        // Color check at a coarser 4x4 grid: catches a mis-parsed paint
        // (e.g. #fff facet rendering blue) that the ink grid ignores.
        // Tolerance is generous (different rasterizers' AA + edge
        // coverage), but a wholesale hue error blows well past it.
        if let refC = colorGrid(ref, n: 4), let swC = colorGrid(sw, n: 4) {
            let cdist = maxColorDistance(refC, swC)
            if cdist > 60.0 {
                reportable.append("\(name): max cell color distance \(Int(cdist)) (> 60)")
            }
        }
        // Optional visual dump for manual inspection.
        if ProcessInfo.processInfo.environment["DUMP_ICONS"] != nil {
            let rep = NSBitmapImageRep(cgImage: sw)
            if let d = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: "/tmp/iconswift", withIntermediateDirectories: true)
                try? d.write(to: URL(fileURLWithPath: "/tmp/iconswift/\(name).png"))
            }
        }
    }
    #expect(reportable.isEmpty,
            "Swift icon renders diverge from rsvg references: \(reportable)")
}
