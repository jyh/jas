/// Render a named workspace icon (from icons.yaml) as a SwiftUI view.
/// Mirrors the inline-SVG approach used by jas_dioxus's render_icon_button:
/// looks up the icon's viewbox + svg fragment, parses the supported
/// primitives, and draws them into a Canvas at the requested pixel size,
/// substituting `currentColor` strokes/fills with the supplied tint.
///
/// Supported SVG primitives: rect, line, circle, ellipse, polyline,
/// polygon, path. Path d-string supports M/L/H/V/C/S/Q/T/A/Z
/// (case-sensitive absolute + lowercase relative), including the
/// smooth-curve reflected-control-point rule (S/s, T/t) and the
/// elliptical-arc endpoint parameterization (A/a, approximated with
/// <=90-degree cubic-bezier segments). Elements may carry a
/// `transform` attribute of `rotate(a[,cx,cy])` / `translate(tx[,ty])`
/// (composed left-to-right; degrees). The `<text>` element is rendered
/// via Canvas text. Anything else (tspan/use/image, scale/matrix
/// transforms) causes WorkspaceIcon to render an EmptyView so the
/// caller can fall back to a text label.

import SwiftUI
import AppKit

struct WorkspaceIcon: View {
    let name: String
    let size: CGFloat
    let tint: NSColor

    var body: some View {
        if let parsed = WorkspaceIconCache.shared.lookup(name) {
            Canvas { ctx, canvasSize in
                Self.draw(parsed: parsed, ctx: &ctx, canvasSize: canvasSize, tint: tint)
            }
            .frame(width: size, height: size)
        } else {
            EmptyView()
        }
    }

    private static func draw(parsed: ParsedIcon,
                             ctx: inout GraphicsContext,
                             canvasSize: CGSize,
                             tint: NSColor) {
        let vb = parsed.viewbox
        guard vb.w > 0, vb.h > 0 else { return }
        let scale = min(canvasSize.width / vb.w, canvasSize.height / vb.h)
        let drawW = vb.w * scale
        let drawH = vb.h * scale
        let xOff = (canvasSize.width - drawW) / 2 - vb.x * scale
        let yOff = (canvasSize.height - drawH) / 2 - vb.y * scale
        ctx.translateBy(x: xOff, y: yOff)
        ctx.scaleBy(x: scale, y: scale)

        for prim in parsed.primitives {
            if let t = prim.text {
                // Render text in icon-viewbox coords. SVG y is the
                // baseline; SwiftUI.Text draws from a top-left
                // origin, so estimate the ascent (≈0.8 * fontSize)
                // and shift the draw point up by it.
                var color = prim.fill.toColor(tint: tint)
                    ?? SwiftUI.Color(nsColor: tint)
                if prim.fillAlpha < 1.0 { color = color.opacity(prim.fillAlpha) }
                let font = NSFont.systemFont(ofSize: t.fontSize, weight: t.fontWeight)
                var resolved = ctx.resolve(SwiftUI.Text(t.content)
                    .font(SwiftUI.Font(font as CTFont))
                    .foregroundColor(color))
                let ascent = t.fontSize * 0.8
                resolved.shading = .color(color)
                ctx.draw(resolved, at: CGPoint(x: t.x, y: t.y - ascent), anchor: .topLeading)
                continue
            }
            if let fillColor = prim.fill.toColor(tint: tint) {
                let shaded = prim.fillAlpha < 1.0
                    ? fillColor.opacity(prim.fillAlpha) : fillColor
                ctx.fill(prim.path, with: .color(shaded),
                         style: FillStyle(eoFill: prim.fillEvenOdd))
            }
            if let strokeColor = prim.stroke.toColor(tint: tint), prim.strokeWidth > 0 {
                let style = StrokeStyle(
                    lineWidth: prim.strokeWidth,
                    lineCap: prim.strokeLineCap,
                    lineJoin: prim.strokeLineJoin,
                    dash: prim.strokeDashArray.map { CGFloat($0) }
                )
                let shaded = prim.strokeAlpha < 1.0
                    ? strokeColor.opacity(prim.strokeAlpha) : strokeColor
                ctx.stroke(prim.path, with: .color(shaded), style: style)
            }
        }
    }
}

