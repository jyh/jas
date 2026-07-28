import Foundation
import Testing
@testable import JasLib

/// A corrupt session file must not brick the app at launch.
///
/// `App/JasApp.swift` calls `restoreSession()` whenever the workspace is
/// empty — every cold launch — and `restoreSession` reads each
/// `~/Library/Application Support/Jas/session/tabN.jasbin` through
/// `binaryToDocument`. That call already sat in a `do`/`catch`, which read as
/// recovery; it was not, because the decoder's failure mode was `fatalError`
/// and `catch` cannot catch a trap. One bad byte aborted the application at
/// launch, every launch, with no in-app way to clear the file.
///
/// The decoder now throws (Tests/Geometry/BinaryMalformedBlobTests.swift), so
/// the recovery is real. These tests pin the SESSION side of it: that the
/// per-tab decode is a value-returning step which yields nil rather than
/// aborting, and that the caller keeps the tabs it could read. Mirrors Rust's
/// `load_session` (jas_dioxus/src/workspace/session.rs), which logs a warning
/// and `continue`s past a tab whose `binary_to_document` returns `Err`.
///
/// These tests deliberately do NOT touch the real session directory — a test
/// that wrote to `~/Library/Application Support/Jas/session` would destroy the
/// developer's open tabs. They drive the decode step directly, which is why it
/// is a named function instead of an inline `try` in the middle of the loop.

private func header(_ version: UInt8 = 2, flags: UInt8 = 0) -> [UInt8] {
    [0x4A, 0x41, 0x53, 0x00, version, 0, flags, 0]
}

@Test func aCorruptSessionBlobYieldsNilInsteadOfAborting() {
    let cases: [(String, Data)] = [
        ("an empty file", Data()),
        ("a truncated header", Data([0x4A, 0x41, 0x53])),
        ("a file that is not ours", Data("<?xml version=\"1.0\"?>".utf8)),
        ("a valid header with no payload", Data(header())),
        ("a valid header with a garbage payload",
         Data(header() + [UInt8](repeating: 0xAB, count: 32))),
        ("a deflate-flagged file with no payload", Data(header(flags: 1))),
        ("a deflate-flagged file with a garbage payload",
         Data(header(flags: 1) + [UInt8](repeating: 0x5A, count: 32))),
        // msgpack that DECODES but is the wrong document shape — the class
        // that used to trap rather than throw.
        ("a payload that is a bare integer", Data(header() + [0x07])),
        ("a payload that is an empty array", Data(header() + [0x90])),
        ("a payload whose layers slot is an int", Data(header() + [0x93, 0x00, 0x00, 0x90])),
        ("a payload whose only layer is a bare tag",
         Data(header() + [0x93, 0x91, 0x91, 0x02, 0x00, 0x90])),
        // A length prefix that cannot be satisfied by the bytes present.
        ("a payload claiming 65535 array elements",
         Data(header() + [0xdc, 0xFF, 0xFF, 0x01])),
        ("a version this build cannot read", Data(header(9) + [0x90])),
    ]
    for (label, blob) in cases {
        // The assertion is that this call RETURNS. A decoder that traps takes
        // the whole test process with it, so a crashed run is the failure.
        let doc = WorkspaceState.sessionDocument(fromBlob: blob)
        #expect(doc == nil, "\(label) should decode to nil, not a document")
    }
}

@Test func aValidSessionBlobStillRestores() throws {
    let rect = Element.rect(Rect(x: 1, y: 2, width: 30, height: 40,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let doc = Document(layers: [Layer(name: "Restored", children: [rect])],
                       selectedLayer: 0)
    let blob = documentToBinary(doc, compress: true)
    let back = try #require(WorkspaceState.sessionDocument(fromBlob: blob))
    #expect(back.layers.count == 1)
    #expect(back.layers[0].name == "Restored")
    #expect(back.layers[0].children.count == 1)
    // The at-least-one-artboard repair runs here, exactly as the Rust
    // `load_session` path calls `ensure_artboards_invariant`: the binary format
    // predates artboards, and a restored tab with none draws no artboard frame.
    #expect(!back.artboards.isEmpty, "the artboard invariant must be repaired on restore")
}

/// Every single-byte corruption of a real session blob must yield either a
/// document or nil — never an abort. This is the vector a real disk fault
/// produces, and the one no hand-written case list would have found.
@Test func everySingleByteCorruptionOfASessionBlobFailsSoft() {
    let rect = Element.rect(Rect(x: 1, y: 2, width: 30, height: 40,
                                 fill: Fill(color: Color(r: 1, g: 0, b: 0))))
    let path = Element.path(Path(d: [.moveTo(0, 0), .lineTo(5, 5), .closePath],
                                 fillRule: .evenodd))
    let doc = Document(layers: [Layer(name: "L", children: [rect, path])],
                       selectedLayer: 0)
    let blob = [UInt8](documentToBinary(doc, compress: false))
    #expect(blob.count > 40)
    var decoded = 0, rejected = 0
    for i in 0..<blob.count {
        for flip in [0x00, 0x01, 0x7f, 0x90, 0xc0, 0xc1, 0xdd, 0xff] as [UInt8] {
            var mutated = blob
            mutated[i] = flip
            if WorkspaceState.sessionDocument(fromBlob: Data(mutated)) == nil {
                rejected += 1
            } else {
                decoded += 1
            }
        }
    }
    // The numbers themselves are not the contract — reaching this line is.
    #expect(decoded + rejected == blob.count * 8)
    #expect(rejected > 0, "no corruption was rejected; the fixture is not being decoded")
}
