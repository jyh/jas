/// Binary document serialization using MessagePack + deflate.
///
/// Format:
///     [Magic 4B "JAS\0"] [Version u16 LE] [Flags u16 LE] [Payload]
///
/// Flags bits 0-1: compression method (0=none, 1=raw deflate).
/// Payload: MessagePack-encoded document using positional arrays.
///
/// Scope: this module is consumed only by cross-language fixture tests
/// (Tests/CrossLanguageTests.swift). The real save path uses
/// documentToSvg/svgToDocument; binary disk persistence is deferred
/// (Sources/Document/Model.swift documents this as Phase 1). The
/// fatalError sites below are appropriate for fixture parsing where
/// corrupt input is a test bug, not a runtime concern.

import Foundation
import zlib

// MARK: - Constants

private let magic: [UInt8] = [0x4A, 0x41, 0x53, 0x00] // "JAS\0"
// v2 (CommonProps id+name): every element array now carries name and id in the
// shared common block at fixed indices 5 and 6, with the type-specific payload
// shifted to index 7. v1 (name was Layer-only at index 5, no id) is a different
// positional layout and is NOT forward-readable — binary persistence is a
// deferred secondary format with no real-world v1 data, so the fixtures were
// regenerated to v2 rather than carrying a dual parse path.
private let version: UInt16 = 2
private let minVersion: UInt16 = 2
private let headerSize = 8

private let compressNone: UInt16 = 0
private let compressDeflate: UInt16 = 1

// Element type tags.
private let tagLayer: Int = 0
private let tagLine: Int = 1
private let tagRect: Int = 2
private let tagCircle: Int = 3
private let tagEllipse: Int = 4
private let tagPolyline: Int = 5
private let tagPolygon: Int = 6
private let tagPath: Int = 7
private let tagText: Int = 8
private let tagTextPath: Int = 9
private let tagGroup: Int = 10
// Live elements (REFERENCE_GRAPH.md Phase 2b): one tag for every
// LiveElement kind, disambiguated by a kind string at index 7.
private let tagLive: Int = 11

// Path command tags.
private let cmdMoveTo: Int = 0
private let cmdLineTo: Int = 1
private let cmdCurveTo: Int = 2
private let cmdSmoothCurveTo: Int = 3
private let cmdQuadTo: Int = 4
private let cmdSmoothQuadTo: Int = 5
private let cmdArcTo: Int = 6
private let cmdClosePath: Int = 7

// Color space tags.
private let spaceRgb: Int = 0
private let spaceHsb: Int = 1
private let spaceCmyk: Int = 2

// MARK: - Minimal MessagePack Value

/// A MessagePack value: only the subset we need.
private enum MsgValue {
    case `nil`
    case bool(Bool)
    case int(Int)
    case float64(Double)
    case string(String)
    case array([MsgValue])
}

// MARK: - MessagePack Encoder

private func encodeValue(_ v: MsgValue, to buf: inout [UInt8]) {
    switch v {
    case .nil:
        buf.append(0xc0)
    case .bool(let b):
        buf.append(b ? 0xc3 : 0xc2)
    case .int(let n):
        if n >= 0 && n <= 127 {
            buf.append(UInt8(n))
        } else if n >= -32 && n < 0 {
            buf.append(UInt8(bitPattern: Int8(n)))
        } else if n >= 0 && n <= 0xFF {
            buf.append(0xcc)
            buf.append(UInt8(n))
        } else if n >= 0 && n <= 0xFFFF {
            buf.append(0xcd)
            buf.append(UInt8((n >> 8) & 0xFF))
            buf.append(UInt8(n & 0xFF))
        } else if n >= 0 && n <= 0xFFFF_FFFF {
            buf.append(0xce)
            buf.append(UInt8((n >> 24) & 0xFF))
            buf.append(UInt8((n >> 16) & 0xFF))
            buf.append(UInt8((n >> 8) & 0xFF))
            buf.append(UInt8(n & 0xFF))
        } else if n >= -128 && n < 0 {
            buf.append(0xd0)
            buf.append(UInt8(bitPattern: Int8(n)))
        } else if n >= -32768 && n < 0 {
            buf.append(0xd1)
            let u = UInt16(bitPattern: Int16(n))
            buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8(u & 0xFF))
        } else {
            // int64
            buf.append(0xd3)
            let u = UInt64(bitPattern: Int64(n))
            for shift in stride(from: 56, through: 0, by: -8) {
                buf.append(UInt8((u >> shift) & 0xFF))
            }
        }
    case .float64(let f):
        buf.append(0xcb)
        var bits = f.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { buf.append(contentsOf: $0) }
    case .string(let s):
        let utf8 = Array(s.utf8)
        let len = utf8.count
        if len <= 31 {
            buf.append(0xa0 | UInt8(len))
        } else if len <= 0xFF {
            buf.append(0xd9)
            buf.append(UInt8(len))
        } else if len <= 0xFFFF {
            buf.append(0xda)
            buf.append(UInt8((len >> 8) & 0xFF))
            buf.append(UInt8(len & 0xFF))
        } else {
            buf.append(0xdb)
            buf.append(UInt8((len >> 24) & 0xFF))
            buf.append(UInt8((len >> 16) & 0xFF))
            buf.append(UInt8((len >> 8) & 0xFF))
            buf.append(UInt8(len & 0xFF))
        }
        buf.append(contentsOf: utf8)
    case .array(let items):
        let count = items.count
        if count <= 15 {
            buf.append(0x90 | UInt8(count))
        } else if count <= 0xFFFF {
            buf.append(0xdc)
            buf.append(UInt8((count >> 8) & 0xFF))
            buf.append(UInt8(count & 0xFF))
        } else {
            buf.append(0xdd)
            buf.append(UInt8((count >> 24) & 0xFF))
            buf.append(UInt8((count >> 16) & 0xFF))
            buf.append(UInt8((count >> 8) & 0xFF))
            buf.append(UInt8(count & 0xFF))
        }
        for item in items {
            encodeValue(item, to: &buf)
        }
    }
}