// MARK: - Parsed model

struct ParsedIcon {
    let viewbox: SvgViewbox
    let primitives: [SvgPrimitive]
}

struct SvgViewbox {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct SvgPrimitive {
    let path: SwiftUI.Path
    let fill: SvgPaint
    let stroke: SvgPaint
    let strokeWidth: Double
    let strokeLineCap: CGLineCap
    let strokeLineJoin: CGLineJoin
    let strokeDashArray: [Double]
    /// SVG `fill-rule`. The spec default is nonzero; even-odd is the
    /// only other value the bundle uses (star + boolean_* holes). When
    /// true the fill is drawn with `FillStyle(eoFill: true)` so
    /// self-intersecting / nested subpaths leave holes instead of
    /// filling solid, matching the real SVG engines.
    let fillEvenOdd: Bool
    /// Effective fill alpha multiplier = `opacity` * `fill-opacity`.
    /// 1.0 when neither attribute is present. Folded into the fill
    /// color's alpha at draw time. (Element `opacity` strictly
    /// composites the whole element, but every opacity-bearing bundle
    /// icon paints a single channel — fill XOR stroke — so multiplying
    /// the paint alpha is exact here.)
    let fillAlpha: Double
    /// Effective stroke alpha multiplier = `opacity` * `stroke-opacity`.
    let strokeAlpha: Double
    /// Set when the primitive came from an SVG `<text>` element. The
    /// `path` is empty in that case; the renderer draws the string at
    /// `(textX, textY)` (where y is the SVG baseline) using the
    /// supplied font + the icon's tint as foreground.
    let text: SvgText?
}

struct SvgText {
    let content: String
    let x: Double
    let y: Double
    let fontFamily: String
    let fontSize: Double
    let fontWeight: NSFont.Weight
}

enum SvgPaint {
    case none
    case current
    case literal(NSColor)

    func toColor(tint: NSColor) -> SwiftUI.Color? {
        switch self {
        case .none: return nil
        case .current: return SwiftUI.Color(nsColor: tint)
        case .literal(let c): return SwiftUI.Color(nsColor: c)
        }
    }
}

// MARK: - Cache

final class WorkspaceIconCache {
    static let shared = WorkspaceIconCache()
    private var parsed: [String: ParsedIcon] = [:]
    private var unsupported: Set<String> = []
    private let lock = NSLock()

    func lookup(_ name: String) -> ParsedIcon? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = parsed[name] { return cached }
        if unsupported.contains(name) { return nil }
        guard let ws = WorkspaceData.load(),
              let iconDef = ws.icons()[name] as? [String: Any],
              let viewboxStr = iconDef["viewbox"] as? String,
              let svgStr = iconDef["svg"] as? String,
              let result = SvgIconParser.parse(viewbox: viewboxStr, svgFragment: svgStr) else {
            unsupported.insert(name)
            return nil
        }
        parsed[name] = result
        return result
    }
}

// MARK: - Parser (XMLParser delegate)

enum SvgIconParser {
    static func parse(viewbox: String, svgFragment: String) -> ParsedIcon? {
        guard let vb = parseViewbox(viewbox) else { return nil }
        let wrapped = #"<svg xmlns="http://www.w3.org/2000/svg">"# + svgFragment + "</svg>"
        guard let data = wrapped.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = SvgIconDelegate()
        parser.delegate = delegate
        parser.parse()
        if delegate.failed { return nil }
        return ParsedIcon(viewbox: vb, primitives: delegate.primitives)
    }

    private static func parseViewbox(_ s: String) -> SvgViewbox? {
        let parts = s.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return SvgViewbox(x: parts[0], y: parts[1], w: parts[2], h: parts[3])
    }
}

