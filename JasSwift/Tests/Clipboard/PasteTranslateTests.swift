import Testing
import Foundation
@testable import JasLib

/// The PASTE OFFSET, at the helper the paste path actually calls.
///
/// `workspace/actions.yaml` §paste specifies "offset 24 points down and to the
/// right from the original position", against `paste_in_place`'s explicit "no
/// offset". That spec sentence is tier 1 of the adjudication hierarchy — this is
/// not a Rust-vs-Swift consistency call, it is a written requirement one port
/// met and the other did not.
///
/// Cross-language pin: test_fixtures/algorithms/paste_translate.json. These are
/// the in-port twins, and they assert the two halves separately so a partial
/// regression is legible.
@Suite struct PasteTranslateTests {
    private static let dx = 24.0
    private static let dy = 24.0

    private func richRect(_ x: Double, _ y: Double, _ name: String, _ id: String) -> Element {
        .rect(Rect(x: x, y: y, width: 10, height: 10,
                   opacity: 0.5, transform: nil, locked: false,
                   visibility: .outline, blendMode: .multiply,
                   name: name, id: id))
    }

    /// HALF ONE, the live divergence. A pasted compound must MOVE. It did not:
    /// the old helper sent everything that was not a group or a layer to
    /// `moveControlPoints(.all, …)`, whose only live arm is `.reference`, so the
    /// compound came back untouched and the paste landed exactly on top of its
    /// source — invisible, the one outcome the offset exists to prevent.
    @Test func pasteTranslateOffsetsACompoundShapesOperands() {
        let cs = CompoundShape(operation: .union,
                               operands: [richRect(0, 0, "port", "op-back"),
                                          richRect(5, 0, "starboard", "op-front")],
                               id: "cs-1", opacity: 0.25, transform: nil,
                               locked: false, visibility: .outline,
                               blendMode: .multiply)
        let moved = EditClipboard.translateElement(.live(.compoundShape(cs)),
                                                   dx: Self.dx, dy: Self.dy)
        guard case .live(.compoundShape(let out)) = moved else {
            Issue.record("expected a compound shape back, got \(moved)"); return
        }
        // MANDATORY GEOMETRY PAIRING: say where the operands are, by value.
        #expect(out.operands.count == 2)
        guard out.operands.count == 2,
              case .rect(let r0) = out.operands[0],
              case .rect(let r1) = out.operands[1] else {
            Issue.record("expected two rect operands"); return
        }
        #expect(abs(r0.x - 24) < 1e-9 && abs(r0.y - 24) < 1e-9,
                "operand 0 should be at (24, 24), got (\(r0.x), \(r0.y))")
        #expect(abs(r1.x - 29) < 1e-9 && abs(r1.y - 24) < 1e-9,
                "operand 1 should be at (29, 24), got (\(r1.x), \(r1.y))")
        // §3.1: a translation speaks to POSITION only.
        #expect(out.id == "cs-1", "the offset must not touch identity")
        #expect(r0.id == "op-back" && r1.id == "op-front")
        #expect(r0.name == "port" && r1.name == "starboard")
        #expect(out.opacity == 0.25 && out.visibility == .outline
                && out.blendMode == .multiply)
        #expect(r0.width == 10 && r0.height == 10, "the shape did not resize")
    }

    /// HALF TWO, found while fixing half one: the same helper's `.group` arm was
    /// a field-by-field rebuild and dropped seven fields, so pasting a NAMED
    /// group produced an unnamed one — the Swift copy-site omission class
    /// (EDIT_SEMANTICS_FREEZE.md §3.1) landing at a paste.
    @Test func pasteTranslateKeepsAGroupsNameAndMovesItsChild() {
        let g = Group(children: [richRect(3, 7, "inner", "r-inner")],
                      opacity: 0.75, transform: nil, locked: false,
                      visibility: .outline, blendMode: .multiply,
                      name: "mast", id: "g-outer")
        let moved = EditClipboard.translateElement(.group(g), dx: Self.dx, dy: Self.dy)
        guard case .group(let out) = moved else {
            Issue.record("expected a group back, got \(moved)"); return
        }
        #expect(out.name == "mast", "the paste dropped the group's NAME")
        #expect(out.id == "g-outer", "the paste dropped the group's id")
        #expect(out.visibility == .outline, "the paste dropped visibility")
        #expect(out.blendMode == .multiply, "the paste dropped the blend mode")
        #expect(out.opacity == 0.75)
        // MANDATORY GEOMETRY PAIRING: the child really moved.
        guard case .rect(let kid) = out.children.first else {
            Issue.record("expected one rect child"); return
        }
        #expect(abs(kid.x - 27) < 1e-9 && abs(kid.y - 31) < 1e-9,
                "the child should be at (27, 31), got (\(kid.x), \(kid.y))")
        #expect(kid.name == "inner" && kid.id == "r-inner")
    }

    /// THE BOUNDARY the spec's other half needs: `paste_in_place` is "no
    /// offset", so a zero offset must leave the element identical. Green before
    /// and after the fix — it is here so a repair cannot "apply the offset" by
    /// adding one unconditionally.
    @Test func pasteInPlaceMovesNothing() {
        let cs = CompoundShape(operation: .union,
                               operands: [richRect(0, 0, "port", "op-back"),
                                          richRect(5, 0, "starboard", "op-front")],
                               id: "cs-1")
        let same = EditClipboard.translateElement(.live(.compoundShape(cs)), dx: 0, dy: 0)
        guard case .live(.compoundShape(let out)) = same,
              case .rect(let r0) = out.operands[0],
              case .rect(let r1) = out.operands[1] else {
            Issue.record("expected the compound back unchanged"); return
        }
        #expect(r0.x == 0 && r0.y == 0 && r1.x == 5 && r1.y == 0,
                "paste_in_place moved something: (\(r0.x),\(r0.y)) (\(r1.x),\(r1.y))")
        #expect(out.id == "cs-1")
    }
}
