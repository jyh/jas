// PDF emitter (PRINT.md §Phase 1B). Uses Core Graphics' PDF context
// (no PDFKit dependency needed for emit — PDFKit's APIs are oriented
// around displaying / annotating existing PDFs).
//
// Walks the document, emitting one page per artboard (or a single
// page covering the artboard union when print_preferences.ignoreArtboards
// is set). Per-page MediaBox = artboard rect. Element types covered:
// path (cubic + quad-as-cubic + arc-as-line fallback), rect, line,
// circle, ellipse, polyline, polygon, basic text (single-tspan
// concatenation, system font), groups, layers (transforms only).
// PrintLayers filter applied at layer boundaries; visiblePrintable
// currently collapses to visible until Layer.print lands.

import Foundation
import CoreGraphics
import AppKit

/// Convert a document to PDF bytes.
public func documentToPdf(_ doc: Document) -> Data {
    let pages = collectPages(doc)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        return Data()
    }
    // Use the first page's mediaBox as the default; per-page mediaBox
    // is set on each beginPDFPage call.
    var defaultMediaBox = pages.first?.mediaBox ?? CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultMediaBox, nil) else {
        return Data()
    }
    for page in pages {
        var box = page.mediaBox
        let pageInfo: CFDictionary = [
            kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        ] as CFDictionary
        ctx.beginPDFPage(pageInfo)
        drawPage(ctx, doc, page)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

private struct Page {
    let mediaBox: CGRect
    let srcX: Double
    let srcY: Double
    let srcW: Double
    let srcH: Double
}

private func collectPages(_ doc: Document) -> [Page] {
    if doc.printPreferences.ignoreArtboards || doc.artboards.isEmpty {
        let (x, y, w, h): (Double, Double, Double, Double)
        if doc.artboards.isEmpty {
            (x, y, w, h) = (0, 0, 612, 792)
        } else {
            (x, y, w, h) = artboardBoundsUnion(doc.artboards)
        }
        return [Page(mediaBox: CGRect(x: 0, y: 0, width: w, height: h),
                     srcX: x, srcY: y, srcW: w, srcH: h)]
    }
    return doc.artboards.map { ab in
        Page(mediaBox: CGRect(x: 0, y: 0, width: ab.width, height: ab.height),
             srcX: ab.x, srcY: ab.y, srcW: ab.width, srcH: ab.height)
    }
}

private func artboardBoundsUnion(_ abs: [Artboard]) -> (Double, Double, Double, Double) {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for ab in abs {
        minX = min(minX, ab.x)
        minY = min(minY, ab.y)
        maxX = max(maxX, ab.x + ab.width)
        maxY = max(maxY, ab.y + ab.height)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

// MARK: - Per-page draw

private func drawPage(_ ctx: CGContext, _ doc: Document, _ page: Page) {
    ctx.saveGState()
    // PDF is y-up, internal model is y-down. Flip the page CTM and
    // translate so document-space (page.srcX, page.srcY) lands at the
    // page origin. User placement and scaling apply in page space
    // (post-flip).
    ctx.translateBy(x: 0, y: page.srcH)
    ctx.scaleBy(x: 1, y: -1)
    let (sx, sy) = scalingPair(doc)
    let (px, py) = (doc.printPreferences.placementX, doc.printPreferences.placementY)
    if px != 0 || py != 0 {
        ctx.translateBy(x: CGFloat(px), y: CGFloat(py))
    }
    if sx != 1 || sy != 1 {
        ctx.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
    }
    if page.srcX != 0 || page.srcY != 0 {
        ctx.translateBy(x: CGFloat(-page.srcX), y: CGFloat(-page.srcY))
    }
    for layer in doc.layers {
        emitElement(ctx, .layer(layer), filter: doc.printPreferences.printLayers)
    }
    ctx.restoreGState()
}

private func scalingPair(_ doc: Document) -> (Double, Double) {
    switch doc.printPreferences.scalingMode {
    case .doNotScale, .fitToPage: return (1, 1)
    case .custom:
        let s = doc.printPreferences.customScale / 100.0
        return (s, s)
    }
}

// MARK: - Element walk

private func layerPassesFilter(_ layer: Layer, _ filter: PrintLayers) -> Bool {
    switch filter {
    case .all: return true
    case .visible, .visiblePrintable:
        return layer.visibility != .invisible
    }
}

private func emitElement(_ ctx: CGContext, _ el: Element, filter: PrintLayers) {
    if el.visibility == .invisible { return }
    switch el {
    case .layer(let l):
        if !layerPassesFilter(l, filter) { return }
        ctx.saveGState()
        applyTransform(ctx, l.transform)
        for child in l.children {
            emitElement(ctx, child, filter: filter)
        }
        ctx.restoreGState()
    case .group(let g):
        ctx.saveGState()
        applyTransform(ctx, g.transform)
        for child in g.children {
            emitElement(ctx, child, filter: filter)
        }
        ctx.restoreGState()
    case .rect(let r):
        emitPaint(ctx, fill: r.fill, stroke: r.stroke, transform: r.transform) {
            ctx.addRect(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
    case .line(let l):
        emitStrokeOnly(ctx, stroke: l.stroke, transform: l.transform) {
            ctx.move(to: CGPoint(x: l.x1, y: l.y1))
            ctx.addLine(to: CGPoint(x: l.x2, y: l.y2))
        }
    case .circle(let c):
        emitPaint(ctx, fill: c.fill, stroke: c.stroke, transform: c.transform) {
            ctx.addEllipse(in: CGRect(x: c.cx - c.r, y: c.cy - c.r, width: 2 * c.r, height: 2 * c.r))
        }
    case .ellipse(let e):
        emitPaint(ctx, fill: e.fill, stroke: e.stroke, transform: e.transform) {
            ctx.addEllipse(in: CGRect(x: e.cx - e.rx, y: e.cy - e.ry, width: 2 * e.rx, height: 2 * e.ry))
        }
    case .polyline(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPolyline(ctx, p.points, close: false)
        }
    case .polygon(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPolyline(ctx, p.points, close: true)
        }
    case .path(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPathCommands(ctx, p.d)
        }
    case .text(let t):
        emitText(ctx, t)
    case .textPath, .live:
        // Phase 1B deferral.
        break
    }
}

private func applyTransform(_ ctx: CGContext, _ t: Transform?) {
    guard let t = t else { return }
    ctx.concatenate(CGAffineTransform(a: CGFloat(t.a), b: CGFloat(t.b),
                                       c: CGFloat(t.c), d: CGFloat(t.d),
                                       tx: CGFloat(t.e), ty: CGFloat(t.f)))
}

private func emitPaint(
    _ ctx: CGContext,
    fill: Fill?, stroke: Stroke?, transform: Transform?,
    addGeom: () -> Void
) {
    if fill == nil && stroke == nil { return }
    ctx.saveGState()
    applyTransform(ctx, transform)
    addGeom()
    if let f = fill {
        let (r, g, b, a) = f.color.toRgba()
        ctx.setFillColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * f.opacity)))
    }
    if let s = stroke {
        let (r, g, b, a) = s.color.toRgba()
        ctx.setStrokeColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * s.opacity)))
        ctx.setLineWidth(CGFloat(s.width))
    }
    let mode: CGPathDrawingMode
    switch (fill != nil, stroke != nil) {
    case (true, true):  mode = .fillStroke
    case (true, false): mode = .fill
    case (false, true): mode = .stroke
    default:            mode = .fill
    }
    ctx.drawPath(using: mode)
    ctx.restoreGState()
}