// MARK: - MessagePack Decoder

private struct MsgReader {
    let data: [UInt8]
    var pos: Int = 0

    mutating func readValue() throws -> MsgValue {
        guard pos < data.count else { throw BinaryError.truncated }
        let byte = data[pos]; pos += 1

        // positive fixint
        if byte <= 0x7f { return .int(Int(byte)) }
        // negative fixint
        if byte >= 0xe0 { return .int(Int(Int8(bitPattern: byte))) }
        // fixstr
        if byte >= 0xa0 && byte <= 0xbf {
            let len = Int(byte & 0x1f)
            return .string(try readString(len))
        }
        // fixarray
        if byte >= 0x90 && byte <= 0x9f {
            let count = Int(byte & 0x0f)
            return .array(try readArray(count))
        }

        switch byte {
        case 0xc0: return .nil
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)

        // unsigned ints
        case 0xcc: return .int(Int(try readUInt8()))
        case 0xcd: return .int(Int(try readUInt16()))
        case 0xce: return .int(Int(try readUInt32()))
        case 0xcf: return .int(Int(try readUInt64()))

        // signed ints
        case 0xd0: return .int(Int(Int8(bitPattern: try readUInt8())))
        case 0xd1: return .int(Int(Int16(bitPattern: try readUInt16())))
        case 0xd2: return .int(Int(Int32(bitPattern: try readUInt32())))
        case 0xd3: return .int(Int(Int64(bitPattern: try readUInt64())))

        // float
        case 0xca:
            let bits = try readUInt32()
            return .float64(Double(Float(bitPattern: bits)))
        case 0xcb:
            let bits = try readUInt64()
            return .float64(Double(bitPattern: bits))

        // str
        case 0xd9: return .string(try readString(Int(try readUInt8())))
        case 0xda: return .string(try readString(Int(try readUInt16())))
        case 0xdb: return .string(try readString(Int(try readUInt32())))

        // array
        case 0xdc: return .array(try readArray(Int(try readUInt16())))
        case 0xdd: return .array(try readArray(Int(try readUInt32())))

        default: throw BinaryError.unsupportedMsgpack(byte)
        }
    }

    private mutating func readUInt8() throws -> UInt8 {
        guard pos < data.count else { throw BinaryError.truncated }
        let v = data[pos]; pos += 1; return v
    }

    private mutating func readUInt16() throws -> UInt16 {
        guard pos + 1 < data.count else { throw BinaryError.truncated }
        let v = UInt16(data[pos]) << 8 | UInt16(data[pos+1]); pos += 2; return v
    }

    private mutating func readUInt32() throws -> UInt32 {
        guard pos + 3 < data.count else { throw BinaryError.truncated }
        let v = UInt32(data[pos]) << 24 | UInt32(data[pos+1]) << 16 |
                UInt32(data[pos+2]) << 8 | UInt32(data[pos+3])
        pos += 4; return v
    }

    private mutating func readUInt64() throws -> UInt64 {
        guard pos + 7 < data.count else { throw BinaryError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[pos + i]) }
        pos += 8; return v
    }

    private mutating func readString(_ len: Int) throws -> String {
        guard pos + len <= data.count else { throw BinaryError.truncated }
        let bytes = Array(data[pos..<pos+len])
        pos += len
        guard let s = String(bytes: bytes, encoding: .utf8) else { throw BinaryError.invalidUtf8 }
        return s
    }

    private mutating func readArray(_ count: Int) throws -> [MsgValue] {
        var arr = [MsgValue]()
        arr.reserveCapacity(count)
        for _ in 0..<count { arr.append(try readValue()) }
        return arr
    }
}

// MARK: - Raw Deflate Compression

private func deflateCompress(_ input: [UInt8]) -> [UInt8] {
    var stream = z_stream()
    // wbits=-15 for raw deflate (no zlib/gzip header)
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                        Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        fatalError("deflateInit2_ failed")
    }
    defer { deflateEnd(&stream) }

    let bound = Int(deflateBound(&stream, UInt(input.count)))
    var output = [UInt8](repeating: 0, count: bound)

    input.withUnsafeBufferPointer { inBuf in
        output.withUnsafeMutableBufferPointer { outBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
            stream.avail_in = UInt32(input.count)
            stream.next_out = outBuf.baseAddress!
            stream.avail_out = UInt32(outBuf.count)
            let result = deflate(&stream, Z_FINISH)
            precondition(result == Z_STREAM_END, "deflate failed: \(result)")
        }
    }

    return Array(output.prefix(Int(stream.total_out)))
}

private func deflateDecompress(_ input: [UInt8]) throws -> [UInt8] {
    var stream = z_stream()
    // wbits=-15 for raw deflate
    guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw BinaryError.decompressFailed
    }
    defer { inflateEnd(&stream) }

    var output = [UInt8](repeating: 0, count: input.count * 4)
    var result: Int32 = Z_OK

    try input.withUnsafeBufferPointer { inBuf in
        stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress!)
        stream.avail_in = UInt32(input.count)

        while result != Z_STREAM_END {
            if stream.avail_out == 0 {
                let oldCount = output.count
                output.append(contentsOf: [UInt8](repeating: 0, count: oldCount))
            }
            try output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress!.advanced(by: Int(stream.total_out))
                stream.avail_out = UInt32(outBuf.count - Int(stream.total_out))
                result = inflate(&stream, Z_NO_FLUSH)
                if result != Z_OK && result != Z_STREAM_END {
                    throw BinaryError.decompressFailed
                }
            }
        }
    }

    return Array(output.prefix(Int(stream.total_out)))
}

// MARK: - Errors

package enum BinaryError: Error {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unsupportedCompression(UInt16)
    case decompressFailed
    case invalidUtf8
    case unsupportedMsgpack(UInt8)
    case invalidData(String)
}

// MARK: - Pack helpers

private func vint(_ n: Int) -> MsgValue { .int(n) }
private func vf64(_ f: Double) -> MsgValue { .float64(f) }
private func vbool(_ b: Bool) -> MsgValue { .bool(b) }
private func vstr(_ s: String) -> MsgValue { .string(s) }
private func vnil() -> MsgValue { .nil }

