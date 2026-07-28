import Foundation
import Testing
@testable import JasLib

/// The Swift twin of jas_dioxus's standing contract
/// `malformed_but_decodable_blob_errors_not_panics`
/// (`jas_dioxus/src/geometry/binary.rs`), extended from the ONE slot
/// `BinaryFillRuleTests` covered to the WHOLE decoder.
///
/// Why this file exists. `Binary.swift` carried a scope comment claiming the
/// module "is consumed only by cross-language fixture tests ... corrupt input
/// is a test bug, not a runtime concern". That was false as shipped:
/// `Canvas/Session.swift` writes `documentToBinary` to
/// `~/Library/Application Support/Jas/session/tabN.jasbin` and reads it back
/// with `binaryToDocument`, and `App/JasApp.swift` calls `restoreSession()`
/// whenever the workspace is empty — i.e. on every cold launch. A `fatalError`
/// in the decoder is therefore an unconditional launch abort with no in-app
/// way to clear the bad file, and `Session.swift`'s `do`/`catch` cannot catch
/// it. Rust has held the opposite contract since #8 because a panic on wasm
/// aborts the module.
///
/// READING A RED RUN. A trap is not a failed expectation: `fatalError` aborts
/// the whole `swift test` process, so a decoder regression shows up as a
/// CRASHED RUN, not as a red check. Set `JAS_TRAP_TRACE=1` in the environment
/// and each vector's label is written to stderr before it is decoded, so the
/// last line before the abort names the vector that trapped.
///
/// NOT TESTED HERE, DELIBERATELY: the 4-byte `0xdd` array-length prefix is
/// exercised only at magnitudes whose unguarded allocation is measured and
/// survivable (see `arrayLengthPrefixIsValidatedAgainstRemainingInput`). The
/// full `0xdd ff ff ff ff` bomb is present as a vector but is only meaningful
/// once the guard exists — with the guard it is rejected by a single
/// comparison before any allocation, and that comparison has no
/// magnitude-dependent branch, so the small vectors prove it.

// MARK: - An independent MessagePack writer
//
// Deliberately NOT `Binary.swift`'s encoder (which is private, and which would
// make this test a statement about the encoder rather than about the decoder).
// This writer can emit things the real encoder never emits: an oversized
// length prefix, a u64 above Int.max, a truncated body.

private indirect enum MP {
    case nul
    case bool(Bool)
    case int(Int)
    /// A msgpack `uint 64` (tag 0xcf) written verbatim — the real encoder
    /// never emits one above `Int.max`, a hostile file can.
    case uint64(UInt64)
    case f64(Double)
    case str(String)
    case arr([MP])
    /// Verbatim bytes, for hand-built malformed prefixes.
    case rawBytes([UInt8])
}

private func mpEncode(_ v: MP, into buf: inout [UInt8]) {
    switch v {
    case .nul: buf.append(0xc0)
    case .bool(let b): buf.append(b ? 0xc3 : 0xc2)
    case .int(let n):
        if n >= 0 && n <= 127 { buf.append(UInt8(n)) }
        else if n >= -32 && n < 0 { buf.append(UInt8(bitPattern: Int8(n))) }
        else {
            buf.append(0xd3)
            let u = UInt64(bitPattern: Int64(n))
            for shift in stride(from: 56, through: 0, by: -8) {
                buf.append(UInt8((u >> shift) & 0xFF))
            }
        }
    case .uint64(let u):
        buf.append(0xcf)
        for shift in stride(from: 56, through: 0, by: -8) {
            buf.append(UInt8((u >> shift) & 0xFF))
        }
    case .f64(let f):
        buf.append(0xcb)
        let bits = f.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            buf.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
    case .str(let s):
        let utf8 = Array(s.utf8)
        if utf8.count <= 31 { buf.append(0xa0 | UInt8(utf8.count)) }
        else { buf.append(0xd9); buf.append(UInt8(utf8.count)) }
        buf.append(contentsOf: utf8)
    case .arr(let items):
        if items.count <= 15 { buf.append(0x90 | UInt8(items.count)) }
        else {
            buf.append(0xdc)
            buf.append(UInt8((items.count >> 8) & 0xFF))
            buf.append(UInt8(items.count & 0xFF))
        }
        for it in items { mpEncode(it, into: &buf) }
    case .rawBytes(let b):
        buf.append(contentsOf: b)
    }
}

/// Wrap a msgpack payload in a valid, current-version, uncompressed header.
/// Mirrors the Rust twin's `frame`.
private func frame(_ payload: MP) -> Data {
    var raw = [UInt8]()
    mpEncode(payload, into: &raw)
    var blob: [UInt8] = [0x4A, 0x41, 0x53, 0x00] // "JAS\0"
    blob += [2, 0]  // version 2, LE
    blob += [0, 0]  // flags: COMPRESS_NONE
    blob += raw
    return Data(blob)
}

// MARK: - Wire constants (private in Binary.swift; restated as literals)

private let tLayer = 0, tLine = 1, tRect = 2, tCircle = 3, tEllipse = 4
private let tPolyline = 5, tPolygon = 6, tPath = 7, tText = 8
private let tTextPath = 9, tGroup = 10, tLive = 11
private let allTags = [tLayer, tLine, tRect, tCircle, tEllipse, tPolyline,
                       tPolygon, tPath, tText, tTextPath, tGroup, tLive]