private func emitStrokeOnly(
    _ ctx: CGContext,
    stroke: Stroke?, transform: Transform?,
    addGeom: () -> Void
) {
    guard let s = stroke else { return }
    ctx.saveGState()
    applyTransform(ctx, transform)
    addGeom()
    let (r, g, b, a) = s.color.toRgba()
    ctx.setStrokeColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * s.opacity)))
    ctx.setLineWidth(CGFloat(s.width))
    ctx.strokePath()
    ctx.restoreGState()
}

private func addPolyline(_ ctx: CGContext, _ points: [(Double, Double)], close: Bool) {
    guard !points.isEmpty else { return }
    ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() {
        ctx.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    if close { ctx.closePath() }
}

private func addPathCommands(_ ctx: CGContext, _ commands: [PathCommand]) {
    var cur: (Double, Double) = (0, 0)
    var prevCubicCp: (Double, Double)? = nil
    var prevQuadCp: (Double, Double)? = nil
    for cmd in commands {
        switch cmd {
        case .moveTo(let x, let y):
            ctx.move(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .lineTo(let x, let y):
            ctx.addLine(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            cur = (x, y); prevCubicCp = (x2, y2); prevQuadCp = nil
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let (x1, y1): (Double, Double) = {
                if let p = prevCubicCp { return (2 * cur.0 - p.0, 2 * cur.1 - p.1) }
                return cur
            }()
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            cur = (x, y); prevCubicCp = (x2, y2); prevQuadCp = nil
        case .quadTo(let x1, let y1, let x, let y):
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: x1, y: y1))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = (x1, y1)
        case .smoothQuadTo(let x, let y):
            let qCtrl: (Double, Double) = {
                if let p = prevQuadCp { return (2 * cur.0 - p.0, 2 * cur.1 - p.1) }
                return cur
            }()
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: qCtrl.0, y: qCtrl.1))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = qCtrl
        case .arcTo(_, _, _, _, _, let x, let y):
            // Phase 1B deferral: arc-as-line fallback. Real arc
            // flattening is part of the arc-extrema gap backlog.
            ctx.addLine(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .closePath:
            ctx.closePath()
            prevCubicCp = nil; prevQuadCp = nil
        }
    }
}

private func emitText(_ ctx: CGContext, _ t: Text) {
    let s = t.tspans.map(\.content).joined()
    if s.isEmpty { return }
    let (r, g, b, a) = (t.fill?.color ?? Color.black).toRgba()
    let fillAlpha = (t.fill?.opacity ?? 1.0) * a
    let font = NSFont(name: t.fontFamily, size: CGFloat(t.fontSize))
        ?? NSFont.systemFont(ofSize: CGFloat(t.fontSize))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: CGFloat(r), green: CGFloat(g),
                                  blue: CGFloat(b), alpha: CGFloat(fillAlpha)),
    ]
    let attr = NSAttributedString(string: s, attributes: attrs)
    ctx.saveGState()
    applyTransform(ctx, t.transform)
    // The page CTM has Y flipped; re-flip locally so the text reads
    // right-side up. Anchor at the text origin (t.x, t.y).
    ctx.translateBy(x: CGFloat(t.x), y: CGFloat(t.y))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(at: CGPoint(x: 0, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}