// Optional-aware packers: `nil` → msgpack nil, `Some(v)` → typed value.
private func optF64(_ o: Double?) -> MsgValue { o.map(vf64) ?? .nil }
private func optStr(_ o: String?) -> MsgValue { o.map(vstr) ?? .nil }
private func optBool(_ o: Bool?) -> MsgValue { o.map(vbool) ?? .nil }

private func asOptF64(_ v: MsgValue) -> Double? {
    if case .nil = v { return nil }
    return asF64(v)
}
private func asOptStr(_ v: MsgValue) -> String? {
    if case .nil = v { return nil }
    return asStr(v)
}
private func asOptBool(_ v: MsgValue) -> Bool? {
    if case .nil = v { return nil }
    return asBool(v)
}

/// Pack a single Tspan as a compact msgpack array. Mirrors Rust's
/// `pack_tspan` — 22 fields in the same order.
private func packTspan(_ t: Tspan) -> MsgValue {
    let decor: MsgValue
    if let members = t.textDecoration {
        decor = .array(members.map { vstr($0) })
    } else {
        decor = .nil
    }
    let transform: MsgValue
    if let tr = t.transform {
        transform = .array([
            vf64(tr.a), vf64(tr.b), vf64(tr.c),
            vf64(tr.d), vf64(tr.e), vf64(tr.f),
        ])
    } else {
        transform = .nil
    }
    return .array([
        vint(Int(t.id)),
        vstr(t.content),
        optF64(t.baselineShift),
        optF64(t.dx),
        optStr(t.fontFamily),
        optF64(t.fontSize),
        optStr(t.fontStyle),
        optStr(t.fontVariant),
        optStr(t.fontWeight),
        optStr(t.jasAaMode),
        optBool(t.jasFractionalWidths),
        optStr(t.jasKerningMode),
        optBool(t.jasNoBreak),
        optF64(t.letterSpacing),
        optF64(t.lineHeight),
        optF64(t.rotate),
        optStr(t.styleName),
        decor,
        optStr(t.textRendering),
        optStr(t.textTransform),
        transform,
        optStr(t.xmlLang),
    ])
}

private func unpackTspan(_ v: MsgValue) -> Tspan {
    let arr = asArray(v)
    func get(_ i: Int) -> MsgValue { i < arr.count ? arr[i] : .nil }
    let id = arr.count > 0 ? UInt32(asInt(arr[0])) : 0
    let content = arr.count > 1 ? asStr(arr[1]) : ""
    let decor: [String]?
    if case .array(let xs) = get(17) {
        decor = xs.map { asStr($0) }
    } else {
        decor = nil
    }
    let transform: Transform?
    if case .array(let xs) = get(20), xs.count >= 6 {
        transform = Transform(
            a: asF64(xs[0]), b: asF64(xs[1]), c: asF64(xs[2]),
            d: asF64(xs[3]), e: asF64(xs[4]), f: asF64(xs[5]))
    } else {
        transform = nil
    }
    return Tspan(
        id: id, content: content,
        baselineShift: asOptF64(get(2)),
        dx: asOptF64(get(3)),
        fontFamily: asOptStr(get(4)),
        fontSize: asOptF64(get(5)),
        fontStyle: asOptStr(get(6)),
        fontVariant: asOptStr(get(7)),
        fontWeight: asOptStr(get(8)),
        jasAaMode: asOptStr(get(9)),
        jasFractionalWidths: asOptBool(get(10)),
        jasKerningMode: asOptStr(get(11)),
        jasNoBreak: asOptBool(get(12)),
        letterSpacing: asOptF64(get(13)),
        lineHeight: asOptF64(get(14)),
        rotate: asOptF64(get(15)),
        styleName: asOptStr(get(16)),
        textDecoration: decor,
        textRendering: asOptStr(get(18)),
        textTransform: asOptStr(get(19)),
        transform: transform,
        xmlLang: asOptStr(get(21)))
}

// MARK: - Unpack helpers

private func asInt(_ v: MsgValue) -> Int {
    guard case .int(let n) = v else {
        if case .float64(let f) = v { return Int(f) }
        fatalError("expected int, got \(v)")
    }
    return n
}

private func asF64(_ v: MsgValue) -> Double {
    switch v {
    case .float64(let f): return f
    case .int(let n): return Double(n)
    default: fatalError("expected f64, got \(v)")
    }
}

private func asBool(_ v: MsgValue) -> Bool {
    guard case .bool(let b) = v else { fatalError("expected bool, got \(v)") }
    return b
}

private func asStr(_ v: MsgValue) -> String {
    guard case .string(let s) = v else { fatalError("expected string, got \(v)") }
    return s
}

private func asArray(_ v: MsgValue) -> [MsgValue] {
    guard case .array(let a) = v else { fatalError("expected array, got \(v)") }
    return a
}

// MARK: - Pack (Document -> MsgValue)

private func packColor(_ c: Color) -> MsgValue {
    switch c {
    case .rgb(let r, let g, let b, let a):
        return .array([vint(spaceRgb), vf64(r), vf64(g), vf64(b), vf64(0.0), vf64(a)])
    case .hsb(let h, let s, let b, let a):
        return .array([vint(spaceHsb), vf64(h), vf64(s), vf64(b), vf64(0.0), vf64(a)])
    case .cmyk(let c, let m, let y, let k, let a):
        return .array([vint(spaceCmyk), vf64(c), vf64(m), vf64(y), vf64(k), vf64(a)])
    }
}

private func packFill(_ fill: Fill?) -> MsgValue {
    guard let f = fill else { return .nil }
    return .array([packColor(f.color), vf64(f.opacity)])
}

