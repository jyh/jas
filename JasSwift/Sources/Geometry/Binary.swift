/// Binary document serialization using MessagePack + deflate.
///
/// Format:
///     [Magic 4B "JAS\0"] [Version u16 LE] [Flags u16 LE] [Payload]
///
/// Flags bits 0-1: compression method (0=none, 1=raw deflate).
/// Payload: MessagePack-encoded document using positional arrays.
///
/// Scope: this module is on the SHIPPING LAUNCH PATH, not just in tests.
/// `Canvas/Session.swift` writes `documentToBinary` output to
/// `~/Library/Application Support/Jas/session/tabN.jasbin` on quit and reads
/// it back with `binaryToDocument`, and `App/JasApp.swift` calls
/// `restoreSession()` whenever the workspace is empty — i.e. on every cold
/// launch. (An earlier version of this comment claimed the module was
/// "consumed only by cross-language fixture tests ... corrupt input is a test
/// bug, not a runtime concern". That was false as shipped, and the
/// `fatalError` decode path it licensed meant one bad byte on disk aborted
/// the application at launch, every launch, uncatchably.)
///
/// Therefore: the DECODE path returns errors, never traps. Every read of a
/// wire value goes through a throwing helper (`asInt`/`asF64`/`asBool`/
/// `asStr`/`asArray`) or a deliberately tolerant one (`unpackFillRule`,
/// `blendModeFromTag`, `tolerantOptStr`, `unpackMask`), and every positional
/// read goes through the bounds-checked `at`. This mirrors jas_dioxus, whose
/// standing contract `malformed_but_decodable_blob_errors_not_panics` says
/// the same thing for the same reason (on wasm a panic aborts the module and
/// `save_session` reads from localStorage on every startup). The whole-decoder
/// gate is Tests/Geometry/BinaryMalformedBlobTests.swift.
///
/// The ENCODE path still uses `fatalError` in two places, deliberately: both
/// are programmer-error invariants over data this process just built, not
/// statements about untrusted input. They are marked at their sites.

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

/// Every tag `unpackElement` knows how to read. Checked before ANY positional
/// read, so an unknown tag from a corrupt file is an error rather than a
/// bounds-checked walk through slots that mean nothing. Adding a tag means
/// adding it here, to `tagBaseArity`, and to `unpackElement`'s switch — the
/// last of which then errors rather than trapping if the other two are missed.
private let knownTags: Set<Int> = [
    tagLayer, tagLine, tagRect, tagCircle, tagEllipse, tagPolyline,
    tagPolygon, tagPath, tagText, tagTextPath, tagGroup, tagLive,
]

// Fill-rule tags. TAG_PATH slot 11 (see packElement / unpackElement).
// Trailing-append, like widthPoints (slot 10) before it: a blob written
// before this slot existed simply has 11 slots and reads as .nonzero, so
// nothing on disk is orphaned and the header stays at v2 — a version bump
// would make the frozen reference reader (which rejects version > 2)
// unable to read anything we write. jas_dioxus pins the identical slot
// and tag values so the two ports stay byte-identical.
private let fillRuleNonZero: Int = 0
private let fillRuleEvenOdd: Int = 1

// MARK: - The per-tag trailing common extension
//
// RULED 2026-07-27 (transcripts/EDIT_SEMANTICS_FREEZE.md): `common.mode`,
// `common.mask` and `common.tool_origin` were dropped by this codec in BOTH
// active ports -- save as binary, reload, and they were gone -- and
// `stroke_brush` / `stroke_brush_overrides` with them on Path. A round trip
// speaks to NOTHING, so under the preservation law it must preserve
// EVERYTHING.
//
// The SHAPE is forced by the layout: `unpackCommon` reads FIXED indices 1..6
// and every variant's payload starts at index 7, so the shared common block
// cannot be extended once. The three fields it never carried are therefore
// appended PER ELEMENT TAG at the tag's own trailing edge. `version` STAYS AT
// 2: the frozen tag-pinned readers reject `version > 2` and index positionally
// without validating array length, so trailing append keeps them able to read
// what we write -- the same reasoning that settled the fill_rule slot-11
// decision.
//
// jas_dioxus/src/geometry/binary.rs mirrors these offsets, and
// test_fixtures/expected/binary_wire.json pins the resulting arity and BYTES
// for both ports at once.

/// Offset of `common.mode` within a tag's extension block.
private let extMode = 0
/// Offset of `common.mask` within a tag's extension block.
private let extMask = 1
/// Offset of `common.tool_origin` within a tag's extension block.
private let extToolOrigin = 2
/// Slots in the extension block that EVERY tag carries.
private let commonExtLen = 3
/// tagPath only, immediately after the common extension.
private let extStrokeBrush = commonExtLen
private let extStrokeBrushOverrides = commonExtLen + 1
/// tagLayer / tagGroup only, immediately after the common extension. These
/// share their OFFSETS with the two tagPath slots above, which is safe and
/// deliberate: the offset is read only inside the arm for its own tag, and a
/// tag carries either the container pair or the path pair, never both. Written
/// unconditionally for both container tags, so each tag's arity stays constant
/// and the shared wire gate can assert it. Mirrors Rust's EXT_* constants.
private let extIsolatedBlending = commonExtLen
private let extKnockoutGroup = commonExtLen + 1

/// Slots a tag carried BEFORE the extension -- equivalently, the index at
/// which its extension block starts. Mirrors Rust's `tag_base_arity` and is
/// declared as data in test_fixtures/expected/binary_wire.json.
private func tagBaseArity(_ tag: Int) -> Int {
    switch tag {
    case tagLayer: return 8
    case tagGroup: return 8
    case tagLine: return 13
    case tagRect: return 15
    case tagCircle: return 12
    case tagEllipse: return 13
    case tagPolyline: return 10
    case tagPolygon: return 10
    case tagPath: return 12
    case tagText: return 20
    case tagTextPath: return 18
    case tagLive: return 10
    // An unknown tag never reaches here: `unpackElement` rejects it against
    // `knownTags` before the extension is read, and `packElement` is
    // exhaustive. (That rejection is now actually written; before it was, this
    // comment described an intention and an unknown tag DID reach here, with
    // base 0 pointing the extension block at the tag slot.)
    default: return 0
    }
}