/// The shared common block at indices 1..6, well-formed.
private let okCommon: [MP] = [.bool(false), .f64(1.0), .int(2), .nul, .nul, .nul]

/// A well-formed Layer element wrapping `children`.
private func layerElem(_ children: [MP]) -> MP {
    .arr([.int(tLayer)] + okCommon + [.arr(children)])
}

/// A document payload whose single layer holds `children`.
private func docWith(_ children: [MP]) -> MP {
    .arr([.arr([layerElem(children)]), .int(0), .arr([])])
}

// MARK: - The assertion

/// Decode `blob` and require an ERROR, not a trap. If the decoder traps the
/// process dies here and this function never returns — that crash IS the red.
private func expectDecodeError(_ label: String, _ blob: Data,
                               sourceLocation: SourceLocation = #_sourceLocation) {
    if ProcessInfo.processInfo.environment["JAS_TRAP_TRACE"] != nil {
        FileHandle.standardError.write(Data("[vector] \(label)\n".utf8))
    }
    #expect(throws: (any Error).self, "\(label) must Err, not trap",
            sourceLocation: sourceLocation) {
        _ = try binaryToDocument(blob)
    }
}

// MARK: - 1. Top-level document shape

@Test func malformedTopLevelDocumentErrorsNotTraps() {
    // Built by append rather than as one literal: a 13-row tuple literal of a
    // recursive enum is what makes the Swift type checker give up.
    var cases: [(String, MP)] = []
    cases.append(("payload is an int, not an array", .int(0)))
    cases.append(("payload is a string", .str("nope")))
    cases.append(("payload is nil", .nul))
    cases.append(("payload is an empty array (no layers slot)", .arr([])))
    cases.append(("payload has only the layers slot", .arr([.arr([])])))
    cases.append(("payload has no selection slot", .arr([.arr([]), .int(0)])))
    // Rust twin case (1): [0] should be an array of elements.
    cases.append(("layers slot is an int", .arr([.int(0), .int(0), .arr([])])))
    cases.append(("layers slot is a string", .arr([.str("x"), .int(0), .arr([])])))
    cases.append(("selectedLayer slot is a string", .arr([.arr([]), .str("x"), .arr([])])))
    cases.append(("selectedLayer slot is nil", .arr([.arr([]), .nul, .arr([])])))
    cases.append(("selection slot is an int", .arr([.arr([]), .int(0), .int(3)])))
    cases.append(("a layer entry is not an array", .arr([.arr([.int(7)]), .int(0), .arr([])])))
    let rectGeom: [MP] = [.f64(0), .f64(0), .f64(1), .f64(1), .f64(0), .f64(0), .nul, .nul]
    let rectSlots: [MP] = [.int(tRect)] + okCommon + rectGeom
    cases.append(("a layer entry is a non-layer element",
                  .arr([.arr([.arr(rectSlots)]), .int(0), .arr([])])))
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 2. The element header: tag + the shared common block

@Test func malformedElementHeaderErrorsNotTraps() {
    // Rust twin case (3): unknown element tag must Err, not panic.
    var cases: [(String, MP)] = [
        ("element array is empty", docWith([.arr([])])),
        ("element tag is a string", docWith([.arr([.str("rect")] + okCommon + [.nul])])),
        ("element tag is nil", docWith([.arr([.nul] + okCommon + [.nul])])),
        ("element tag is an array", docWith([.arr([.arr([])] + okCommon + [.nul])])),
        ("unknown element tag 9999",
         docWith([.arr([.int(9999)] + okCommon + [.nul])])),
        ("unknown element tag -1", docWith([.arr([.int(-1)] + okCommon + [.nul])])),
        // Rust twin case (2): a too-short element array — the bounds-checked
        // read inside unpackCommon, where a raw arr[3] panicked.
        ("element carries only its tag", docWith([.arr([.int(tRect)])])),
        ("element is missing the id slot",
         docWith([.arr([.int(tRect), .bool(false), .f64(1), .int(2), .nul, .nul])])),
        ("locked slot is a string",
         docWith([.arr([.int(tLayer), .str("x"), .f64(1), .int(2), .nul, .nul, .nul, .arr([])])])),
        ("opacity slot is a bool",
         docWith([.arr([.int(tLayer), .bool(false), .bool(true), .int(2), .nul, .nul, .nul, .arr([])])])),
        ("visibility slot is a string",
         docWith([.arr([.int(tLayer), .bool(false), .f64(1), .str("x"), .nul, .nul, .nul, .arr([])])])),
        ("name slot is an int",
         docWith([.arr([.int(tLayer), .bool(false), .f64(1), .int(2), .nul, .int(5), .nul, .arr([])])])),
        ("id slot is an array",
         docWith([.arr([.int(tLayer), .bool(false), .f64(1), .int(2), .nul, .nul, .arr([]), .arr([])])])),
        ("transform slot is a 3-long array",
         docWith([.arr([.int(tLayer), .bool(false), .f64(1), .int(2),
                        .arr([.f64(1), .f64(0), .f64(0)]), .nul, .nul, .arr([])])])),
        ("transform slot is a string",
         docWith([.arr([.int(tLayer), .bool(false), .f64(1), .int(2), .str("x"), .nul, .nul, .arr([])])])),
    ]
    // EVERY tag, truncated right after the common block: the payload the tag
    // needs at index 7 and beyond is simply absent. A raw arr[7] panicked for
    // every one of them.
    for tag in allTags {
        cases.append(("tag \(tag) with no payload past the common block",
                      docWith([.arr([.int(tag)] + okCommon)])))
    }
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 3. Nested geometry: color, fill, stroke, transform, commands, points

@Test func malformedNestedGeometryErrorsNotTraps() {
    func rectWith(_ payload: [MP]) -> MP { docWith([.arr([.int(tRect)] + okCommon + payload)]) }
    let rectGeom: [MP] = [.f64(0), .f64(0), .f64(10), .f64(10), .f64(0), .f64(0)]
    func pathWith(_ payload: [MP]) -> MP { docWith([.arr([.int(tPath)] + okCommon + payload)]) }

    let cases: [(String, MP)] = [
        ("fill slot is an int", rectWith(rectGeom + [.int(3), .nul])),
        ("fill array is empty", rectWith(rectGeom + [.arr([]), .nul])),
        ("fill array has no opacity", rectWith(rectGeom + [.arr([.arr([.int(0), .f64(0), .f64(0), .f64(0), .f64(0), .f64(1)])]), .nul])),
        ("color slot is a string", rectWith(rectGeom + [.arr([.str("black"), .f64(1)]), .nul])),
        ("color array is empty", rectWith(rectGeom + [.arr([.arr([]), .f64(1)]), .nul])),
        ("color array is too short", rectWith(rectGeom + [.arr([.arr([.int(0), .f64(0)]), .f64(1)]), .nul])),
        ("unknown color space tag", rectWith(rectGeom + [.arr([.arr([.int(99), .f64(0), .f64(0), .f64(0), .f64(0), .f64(1)]), .f64(1)]), .nul])),
        ("color channel is a string", rectWith(rectGeom + [.arr([.arr([.int(0), .str("r"), .f64(0), .f64(0), .f64(0), .f64(1)]), .f64(1)]), .nul])),
        ("stroke slot is a bool", rectWith(rectGeom + [.nul, .bool(true)])),
        ("stroke array is empty", rectWith(rectGeom + [.nul, .arr([])])),
        ("stroke array stops before opacity",
         rectWith(rectGeom + [.nul, .arr([.arr([.int(0), .f64(0), .f64(0), .f64(0), .f64(0), .f64(1)]),
                                          .f64(1), .int(0), .int(0)])])),
        ("stroke extended block stops mid-way",
         rectWith(rectGeom + [.nul, .arr([.arr([.int(0), .f64(0), .f64(0), .f64(0), .f64(0), .f64(1)]),
                                          .f64(1), .int(0), .int(0), .f64(1), .f64(4), .int(0)])])),
        ("stroke dash slot is a string",
         rectWith(rectGeom + [.nul, .arr([.arr([.int(0), .f64(0), .f64(0), .f64(0), .f64(0), .f64(1)]),
                                          .f64(1), .int(0), .int(0), .f64(1), .f64(4), .int(0),
                                          .str("dashes"), .str("none"), .str("none"),
                                          .f64(1), .f64(1), .int(0)])])),
        ("path d slot is an int", pathWith([.int(1), .nul, .nul])),
        ("a path command is not an array", pathWith([.arr([.int(3)]), .nul, .nul])),
        ("a path command array is empty", pathWith([.arr([.arr([])]), .nul, .nul])),
        ("unknown path command tag", pathWith([.arr([.arr([.int(42), .f64(0), .f64(0)])]), .nul, .nul])),
        ("path command tag is a string", pathWith([.arr([.arr([.str("M"), .f64(0), .f64(0)])]), .nul, .nul])),
        ("moveTo is missing its y", pathWith([.arr([.arr([.int(0), .f64(0)])]), .nul, .nul])),
        ("curveTo is missing three coords",
         pathWith([.arr([.arr([.int(2), .f64(0), .f64(0), .f64(1)])]), .nul, .nul])),
        ("arcTo is missing its endpoint",
         pathWith([.arr([.arr([.int(6), .f64(1), .f64(1), .f64(0), .bool(false), .bool(true)])]), .nul, .nul])),
        ("arcTo flag is a float", pathWith([.arr([.arr([.int(6), .f64(1), .f64(1), .f64(0), .f64(0), .f64(1), .f64(2), .f64(3)])]), .nul, .nul])),
        ("widthPoints slot is a string", pathWith([.arr([]), .nul, .nul, .str("x")])),
        ("a widthPoint is not an array", pathWith([.arr([]), .nul, .nul, .arr([.f64(1)])])),
        ("a widthPoint is too short", pathWith([.arr([]), .nul, .nul, .arr([.arr([.f64(0), .f64(1)])])])),
        ("polyline points slot is an int",
         docWith([.arr([.int(tPolyline)] + okCommon + [.int(2), .nul, .nul])])),
        ("a polyline point is not an array",
         docWith([.arr([.int(tPolyline)] + okCommon + [.arr([.f64(1)]), .nul, .nul])])),
        ("a polyline point is too short",
         docWith([.arr([.int(tPolyline)] + okCommon + [.arr([.arr([.f64(1)])]), .nul, .nul])])),
        ("a polygon point is too short",
         docWith([.arr([.int(tPolygon)] + okCommon + [.arr([.arr([])]), .nul, .nul])])),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 4. Live elements

@Test func malformedLiveElementErrorsNotTraps() {
    func liveWith(_ payload: [MP]) -> MP { docWith([.arr([.int(tLive)] + okCommon + payload)]) }
    let cases: [(String, MP)] = [
        ("live kind slot is an int", liveWith([.int(0), .nul, .nul])),
        ("live kind slot is nil", liveWith([.nul, .nul, .nul])),
        ("unknown live kind string", liveWith([.str("teleporter"), .nul, .nul])),
        ("compound_shape with no operation slot", liveWith([.str("compound_shape")])),
        ("compound_shape operation is an int", liveWith([.str("compound_shape"), .int(0), .arr([])])),
        ("compound_shape operands slot is a string", liveWith([.str("compound_shape"), .str("union"), .str("x")])),
        ("compound_shape operand is malformed",
         liveWith([.str("compound_shape"), .str("union"), .arr([.arr([.int(tRect)])])])),
        ("reference target is an int", liveWith([.str("reference"), .int(1), .nul])),
        ("reference has no target slot", liveWith([.str("reference")])),
        ("reference instance transform is too short",
         liveWith([.str("reference"), .str("abc"), .arr([.f64(1), .f64(0)])])),
        ("recorded inputs slot is an array", liveWith([.str("recorded"), .arr([]), .str("[]")])),
        ("recorded ops slot is nil", liveWith([.str("recorded"), .str("[]"), .nul])),
        ("generated concept id is a float", liveWith([.str("generated"), .f64(1), .str("{}")])),
        ("generated params slot is a bool", liveWith([.str("generated"), .str("c"), .bool(true)])),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 5. The mask slot — the audit's named vector
//
// `unpackCommonExt` reads the mask at the tag's trailing edge and
// `unpackMask` recurses into `unpackElement` on the subtree. A too-short
// subtree array reached index-out-of-range INSIDE `unpackCommon`, one level
// down from the slot that was already documented as tolerant.

@Test func malformedMaskSubtreeErrorsNotTraps() {
    // tagRect base arity is 15: [tag] + common(6) + payload(8) = 15 slots,
    // then ext = [mode, mask, toolOrigin].
    func rectWithExt(_ ext: [MP]) -> MP {
        docWith([.arr([.int(tRect)] + okCommon +
                      [.f64(0), .f64(0), .f64(10), .f64(10), .f64(0), .f64(0), .nul, .nul] + ext)])
    }
    let cases: [(String, MP)] = [
        ("mask subtree carries only its tag",
         rectWithExt([.int(0), .arr([.arr([.int(tRect)])]), .nul])),
        ("mask subtree has an unknown tag",
         rectWithExt([.int(0), .arr([.arr([.int(9999)] + okCommon + [.nul])]), .nul])),
        ("mask subtree has a bad common block",
         rectWithExt([.int(0), .arr([.arr([.int(tLayer), .str("x"), .f64(1), .int(2), .nul, .nul, .nul, .arr([])])]), .nul])),
        ("mask subtree geometry is malformed",
         rectWithExt([.int(0), .arr([.arr([.int(tCircle)] + okCommon + [.str("cx")])]), .nul])),
        ("nested mask subtree is malformed",
         rectWithExt([.int(0), .arr([.arr([.int(tRect)] + okCommon +
                                          [.f64(0), .f64(0), .f64(1), .f64(1), .f64(0), .f64(0), .nul, .nul,
                                           .int(0), .arr([.arr([.int(tRect)])]), .nul])]), .nul])),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 6. Selection

@Test func malformedSelectionErrorsNotTraps() {
    func docSel(_ sel: MP) -> MP { .arr([.arr([layerElem([])]), .int(0), sel]) }
    let cases: [(String, MP)] = [
        ("selection entry is not an array", docSel(.arr([.int(1)]))),
        ("selection entry is empty", docSel(.arr([.arr([])]))),
        ("selection entry has no kind slot", docSel(.arr([.arr([.arr([.int(0)])])]))),
        ("selection path slot is an int", docSel(.arr([.arr([.int(0), .int(0)])]))),
        ("selection path holds a string", docSel(.arr([.arr([.arr([.str("0")]), .int(0)])]))),
        ("selection kind is a string", docSel(.arr([.arr([.arr([.int(0)]), .str("all")])]))),
        ("selection partial cp is a string",
         docSel(.arr([.arr([.arr([.int(0)]), .arr([.int(1), .str("cp")])])]))),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 7. Tspans

@Test func malformedTspanErrorsNotTraps() {
    // tagText payload: x, y, content, fontFamily, fontSize, fontWeight,
    // fontStyle, textDecoration, width, height, fill, stroke, tspans(19).
    func textWith(_ tspans: MP) -> MP {
        docWith([.arr([.int(tText)] + okCommon +
                      [.f64(0), .f64(0), .str(""), .str("Helvetica"), .f64(12),
                       .str("normal"), .str("normal"), .str("none"),
                       .f64(10), .f64(10), .nul, .nul, tspans])])
    }
    let cases: [(String, MP)] = [
        ("a tspan is not an array", textWith(.arr([.int(3)]))),
        ("a tspan id slot is a string", textWith(.arr([.arr([.str("id"), .str("hi")])]))),
        ("a tspan content slot is an int", textWith(.arr([.arr([.int(1), .int(2)])]))),
        ("a tspan optional-float slot is a bool",
         textWith(.arr([.arr([.int(1), .str("hi"), .bool(true)])]))),
        ("a tspan optional-string slot is a float",
         textWith(.arr([.arr([.int(1), .str("hi"), .nul, .nul, .f64(3)])]))),
        ("a tspan textDecoration member is an int",
         textWith(.arr([.arr([.int(1), .str("hi"), .nul, .nul, .nul, .nul, .nul, .nul, .nul,
                              .nul, .nul, .nul, .nul, .nul, .nul, .nul, .nul,
                              .arr([.int(7)])])]))),
        ("a tspan transform member is a string",
         textWith(.arr([.arr([.int(1), .str("hi"), .nul, .nul, .nul, .nul, .nul, .nul, .nul,
                              .nul, .nul, .nul, .nul, .nul, .nul, .nul, .nul, .nul, .nul, .nul,
                              .arr([.str("a"), .f64(0), .f64(0), .f64(1), .f64(0), .f64(0)])])]))),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 8. Symbols (the trailing document slot)

@Test func malformedSymbolStoreErrorsNotTraps() {
    let cases: [(String, MP)] = [
        ("a symbol entry is not an array",
         .arr([.arr([layerElem([])]), .int(0), .arr([]), .arr([.int(4)])])),
        ("a symbol entry carries only its tag",
         .arr([.arr([layerElem([])]), .int(0), .arr([]), .arr([.arr([.int(tRect)])])])),
        ("a symbol entry has an unknown tag",
         .arr([.arr([layerElem([])]), .int(0), .arr([]), .arr([.arr([.int(9999)] + okCommon + [.nul])])])),
    ]
    for (label, payload) in cases { expectDecodeError(label, frame(payload)) }
}

// MARK: - 9. Integers outside Int's range
//
// `readValue` mapped msgpack `uint 64` (tag 0xcf) with `Int(_:)`, which is a
// PRECONDITION FAILURE above `Int.max` — measured directly:
// `Int(UInt64(0xFFFF_FFFF_FFFF_FFFF))` aborts with "Not enough bits to
// represent the passed value". Rust's rmpv keeps the u64 and `as_i64`
// converts with `as`, which WRAPS. The blob need not even be hostile: any
// port that writes a large unsigned id produces one.

@Test func oversizedUnsignedIntegersWrapInsteadOfTrapping() throws {
    // An element tag that wraps to -1 is not a known tag, so it is REJECTED —
    // the same outcome the plain `9999` tag gets, reached through the wrap.
    expectDecodeError("an element tag is u64 max",
                      frame(docWith([.arr([.uint64(UInt64.max)] + okCommon + [.nul])])))

    // The other two slots ACCEPT the wrapped value rather than erroring,
    // exactly as Rust does: rmpv keeps the u64 and `as_i64().or_else(as_u64)`
    // converts with `as`, which wraps. Pinned as values so a future change to
    // clamping-instead-of-wrapping is a visible divergence, not a silent one.
    let sel = try binaryToDocument(frame(.arr([.arr([]), .uint64(UInt64.max), .arr([])])))
    #expect(sel.selectedLayer == -1, "u64 max in the selectedLayer slot must wrap, as Rust's `as` does")

    let sel2 = try binaryToDocument(frame(.arr([.arr([]), .uint64(UInt64(Int.max) + 1), .arr([])])))
    #expect(sel2.selectedLayer == Int.min, "Int.max + 1 must wrap to Int.min")

    // A visibility tag outside 0/1 falls to the documented default.
    let vis = try binaryToDocument(frame(docWith([
        .arr([.int(tLayer), .bool(false), .f64(1), .uint64(UInt64.max),
              .nul, .nul, .nul, .arr([])])])))
    #expect(vis.layers[0].children.count == 1)
    guard case .layer(let inner) = vis.layers[0].children[0] else {
        Issue.record("expected a nested layer"); return
    }
    #expect(inner.visibility == .preview, "an out-of-range visibility tag reads as .preview")
}

// MARK: - 10. Length prefixes must be validated against remaining input
//
// `MsgReader.readArray` called `reserveCapacity(count)` with a count taken
// straight from the wire — up to 2^32-1 from a `0xdd` prefix — BEFORE reading
// a single element. Every msgpack value costs at least one byte, so an array
// of N elements needs at least N bytes of input; a count above the remaining
// byte count is unsatisfiable and must be rejected before any allocation.
//
// SAFETY OF THIS TEST: the magnitudes below are chosen so that an UNGUARDED
// decoder merely reserves a few megabytes and then throws `.truncated` — the
// red run is survivable and was measured. The full `0xdd ff ff ff ff` vector
// is the last case and is only reached once the guard exists; the guard is a
// single `count > remaining` comparison with no magnitude-dependent branch, so
// the small magnitudes are what actually prove it.

@Test func arrayLengthPrefixIsValidatedAgainstRemainingInput() {
    // 0xdc = array16. Claims 65535 elements; 3 bytes of body follow.
    let arr16Bomb: [UInt8] = [0xdc, 0xFF, 0xFF, 0x01, 0x02, 0x03]
    // 0xdd = array32. Claims 1,048,576 elements; 3 bytes of body follow.
    let arr32Small: [UInt8] = [0xdd, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x03]
    // The real bomb: 2^32-1 elements, 3 bytes of body.
    let arr32Bomb: [UInt8] = [0xdd, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x02, 0x03]

    for (label, body) in [("array16 claiming 65535 elements", arr16Bomb),
                          ("array32 claiming 1M elements", arr32Small),
                          ("BOMB-array32 claiming 2^32-1 elements", arr32Bomb)] {
        if ProcessInfo.processInfo.environment["JAS_TRAP_TRACE"] != nil {
            FileHandle.standardError.write(Data("[vector] \(label)\n".utf8))
        }
        // Hazard opt-out, for deliberately running this test against a decoder
        // whose length guard has been removed (a mutation proof). WITHOUT the
        // guard the BOMB row reserves ~2^32 msgpack values before it reads a
        // byte; with it, the row is rejected by one comparison. Set
        // JAS_SKIP_BOMB=1 for such a run. Normal runs must NOT set it.
        if label.hasPrefix("BOMB-"),
           ProcessInfo.processInfo.environment["JAS_SKIP_BOMB"] != nil { continue }
        let blob = frame(.rawBytes(body))
        var thrown: (any Error)?
        #expect(throws: (any Error).self, "\(label) must Err, not allocate") {
            do { _ = try binaryToDocument(blob) } catch { thrown = error; throw error }
        }
        // The specific error matters: `.truncated` would mean the length was
        // ACCEPTED and the allocation already happened. Only the length check
        // reports `invalidData`.
        guard case .some(BinaryError.invalidData(let msg)) = thrown else {
            let got = String(describing: thrown)
            Issue.record(Comment(rawValue: "\(label): expected BinaryError.invalidData from the length check, got \(got) — a `.truncated` here means the count was reserved before it was validated"))
            continue
        }
        #expect(msg.contains("length"), "\(label): \(msg)")
    }

    // A string length prefix was already validated (`pos + len <= data.count`);
    // this pins that it stays validated.
    let strBomb: [UInt8] = [0xdb, 0xFF, 0xFF, 0xFF, 0xFF, 0x41]
    expectDecodeError("str32 claiming 2^32-1 bytes", frame(.rawBytes(strBomb)))
}

// MARK: - 10b. Nesting depth must be bounded
//
// `readValue` recurses once per nested array with no depth limit, so a payload
// of N repeated `0x91` (fixarray of 1) bytes recurses N deep. A ~100 KB file of
// them overflows the stack, which is a SIGSEGV — not catchable, not even by the
// `do`/`catch` in `Session.swift`, and reached on every cold launch.
//
// Rust does not have this hole: rmpv threads a `depth` counter through
// `read_value_inner` and returns `Error::DepthLimitExceeded` past
// `rmpv::decode::MAX_DEPTH == 1024`. Swift uses the SAME limit so the two ports
// accept and reject the same blobs.

/// Run `body` on a thread with an explicitly large stack and return its result.
///
/// Needed because the ceiling can only be OBSERVED by reaching it, and reaching
/// level 1024 costs ~1024 frame pairs. Swift Testing runs each `@Test` on a
/// concurrency cooperative thread whose stack is small — measured here: this
/// decoder survives 250 levels there and dies at 400. The shipping caller is
/// `restoreSession()` from SwiftUI `.onAppear`, i.e. the MAIN thread with an
/// 8 MB stack, which this 16 MB test thread stands in for.
///
/// STATED BLIND SPOT: the ceiling bounds recursion, it does not make the reader
/// constant-stack. A caller that decodes on a small-stack cooperative thread
/// can still overflow BELOW the ceiling. Closing that would take an iterative
/// reader with an explicit work stack; it is not done here, and no claim is
/// made that it is.
private func onBigStack<T>(_ body: @escaping () -> T) -> T {
    var result: T?
    let thread = Thread { result = body() }
    thread.stackSize = 16 << 20
    thread.start()
    while result == nil { usleep(200) }
    return result!
}

@Test func deeplyNestedArraysErrorInsteadOfOverflowingTheStack() {
    let outcomes: [(String, Bool)] = onBigStack {
        var out: [(String, Bool)] = []
        // Past the ceiling: rejected.
        for n in [1_025, 5_000, 100_000] {
            let nested = [UInt8](repeating: 0x91, count: n) + [0xc0]
            let threw = (try? binaryToDocument(frame(.rawBytes(nested)))) == nil
            out.append(("\(n) nested arrays", threw))
        }
        // Inside the ceiling: msgpack parses, then the DOCUMENT shape is wrong,
        // so it still errors — but it is not the depth ceiling that rejects it.
        // The point of the row is that the ceiling did not fire early.
        for n in [500, 1_000] {
            let nested = [UInt8](repeating: 0x91, count: n) + [0xc0]
            var msg = ""
            do { _ = try binaryToDocument(frame(.rawBytes(nested))) }
            catch { msg = "\(error)" }
            out.append(("\(n) nested arrays rejected for depth", msg.contains("nesting deeper")))
        }
        return out
    }
    for (label, threw) in outcomes.prefix(3) {
        #expect(threw, "\(label) must be rejected by the depth ceiling, not overflow the stack")
    }
    for (label, hitCeiling) in outcomes.suffix(2) {
        #expect(!hitCeiling, "\(label): the ceiling fired inside its own limit")
    }
}

/// Real documents nest far below the ceiling, and must be unaffected: a Layer
/// holding a Group holding a Group ... costs only a couple of msgpack levels
/// per step. This pins that the depth ceiling does not reject legitimate art.
///
/// The chain is 10 deep, not 50, for a reason worth stating rather than hiding.
/// `unpackElement` recurses per nested ELEMENT, and its debug frame is large:
/// measured on this toolchain, a swift-testing task (a small-stack concurrency
/// cooperative thread) overflows at 15 nested groups — roughly 34 KB of stack
/// per level. That limit is PRE-EXISTING and unchanged by the throwing
/// conversion: the same probe against the unmodified decoder dies at the same
/// 15. It is a function of the caller's stack, not of the input alone — the
/// shipping caller is the main thread with 8 MB — so it is recorded here as a
/// known bound rather than asserted away. Closing it would take an iterative
/// unpacker; that is not done here.
@Test func aNestedRealDocumentStillRoundTrips() throws {
    var elem = Element.rect(Rect(x: 0, y: 0, width: 1, height: 1))
    for _ in 0..<10 { elem = .group(Group(children: [elem])) }
    let doc = Document(layers: [Layer(name: "deep", children: [elem])], selectedLayer: 0)
    let back = try binaryToDocument(documentToBinary(doc, compress: false))
    var depth = 0
    var cursor = back.layers[0].children[0]
    while case .group(let g) = cursor, let first = g.children.first {
        depth += 1; cursor = first
    }
    #expect(depth == 10, "a 10-deep group chain must survive the codec, got \(depth)")
}

// MARK: - 11. Header and compression framing

@Test func malformedFramingErrorsNotTraps() {
    let cases: [(String, Data)] = [
        ("empty file", Data()),
        ("4 bytes", Data([0x4A, 0x41, 0x53, 0x00])),
        ("7 bytes", Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 0])),
        ("bad magic", Data([0x00, 0x41, 0x53, 0x00, 2, 0, 0, 0, 0x90])),
        ("version 1", Data([0x4A, 0x41, 0x53, 0x00, 1, 0, 0, 0, 0x90])),
        ("version 999", Data([0x4A, 0x41, 0x53, 0x00, 0xE7, 0x03, 0, 0, 0x90])),
        ("compression method 2", Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 2, 0, 0x90])),
        // Deflate flag set with an EMPTY payload: `deflateDecompress` sizes its
        // output buffer at `input.count * 4` = 0 and then takes
        // `baseAddress!` of an empty buffer, which Swift documents as
        // possibly-nil.
        ("deflate flag, empty payload", Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 1, 0])),
        ("deflate flag, one junk byte", Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 1, 0, 0xFF])),
        ("deflate flag, garbage payload",
         Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 1, 0] + [UInt8](repeating: 0xAB, count: 64))),
        ("uncompressed, empty payload", Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 0, 0])),
        ("uncompressed, unsupported msgpack tag 0xc1",
         Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 0, 0, 0xc1])),
        ("uncompressed, invalid utf8 in a fixstr",
         Data([0x4A, 0x41, 0x53, 0x00, 2, 0, 0, 0, 0xa1, 0xFF])),
    ]
    for (label, blob) in cases { expectDecodeError(label, blob) }
}