private final class SvgIconDelegate: NSObject, XMLParserDelegate {
    var primitives: [SvgPrimitive] = []
    var failed: Bool = false
    /// In-flight text element being parsed. Populated on the
    /// `<text>` open tag, fed character data via `foundCharacters`,
    /// and committed on the corresponding `</text>`.
    private var pendingText: (attrs: [String: String], buffer: String)? = nil

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attrs: [String: String] = [:]) {
        if failed { return }
        switch elementName {
        case "svg", "g", "defs", "title", "desc":
            // Containers / metadata — ignore (we don't honor group transforms).
            return
        case "text":
            // Open text — capture character data until </text>.
            // Character-panel row labels rely on this (single-glyph
            // text-as-icon glyphs, e.g. char_size renders two T's).
            pendingText = (attrs: attrs, buffer: "")
        case "tspan", "use", "image", "foreignObject":
            failed = true
            return
        case "rect", "line", "circle", "ellipse", "polyline", "polygon", "path":
            if let prim = SvgPrimitiveBuilder.build(name: elementName, attrs: attrs) {
                primitives.append(prim)
            } else {
                failed = true
            }
        default:
            failed = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if pendingText != nil {
            pendingText!.buffer += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "text", let pt = pendingText {
            pendingText = nil
            if let prim = SvgPrimitiveBuilder.buildText(content: pt.buffer, attrs: pt.attrs) {
                primitives.append(prim)
            }
        }
    }
}

// MARK: - Primitive builder

private enum SvgPrimitiveBuilder {
    static func build(name: String, attrs: [String: String]) -> SvgPrimitive? {
        let path: SwiftUI.Path?
        switch name {
        case "rect": path = buildRect(attrs)
        case "line": path = buildLine(attrs)
        case "circle": path = buildCircle(attrs)
        case "ellipse": path = buildEllipse(attrs)
        case "polyline": path = buildPolylike(attrs, closed: false)
        case "polygon": path = buildPolylike(attrs, closed: true)
        case "path":
            guard let d = attrs["d"] else { return nil }
            path = SvgDParser.parse(d)
        default: return nil
        }
        guard var p = path else { return nil }
        // Apply an element-level transform (rotate / translate). SVG
        // transforms are right-to-left function composition; we build
        // the equivalent CGAffineTransform and run the path through it.
        if let tf = attrs["transform"], let xform = parseTransform(tf) {
            p = p.applying(xform)
        }
        // SVG paint defaults: an absent `fill` is BLACK (not none, not
        // currentColor) — the real engines fill an attribute-less path
        // black, so a no-fill icon like `pen` must NOT vanish. An
        // absent `stroke` IS none (spec default), so keep that.
        let opacity = parseOpacity(attrs["opacity"]) ?? 1.0
        let fillOpacity = parseOpacity(attrs["fill-opacity"]) ?? 1.0
        let strokeOpacity = parseOpacity(attrs["stroke-opacity"]) ?? 1.0
        return SvgPrimitive(
            path: p,
            fill: parsePaint(attrs["fill"]) ?? .literal(.black),
            stroke: parsePaint(attrs["stroke"]) ?? .none,
            strokeWidth: Double(attrs["stroke-width"] ?? "") ?? 1.0,
            strokeLineCap: parseLineCap(attrs["stroke-linecap"]),
            strokeLineJoin: parseLineJoin(attrs["stroke-linejoin"]),
            strokeDashArray: parseNumberList(attrs["stroke-dasharray"]),
            fillEvenOdd: (attrs["fill-rule"]?.trimmingCharacters(in: .whitespaces)
                .lowercased() == "evenodd"),
            fillAlpha: opacity * fillOpacity,
            strokeAlpha: opacity * strokeOpacity,
            text: nil
        )
    }

    /// Build a primitive from an SVG `<text>` element. Path is empty
    /// — WorkspaceIcon renders the text via Canvas.draw(_:Text) using
    /// the captured font props.
    static func buildText(content: String, attrs: [String: String]) -> SvgPrimitive? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let x = Double(attrs["x"] ?? "0") ?? 0
        let y = Double(attrs["y"] ?? "0") ?? 0
        let family = attrs["font-family"] ?? "Helvetica"
        let size = Double(attrs["font-size"] ?? "12") ?? 12
        let weight: NSFont.Weight = {
            // Common numeric and named weights — covers the icons.yaml
            // shorthands used today (700 / "bold").
            switch (attrs["font-weight"] ?? "").lowercased() {
            case "100", "thin": return .thin
            case "200", "ultralight": return .ultraLight
            case "300", "light": return .light
            case "400", "normal", "regular", "": return .regular
            case "500", "medium": return .medium
            case "600", "semibold", "demibold": return .semibold
            case "700", "bold": return .bold
            case "800", "heavy", "extrabold": return .heavy
            case "900", "black": return .black
            default: return .regular
            }
        }()
        let opacity = parseOpacity(attrs["opacity"]) ?? 1.0
        let fillOpacity = parseOpacity(attrs["fill-opacity"]) ?? 1.0
        return SvgPrimitive(
            path: SwiftUI.Path(),
            // Text-as-icon glyphs default to the tint (currentColor)
            // rather than black so they pick up the toolbar color, as
            // before; an explicit `fill` still wins.
            fill: parsePaint(attrs["fill"]) ?? .current,
            stroke: .none,
            strokeWidth: 0,
            strokeLineCap: .butt,
            strokeLineJoin: .miter,
            strokeDashArray: [],
            fillEvenOdd: false,
            fillAlpha: opacity * fillOpacity,
            strokeAlpha: 1.0,
            text: SvgText(
                content: trimmed, x: x, y: y,
                fontFamily: family, fontSize: size,
                fontWeight: weight
            )
        )
    }

    private static func buildRect(_ a: [String: String]) -> SwiftUI.Path? {
        let x = Double(a["x"] ?? "0") ?? 0
        let y = Double(a["y"] ?? "0") ?? 0
        guard let w = Double(a["width"] ?? ""), let h = Double(a["height"] ?? "") else { return nil }
        let rx = Double(a["rx"] ?? "0") ?? 0
        let ry = Double(a["ry"] ?? "0") ?? 0
        var p = SwiftUI.Path()
        if rx > 0 || ry > 0 {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                             cornerSize: CGSize(width: rx, height: ry))
        } else {
            p.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return p
    }

    private static func buildLine(_ a: [String: String]) -> SwiftUI.Path? {
        guard let x1 = Double(a["x1"] ?? ""), let y1 = Double(a["y1"] ?? ""),
              let x2 = Double(a["x2"] ?? ""), let y2 = Double(a["y2"] ?? "") else { return nil }
        var p = SwiftUI.Path()
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        return p
    }

    private static func buildCircle(_ a: [String: String]) -> SwiftUI.Path? {
        guard let cx = Double(a["cx"] ?? ""), let cy = Double(a["cy"] ?? ""),
              let r = Double(a["r"] ?? "") else { return nil }
        var p = SwiftUI.Path()
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        return p
    }

    private static func buildEllipse(_ a: [String: String]) -> SwiftUI.Path? {
        guard let cx = Double(a["cx"] ?? ""), let cy = Double(a["cy"] ?? ""),
              let rx = Double(a["rx"] ?? ""), let ry = Double(a["ry"] ?? "") else { return nil }
        var p = SwiftUI.Path()
        p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        return p
    }

    private static func buildPolylike(_ a: [String: String], closed: Bool) -> SwiftUI.Path? {
        guard let pts = a["points"] else { return nil }
        let nums = parseNumberList(pts)
        guard nums.count >= 4, nums.count % 2 == 0 else { return nil }
        var p = SwiftUI.Path()
        p.move(to: CGPoint(x: nums[0], y: nums[1]))
        for i in stride(from: 2, to: nums.count, by: 2) {
            p.addLine(to: CGPoint(x: nums[i], y: nums[i + 1]))
        }
        if closed { p.closeSubpath() }
        return p
    }

    private static func parsePaint(_ raw: String?) -> SvgPaint? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              !s.isEmpty else { return nil }
        if s == "none" { return SvgPaint.none }
        if s == "currentcolor" { return .current }
        if s.hasPrefix("#"), let c = parseHexColor(s) { return .literal(c) }
        switch s {
        case "black": return .literal(.black)
        case "white": return .literal(.white)
        case "gray", "grey": return .literal(.gray)
        case "red": return .literal(.red)
        case "green": return .literal(.green)
        case "blue": return .literal(.blue)
        default: return nil
        }
    }

    /// Parse an SVG hex color, supporting all four CSS forms the bundle
    /// uses: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`. The shorthand
    /// forms expand each nibble (`#fff` -> `#ffffff`), which the shared
    /// `NSColor(hex:)` does NOT do (it would read `#fff` as 0x000fff =
    /// blue). The real SVG engines expand shorthand, so we must too,
    /// or every `#fff` facet (pen / anchor_point / paintbrush / arrows)
    /// renders the wrong color. Returns nil for malformed input.
    private static func parseHexColor(_ raw: String) -> NSColor? {
        let h = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        let hex = Array(h)
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        func val(_ a: Character, _ b: Character) -> Double? {
            guard let n = UInt8(String([a, b]), radix: 16) else { return nil }
            return Double(n) / 255.0
        }
        let r, g, b: Double
        var a: Double = 1.0
        switch hex.count {
        case 3, 4:
            // Shorthand: duplicate each nibble.
            guard let rr = val(hex[0], hex[0]),
                  let gg = val(hex[1], hex[1]),
                  let bb = val(hex[2], hex[2]) else { return nil }
            r = rr; g = gg; b = bb
            if hex.count == 4, let aa = val(hex[3], hex[3]) { a = aa }
        case 6, 8:
            guard let rr = val(hex[0], hex[1]),
                  let gg = val(hex[2], hex[3]),
                  let bb = val(hex[4], hex[5]) else { return nil }
            r = rr; g = gg; b = bb
            if hex.count == 8, let aa = val(hex[6], hex[7]) { a = aa }
        default:
            return nil
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Parse the subset of the SVG `transform` attribute used by the
    /// bundle icons: `rotate(a)`, `rotate(a, cx, cy)`, `translate(tx)`,
    /// `translate(tx, ty)`. Multiple space-separated functions compose
    /// left-to-right (the leftmost is outermost), matching SVG. Angles
    /// are in DEGREES. Returns nil if the string contains an
    /// unsupported function so the caller can decide how to handle it
    /// (here: nil means "no transform", but every transform in the
    /// bundle is one of the supported forms).
    private static func parseTransform(_ raw: String) -> CGAffineTransform? {
        var result = CGAffineTransform.identity
        var sawAny = false
        // Match `name( args )` repeatedly.
        let pattern = #"([a-zA-Z]+)\s*\(([^)]*)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let fn = ns.substring(with: m.range(at: 1)).lowercased()
            let argStr = ns.substring(with: m.range(at: 2))
            let args = argStr
                .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .compactMap { Double($0) }
            let step: CGAffineTransform
            switch fn {
            case "rotate":
                if args.count >= 3 {
                    // rotate(a, cx, cy) = T(cx,cy) . R(a) . T(-cx,-cy)
                    let a = args[0] * .pi / 180.0
                    let cx = args[1], cy = args[2]
                    step = CGAffineTransform(translationX: cx, y: cy)
                        .rotated(by: a)
                        .translatedBy(x: -cx, y: -cy)
                } else if args.count >= 1 {
                    step = CGAffineTransform(rotationAngle: args[0] * .pi / 180.0)
                } else {
                    return nil
                }
            case "translate":
                let tx = args.first ?? 0
                let ty = args.count >= 2 ? args[1] : 0
                step = CGAffineTransform(translationX: tx, y: ty)
            default:
                // scale / matrix / skew: not used by any bundle icon.
                return nil
            }
            // Compose left-to-right: a point is mapped by the leftmost
            // function last. CGAffineTransform applies `result` after
            // `step` when we do step.concatenating(result), so prepend.
            result = step.concatenating(result)
            sawAny = true
        }
        return sawAny ? result : nil
    }

    private static func parseLineCap(_ s: String?) -> CGLineCap {
        switch s {
        case "round": return .round
        case "square": return .square
        default: return .butt
        }
    }

    private static func parseLineJoin(_ s: String?) -> CGLineJoin {
        switch s {
        case "round": return .round
        case "bevel": return .bevel
        default: return .miter
        }
    }

    private static func parseNumberList(_ raw: String?) -> [Double] {
        guard let s = raw else { return [] }
        return s.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { Double($0) }
    }

    /// Parse an SVG opacity value (`opacity` / `fill-opacity` /
    /// `stroke-opacity`). Accepts a plain `<number>` or a `<percentage>`
    /// and clamps to [0, 1] per the spec. Returns nil if absent /
    /// unparseable so the caller can default to 1.0.
    private static func parseOpacity(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty
        else { return nil }
        var scale = 1.0
        if s.hasSuffix("%") { s = String(s.dropLast()); scale = 0.01 }
        guard let v = Double(s) else { return nil }
        return min(1.0, max(0.0, v * scale))
    }
}