/// Blend-mode wire tags, in `BlendMode`'s declaration order. Mirrors Rust's
/// `blend_mode_tag`; an unrecognized tag reads as `.normal`, the value every
/// document written before this slot existed was authored with.
private func blendModeTag(_ m: BlendMode) -> Int {
    switch m {
    case .normal: return 0
    case .darken: return 1
    case .multiply: return 2
    case .colorBurn: return 3
    case .lighten: return 4
    case .screen: return 5
    case .colorDodge: return 6
    case .overlay: return 7
    case .softLight: return 8
    case .hardLight: return 9
    case .difference: return 10
    case .exclusion: return 11
    case .hue: return 12
    case .saturation: return 13
    case .color: return 14
    case .luminosity: return 15
    }
}

/// Deliberately does NOT go through `asInt`, which `fatalError`s on msgpack
/// nil / string / array and truncates a float: Rust's `blend_mode_from_tag`
/// accepts none of those and traps on none of them, and matching it keeps the
/// ports equal AND keeps the standing contract that a
/// malformed-but-decodable blob does not take the app down.
private func blendModeFromTag(_ v: MsgValue?) -> BlendMode {
    guard case .some(.int(let n)) = v else { return .normal }
    switch n {
    case 1: return .darken
    case 2: return .multiply
    case 3: return .colorBurn
    case 4: return .lighten
    case 5: return .screen
    case 6: return .colorDodge
    case 7: return .overlay
    case 8: return .softLight
    case 9: return .hardLight
    case 10: return .difference
    case 11: return .exclusion
    case 12: return .hue
    case 13: return .saturation
    case 14: return .color
    case 15: return .luminosity
    default: return .normal
    }
}

/// A trailing optional-string slot: absent, nil, or anything that is not a
/// string all read as `nil` rather than trapping. Mirrors Rust's
/// `tolerant_opt_str`.
private func tolerantOptStr(_ v: MsgValue?) -> String? {
    guard case .some(.string(let s)) = v else { return nil }
    return s
}

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

/// Maximum msgpack nesting depth. Identical to `rmpv::decode::MAX_DEPTH`, so
/// the two active ports accept and reject exactly the same blobs.
///
/// Without a ceiling, `readValue` recurses once per nested array and a payload
/// of repeated `0x91` bytes overflows the stack — a SIGSEGV, which no `catch`
/// can see and which `Session.swift` meets on every cold launch. Measured: an
/// unbounded reader died at 2,000 levels in a debug test process. Real
/// documents nest a couple of msgpack levels per group, so this ceiling is
/// orders of magnitude above any art (gated by
/// `aDeeplyNestedRealDocumentStillRoundTrips`).
private let maxMsgpackDepth = 1024

private struct MsgReader {
    let data: [UInt8]
    var pos: Int = 0
    /// Remaining nesting budget; decremented on entry to every nested read.
    var depth: Int = maxMsgpackDepth

    mutating func readValue() throws -> MsgValue {
        guard depth > 0 else {
            throw BinaryError.invalidData("msgpack nesting deeper than \(maxMsgpackDepth)")
        }
        depth -= 1
        defer { depth += 1 }
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
        // uint64 above Int.max: WRAP, do not trap. `Int(_:)` is a precondition
        // failure here ("Not enough bits to represent the passed value"), and
        // this tag needs no hostile author — any port that writes a large
        // unsigned value produces it. Rust's rmpv keeps the u64 and `as_i64`
        // converts with `as`, which wraps; `Int(bitPattern:)` is that same
        // reinterpretation. A wrapped value is then rejected by whatever slot
        // it lands in, as an error.
        case 0xcf: return .int(Int(bitPattern: UInt(try readUInt64())))

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
        // Validate the length prefix against the input BEFORE allocating.
        // `count` comes straight off the wire — a `0xdd` prefix carries up to
        // 2^32-1 — and `reserveCapacity` used to run on it unchecked, so an
        // 8-byte file could ask for tens of gigabytes. Every msgpack value
        // costs at least one byte, so an array of N elements needs at least N
        // bytes of remaining input; anything above that is unsatisfiable and
        // can never reject a well-formed blob.
        let remaining = data.count - pos
        guard count >= 0, count <= remaining else {
            throw BinaryError.invalidData(
                "array length \(count) exceeds \(remaining) remaining bytes")
        }
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
        // ENCODE path, deliberately fatal. The arguments are compile-time
        // constants, so the only ways this fails are a zlib version mismatch
        // or an allocation failure — neither is data-dependent and neither is
        // recoverable by a caller. `documentToBinary` is non-throwing on
        // purpose (a session SAVE that silently produced no bytes would be
        // worse than a crash). Nothing here reads untrusted input.
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
    // DECODE path: every exit below is an error, never a trap.
    //
    // An empty payload is a real on-disk case (a file truncated to its 8-byte
    // header with the deflate flag set) and it is handled here rather than
    // inside the buffer dance: with `input.count == 0` the output buffer is
    // also zero-length, and `baseAddress` of an empty buffer is documented as
    // possibly-nil — `baseAddress!` would then trap. It is measured non-nil on
    // the current toolchain, so this is a guard against a documented
    // implementation freedom, not against a live crash.
    guard !input.isEmpty else { throw BinaryError.decompressFailed }
    // zlib takes lengths as UInt32. A payload at or above 4 GiB cannot be fed
    // to it; reject rather than let the conversion trap.
    guard input.count <= Int(UInt32.max) else {
        throw BinaryError.invalidData("compressed payload too large: \(input.count) bytes")
    }

    var stream = z_stream()
    // wbits=-15 for raw deflate
    guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw BinaryError.decompressFailed
    }
    defer { inflateEnd(&stream) }

    var output = [UInt8](repeating: 0, count: input.count * 4)
    var result: Int32 = Z_OK