// MARK: - 12. Every byte prefix of a real blob
//
// The broadest vector in the file and the one that needs no imagination: take
// a real document, truncate it at every length, and require an error at each.
// A decoder that traps on any prefix fails here.

@Test func everyTruncationOfARealBlobErrorsNotTraps() throws {
    let rect = Element.rect(Rect(x: 1, y: 2, width: 3, height: 4,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                                 stroke: Stroke(color: Color(r: 0, g: 0, b: 1), width: 2)))
    let path = Element.path(Path(
        d: [.moveTo(0, 0), .curveTo(x1: 1, y1: 1, x2: 2, y2: 2, x: 3, y: 3), .closePath],
        fill: Fill(color: Color(r: 0, g: 1, b: 0)), fillRule: .nonzero))
    let text = Element.text(Text(x: 5, y: 6, content: "hello"))
    let doc = Document(layers: [Layer(name: "L", children: [rect, path, text])],
                       selectedLayer: 0)
    let full = documentToBinary(doc, compress: false)
    #expect(full.count > 60, "fixture should be a real blob, got \(full.count) bytes")
    // The full blob decodes.
    _ = try binaryToDocument(full)
    // Every proper prefix must Err.
    for n in 0..<full.count {
        expectDecodeError("prefix of length \(n)", full.prefix(n))
    }
    // And every single-byte corruption of the payload must Err or decode —
    // never trap. (Many corruptions are legal msgpack that happens to be the
    // wrong type; those are exactly the vectors that used to trap.)
    for i in 8..<full.count {
        for flip in [0x00, 0x7f, 0xc1, 0xdd, 0xff] as [UInt8] {
            var mutated = [UInt8](full)
            mutated[i] = flip
            if ProcessInfo.processInfo.environment["JAS_TRAP_TRACE"] != nil {
                FileHandle.standardError.write(
                    Data("[vector] byte \(i) := \(flip)\n".utf8))
            }
            _ = try? binaryToDocument(Data(mutated))
        }
    }
}