private func packStroke(_ stroke: Stroke?) -> MsgValue {
    guard let s = stroke else { return .nil }
    let cap: Int = switch s.linecap { case .butt: 0; case .round: 1; case .square: 2 }
    let join: Int = switch s.linejoin { case .miter: 0; case .round: 1; case .bevel: 2 }
    let align: Int = switch s.align { case .center: 0; case .inside: 1; case .outside: 2 }
    let arrowAlign: Int = switch s.arrowAlign { case .tipAtEnd: 0; case .centerAtEnd: 1 }
    let dash: [MsgValue] = s.dashPattern.map { vf64($0) }
    return .array([packColor(s.color), vf64(s.width), vint(cap), vint(join), vf64(s.opacity),
                   vf64(s.miterLimit), vint(align), .array(dash),
                   vstr(s.startArrow.name), vstr(s.endArrow.name),
                   vf64(s.startArrowScale), vf64(s.endArrowScale), vint(arrowAlign),
                   // Element 13: dash_align_anchors (added with DASH_ALIGN.md).
                   vbool(s.dashAlignAnchors)])
}

private func packWidthPoints(_ pts: [StrokeWidthPoint]) -> MsgValue {
    if pts.isEmpty { return .nil }
    return .array(pts.map { .array([vf64($0.t), vf64($0.widthLeft), vf64($0.widthRight)]) })
}

private func packTransform(_ t: Transform?) -> MsgValue {
    guard let t = t else { return .nil }
    return .array([vf64(t.a), vf64(t.b), vf64(t.c), vf64(t.d), vf64(t.e), vf64(t.f)])
}

private func packPathCommand(_ cmd: PathCommand) -> MsgValue {
    switch cmd {
    case .moveTo(let x, let y):
        return .array([vint(cmdMoveTo), vf64(x), vf64(y)])
    case .lineTo(let x, let y):
        return .array([vint(cmdLineTo), vf64(x), vf64(y)])
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        return .array([vint(cmdCurveTo), vf64(x1), vf64(y1), vf64(x2), vf64(y2), vf64(x), vf64(y)])
    case .smoothCurveTo(let x2, let y2, let x, let y):
        return .array([vint(cmdSmoothCurveTo), vf64(x2), vf64(y2), vf64(x), vf64(y)])
    case .quadTo(let x1, let y1, let x, let y):
        return .array([vint(cmdQuadTo), vf64(x1), vf64(y1), vf64(x), vf64(y)])
    case .smoothQuadTo(let x, let y):
        return .array([vint(cmdSmoothQuadTo), vf64(x), vf64(y)])
    case .arcTo(let rx, let ry, let rot, let la, let sw, let x, let y):
        return .array([vint(cmdArcTo), vf64(rx), vf64(ry), vf64(rot), vbool(la), vbool(sw), vf64(x), vf64(y)])
    case .closePath:
        return .array([vint(cmdClosePath)])
    }
}

private func packVis(_ v: Visibility) -> MsgValue {
    switch v { case .invisible: vint(0); case .outline: vint(1); case .preview: vint(2) }
}

/// The shared common block written for EVERY element (v2): the six
/// values [locked, opacity, visibility, transform, name, id] that land
/// at array indices 1..6, with the type-specific payload following at
/// index 7. Mirrors Rust's `pack_common` / Python's `_pack_common`.
/// name and id are emitted as value-or-nil so every element type
/// round-trips them uniformly. (`Element` doesn't expose locked/opacity/
/// name at the enum level, so the per-case fields are passed in.)
private func packCommon(locked: Bool, opacity: Double, visibility: Visibility,
                        transform: Transform?, name: String?, id: String?) -> [MsgValue] {
    [vbool(locked), vf64(opacity), packVis(visibility),
     packTransform(transform), optStr(name), optStr(id)]
}