// MARK: - Path d= parser

private enum SvgDParser {
    static func parse(_ d: String) -> SwiftUI.Path? {
        var path = SwiftUI.Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var scanner = SvgDScanner(d)
        var lastCmd: Character = " "
        // Reflected-control-point tracking for the smooth commands.
        // `lastCubicCtrl` holds the second control point of the most
        // recent C/c/S/s command; `lastQuadCtrl` the control point of
        // the most recent Q/q/T/t. Both are nil when the preceding
        // command was of a different family, in which case the
        // reflected control point collapses onto the current point
        // (per the SVG path spec).
        var lastCubicCtrl: CGPoint? = nil
        var lastQuadCtrl: CGPoint? = nil

        while !scanner.atEnd {
            let cmd: Character
            if let c = scanner.peekCommand() {
                scanner.consumeOne()
                cmd = c
                lastCmd = c
            } else {
                // Implicit-repeat rule per SVG spec:
                //   - after M, repeat is L; after m, repeat is l
                //   - otherwise repeat the last explicit command
                //   - repeating after Z/z is undefined → reject
                switch lastCmd {
                case "M": cmd = "L"; lastCmd = "L"
                case "m": cmd = "l"; lastCmd = "l"
                case " ", "Z", "z": return nil
                default: cmd = lastCmd
                }
            }

            // Most commands break the smooth-curve chain. The cubic /
            // quad cases below re-arm their own tracker after running.
            // Compute the reflected control point for S/s/T/t up front
            // using the PREVIOUS command's stored control point.
            switch cmd {
            case "M":
                guard let p = scanner.readPoint() else { return nil }
                current = p; subpathStart = p
                path.move(to: p)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "m":
                guard let p = scanner.readPoint() else { return nil }
                current = CGPoint(x: current.x + p.x, y: current.y + p.y)
                subpathStart = current
                path.move(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "L":
                guard let p = scanner.readPoint() else { return nil }
                current = p
                path.addLine(to: p)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "l":
                guard let p = scanner.readPoint() else { return nil }
                current = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addLine(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "H":
                guard let x = scanner.readNumber() else { return nil }
                current.x = x
                path.addLine(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "h":
                guard let dx = scanner.readNumber() else { return nil }
                current.x += dx
                path.addLine(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "V":
                guard let y = scanner.readNumber() else { return nil }
                current.y = y
                path.addLine(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "v":
                guard let dy = scanner.readNumber() else { return nil }
                current.y += dy
                path.addLine(to: current)
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "C":
                guard let c1 = scanner.readPoint(),
                      let c2 = scanner.readPoint(),
                      let p = scanner.readPoint() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicCtrl = c2; lastQuadCtrl = nil
            case "c":
                guard let c1 = scanner.readPoint(),
                      let c2 = scanner.readPoint(),
                      let p = scanner.readPoint() else { return nil }
                let abs1 = CGPoint(x: current.x + c1.x, y: current.y + c1.y)
                let abs2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                let absP = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addCurve(to: absP, control1: abs1, control2: abs2)
                current = absP
                lastCubicCtrl = abs2; lastQuadCtrl = nil
            case "S":
                guard let c2 = scanner.readPoint(),
                      let p = scanner.readPoint() else { return nil }
                let c1 = Self.reflected(lastCubicCtrl, about: current)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicCtrl = c2; lastQuadCtrl = nil
            case "s":
                guard let c2r = scanner.readPoint(),
                      let pr = scanner.readPoint() else { return nil }
                let c1 = Self.reflected(lastCubicCtrl, about: current)
                let abs2 = CGPoint(x: current.x + c2r.x, y: current.y + c2r.y)
                let absP = CGPoint(x: current.x + pr.x, y: current.y + pr.y)
                path.addCurve(to: absP, control1: c1, control2: abs2)
                current = absP
                lastCubicCtrl = abs2; lastQuadCtrl = nil
            case "Q":
                guard let c = scanner.readPoint(), let p = scanner.readPoint() else { return nil }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadCtrl = c; lastCubicCtrl = nil
            case "q":
                guard let c = scanner.readPoint(), let p = scanner.readPoint() else { return nil }
                let absC = CGPoint(x: current.x + c.x, y: current.y + c.y)
                let absP = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addQuadCurve(to: absP, control: absC)
                current = absP
                lastQuadCtrl = absC; lastCubicCtrl = nil
            case "T":
                guard let p = scanner.readPoint() else { return nil }
                let c = Self.reflected(lastQuadCtrl, about: current)
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadCtrl = c; lastCubicCtrl = nil
            case "t":
                guard let pr = scanner.readPoint() else { return nil }
                let c = Self.reflected(lastQuadCtrl, about: current)
                let absP = CGPoint(x: current.x + pr.x, y: current.y + pr.y)
                path.addQuadCurve(to: absP, control: c)
                current = absP
                lastQuadCtrl = c; lastCubicCtrl = nil
            case "A", "a":
                let relative = (cmd == "a")
                guard let rx = scanner.readNumber(),
                      let ry = scanner.readNumber(),
                      let xRot = scanner.readNumber(),
                      let largeArc = scanner.readFlag(),
                      let sweep = scanner.readFlag(),
                      let end = scanner.readPoint() else { return nil }
                let absEnd = relative
                    ? CGPoint(x: current.x + end.x, y: current.y + end.y)
                    : end
                Self.appendArc(to: &path, from: current, to: absEnd,
                               rx: rx, ry: ry, xAxisRotationDeg: xRot,
                               largeArc: largeArc, sweep: sweep)
                current = absEnd
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicCtrl = nil; lastQuadCtrl = nil
            default:
                return nil
            }
        }

        return path
    }

    /// Reflect the stored control point `ctrl` about `current`. When
    /// `ctrl` is nil (the previous command was not of the matching
    /// curve family) the reflected point is `current` itself, per the
    /// SVG smooth-curve rule.
    private static func reflected(_ ctrl: CGPoint?, about current: CGPoint) -> CGPoint {
        guard let c = ctrl else { return current }
        return CGPoint(x: 2 * current.x - c.x, y: 2 * current.y - c.y)
    }

    /// Append an SVG elliptical arc to `path`, converting the
    /// endpoint parameterization (rx ry x-rotation large-arc sweep
    /// endpoint) into one or more cubic-bezier segments (each <= 90
    /// degrees). Implements the conversion + radius correction from
    /// the SVG implementation notes (appendix on arcs).
    private static func appendArc(to path: inout SwiftUI.Path,
                                  from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: Double, ry ryIn: Double,
                                  xAxisRotationDeg phiDeg: Double,
                                  largeArc: Bool, sweep: Bool) {
        // Degenerate: identical endpoints -> nothing to draw.
        if p0.x == p1.x && p0.y == p1.y { return }
        // rx==0 or ry==0 -> straight line (per spec).
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }

        let phi = phiDeg * Double.pi / 180.0
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // Step 1: compute (x1', y1') — the endpoints in the rotated,
        // midpoint-centred coordinate system.
        let dx2 = (Double(p0.x) - Double(p1.x)) / 2.0
        let dy2 = (Double(p0.y) - Double(p1.y)) / 2.0
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Step 2: radius correction — scale up rx, ry if too small.
        var rxSq = rx * rx
        var rySq = ry * ry
        let x1pSq = x1p * x1p
        let y1pSq = y1p * y1p
        let lambda = x1pSq / rxSq + y1pSq / rySq
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
            rxSq = rx * rx
            rySq = ry * ry
        }

        // Step 3: compute the centre (cx', cy') in the rotated frame.
        var num = rxSq * rySq - rxSq * y1pSq - rySq * x1pSq
        if num < 0 { num = 0 }  // guard against tiny negative from FP error
        let den = rxSq * y1pSq + rySq * x1pSq
        var coef = den == 0 ? 0 : (num / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        // Step 4: centre in the original coordinate system.
        let cx = cosPhi * cxp - sinPhi * cyp + (Double(p0.x) + Double(p1.x)) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + (Double(p0.y) + Double(p1.y)) / 2.0

        // Step 5: start angle theta1 and sweep delta-theta.
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var c = len == 0 ? 0 : dot / len
            c = min(1, max(-1, c))
            var a = acos(c)
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var deltaTheta = angle(ux, uy, vx, vy)
        let twoPi = 2 * Double.pi
        if !sweep && deltaTheta > 0 { deltaTheta -= twoPi }
        if sweep && deltaTheta < 0 { deltaTheta += twoPi }

        // Step 6: split into <= 90-degree segments and emit cubics.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (Double.pi / 2.0) - 1e-9)))
        let delta = deltaTheta / Double(segments)
        // Bezier control-point magnitude for a unit-circle arc of
        // angle `delta`.
        let t = (4.0 / 3.0) * tan(delta / 4.0)

        var theta = theta1
        for _ in 0..<segments {
            let cosT1 = cos(theta)
            let sinT1 = sin(theta)
            let theta2 = theta + delta
            let cosT2 = cos(theta2)
            let sinT2 = sin(theta2)

            // Unit-circle points / tangents, then scale by rx,ry and
            // rotate by phi back into icon coordinates.
            func map(_ ex: Double, _ ey: Double) -> CGPoint {
                let sx = rx * ex
                let sy = ry * ey
                let x = cosPhi * sx - sinPhi * sy + cx
                let y = sinPhi * sx + cosPhi * sy + cy
                return CGPoint(x: x, y: y)
            }
            let c1 = map(cosT1 - t * sinT1, sinT1 + t * cosT1)
            let c2 = map(cosT2 + t * sinT2, sinT2 - t * cosT2)
            let endPt = map(cosT2, sinT2)
            path.addCurve(to: endPt, control1: c1, control2: c2)
            theta = theta2
        }
    }
}

private struct SvgDScanner {
    let chars: [Character]
    var idx: Int = 0

    init(_ s: String) { self.chars = Array(s) }

    var atEnd: Bool {
        var i = idx
        while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        return i >= chars.count
    }

    mutating func skipSep() {
        while idx < chars.count, chars[idx].isWhitespace || chars[idx] == "," { idx += 1 }
    }

    mutating func peekCommand() -> Character? {
        skipSep()
        guard idx < chars.count else { return nil }
        let c = chars[idx]
        return c.isLetter ? c : nil
    }

    mutating func consumeOne() {
        guard idx < chars.count else { return }
        idx += 1
    }

    mutating func readNumber() -> Double? {
        skipSep()
        guard idx < chars.count else { return nil }
        let start = idx
        if chars[idx] == "-" || chars[idx] == "+" { idx += 1 }
        while idx < chars.count, chars[idx].isNumber { idx += 1 }
        if idx < chars.count, chars[idx] == "." {
            idx += 1
            while idx < chars.count, chars[idx].isNumber { idx += 1 }
        }
        if idx < chars.count, chars[idx] == "e" || chars[idx] == "E" {
            idx += 1
            if idx < chars.count, chars[idx] == "-" || chars[idx] == "+" { idx += 1 }
            while idx < chars.count, chars[idx].isNumber { idx += 1 }
        }
        guard idx > start else { return nil }
        return Double(String(chars[start..<idx]))
    }

    mutating func readPoint() -> CGPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Read a single arc flag: exactly one `0` or `1` digit. The SVG
    /// grammar allows arc flags to be packed against the following
    /// number with no separator (e.g. `...1 1 0 5 5` may appear as
    /// `...110 5 5`), so a flag must consume just one character and
    /// NOT greedily read a full number. Returns true for `1`.
    mutating func readFlag() -> Bool? {
        skipSep()
        guard idx < chars.count else { return nil }
        let c = chars[idx]
        if c == "0" { idx += 1; return false }
        if c == "1" { idx += 1; return true }
        return nil
    }
}