// MARK: - 13. Tolerance did not become strictness
//
// The conversion to throwing reads must not make the DELIBERATELY tolerant
// slots strict. This is the missing Swift twin of Rust's
// `binary_tolerates_malformed_common_extension_slots` — the Rust file's
// "Twins in JasSwift/.../BinaryCommonExtensionTests.swift" comment named a
// twin that did not exist.

@Test func toleratedExtensionSlotsStayTolerated() throws {
    // A Path with the full extension: base arity 12, then
    // [mode, mask, toolOrigin, strokeBrush, strokeBrushOverrides].
    func pathWithExt(_ ext: [MP]) -> Data {
        frame(docWith([.arr([.int(tPath)] + okCommon +
                            [.arr([.arr([.int(0), .f64(0), .f64(0)]),
                                   .arr([.int(1), .f64(9), .f64(9)])]),
                             .nul, .nul, .nul, .int(1)] + ext)]))
    }
    let junk: [(String, MP)] = [
        ("a string", .str("nope")),
        ("an empty array", .arr([])),
        ("a float", .f64(1.5)),
        ("a bool", .bool(true)),
        ("nil", .nul),
    ]
    for (label, j) in junk {
        for slot in 0..<5 {
            var ext: [MP] = [.int(2), .nul, .nul, .nul, .nul]
            ext[slot] = j
            let doc = try binaryToDocument(pathWithExt(ext))
            guard case .path(let p) = doc.layers[0].children[0] else {
                Issue.record(Comment(rawValue: "expected Path for \(label) at ext slot \(slot)"))
                continue
            }
            // What the Rust twin asserts: it still LOADS, and the element is
            // not a husk — its geometry and its fill rule survived.
            #expect(p.d.count == 2, "\(label) at ext slot \(slot) lost the geometry")
            #expect(p.fillRule == .evenodd, "\(label) at ext slot \(slot) lost the fill rule")
            // Stronger than the Rust twin where the semantics allow it. The
            // three optional-string slots go through `tolerantOptStr`, which
            // ACCEPTS a string — a junk value that happens to be a string is
            // legitimately read as that string, in both ports. So the
            // default-value claim is made for the non-string junk only.
            let isString = { if case .str = j { return true }; return false }()
            if slot == 0 { #expect(p.blendMode == .normal, "\(label) in the mode slot") }
            if slot == 1 { #expect(p.mask == nil, "\(label) in the mask slot") }
            if !isString {
                if slot == 2 { #expect(p.toolOrigin == nil, "\(label) in the toolOrigin slot") }
                if slot == 3 { #expect(p.strokeBrush == nil, "\(label) in the strokeBrush slot") }
                if slot == 4 { #expect(p.strokeBrushOverrides == nil, "\(label) in the overrides slot") }
            }
        }
    }
}

/// A blob written before the trailing slots existed must still load — the
/// tolerance that makes trailing-append safe. Twin of Rust's
/// `binary_without_the_common_extension_still_loads`.
@Test func aPreExtensionBlobStillLoads() throws {
    // tagPath with exactly its base arity (12 slots): no extension at all.
    let blob = frame(docWith([.arr([.int(tPath)] + okCommon +
                                   [.arr([.arr([.int(0), .f64(1), .f64(2)])]),
                                    .nul, .nul, .nul, .int(1)])]))
    let doc = try binaryToDocument(blob)
    guard case .path(let p) = doc.layers[0].children[0] else {
        Issue.record("expected Path"); return
    }
    #expect(p.blendMode == .normal)
    #expect(p.mask == nil)
    #expect(p.toolOrigin == nil)
    #expect(p.strokeBrush == nil)
    #expect(p.strokeBrushOverrides == nil)
    #expect(p.d.count == 1, "the pre-extension blob lost its geometry")
    #expect(p.fillRule == .evenodd, "the pre-extension blob lost its fill rule")
}

// MARK: - 14. A real round trip still works
//
// The whole point of the conversion is that VALID input is unaffected.

@Test func aValidBlobStillRoundTripsAfterTheConversion() throws {
    let rect = Element.rect(Rect(x: 1, y: 2, width: 3, height: 4,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let circle = Element.circle(Circle(cx: 5, cy: 6, r: 7,
                                       stroke: Stroke(color: Color(r: 0, g: 1, b: 0), width: 3)))
    let poly = Element.polyline(Polyline(points: [(0, 0), (1, 1), (2, 4)]))
    let path = Element.path(Path(
        d: [.moveTo(0, 0), .arcTo(rx: 1, ry: 2, rotation: 30,
                                  largeArc: true, sweep: false, x: 9, y: 9)],
        fillRule: .evenodd))
    let text = Element.text(Text(x: 5, y: 6, content: "hello"))
    let doc = Document(layers: [Layer(name: "Layer 1",
                                      children: [rect, circle, poly, path, text])],
                       selectedLayer: 0)
    for compress in [false, true] {
        let back = try binaryToDocument(documentToBinary(doc, compress: compress))
        #expect(back.layers.count == 1)
        #expect(back.layers[0].name == "Layer 1")
        #expect(back.layers[0].children.count == 5)
        guard case .path(let p) = back.layers[0].children[3] else {
            Issue.record("expected Path at index 3"); continue
        }
        #expect(p.fillRule == .evenodd)
        #expect(p.d.count == 2)
    }
}