    try input.withUnsafeBufferPointer { inBuf in
        guard let inBase = inBuf.baseAddress else { throw BinaryError.decompressFailed }
        stream.next_in = UnsafeMutablePointer(mutating: inBase)
        stream.avail_in = UInt32(input.count)

        while result != Z_STREAM_END {
            if stream.avail_out == 0 {
                let oldCount = output.count
                // The doubled buffer must stay addressable by zlib's UInt32
                // lengths. A stream that inflates past 4 GiB is refused rather
                // than allowed to overflow the conversion below.
                guard oldCount <= Int(UInt32.max) / 2 else {
                    throw BinaryError.invalidData(
                        "decompressed payload exceeds \(Int(UInt32.max)) bytes")
                }
                output.append(contentsOf: [UInt8](repeating: 0, count: oldCount))
            }
            try output.withUnsafeMutableBufferPointer { outBuf in
                guard let outBase = outBuf.baseAddress else {
                    throw BinaryError.decompressFailed
                }
                stream.next_out = outBase.advanced(by: Int(stream.total_out))
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

private func asOptF64(_ v: MsgValue) throws -> Double? {
    if case .nil = v { return nil }
    return try asF64(v)
}
private func asOptStr(_ v: MsgValue) throws -> String? {
    if case .nil = v { return nil }
    return try asStr(v)
}
private func asOptBool(_ v: MsgValue) throws -> Bool? {
    if case .nil = v { return nil }
    return try asBool(v)
}

/// Pack a single Tspan as a compact msgpack array. Mirrors Rust's
/// `pack_tspan` — 51 fields in the same order.
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
        // Slots 22..50, appended 2026-07-27. This writer stopped at 22 while
        // Rust's `pack_tspan` wrote 51, so the two ports had never produced the
        // same bytes for any Text or TextPath and this port lost 29 fields on a
        // round trip. Found by the byte-level wire gate
        // (test_fixtures/expected/binary_wire.json). The ORDER below is Rust's,
        // slot for slot -- that is the whole contract.
        optStr(t.jasRole),
        optF64(t.jasLeftIndent),
        optF64(t.jasRightIndent),
        optBool(t.jasHyphenate),
        optBool(t.jasHangingPunctuation),
        optStr(t.jasListStyle),
        optStr(t.textAlign),
        optStr(t.textAlignLast),
        optF64(t.textIndent),
        optF64(t.jasSpaceBefore),
        optF64(t.jasSpaceAfter),
        optF64(t.jasWordSpacingMin),
        optF64(t.jasWordSpacingDesired),
        optF64(t.jasWordSpacingMax),
        optF64(t.jasLetterSpacingMin),
        optF64(t.jasLetterSpacingDesired),
        optF64(t.jasLetterSpacingMax),
        optF64(t.jasGlyphScalingMin),
        optF64(t.jasGlyphScalingDesired),
        optF64(t.jasGlyphScalingMax),
        optF64(t.jasAutoLeading),
        optStr(t.jasSingleWordJustify),
        optF64(t.jasHyphenateMinWord),
        optF64(t.jasHyphenateMinBefore),
        optF64(t.jasHyphenateMinAfter),
        optF64(t.jasHyphenateLimit),
        optF64(t.jasHyphenateZone),
        optF64(t.jasHyphenateBias),
        optBool(t.jasHyphenateCapitalized),
    ])
}

private func unpackTspan(_ v: MsgValue) throws -> Tspan {
    let arr = try asArray(v)
    func get(_ i: Int) -> MsgValue { i < arr.count ? arr[i] : .nil }
    // truncatingIfNeeded mirrors Rust's `as u32`, which WRAPS an out-of-range
    // integer where UInt32(_:) is a precondition failure -- a crafted blob with
    // a negative tspan id crashed only here (risk R9).
    let id = arr.count > 0 ? UInt32(truncatingIfNeeded: try asInt(arr[0])) : 0
    let content = arr.count > 1 ? try asStr(arr[1]) : ""
    let decor: [String]?
    if case .array(let xs) = get(17) {
        decor = try xs.map { try asStr($0) }
    } else {
        decor = nil
    }
    let transform: Transform?
    if case .array(let xs) = get(20), xs.count >= 6 {
        transform = Transform(
            a: try asF64(xs[0]), b: try asF64(xs[1]), c: try asF64(xs[2]),
            d: try asF64(xs[3]), e: try asF64(xs[4]), f: try asF64(xs[5]))
    } else {
        transform = nil
    }
    // NOTE: the argument order below must match `Tspan.init`'s declaration
    // order, not the WIRE order -- Swift enforces the former. The wire order is
    // the `get(n)` indices, which are Rust's slot numbers.
    return try Tspan(
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
        // Slots 22..50 (see packTspan). `get` is already tolerant of a short
        // array, so a pre-2026-07-27 blob -- including every .bin the frozen
        // Python writer produced -- still reads with these fields nil.
        jasRole: asOptStr(get(22)),
        jasLeftIndent: asOptF64(get(23)),
        jasRightIndent: asOptF64(get(24)),
        jasHyphenate: asOptBool(get(25)),
        jasHangingPunctuation: asOptBool(get(26)),
        jasListStyle: asOptStr(get(27)),
        textAlign: asOptStr(get(28)),
        textAlignLast: asOptStr(get(29)),
        textIndent: asOptF64(get(30)),
        jasSpaceBefore: asOptF64(get(31)),
        jasSpaceAfter: asOptF64(get(32)),
        jasWordSpacingMin: asOptF64(get(33)),
        jasWordSpacingDesired: asOptF64(get(34)),
        jasWordSpacingMax: asOptF64(get(35)),
        jasLetterSpacingMin: asOptF64(get(36)),
        jasLetterSpacingDesired: asOptF64(get(37)),
        jasLetterSpacingMax: asOptF64(get(38)),
        jasGlyphScalingMin: asOptF64(get(39)),
        jasGlyphScalingDesired: asOptF64(get(40)),
        jasGlyphScalingMax: asOptF64(get(41)),
        jasAutoLeading: asOptF64(get(42)),
        jasSingleWordJustify: asOptStr(get(43)),
        jasHyphenateMinWord: asOptF64(get(44)),
        jasHyphenateMinBefore: asOptF64(get(45)),
        jasHyphenateMinAfter: asOptF64(get(46)),
        jasHyphenateLimit: asOptF64(get(47)),
        jasHyphenateZone: asOptF64(get(48)),
        jasHyphenateBias: asOptF64(get(49)),
        jasHyphenateCapitalized: asOptBool(get(50)),
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

// The read helpers below THROW rather than trap. See this file's header: the
// decode path runs on every cold launch against a file on disk, so a type
// mismatch is untrusted input, not a programmer error. Each mirrors the
// same-named Rust helper, which returns `Result<_, String>` for the same
// reason.

private func asInt(_ v: MsgValue) throws -> Int {
    guard case .int(let n) = v else {
        // saturatingInt so a non-finite float in this slot cannot take the
        // process down (risk R9). Kept as-is: Rust's `as_i64` REJECTS a float
        // outright, so this is a live tolerance difference between the ports
        // — banked in transcripts/CORPUS_CENSUS.md §7.1 and out of scope here,
        // which is about trapping versus erroring, not about which values are
        // accepted.
        if case .float64(let f) = v { return saturatingInt(f) }
        throw BinaryError.invalidData("expected int, got \(v)")
    }
    return n
}

private func asF64(_ v: MsgValue) throws -> Double {
    switch v {
    case .float64(let f): return f
    case .int(let n): return Double(n)
    default: throw BinaryError.invalidData("expected f64, got \(v)")
    }
}

private func asBool(_ v: MsgValue) throws -> Bool {
    guard case .bool(let b) = v else {
        throw BinaryError.invalidData("expected bool, got \(v)")
    }
    return b
}

private func asStr(_ v: MsgValue) throws -> String {
    guard case .string(let s) = v else {
        throw BinaryError.invalidData("expected string, got \(v)")
    }
    return s
}

private func asArray(_ v: MsgValue) throws -> [MsgValue] {
    guard case .array(let a) = v else {
        throw BinaryError.invalidData("expected array, got \(v)")
    }
    return a
}

/// Bounds-checked positional access, replacing raw `arr[i]` everywhere on the
/// unpack path so a too-short array yields an error instead of an index trap.
/// Mirrors Rust's `at`.
private func at(_ arr: [MsgValue], _ i: Int) throws -> MsgValue {
    guard i >= 0, i < arr.count else {
        throw BinaryError.invalidData("index \(i) out of range (len \(arr.count))")
    }
    return arr[i]
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

/// Pack a fill rule as its wire tag.
private func packFillRule(_ r: FillRule) -> MsgValue {
    vint(r == .evenodd ? fillRuleEvenOdd : fillRuleNonZero)
}

/// Read the fill rule from an optional trailing slot. Only the exact
/// integer tag `fillRuleEvenOdd` yields `.evenodd`; EVERYTHING else reads
/// as the app default `.nonzero` — an absent slot (a pre-fillRule blob,
/// written when nonzero was the only rule), an out-of-range tag, and any
/// wrong-typed payload a corrupt or hostile blob might carry.
///
/// Deliberately does NOT go through `asInt`, which `fatalError`s on
/// msgpack nil / string / array and truncates a float. Rust's
/// `unpack_fill_rule` is `as_i64().or_else(as_u64)` with `_ => NonZero`,
/// so it accepts none of those and traps on none of them; matching it here
/// keeps the ports equal AND keeps jas_dioxus's standing contract that a
/// malformed-but-decodable blob does not take the app down
/// (`malformed_but_decodable_blob_errors_not_panics`).
private func unpackFillRule(_ v: MsgValue?) -> FillRule {
    if case .some(.int(let n)) = v, n == fillRuleEvenOdd { return .evenodd }
    return .nonzero
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

/// Pack an opacity mask: `[subtree, clip, invert, disabled, linked,
/// unlinkTransform]`. The subtree is a full nested element, so a masked
/// element's mask artwork round-trips with all of its own fields. Mirrors
/// Rust's `pack_mask`.
private func packMask(_ m: Mask?) -> MsgValue {
    guard let m = m else { return .nil }
    return .array([packElement(m.subtreeElement),
                   vbool(m.clip), vbool(m.invert), vbool(m.disabled), vbool(m.linked),
                   packTransform(m.unlinkTransform)])
}

/// Inverse of `packMask`, tolerant in the same way `unpackFillRule` is: an
/// absent slot, a nil slot, a slot holding something that is not an array, and
/// an array whose subtree slot is not itself an element array ALL read as "no
/// mask" rather than trapping or guessing. Mirrors Rust's `unpack_mask`.
///
/// The tolerance stops at the SHAPE of this slot. Once the slot does hold an
/// element array, that subtree is decoded like any other element and a
/// malformed one is an error, not a silently-dropped mask — this is exactly
/// where a too-short subtree used to reach an index-out-of-range inside
/// `unpackCommon`, one level below a slot documented as tolerant. Rust's
/// `unpack_mask` returns `Result` for the same reason.
private func unpackMask(_ v: MsgValue?) throws -> Mask? {
    guard case .some(.array(let arr)) = v, let first = arr.first,
          case .array = first else { return nil }
    func b(_ i: Int, _ fallback: Bool) -> Bool {
        guard i < arr.count, case .bool(let x) = arr[i] else { return fallback }
        return x
    }
    let unlink: Transform?
    if arr.count > 5, case .array = arr[5] {
        unlink = try unpackTransform(arr[5])
    } else {
        unlink = nil
    }
    return Mask(subtreeElement: try unpackElement(first),
                clip: b(1, true), invert: b(2, false),
                disabled: b(3, false), linked: b(4, true),
                unlinkTransform: unlink)
}

/// The trailing per-tag extension block: the `CommonProps` fields the fixed
/// 1..6 block cannot hold. Written for EVERY tag, always, so a tag's arity is
/// constant and the shared wire gate can assert it.
///
/// `toolOrigin` lives only on `Path` in THIS port's model (Rust carries it on
/// every element's `CommonProps`), so every other tag packs nil here -- the
/// same shape as `packCommon(name: nil, ...)` for the live variants, which
/// have no `name` field. Documented, not guessed: a Swift element that cannot
/// hold the value cannot lose it either.
private func packCommonExt(_ elem: Element) -> [MsgValue] {
    var toolOrigin: String? = nil
    if case .path(let e) = elem { toolOrigin = e.toolOrigin }
    return [vint(blendModeTag(elem.blendMode)), packMask(elem.mask), optStr(toolOrigin)]
}

private func packElement(_ elem: Element) -> MsgValue {
    guard case .array(var slots) = packElementBase(elem) else {
        // ENCODE path, deliberately fatal. `packElementBase` is an exhaustive
        // switch in which every arm returns `.array(...)`, so this is a
        // compile-time-checkable invariant about code in this file, not a
        // statement about input. Making it an error would put a `try` on every
        // caller for a branch no data can reach.
        fatalError("packElementBase must produce an array")
    }
    // The per-tag trailing common extension (see extMode / extMask /
    // extToolOrigin). Appended here rather than inside each arm so no tag can
    // be forgotten.
    slots += packCommonExt(elem)
    if case .path(let e) = elem {
        // Path-only, immediately after the common extension.
        slots.append(optStr(e.strokeBrush))
        slots.append(optStr(e.strokeBrushOverrides))
    }
    // Container-only, immediately after the common extension. Before this the
    // codec dropped both flags outright: set knockout on a group, save,
    // relaunch, and the setting was gone (coverage gap
    // `container-blend-fields-survive-no-codec`). Appended, VERSION still 2,
    // read tolerantly, exactly as the 2026-07-27 common extension was.
    switch elem {
    case .group, .layer:
        let flags = containerBlendFlags(elem)
        slots.append(vbool(flags.isolatedBlending))
        slots.append(vbool(flags.knockoutGroup))
    default:
        break
    }
    return .array(slots)
}

/// The tag's slots up to `tagBaseArity(tag)` -- everything the format carried
/// before the trailing extension.
private func packElementBase(_ elem: Element) -> MsgValue {
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
        // fillRule rides the trailing slot 11 (always written).
        return .array([vint(tagPath)] + common +
                      [.array(cmds), packFill(e.fill), packStroke(e.stroke),
                       packWidthPoints(e.widthPoints),
                       packFillRule(e.fillRule)])
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
            // A live element's `name` rides the generic common block at slot 5
            // like every other element's — jas_dioxus packs `pack_common(&cs.common)`
            // for all four kinds. This used to hand-write a literal `nil`,
            // which is why a named compound survived a binary save in Rust and
            // not here. An unnamed compound is byte-identical to before.
            let common = packCommon(locked: cs.locked, opacity: cs.opacity,
                                    visibility: cs.visibility, transform: cs.transform,
                                    name: cs.name, id: cs.id)
            // [tag, common(1..6), kind(7), operation(8), operands(9)]
            let operands: [MsgValue] = cs.operands.map { packElement($0) }
            return .array([vint(tagLive)] + common +
                          [vstr("compound_shape"), vstr(cs.operation.rawValue),
                           .array(operands)])
        case .reference(let r):
            let common = packCommon(locked: r.locked, opacity: r.opacity,
                                    visibility: r.visibility, transform: r.transform,
                                    name: r.name, id: r.id)
            // [tag, common(1..6), kind(7), target(8), instance_transform(9)]
            // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
            // (distinct from the render CTM packed at slot 4) rides slot 9 via
            // packTransform; nil when unset. Old 9-element .bin (no slot 9)
            // still decode TOLERANTLY to nil on the read side.
            return .array([vint(tagLive)] + common +
                          [vstr("reference"), vstr(r.target.id),
                           packTransform(r.instanceTransform)])
        case .recorded(let rec):
            let common = packCommon(locked: rec.locked, opacity: rec.opacity,
                                    visibility: rec.visibility, transform: rec.transform,
                                    name: rec.name, id: rec.id)
            // The recipe (inputs + ops) rides slots 8/9 as canonical JSON
            // strings (RECORDED_ELEMENTS.md), mirroring the Rust binary codec.
            // [tag, common(1..6), kind(7), inputs-json(8), ops-json(9)].
            let inputsJson = "[" +
                rec.inputs.map { "\"\($0.id)\"" }.joined(separator: ",") + "]"
            let opsJson = recordedOpsCanonical(rec.ops)
            return .array([vint(tagLive)] + common +
                          [vstr("recorded"), vstr(inputsJson), vstr(opsJson)])
        case .generated(let gen):
            let common = packCommon(locked: gen.locked, opacity: gen.opacity,
                                    visibility: gen.visibility, transform: gen.transform,
                                    name: gen.name, id: gen.id)
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

private func unpackColor(_ v: MsgValue) throws -> Color {
    let arr = try asArray(v)
    let space = try asInt(at(arr, 0))
    switch space {
    case spaceRgb: return .rgb(r: try asF64(at(arr, 1)), g: try asF64(at(arr, 2)),
                               b: try asF64(at(arr, 3)), a: try asF64(at(arr, 5)))
    case spaceHsb: return .hsb(h: try asF64(at(arr, 1)), s: try asF64(at(arr, 2)),
                               b: try asF64(at(arr, 3)), a: try asF64(at(arr, 5)))
    case spaceCmyk: return .cmyk(c: try asF64(at(arr, 1)), m: try asF64(at(arr, 2)),
                                 y: try asF64(at(arr, 3)), k: try asF64(at(arr, 4)),
                                 a: try asF64(at(arr, 5)))
    default: throw BinaryError.invalidData("unknown color space: \(space)")
    }
}

private func unpackFill(_ v: MsgValue) throws -> Fill? {
    if case .nil = v { return nil }
    let arr = try asArray(v)
    return Fill(color: try unpackColor(at(arr, 0)), opacity: try asF64(at(arr, 1)))
}

private func unpackStroke(_ v: MsgValue) throws -> Stroke? {
    if case .nil = v { return nil }
    let arr = try asArray(v)
    let cap: LineCap = switch try asInt(at(arr, 2)) { case 0: .butt; case 1: .round; case 2: .square; default: .butt }
    let join: LineJoin = switch try asInt(at(arr, 3)) { case 0: .miter; case 1: .round; case 2: .bevel; default: .miter }
    // Extended fields (backward compatible: old files have 5 elements)
    if arr.count > 5 {
        let miterLimit = try asF64(at(arr, 5))
        let align: StrokeAlign = switch try asInt(at(arr, 6)) { case 1: .inside; case 2: .outside; default: .center }
        let dashPattern = try asArray(at(arr, 7)).map { try asF64($0) }
        let startArrow = Arrowhead(fromString: try asStr(at(arr, 8)))
        let endArrow = Arrowhead(fromString: try asStr(at(arr, 9)))
        let startArrowScale = try asF64(at(arr, 10))
        let endArrowScale = try asF64(at(arr, 11))
        let arrowAlign: ArrowAlign = switch try asInt(at(arr, 12)) { case 1: .centerAtEnd; default: .tipAtEnd }
        // Element 13: dash_align_anchors (added later — backward
        // compatible with older files that had 13 elements).
        let dashAlignAnchors = arr.count > 13 ? try asBool(arr[13]) : false
        return Stroke(color: try unpackColor(at(arr, 0)), width: try asF64(at(arr, 1)),
                      linecap: cap, linejoin: join,
                      miterLimit: miterLimit, align: align, dashPattern: dashPattern,
                      dashAlignAnchors: dashAlignAnchors,
                      startArrow: startArrow, endArrow: endArrow,
                      startArrowScale: startArrowScale, endArrowScale: endArrowScale,
                      arrowAlign: arrowAlign, opacity: try asF64(at(arr, 4)))
    }
    return Stroke(color: try unpackColor(at(arr, 0)), width: try asF64(at(arr, 1)),
                  linecap: cap, linejoin: join, opacity: try asF64(at(arr, 4)))
}

private func unpackWidthPoints(_ v: MsgValue) throws -> [StrokeWidthPoint] {
    if case .nil = v { return [] }
    return try asArray(v).map { p in
        let a = try asArray(p)
        return StrokeWidthPoint(t: try asF64(at(a, 0)), widthLeft: try asF64(at(a, 1)),
                                widthRight: try asF64(at(a, 2)))
    }
}

private func unpackTransform(_ v: MsgValue) throws -> Transform? {
    if case .nil = v { return nil }
    let arr = try asArray(v)
    return Transform(a: try asF64(at(arr, 0)), b: try asF64(at(arr, 1)), c: try asF64(at(arr, 2)),
                     d: try asF64(at(arr, 3)), e: try asF64(at(arr, 4)), f: try asF64(at(arr, 5)))
}

private func unpackPathCommand(_ v: MsgValue) throws -> PathCommand {
    let arr = try asArray(v)
    let tag = try asInt(at(arr, 0))
    switch tag {
    case cmdMoveTo: return .moveTo(try asF64(at(arr, 1)), try asF64(at(arr, 2)))
    case cmdLineTo: return .lineTo(try asF64(at(arr, 1)), try asF64(at(arr, 2)))
    case cmdCurveTo: return .curveTo(x1: try asF64(at(arr, 1)), y1: try asF64(at(arr, 2)),
                                     x2: try asF64(at(arr, 3)), y2: try asF64(at(arr, 4)),
                                     x: try asF64(at(arr, 5)), y: try asF64(at(arr, 6)))
    case cmdSmoothCurveTo: return .smoothCurveTo(x2: try asF64(at(arr, 1)), y2: try asF64(at(arr, 2)),
                                                 x: try asF64(at(arr, 3)), y: try asF64(at(arr, 4)))
    case cmdQuadTo: return .quadTo(x1: try asF64(at(arr, 1)), y1: try asF64(at(arr, 2)),
                                   x: try asF64(at(arr, 3)), y: try asF64(at(arr, 4)))
    case cmdSmoothQuadTo: return .smoothQuadTo(try asF64(at(arr, 1)), try asF64(at(arr, 2)))
    case cmdArcTo: return .arcTo(rx: try asF64(at(arr, 1)), ry: try asF64(at(arr, 2)),
                                 rotation: try asF64(at(arr, 3)),
                                 largeArc: try asBool(at(arr, 4)), sweep: try asBool(at(arr, 5)),
                                 x: try asF64(at(arr, 6)), y: try asF64(at(arr, 7)))
    case cmdClosePath: return .closePath
    default: throw BinaryError.invalidData("unknown path command tag: \(tag)")
    }
}

/// Inverse of `packCommon`: reads the shared common block at indices
/// 1..6 (locked, opacity, visibility, transform, name, id). The
/// type-specific payload begins at index 7. Mirrors Rust's
/// `unpack_common` / Python's `_unpack_common`.
private func unpackCommon(_ arr: [MsgValue]) throws -> (Bool, Double, Visibility, Transform?, String?, String?) {
    let vis: Visibility = switch try asInt(at(arr, 3)) { case 0: .invisible; case 1: .outline; default: .preview }
    return (try asBool(at(arr, 1)), try asF64(at(arr, 2)), vis, try unpackTransform(at(arr, 4)),
            try asOptStr(at(arr, 5)), try asOptStr(at(arr, 6)))
}

/// Read the tag's TRAILING extension block at `tagBaseArity(tag)`. Read
/// TOLERANTLY -- an absent slot yields the documented default, so a blob
/// written before the extension existed still loads with exactly the values it
/// was authored with. Mirrors the extension half of Rust's `unpack_common`.
private func unpackCommonExt(_ arr: [MsgValue], _ tag: Int) throws -> (BlendMode, Mask?, String?) {
    let base = tagBaseArity(tag)
    func slot(_ off: Int) -> MsgValue? {
        let i = base + off
        return i < arr.count ? arr[i] : nil
    }
    return (blendModeFromTag(slot(extMode)),
            try unpackMask(slot(extMask)),
            tolerantOptStr(slot(extToolOrigin)))
}

/// The two CONTAINER-only extension slots, read TOLERANTLY -- absent, nil or
/// anything that is not a boolean yields `false`, so a blob written before the
/// slots existed still loads with exactly the values it was authored with.
/// Mirrors Rust's `tolerant_bool` reads in the TAG_LAYER / TAG_GROUP arms.
private func containerFlagSlots(_ arr: [MsgValue], _ tag: Int)
    -> (isolatedBlending: Bool, knockoutGroup: Bool) {
    let base = tagBaseArity(tag)
    func flag(_ off: Int) -> Bool {
        let i = base + off
        guard i < arr.count, case .bool(let b) = arr[i] else { return false }
        return b
    }
    return (flag(extIsolatedBlending), flag(extKnockoutGroup))
}

private func unpackElement(_ v: MsgValue) throws -> Element {
    let arr = try asArray(v)
    let tag = try asInt(at(arr, 0))
    // Reject an unknown tag BEFORE reading anything positional. Two reasons:
    // `tagBaseArity` returns 0 for an unknown tag, so `unpackCommonExt` would
    // otherwise read the extension block starting at the tag slot itself and
    // could recurse into `unpackMask` on unrelated data; and `tagBaseArity`'s
    // own comment asserts this rejection happens here, which was not true
    // until it was written down.
    guard knownTags.contains(tag) else {
        throw BinaryError.invalidData("unknown element tag: \(tag)")
    }
    let (locked, opacity, vis, xform, name, id) = try unpackCommon(arr)
    let (mode, mask, toolOrigin) = try unpackCommonExt(arr, tag)
    // Type-specific payload begins at index 7 (after the common block); the
    // trailing extension begins at tagBaseArity(tag).

    switch tag {
    case tagLayer:
        let children = try asArray(at(arr, 7)).map { try unpackElement($0) }
        let (iso, ko) = containerFlagSlots(arr, tagLayer)
        return .layer(Layer(name: name, children: children, opacity: opacity,
                            transform: xform, locked: locked, visibility: vis,
                            blendMode: mode,
                            isolatedBlending: iso, knockoutGroup: ko,
                            mask: mask, id: id))
    case tagGroup:
        let children = try asArray(at(arr, 7)).map { try unpackElement($0) }
        let (iso, ko) = containerFlagSlots(arr, tagGroup)
        return .group(Group(children: children, opacity: opacity,
                            transform: xform, locked: locked, visibility: vis,
                            blendMode: mode,
                            isolatedBlending: iso, knockoutGroup: ko,
                            mask: mask, name: name, id: id))
    case tagLine:
        let wp = arr.count > 12 ? try unpackWidthPoints(arr[12]) : []
        return .line(Line(x1: try asF64(at(arr, 7)), y1: try asF64(at(arr, 8)),
                          x2: try asF64(at(arr, 9)), y2: try asF64(at(arr, 10)),
                          stroke: try unpackStroke(at(arr, 11)), widthPoints: wp,
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          blendMode: mode, mask: mask,
                          name: name, id: id))
    case tagRect:
        return .rect(Rect(x: try asF64(at(arr, 7)), y: try asF64(at(arr, 8)),
                          width: try asF64(at(arr, 9)), height: try asF64(at(arr, 10)),
                          rx: try asF64(at(arr, 11)), ry: try asF64(at(arr, 12)),
                          fill: try unpackFill(at(arr, 13)), stroke: try unpackStroke(at(arr, 14)),
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          blendMode: mode, mask: mask,
                          name: name, id: id))
    case tagCircle:
        return .circle(Circle(cx: try asF64(at(arr, 7)), cy: try asF64(at(arr, 8)),
                              r: try asF64(at(arr, 9)),
                              fill: try unpackFill(at(arr, 10)), stroke: try unpackStroke(at(arr, 11)),
                              opacity: opacity, transform: xform, locked: locked, visibility: vis,
                              blendMode: mode, mask: mask,
                              name: name, id: id))
    case tagEllipse:
        return .ellipse(Ellipse(cx: try asF64(at(arr, 7)), cy: try asF64(at(arr, 8)),
                                rx: try asF64(at(arr, 9)), ry: try asF64(at(arr, 10)),
                                fill: try unpackFill(at(arr, 11)), stroke: try unpackStroke(at(arr, 12)),
                                opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                blendMode: mode, mask: mask,
                                name: name, id: id))
    case tagPolyline:
        let points = try unpackPoints(at(arr, 7))
        return .polyline(Polyline(points: points, fill: try unpackFill(at(arr, 8)),
                                  stroke: try unpackStroke(at(arr, 9)),
                                  opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                  blendMode: mode, mask: mask,
                                  name: name, id: id))
    case tagPolygon:
        let points = try unpackPoints(at(arr, 7))
        return .polygon(Polygon(points: points, fill: try unpackFill(at(arr, 8)),
                                stroke: try unpackStroke(at(arr, 9)),
                                opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                blendMode: mode, mask: mask,
                                name: name, id: id))
    case tagPath:
        let cmds = try asArray(at(arr, 7)).map { try unpackPathCommand($0) }
        let wp = arr.count > 10 ? try unpackWidthPoints(arr[10]) : []
        // Trailing slot 11; absent in pre-fillRule blobs.
        let rule = unpackFillRule(arr.count > 11 ? arr[11] : nil)
        let base = tagBaseArity(tagPath)
        func pathSlot(_ off: Int) -> MsgValue? {
            let i = base + off
            return i < arr.count ? arr[i] : nil
        }
        return .path(Path(d: cmds, fill: try unpackFill(at(arr, 8)),
                          stroke: try unpackStroke(at(arr, 9)),
                          widthPoints: wp,
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          blendMode: mode, mask: mask,
                          strokeBrush: tolerantOptStr(pathSlot(extStrokeBrush)),
                          strokeBrushOverrides: tolerantOptStr(pathSlot(extStrokeBrushOverrides)),
                          toolOrigin: toolOrigin,
                          name: name, id: id, fillRule: rule))
    case tagText:
        // Prefer the trailing tspans field when present; otherwise
        // fall back to the single-default-tspan seeded from content
        // (pre-tspan-codec blobs). Constructed via the tspans-bearing
        // init so the common block (name/id/visibility/transform)
        // survives — `withTspans` does not carry those through.
        if arr.count > 19, case .array(let ts) = arr[19], !ts.isEmpty {
            return .text(Text(x: try asF64(at(arr, 7)), y: try asF64(at(arr, 8)),
                              tspans: try ts.map { try unpackTspan($0) },
                              fontFamily: try asStr(at(arr, 10)), fontSize: try asF64(at(arr, 11)),
                              fontWeight: try asStr(at(arr, 12)), fontStyle: try asStr(at(arr, 13)),
                              textDecoration: try asStr(at(arr, 14)),
                              width: try asF64(at(arr, 15)), height: try asF64(at(arr, 16)),
                              fill: try unpackFill(at(arr, 17)), stroke: try unpackStroke(at(arr, 18)),
                              opacity: opacity, transform: xform, locked: locked, visibility: vis,
                              blendMode: mode, mask: mask,
                              name: name, id: id))
        }
        return .text(Text(x: try asF64(at(arr, 7)), y: try asF64(at(arr, 8)),
                          content: try asStr(at(arr, 9)),
                          fontFamily: try asStr(at(arr, 10)), fontSize: try asF64(at(arr, 11)),
                          fontWeight: try asStr(at(arr, 12)), fontStyle: try asStr(at(arr, 13)),
                          textDecoration: try asStr(at(arr, 14)),
                          width: try asF64(at(arr, 15)), height: try asF64(at(arr, 16)),
                          fill: try unpackFill(at(arr, 17)), stroke: try unpackStroke(at(arr, 18)),
                          opacity: opacity, transform: xform, locked: locked, visibility: vis,
                          blendMode: mode, mask: mask,
                          name: name, id: id))
    case tagTextPath:
        let cmds = try asArray(at(arr, 7)).map { try unpackPathCommand($0) }
        if arr.count > 17, case .array(let ts) = arr[17], !ts.isEmpty {
            return .textPath(TextPath(d: cmds, tspans: try ts.map { try unpackTspan($0) },
                                      startOffset: try asF64(at(arr, 9)),
                                      fontFamily: try asStr(at(arr, 10)), fontSize: try asF64(at(arr, 11)),
                                      fontWeight: try asStr(at(arr, 12)), fontStyle: try asStr(at(arr, 13)),
                                      textDecoration: try asStr(at(arr, 14)),
                                      fill: try unpackFill(at(arr, 15)), stroke: try unpackStroke(at(arr, 16)),
                                      opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                      blendMode: mode, mask: mask,
                                      name: name, id: id))
        }
        return .textPath(TextPath(d: cmds, content: try asStr(at(arr, 8)),
                                  startOffset: try asF64(at(arr, 9)),
                                  fontFamily: try asStr(at(arr, 10)), fontSize: try asF64(at(arr, 11)),
                                  fontWeight: try asStr(at(arr, 12)), fontStyle: try asStr(at(arr, 13)),
                                  textDecoration: try asStr(at(arr, 14)),
                                  fill: try unpackFill(at(arr, 15)), stroke: try unpackStroke(at(arr, 16)),
                                  opacity: opacity, transform: xform, locked: locked, visibility: vis,
                                  blendMode: mode, mask: mask,
                                  name: name, id: id))
    case tagLive:
        // Live elements (REFERENCE_GRAPH.md Phase 2b): dispatch on the
        // kind string at index 7, mirroring the test_json live reader.
        let kind = try asStr(at(arr, 7))
        switch kind {
        case "compound_shape":
            // Unknown operation strings default to union, matching the
            // Rust / Python readers. `name` and `id` both come out of the
            // generic common block (paint is nil in Phase 1); the reader used
            // to drop `name` on the floor because there was nowhere to put it.
            // Reads go through `at(...)` so a short array is an error, not a
            // trap -- the two halves of this line landed in separate waves.
            let operation = CompoundOperation(rawValue: try asStr(at(arr, 8))) ?? .union
            let operands = try asArray(at(arr, 9)).map { try unpackElement($0) }
            return .live(.compoundShape(CompoundShape(
                operation: operation, operands: operands, name: name, id: id,
                opacity: opacity, transform: xform,
                locked: locked, visibility: vis,
                blendMode: mode, mask: mask)))
        case "reference":
            // ReferenceElem is a first-class element with its own id; it
            // takes the full common block (target at index 8, paint nil).
            let target = ElementRef(try asStr(at(arr, 8)))
            // Symbols P4: the instance `transform` rides slot 9, read
            // TOLERANTLY so existing 9-element .bin (no slot 9) decode to nil
            // (SYMBOLS.md §4 / Fork F2).
            let instanceXform = arr.count > 9 ? try unpackTransform(arr[9]) : nil
            return .live(.reference(ReferenceElem(
                target: target,
                name: name,
                id: id,
                transform: xform,
                instanceTransform: instanceXform,
                opacity: opacity, locked: locked, visibility: vis,
                blendMode: mode, mask: mask)))
        case "recorded":
            // Decode the recipe from the two JSON strings packed at slots 8/9
            // (RECORDED_ELEMENTS.md), mirroring the Rust binary codec.
            let inputsJson = try asStr(at(arr, 8))
            let opsJson = try asStr(at(arr, 9))
            let inputs = decodeRecordedInputs(inputsJson)
            let ops = decodeRecordedOps(opsJson)
            return .live(.recorded(RecordedElem(
                ops: ops, inputs: inputs, name: name, id: id,
                transform: xform, opacity: opacity,
                locked: locked, visibility: vis,
                blendMode: mode, mask: mask)))
        case "generated":
            // Decode the concept id + params from slots 8/9 (CONCEPTS.md),
            // mirroring the Rust binary codec.
            let conceptId = try asStr(at(arr, 8))
            let paramsJson = try asStr(at(arr, 9))
            let params = (try? JSONSerialization.jsonObject(
                with: Data(paramsJson.utf8))) as? [String: Any] ?? [:]
            return .live(.generated(GeneratedElem(
                conceptId: conceptId, params: params, name: name, id: id,
                transform: xform, opacity: opacity,
                locked: locked, visibility: vis,
                blendMode: mode, mask: mask)))
        default: throw BinaryError.invalidData("unknown live kind: \(kind)")
        }
    default:
        // Unreachable: `knownTags` was checked at the top. Kept as an error
        // rather than a `fatalError` so a future tag added to `knownTags` but
        // not to this switch cannot become a launch abort.
        throw BinaryError.invalidData("unhandled element tag: \(tag)")
    }
}

/// A polyline/polygon point list: an array of 2-element coordinate arrays.
/// Extracted so the bounds check is written once instead of inline in two
/// nested `map` closures, where `asArray($0)[0]` was an index trap.
private func unpackPoints(_ v: MsgValue) throws -> [(Double, Double)] {
    try asArray(v).map { p in
        let a = try asArray(p)
        return (try asF64(at(a, 0)), try asF64(at(a, 1)))
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

/// DECODE ORDER IS THE STORED ORDER. A codec reads back what was written —
/// it neither reorders nor deduplicates, so a duplicate entry in a file
/// survives the round trip and is visible rather than silently repaired here.
/// Mirrors Rust `unpack_selection`, which collects into the `Vec` directly.
private func unpackSelection(_ v: MsgValue) throws -> Selection {
    let arr = try asArray(v)
    var entries: Selection = []
    for item in arr {
        let itemArr = try asArray(item)
        let path: ElementPath = try asArray(at(itemArr, 0)).map { try asInt($0) }
        let kind: SelectionKind
        if case .int(0) = try at(itemArr, 1) {
            kind = .all
        } else {
            let kindArr = try asArray(at(itemArr, 1))
            let cps = SortedCps(try kindArr.dropFirst().map { try asInt($0) })
            kind = .partial(cps)
        }
        entries.append(ElementSelection(path: path, kind: kind))
    }
    return entries
}

private func unpackDocument(_ v: MsgValue) throws -> Document {
    let arr = try asArray(v)
    let layers: [Layer] = try asArray(at(arr, 0)).map { elem in
        guard case .layer(let l) = try unpackElement(elem) else {
            throw BinaryError.invalidData("expected a layer element at the document root")
        }
        return l
    }
    let selectedLayer = try asInt(at(arr, 1))
    let selection = try unpackSelection(at(arr, 2))
    // Symbols (master store): a trailing element array at index 3. TOLERANT of
    // its absence — existing .bin fixtures predate symbols and decode to an
    // empty store (arr.count <= 3). Present-but-empty arrays decode the same,
    // so empty-symbols docs round-trip unchanged.
    let symbols: [Element]
    if arr.count > 3, case .array(let xs) = arr[3] {
        symbols = try xs.map { try unpackElement($0) }
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

/// The number of msgpack slots `packElement` writes for `elem` -- the arity
/// the per-tag trailing append is defined against. Read by the shared
/// byte-level wire gate (test_fixtures/expected/binary_wire.json), whose whole
/// purpose is that a one-port slot mismatch cannot land silently. Mirrors
/// Rust's `packed_element_slot_count`.
package func packedElementSlotCount(_ elem: Element) -> Int {
    guard case .array(let slots) = packElement(elem) else { return 0 }
    return slots.count
}

/// The wire tag name for an element -- the `tag_arity` keys of
/// test_fixtures/expected/binary_wire.json. Mirrors Rust's
/// `element_tag_label`.
package func elementTagLabel(_ elem: Element) -> String {
    switch elem {
    case .layer: return "layer"
    case .group: return "group"
    case .line: return "line"
    case .rect: return "rect"
    case .circle: return "circle"
    case .ellipse: return "ellipse"
    case .polyline: return "polyline"
    case .polygon: return "polygon"
    case .path: return "path"
    case .text: return "text"
    case .textPath: return "text_path"
    case .live: return "live"
    }
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
    return try unpackDocument(value)
}
