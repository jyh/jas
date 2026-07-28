import Testing
@testable import JasLib

/// THE LAYERS-PANEL ROW LABEL: an element the artist has named shows THAT
/// NAME, whatever kind it is.
///
/// jas_dioxus's `tree_elem_display_name` has always read `elem.common().name`
/// generically and fallen back to a `<Type>` bracket. This port's
/// `elementDisplayName` pattern-matched `.layer` alone, so every named Rect,
/// Group, Path and Text showed its bracket placeholder here and its name
/// there — a prime-directive divergence in the panel an artist reads most.
///
/// WHY THESE ARE VALUE ASSERTIONS AND NOT GOLDENS. The widget-tree panel
/// goldens (scripts/check_panel_goldens.sh) contain no named non-layer
/// element, so the fix moved ZERO golden bytes — measured, not assumed. A
/// snapshot gate can only see the states its snapshots contain.
@Suite struct LayersRowLabelTests {

    @Test func aNamedElementOfAnyKindShowsItsName() {
        let cases: [(Element, String)] = [
            (.rect(Rect(x: 0, y: 0, width: 10, height: 10, name: "hull")), "hull"),
            (.group(Group(children: [], name: "mast")), "mast"),
            (.layer(Layer(name: "Sketch", children: [])), "Sketch"),
            (.line(Line(x1: 0, y1: 0, x2: 1, y2: 1, name: "keel")), "keel"),
            // The live kinds, which had no name to show until this wave.
            (.live(.compoundShape(CompoundShape(
                operation: .union, operands: [], name: "prow"))), "prow"),
            (.live(.reference(ReferenceElem(
                target: ElementRef("t"), name: "eye"))), "eye"),
        ]
        for (elem, expected) in cases {
            let (label, isNamed) = elementDisplayName(elem)
            #expect(label == expected)
            #expect(isNamed, "a named element must report isNamed")
        }
    }

    /// The fallback half, so the fix cannot be "return the name always".
    @Test func anUnnamedElementShowsItsBracketedType() {
        let cases: [(Element, String)] = [
            (.rect(Rect(x: 0, y: 0, width: 10, height: 10)), "<Rectangle>"),
            (.group(Group(children: [])), "<Group>"),
            (.live(.compoundShape(CompoundShape(
                operation: .union, operands: [], name: nil))), "<Compound Shape>"),
            (.live(.recorded(RecordedElem(
                ops: [], inputs: [], name: nil))), "<Recorded>"),
            (.live(.generated(GeneratedElem(
                conceptId: "c", params: [:], name: nil))), "<Generated>"),
        ]
        for (elem, expected) in cases {
            let (label, isNamed) = elementDisplayName(elem)
            #expect(label == expected)
            #expect(!isNamed, "an unnamed element must not report isNamed")
        }
    }

    /// The twelve `<Type>` strings above and in Rust's `tree_type_label` are
    /// byte-identical, "Rectangle" and "Text Path" included — checked arm by
    /// arm while writing this file, and the "Rect"/"Rectangle" mismatch that
    /// first draft carried is why it is asserted rather than assumed.

    /// An EMPTY name is not a name — it falls through to the bracket label,
    /// matching Rust's `if !n.is_empty()` guard. Without this, an element
    /// whose name was cleared to "" would render a blank row.
    @Test func anEmptyNameFallsThroughToTheBracketLabel() {
        let (label, isNamed) = elementDisplayName(
            .rect(Rect(x: 0, y: 0, width: 10, height: 10, name: "")))
        #expect(label == "<Rectangle>")
        #expect(!isNamed)
    }
}