private func packElement(_ elem: Element) -> MsgValue {
    switch elem {
    case .layer(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let children: [MsgValue] = e.children.map { packElement($0) }
        return .array([vint(tagLayer)] + common + [.array(children)])
    case .group(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let children: [MsgValue] = e.children.map { packElement($0) }
        return .array([vint(tagGroup)] + common + [.array(children)])
    case .line(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        return .array([vint(tagLine)] + common +
                      [vf64(e.x1), vf64(e.y1), vf64(e.x2), vf64(e.y2),
                       packStroke(e.stroke), packWidthPoints(e.widthPoints)])
    case .rect(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        return .array([vint(tagRect)] + common +
                      [vf64(e.x), vf64(e.y), vf64(e.width), vf64(e.height),
                       vf64(e.rx), vf64(e.ry),
                       packFill(e.fill), packStroke(e.stroke)])
    case .circle(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        return .array([vint(tagCircle)] + common +
                      [vf64(e.cx), vf64(e.cy), vf64(e.r),
                       packFill(e.fill), packStroke(e.stroke)])
    case .ellipse(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        return .array([vint(tagEllipse)] + common +
                      [vf64(e.cx), vf64(e.cy), vf64(e.rx), vf64(e.ry),
                       packFill(e.fill), packStroke(e.stroke)])
    case .polyline(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let points: [MsgValue] = e.points.map { .array([vf64($0.0), vf64($0.1)]) }
        return .array([vint(tagPolyline)] + common +
                      [.array(points), packFill(e.fill), packStroke(e.stroke)])
    case .polygon(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let points: [MsgValue] = e.points.map { .array([vf64($0.0), vf64($0.1)]) }
        return .array([vint(tagPolygon)] + common +
                      [.array(points), packFill(e.fill), packStroke(e.stroke)])
    case .path(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let cmds: [MsgValue] = e.d.map { packPathCommand($0) }
        return .array([vint(tagPath)] + common +
                      [.array(cmds), packFill(e.fill), packStroke(e.stroke),
                       packWidthPoints(e.widthPoints)])
    case .text(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        // Trailing tspans array — multi-tspan / override-bearing
        // documents round-trip through binary. Old blobs without
        // this field decode via the backward-compat path below.
        let tspans: [MsgValue] = e.tspans.map { packTspan($0) }
        return .array([vint(tagText)] + common +
                      [vf64(e.x), vf64(e.y), vstr(e.content),
                       vstr(e.fontFamily), vf64(e.fontSize),
                       vstr(e.fontWeight), vstr(e.fontStyle), vstr(e.textDecoration),
                       vf64(e.width), vf64(e.height),
                       packFill(e.fill), packStroke(e.stroke),
                       .array(tspans)])
    case .textPath(let e):
        let common = packCommon(locked: e.locked, opacity: e.opacity, visibility: e.visibility,
                                transform: e.transform, name: e.name, id: e.id)
        let cmds: [MsgValue] = e.d.map { packPathCommand($0) }
        let tspans: [MsgValue] = e.tspans.map { packTspan($0) }
        return .array([vint(tagTextPath)] + common +
                      [.array(cmds), vstr(e.content), vf64(e.startOffset),
                       vstr(e.fontFamily), vf64(e.fontSize),
                       vstr(e.fontWeight), vstr(e.fontStyle), vstr(e.textDecoration),
                       packFill(e.fill), packStroke(e.stroke),
                       .array(tspans)])
    case .live(let v):
        // Live elements (REFERENCE_GRAPH.md Phase 2b): a single tagLive
        // with a kind string at index 7, then a kind-specific payload.
        // Paint (fill/stroke) is omitted in Phase 1 (references inherit;
        // compound carries none here), mirroring the test_json live codec.
        switch v {
        case .compoundShape(let cs):
            // CompoundShape carries a stable id but no name field, so name
            // packs as nil while id packs through (matching Python's
            // getattr-based _pack_common). An id-less compound is byte-
            // identical to before.
            let common = packCommon(locked: cs.locked, opacity: cs.opacity,
                                    visibility: cs.visibility, transform: cs.transform,
                                    name: nil, id: cs.id)
            // [tag, common(1..6), kind(7), operation(8), operands(9)]
            let operands: [MsgValue] = cs.operands.map { packElement($0) }
            return .array([vint(tagLive)] + common +
                          [vstr("compound_shape"), vstr(cs.operation.rawValue),
                           .array(operands)])
        case .reference(let r):
            // ReferenceElem has its own id but no name field (name packs nil).
            let common = packCommon(locked: r.locked, opacity: r.opacity,
                                    visibility: r.visibility, transform: r.transform,
                                    name: nil, id: r.id)
            // [tag, common(1..6), kind(7), target(8), instance_transform(9)]
            // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
            // (distinct from the render CTM packed at slot 4) rides slot 9 via
            // packTransform; nil when unset. Old 9-element .bin (no slot 9)
            // still decode TOLERANTLY to nil on the read side.
            return .array([vint(tagLive)] + common +
                          [vstr("reference"), vstr(r.target.id),
                           packTransform(r.instanceTransform)])
        case .recorded(let rec):
            // RecordedElem has its own id but no name field (name packs nil).
            let common = packCommon(locked: rec.locked, opacity: rec.opacity,
                                    visibility: rec.visibility, transform: rec.transform,
                                    name: nil, id: rec.id)
            // The recipe (inputs + ops) rides slots 8/9 as canonical JSON
            // strings (RECORDED_ELEMENTS.md), mirroring the Rust binary codec.
            // [tag, common(1..6), kind(7), inputs-json(8), ops-json(9)].
            let inputsJson = "[" +
                rec.inputs.map { "\"\($0.id)\"" }.joined(separator: ",") + "]"
            let opsJson = recordedOpsCanonical(rec.ops)
            return .array([vint(tagLive)] + common +
                          [vstr("recorded"), vstr(inputsJson), vstr(opsJson)])
        case .generated(let gen):
            // GeneratedElem has its own id but no name field (name packs nil).
            let common = packCommon(locked: gen.locked, opacity: gen.opacity,
                                    visibility: gen.visibility, transform: gen.transform,
                                    name: nil, id: gen.id)
            // The concept id + params ride slots 8/9 as canonical JSON strings
            // (CONCEPTS.md), mirroring the Rust binary codec.
            // [tag, common(1..6), kind(7), concept(8), params-json(9)].
            let paramsJson = canonicalRecordedValue(gen.params)
            return .array([vint(tagLive)] + common +
                          [vstr("generated"), vstr(gen.conceptId), vstr(paramsJson)])
        }
    }
}

private func packSelection(_ sel: Selection) -> MsgValue {
    var entries: [([Int], MsgValue)] = sel.map { es in
        let path: [MsgValue] = es.path.map { vint($0) }
        let kind: MsgValue
        switch es.kind {
        case .all: kind = vint(0)
        case .partial(let cps):
            var v: [MsgValue] = [vint(1)]
            v.append(contentsOf: cps.toArray().map { vint($0) })
            kind = .array(v)
        }
        return (es.path, .array([.array(path), kind]))
    }
    entries.sort { $0.0.lexicographicallyPrecedes($1.0) }
    return .array(entries.map { $0.1 })
}

private func packDocument(_ doc: Document) -> MsgValue {
    let layers: [MsgValue] = doc.layers.map { packElement(.layer($0)) }
    // Symbols (master store, SYMBOLS.md §5): appended to the positional
    // document array AFTER the existing fields, as a (possibly empty) element
    // array sorted by id (the §2 deterministic-order rule). Trailing position
    // keeps existing .bin fixtures (which predate symbols) decodable — unpack
    // tolerates the field's absence via arr.count.
    let sortedMasters = doc.symbols.sorted { ($0.id ?? "") < ($1.id ?? "") }
    let symbols: [MsgValue] = sortedMasters.map { packElement($0) }
    return .array([.array(layers), vint(doc.selectedLayer), packSelection(doc.selection),
                   .array(symbols)])
}

// MARK: - Unpack (MsgValue -> Document)

private func unpackColor(_ v: MsgValue) -> Color {
    let arr = asArray(v)
    let space = asInt(arr[0])
    switch space {
    case spaceRgb: return .rgb(r: asF64(arr[1]), g: asF64(arr[2]), b: asF64(arr[3]), a: asF64(arr[5]))
    case spaceHsb: return .hsb(h: asF64(arr[1]), s: asF64(arr[2]), b: asF64(arr[3]), a: asF64(arr[5]))
    case spaceCmyk: return .cmyk(c: asF64(arr[1]), m: asF64(arr[2]), y: asF64(arr[3]), k: asF64(arr[4]), a: asF64(arr[5]))
    default: fatalError("unknown color space: \(space)")
    }
}

private func unpackFill(_ v: MsgValue) -> Fill? {
    if case .nil = v { return nil }
    let arr = asArray(v)
    return Fill(color: unpackColor(arr[0]), opacity: asF64(arr[1]))
}

private func unpackStroke(_ v: MsgValue) -> Stroke? {
    if case .nil = v { return nil }
    let arr = asArray(v)
    let cap: LineCap = switch asInt(arr[2]) { case 0: .butt; case 1: .round; case 2: .square; default: .butt }
    let join: LineJoin = switch asInt(arr[3]) { case 0: .miter; case 1: .round; case 2: .bevel; default: .miter }
    // Extended fields (backward compatible: old files have 5 elements)
    if arr.count > 5 {
        let miterLimit = asF64(arr[5])
        let align: StrokeAlign = switch asInt(arr[6]) { case 1: .inside; case 2: .outside; default: .center }
        let dashPattern = asArray(arr[7]).map { asF64($0) }
        let startArrow = Arrowhead(fromString: asStr(arr[8]))
        let endArrow = Arrowhead(fromString: asStr(arr[9]))
        let startArrowScale = asF64(arr[10])
        let endArrowScale = asF64(arr[11])
        let arrowAlign: ArrowAlign = switch asInt(arr[12]) { case 1: .centerAtEnd; default: .tipAtEnd }
        // Element 13: dash_align_anchors (added later — backward
        // compatible with older files that had 13 elements).
        let dashAlignAnchors = arr.count > 13 ? asBool(arr[13]) : false
        return Stroke(color: unpackColor(arr[0]), width: asF64(arr[1]), linecap: cap, linejoin: join,
                      miterLimit: miterLimit, align: align, dashPattern: dashPattern,
                      dashAlignAnchors: dashAlignAnchors,
                      startArrow: startArrow, endArrow: endArrow,
                      startArrowScale: startArrowScale, endArrowScale: endArrowScale,
                      arrowAlign: arrowAlign, opacity: asF64(arr[4]))
    }
    return Stroke(color: unpackColor(arr[0]), width: asF64(arr[1]), linecap: cap, linejoin: join, opacity: asF64(arr[4]))
}

private func unpackWidthPoints(_ v: MsgValue) -> [StrokeWidthPoint] {
    if case .nil = v { return [] }
    return asArray(v).map { p in
        let a = asArray(p)
        return StrokeWidthPoint(t: asF64(a[0]), widthLeft: asF64(a[1]), widthRight: asF64(a[2]))
    }
}

private func unpackTransform(_ v: MsgValue) -> Transform? {
    if case .nil = v { return nil }
    let arr = asArray(v)
    return Transform(a: asF64(arr[0]), b: asF64(arr[1]), c: asF64(arr[2]),
                     d: asF64(arr[3]), e: asF64(arr[4]), f: asF64(arr[5]))
}

private func unpackPathCommand(_ v: MsgValue) -> PathCommand {
    let arr = asArray(v)
    let tag = asInt(arr[0])
    switch tag {
    case cmdMoveTo: return .moveTo(asF64(arr[1]), asF64(arr[2]))
    case cmdLineTo: return .lineTo(asF64(arr[1]), asF64(arr[2]))
    case cmdCurveTo: return .curveTo(x1: asF64(arr[1]), y1: asF64(arr[2]),
                                     x2: asF64(arr[3]), y2: asF64(arr[4]),
                                     x: asF64(arr[5]), y: asF64(arr[6]))
    case cmdSmoothCurveTo: return .smoothCurveTo(x2: asF64(arr[1]), y2: asF64(arr[2]),
                                                 x: asF64(arr[3]), y: asF64(arr[4]))
    case cmdQuadTo: return .quadTo(x1: asF64(arr[1]), y1: asF64(arr[2]),
                                   x: asF64(arr[3]), y: asF64(arr[4]))
    case cmdSmoothQuadTo: return .smoothQuadTo(asF64(arr[1]), asF64(arr[2]))
    case cmdArcTo: return .arcTo(rx: asF64(arr[1]), ry: asF64(arr[2]),
                                 rotation: asF64(arr[3]),
                                 largeArc: asBool(arr[4]), sweep: asBool(arr[5]),
                                 x: asF64(arr[6]), y: asF64(arr[7]))
    case cmdClosePath: return .closePath
    default: fatalError("unknown path command tag: \(tag)")
    }
}

/// Inverse of `packCommon`: reads the shared common block at indices
/// 1..6 (locked, opacity, visibility, transform, name, id). The
/// type-specific payload begins at index 7. Mirrors Rust's
/// `unpack_common` / Python's `_unpack_common`.
private func unpackCommon(_ arr: [MsgValue]) -> (Bool, Double, Visibility, Transform?, String?, String?) {
    let vis: Visibility = switch asInt(arr[3]) { case 0: .invisible; case 1: .outline; default: .preview }
    return (asBool(arr[1]), asF64(arr[2]), vis, unpackTransform(arr[4]),
            asOptStr(arr[5]), asOptStr(arr[6]))
}

private func unpackElement(_ v: MsgValue) -> Element {
    let arr = asArray(v)
    let tag = asInt(arr[0])
    let (locked, opacity, vis, xform, name, id) = unpackCommon(arr)
    // Type-specific payload begins at index 7 (after the common block).

    switch tag {
    case tagLayer:
        let children = asArray(arr[7]).map { unpackElement($0) }
        return .layer(Layer(name: name, children: children, opacity: opacity,
                            transform: xform, locked: locked, visibility: vis, id: id))
    case tagGroup:
        let children = asArray(arr[7]).map { unpackElement($0) }
        return .group(Group(children: children, opacity: opacity,
                            transform: xform, locked: locked, visibility: vis, name: name, id: id))
    case tagLine:
        let wp = arr.count > 12 ? unpackWidthPoints(arr[12]) : []
        return .line(Line(x1: asF64(arr[7]), y1: asF64(arr[8]),
                          x2: asF64(arr[9]), y2: asF64(arr[10]),
                          stroke: unpackStroke(arr[11]), widthPoints: wp,
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          name: name, id: id))
    case tagRect:
        return .rect(Rect(x: asF64(arr[7]), y: asF64(arr[8]),
                          width: asF64(arr[9]), height: asF64(arr[10]),
                          rx: asF64(arr[11]), ry: asF64(arr[12]),
                          fill: unpackFill(arr[13]), stroke: unpackStroke(arr[14]),
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          name: name, id: id))
    case tagCircle:
        return .circle(Circle(cx: asF64(arr[7]), cy: asF64(arr[8]), r: asF64(arr[9]),
                              fill: unpackFill(arr[10]), stroke: unpackStroke(arr[11]),
                              opacity: opacity, transform: xform, locked: locked, visibility: vis,
                              name: name, id: id))
    case tagEllipse:
        return .ellipse(Ellipse(cx: asF64(arr[7]), cy: asF64(arr[8]),
                                rx: asF64(arr[9]), ry: asF64(arr[10]),
                                fill: unpackFill(arr[11]), stroke: unpackStroke(arr[12]),
                                opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                name: name, id: id))
    case tagPolyline:
        let points = asArray(arr[7]).map { (asF64(asArray($0)[0]), asF64(asArray($0)[1])) }
        return .polyline(Polyline(points: points, fill: unpackFill(arr[8]), stroke: unpackStroke(arr[9]),
                                  opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                  name: name, id: id))
    case tagPolygon:
        let points = asArray(arr[7]).map { (asF64(asArray($0)[0]), asF64(asArray($0)[1])) }
        return .polygon(Polygon(points: points, fill: unpackFill(arr[8]), stroke: unpackStroke(arr[9]),
                                opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                name: name, id: id))
    case tagPath:
        let cmds = asArray(arr[7]).map { unpackPathCommand($0) }
        let wp = arr.count > 10 ? unpackWidthPoints(arr[10]) : []
        return .path(Path(d: cmds, fill: unpackFill(arr[8]), stroke: unpackStroke(arr[9]),
                          widthPoints: wp,
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          name: name, id: id))
    case tagText:
        // Prefer the trailing tspans field when present; otherwise
        // fall back to the single-default-tspan seeded from content
        // (pre-tspan-codec blobs). Constructed via the tspans-bearing
        // init so the common block (name/id/visibility/transform)
        // survives — `withTspans` does not carry those through.
        if arr.count > 19, case .array(let ts) = arr[19], !ts.isEmpty {
            return .text(Text(x: asF64(arr[7]), y: asF64(arr[8]),
                              tspans: ts.map { unpackTspan($0) },
                              fontFamily: asStr(arr[10]), fontSize: asF64(arr[11]),
                              fontWeight: asStr(arr[12]), fontStyle: asStr(arr[13]),
                              textDecoration: asStr(arr[14]),
                              width: asF64(arr[15]), height: asF64(arr[16]),
                              fill: unpackFill(arr[17]), stroke: unpackStroke(arr[18]),
                              opacity: opacity, transform: xform, locked: locked, visibility: vis,
                              name: name, id: id))
        }
        return .text(Text(x: asF64(arr[7]), y: asF64(arr[8]), content: asStr(arr[9]),
                          fontFamily: asStr(arr[10]), fontSize: asF64(arr[11]),
                          fontWeight: asStr(arr[12]), fontStyle: asStr(arr[13]),
                          textDecoration: asStr(arr[14]),
                          width: asF64(arr[15]), height: asF64(arr[16]),
                          fill: unpackFill(arr[17]), stroke: unpackStroke(arr[18]),
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          name: name, id: id))
    case tagTextPath:
        let cmds = asArray(arr[7]).map { unpackPathCommand($0) }
        if arr.count > 17, case .array(let ts) = arr[17], !ts.isEmpty {
            return .textPath(TextPath(d: cmds, tspans: ts.map { unpackTspan($0) },
                                      startOffset: asF64(arr[9]),
                                      fontFamily: asStr(arr[10]), fontSize: asF64(arr[11]),
                                      fontWeight: asStr(arr[12]), fontStyle: asStr(arr[13]),
                                      textDecoration: asStr(arr[14]),
                                      fill: unpackFill(arr[15]), stroke: unpackStroke(arr[16]),
                                      opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                      name: name, id: id))
        }
        return .textPath(TextPath(d: cmds, content: asStr(arr[8]), startOffset: asF64(arr[9]),
                                  fontFamily: asStr(arr[10]), fontSize: asF64(arr[11]),
                                  fontWeight: asStr(arr[12]), fontStyle: asStr(arr[13]),
                                  textDecoration: asStr(arr[14]),
                                  fill: unpackFill(arr[15]), stroke: unpackStroke(arr[16]),
                                  opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                  name: name, id: id))
    case tagLive:
        // Live elements (REFERENCE_GRAPH.md Phase 2b): dispatch on the
        // kind string at index 7, mirroring the test_json live reader.
        let kind = asStr(arr[7])
        switch kind {
        case "compound_shape":
            // Unknown operation strings default to union, matching the
            // Rust / Python readers. CompoundShape carries a stable id but
            // no name slot, so id passes through while name is dropped
            // (paint is nil in Phase 1).
            let operation = CompoundOperation(rawValue: asStr(arr[8])) ?? .union
            let operands = asArray(arr[9]).map { unpackElement($0) }
            return .live(.compoundShape(CompoundShape(
                operation: operation, operands: operands, id: id,
                opacity: opacity, transform: xform,
                locked: locked, visibility: vis)))
        case "reference":
            // ReferenceElem is a first-class element with its own id; it
            // takes the full common block (target at index 8, paint nil).
            let target = ElementRef(asStr(arr[8]))
            // Symbols P4: the instance `transform` rides slot 9, read
            // TOLERANTLY so existing 9-element .bin (no slot 9) decode to nil
            // (SYMBOLS.md §4 / Fork F2).
            let instanceXform = arr.count > 9 ? unpackTransform(arr[9]) : nil
            return .live(.reference(ReferenceElem(
                target: target,
                id: id,
                transform: xform,
                instanceTransform: instanceXform,
                opacity: opacity, locked: locked, visibility: vis)))
        case "recorded":
            // Decode the recipe from the two JSON strings packed at slots 8/9
            // (RECORDED_ELEMENTS.md), mirroring the Rust binary codec.
            let inputsJson = asStr(arr[8])
            let opsJson = asStr(arr[9])
            let inputs = decodeRecordedInputs(inputsJson)
            let ops = decodeRecordedOps(opsJson)
            return .live(.recorded(RecordedElem(
                ops: ops, inputs: inputs, id: id,
                transform: xform, opacity: opacity,
                locked: locked, visibility: vis)))
        case "generated":
            // Decode the concept id + params from slots 8/9 (CONCEPTS.md),
            // mirroring the Rust binary codec.
            let conceptId = asStr(arr[8])
            let paramsJson = asStr(arr[9])
            let params = (try? JSONSerialization.jsonObject(
                with: Data(paramsJson.utf8))) as? [String: Any] ?? [:]
            return .live(.generated(GeneratedElem(
                conceptId: conceptId, params: params, id: id,
                transform: xform, opacity: opacity,
                locked: locked, visibility: vis)))
        default: fatalError("unknown live kind: \(kind)")
        }
    default: fatalError("unknown element tag: \(tag)")
    }
}

/// Decode a recorded element's input ids from the canonical JSON-string slot.
/// Mirrors the Rust `serde_json::from_str` on the inputs slot.
private func decodeRecordedInputs(_ json: String) -> [ElementRef] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        return []
    }
    return arr.compactMap { $0 as? String }.map { ElementRef($0) }
}

/// Decode a recorded element's recipe ops from the canonical JSON-string slot.
/// Each op is {op, params, targets}; params is kept verbatim as [String: Any].
/// Mirrors the Rust `serde_json::from_str` on the ops slot.
private func decodeRecordedOps(_ json: String) -> [PrimitiveOp] {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return arr.map { d in
        PrimitiveOp(
            op: d["op"] as? String ?? "",
            params: d["params"] as? [String: Any] ?? [:],
            targets: (d["targets"] as? [Any] ?? []).compactMap { $0 as? String })
    }
}

private func unpackSelection(_ v: MsgValue) -> Selection {
    let arr = asArray(v)
    var entries = Set<ElementSelection>()
    for item in arr {
        let itemArr = asArray(item)
        let path: ElementPath = asArray(itemArr[0]).map { asInt($0) }
        let kind: SelectionKind
        if case .int(0) = itemArr[1] {
            kind = .all
        } else {
            let kindArr = asArray(itemArr[1])
            let cps = SortedCps(kindArr.dropFirst().map { asInt($0) })
            kind = .partial(cps)
        }
        entries.insert(ElementSelection(path: path, kind: kind))
    }
    return entries
}

private func unpackDocument(_ v: MsgValue) -> Document {
    let arr = asArray(v)
    let layers: [Layer] = asArray(arr[0]).map { elem in
        if case .layer(let l) = unpackElement(elem) { return l }
        fatalError("expected layer element")
    }
    let selectedLayer = asInt(arr[1])
    let selection = unpackSelection(arr[2])
    // Symbols (master store): a trailing element array at index 3. TOLERANT of
    // its absence — existing .bin fixtures predate symbols and decode to an
    // empty store (arr.count <= 3). Present-but-empty arrays decode the same,
    // so empty-symbols docs round-trip unchanged.
    let symbols: [Element]
    if arr.count > 3, case .array(let xs) = arr[3] {
        symbols = xs.map { unpackElement($0) }
    } else {
        symbols = []
    }
    // Binary format predates the artboards feature — parsed docs have
    // empty artboards; the app's load-time repair adds a default at
    // load.
    return dedupeElementIds(Document(
        layers: layers,
        symbols: symbols,
        selectedLayer: selectedLayer,
        selection: selection,
        artboards: []
    ))
}

// MARK: - Public API

/// Serialize a Document to the JAS binary format.
package func documentToBinary(_ doc: Document, compress: Bool = true) -> Data {
    let value = packDocument(doc)
    var raw = [UInt8]()
    encodeValue(value, to: &raw)

    let payload: [UInt8]
    let flags: UInt16
    if compress {
        payload = deflateCompress(raw)
        flags = compressDeflate
    } else {
        payload = raw
        flags = compressNone
    }

    var out = [UInt8]()
    out.reserveCapacity(headerSize + payload.count)
    out.append(contentsOf: magic)
    out.append(UInt8(version & 0xFF))
    out.append(UInt8((version >> 8) & 0xFF))
    out.append(UInt8(flags & 0xFF))
    out.append(UInt8((flags >> 8) & 0xFF))
    out.append(contentsOf: payload)
    return Data(out)
}

/// Deserialize a Document from the JAS binary format.
package func binaryToDocument(_ data: Data) throws -> Document {
    let bytes = [UInt8](data)
    guard bytes.count >= headerSize else {
        throw BinaryError.truncated
    }

    guard bytes[0] == magic[0] && bytes[1] == magic[1] &&
          bytes[2] == magic[2] && bytes[3] == magic[3] else {
        throw BinaryError.invalidMagic
    }

    let ver = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
    guard ver <= version else {
        throw BinaryError.unsupportedVersion(ver)
    }
    // v1 used a different positional layout (no generic name/id slots);
    // it is a clean break, not forward-readable. See the version comment.
    guard ver >= minVersion else {
        throw BinaryError.unsupportedVersion(ver)
    }

    let flags = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
    let compression = flags & 0x03
    let payloadBytes = Array(bytes[headerSize...])

    let raw: [UInt8]
    switch compression {
    case compressNone:
        raw = payloadBytes
    case compressDeflate:
        raw = try deflateDecompress(payloadBytes)
    default:
        throw BinaryError.unsupportedCompression(compression)
    }

    var reader = MsgReader(data: raw)
    let value = try reader.readValue()
    return unpackDocument(value)
}
