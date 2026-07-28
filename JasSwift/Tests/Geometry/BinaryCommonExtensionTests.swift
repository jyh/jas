import Foundation
import Testing
@testable import JasLib

/// The per-tag trailing common extension (RULED 2026-07-27, see
/// transcripts/EDIT_SEMANTICS_FREEZE.md): `common.mode`, `common.mask` and
/// `common.tool_origin` were dropped by the binary codec in BOTH active
/// ports -- save as binary, reload, gone -- and `strokeBrush` /
/// `strokeBrushOverrides` with them on Path. A round trip speaks to
/// NOTHING, so it must preserve EVERYTHING.
///
/// Twin of the `binary_round_trips_the_*` / `binary_without_the_common_
/// extension_still_loads` / `binary_tolerates_malformed_common_extension_
/// slots` tests in jas_dioxus/src/geometry/binary.rs. The arity the
/// extension is appended at is pinned for both ports at once by
/// test_fixtures/expected/binary_wire.json.

private func extDonutCommands() -> [PathCommand] {
    [.moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .closePath,
     .moveTo(25, 25), .lineTo(75, 25), .lineTo(75, 75), .closePath]
}

/// A Path carrying every field of the extension at a non-default value.
/// Mirrors Rust's `ext_path`.
private func extPath() -> Path {
    Path(d: extDonutCommands(),
         fill: Fill(color: Color(r: 0, g: 0, b: 0)),
         blendMode: .multiply,
         mask: Mask(subtreeElement: .rect(Rect(x: 1, y: 2, width: 3, height: 4,
                                               fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
                    clip: true, invert: true, disabled: false, linked: false,
                    unlinkTransform: Transform(a: 1, b: 0, c: 0, d: 1, e: 9, f: 9)),
         strokeBrush: "basic/calligraphic_5",
         strokeBrushOverrides: "{\"angle\":30}",
         toolOrigin: "blob_brush",
         fillRule: .evenodd)
}

private func extDocWith(_ elem: Element) -> Document {
    Document(layers: [Layer(children: [elem])], selectedLayer: 0)
}

@Test func binaryRoundTripsThePathCommonExtension() throws {
    let before = extPath()
    let back = try binaryToDocument(documentToBinary(extDocWith(.path(before))))
    guard case .path(let after) = back.layers[0].children[0] else {
        Issue.record("expected Path"); return
    }
    #expect(after.blendMode == before.blendMode, "binary dropped common.mode")
    #expect(after.mask == before.mask, "binary dropped common.mask")
    #expect(after.toolOrigin == before.toolOrigin, "binary dropped common.tool_origin")
    #expect(after.strokeBrush == before.strokeBrush, "binary dropped stroke_brush")
    #expect(after.strokeBrushOverrides == before.strokeBrushOverrides,
            "binary dropped stroke_brush_overrides")
    // Field-list-free batteries are structurally blind to geometry, so one
    // GEOMETRY-VALUE assertion rides with the field list.
    #expect(after.d == before.d, "the extension cost the path its geometry")
    #expect(after.fillRule == .evenodd)
}

/// One element per element TAG, each wearing the same mode + mask. Mirrors
/// Rust's `every_tag_elements`. `toolOrigin` is deliberately NOT in this
/// battery: in THIS port's model it exists only on `Path` (Rust carries it
/// on every element's CommonProps), so every other tag packs nil and there
/// is nothing to preserve. That asymmetry is documented in
/// `packCommonExt` and in test_fixtures/expected/binary_wire.json.
private func everyTagElements(mode: BlendMode, mask: Mask?) -> [Element] {
    [
        .line(Line(x1: 0, y1: 0, x2: 1, y2: 1, blendMode: mode, mask: mask)),
        .rect(Rect(x: 0, y: 0, width: 1, height: 2, blendMode: mode, mask: mask)),
        .circle(Circle(cx: 0, cy: 0, r: 1, blendMode: mode, mask: mask)),
        .ellipse(Ellipse(cx: 0, cy: 0, rx: 1, ry: 2, blendMode: mode, mask: mask)),
        .polyline(Polyline(points: [(0, 0), (1, 1)], blendMode: mode, mask: mask)),
        .polygon(Polygon(points: [(0, 0), (1, 1), (2, 0)], blendMode: mode, mask: mask)),
        .path(Path(d: extDonutCommands(), blendMode: mode, mask: mask, fillRule: .nonzero)),
        .text(Text(x: 1, y: 2, content: "hi", blendMode: mode, mask: mask)),
        .textPath(TextPath(d: extDonutCommands(), content: "hi", blendMode: mode, mask: mask)),
        .group(Group(children: [], blendMode: mode, mask: mask)),
        .live(.compoundShape(CompoundShape(operation: .union, operands: [], name: nil,
                                           blendMode: mode, mask: mask))),
        .live(.reference(ReferenceElem(target: ElementRef("m1"), name: nil, blendMode: mode, mask: mask))),
        .live(.recorded(RecordedElem(ops: [], inputs: [], name: nil, blendMode: mode, mask: mask))),
        .live(.generated(GeneratedElem(conceptId: "spiral", params: [:], name: nil,
                                       blendMode: mode, mask: mask))),
    ]
}

@Test func binaryRoundTripsTheCommonExtensionOnEveryTag() throws {
    let mode = BlendMode.hardLight
    let mask = Mask(subtreeElement: .circle(Circle(cx: 1, cy: 2, r: 3,
                                                   fill: Fill(color: Color(r: 0, g: 0, b: 0)))),
                    clip: false, invert: true, disabled: true, linked: false,
                    unlinkTransform: nil)
    for elem in everyTagElements(mode: mode, mask: mask) {
        let label = elementTagLabel(elem)
        let back = try binaryToDocument(documentToBinary(extDocWith(elem), compress: false))
        let after = back.layers[0].children[0]
        #expect(after.blendMode == mode, "\(label) dropped common.mode")
        #expect(after.mask == mask, "\(label) dropped common.mask")
    }
    // The wrapping Layer carries the extension too -- the one tag the loop
    // above cannot reach as a child.
    let doc = Document(layers: [Layer(name: "Layer 1", children: [],
                                      blendMode: mode, mask: mask)],
                       selectedLayer: 0)
    let back = try binaryToDocument(documentToBinary(doc, compress: false))
    #expect(back.layers[0].blendMode == mode, "tagLayer dropped common.mode")
    #expect(back.layers[0].mask == mask, "tagLayer dropped common.mask")
}

/// The complement of `binaryReadsAPreExtensionBlob` (BinaryFillRuleTests,
/// which pins the ABSENT-slot defaults against real old bytes): here every
/// extension slot is SET, so a green defaults test cannot be green merely
/// because the reader ignores the slots. Each sub-field of the mask is read
/// individually, since `Mask ==` alone would not say which one carried.
@Test func binaryReadsBackEveryExtensionSlotItWrote() throws {
    let before = extPath()
    let back = try binaryToDocument(documentToBinary(extDocWith(.path(before)),
                                                    compress: false))
    guard case .path(let after) = back.layers[0].children[0] else {
        Issue.record("expected Path"); return
    }
    #expect(after.blendMode == .multiply)
    #expect(after.toolOrigin == "blob_brush")
    #expect(after.mask?.invert == true)
    #expect(after.mask?.linked == false)
    #expect(after.mask?.unlinkTransform == Transform(a: 1, b: 0, c: 0, d: 1, e: 9, f: 9))
    // The mask's own subtree is a full element and keeps its own fields.
    if case .some(.rect(let r)) = after.mask?.subtreeElement {
        #expect(r.x == 1 && r.y == 2 && r.width == 3 && r.height == 4,
                "the mask subtree lost its geometry")
    } else {
        Issue.record("the mask subtree did not come back as a Rect")
    }
}
