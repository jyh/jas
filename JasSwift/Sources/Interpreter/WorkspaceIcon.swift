/// Render a named workspace icon (from icons.yaml) as a SwiftUI view.
/// Mirrors the inline-SVG approach used by jas_dioxus's render_icon_button:
/// looks up the icon's viewbox + svg fragment, parses the supported
/// primitives, and draws them into a Canvas at the requested pixel size,
/// substituting `currentColor` strokes/fills with the supplied tint.
///
/// Supported SVG primitives: rect, line, circle, ellipse, polyline,
/// polygon, path. Path d-string supports M/L/H/V/C/Q/Z (case-sensitive
/// absolute + lowercase relative). Unsupported features (text element,
/// path commands S/T/A) cause WorkspaceIcon to render an EmptyView so
/// the caller can fall back to a text label.

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
                let color = prim.fill.toColor(tint: tint)
                    ?? SwiftUI.Color(nsColor: tint)
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
                ctx.fill(prim.path, with: .color(fillColor))
            }
            if let strokeColor = prim.stroke.toColor(tint: tint), prim.strokeWidth > 0 {
                let style = StrokeStyle(
                    lineWidth: prim.strokeWidth,
                    lineCap: prim.strokeLineCap,
                    lineJoin: prim.strokeLineJoin,
                    dash: prim.strokeDashArray.map { CGFloat($0) }
                )
                ctx.stroke(prim.path, with: .color(strokeColor), style: style)
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
        guard let p = path else { return nil }
        return SvgPrimitive(
            path: p,
            fill: parsePaint(attrs["fill"]) ?? .none,
            stroke: parsePaint(attrs["stroke"]) ?? .none,
            strokeWidth: Double(attrs["stroke-width"] ?? "") ?? 1.0,
            strokeLineCap: parseLineCap(attrs["stroke-linecap"]),
            strokeLineJoin: parseLineJoin(attrs["stroke-linejoin"]),
            strokeDashArray: parseNumberList(attrs["stroke-dasharray"]),
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
        return SvgPrimitive(
            path: SwiftUI.Path(),
            fill: parsePaint(attrs["fill"]) ?? .current,
            stroke: .none,
            strokeWidth: 0,
            strokeLineCap: .butt,
            strokeLineJoin: .miter,
            strokeDashArray: [],
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
        if s.hasPrefix("#") { return .literal(NSColor(hex: s)) }
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
}

// MARK: - Path d= parser

private enum SvgDParser {
    static func parse(_ d: String) -> SwiftUI.Path? {
        var path = SwiftUI.Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var scanner = SvgDScanner(d)
        var lastCmd: Character = " "

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

            switch cmd {
            case "M":
                guard let p = scanner.readPoint() else { return nil }
                current = p; subpathStart = p
                path.move(to: p)
            case "m":
                guard let p = scanner.readPoint() else { return nil }
                current = CGPoint(x: current.x + p.x, y: current.y + p.y)
                subpathStart = current
                path.move(to: current)
            case "L":
                guard let p = scanner.readPoint() else { return nil }
                current = p
                path.addLine(to: p)
            case "l":
                guard let p = scanner.readPoint() else { return nil }
                current = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.readNumber() else { return nil }
                current.x = x
                path.addLine(to: current)
            case "h":
                guard let dx = scanner.readNumber() else { return nil }
                current.x += dx
                path.addLine(to: current)
            case "V":
                guard let y = scanner.readNumber() else { return nil }
                current.y = y
                path.addLine(to: current)
            case "v":
                guard let dy = scanner.readNumber() else { return nil }
                current.y += dy
                path.addLine(to: current)
            case "C":
                guard let c1 = scanner.readPoint(),
                      let c2 = scanner.readPoint(),
                      let p = scanner.readPoint() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case "c":
                guard let c1 = scanner.readPoint(),
                      let c2 = scanner.readPoint(),
                      let p = scanner.readPoint() else { return nil }
                let abs1 = CGPoint(x: current.x + c1.x, y: current.y + c1.y)
                let abs2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                let absP = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addCurve(to: absP, control1: abs1, control2: abs2)
                current = absP
            case "Q":
                guard let c = scanner.readPoint(), let p = scanner.readPoint() else { return nil }
                path.addQuadCurve(to: p, control: c)
                current = p
            case "q":
                guard let c = scanner.readPoint(), let p = scanner.readPoint() else { return nil }
                let absC = CGPoint(x: current.x + c.x, y: current.y + c.y)
                let absP = CGPoint(x: current.x + p.x, y: current.y + p.y)
                path.addQuadCurve(to: absP, control: absC)
                current = absP
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                // S, s, T, t, A, a — not yet supported.
                return nil
            }
        }

        return path
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
}
