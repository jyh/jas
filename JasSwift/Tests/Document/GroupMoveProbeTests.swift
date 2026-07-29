import Testing
@testable import JasLib

/// PROBE — does a GROUP selected as a single entry move when dragged?
///
/// `Element.moveControlPoints` matches `.line`, `.rect`, `.circle`,
/// `.ellipse`, `.polygon`, `.path`, `.textPath`, `.text` and
/// `.live(.reference)`, then falls to `default: return self`
/// (Geometry/Element.swift:1081). There is no `.group` or `.layer` arm, and
/// `Controller.moveSelection` calls it once per selected path.
///
/// That matters because the Selection tool's click path puts exactly ONE entry in
/// the selection: `workspace/tools/selection.yaml:139` runs
/// `doc.set_selection: { paths: [hit] }`, and `hit_test` returns the GROUP's
/// path when the click lands inside a group's child (the Rust twin asserts
/// this outright — `doc_primitives.rs:248`,
/// `hit_test_returns_group_path_when_clicking_child_rect`).
///
/// The Rust port hides the same missing arm behind `doc.set_selection`, which
/// expands a named container to all its descendants
/// (`interpreter/effects.rs:718`) — so in Rust the CHILDREN are in the
/// selection and each moves itself. Swift does not expand. This probe measures
/// what that difference costs.
@Suite("Group move probe")
struct GroupMoveProbeTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    /// Drag a group that is selected as ONE entry — the shape every
    /// Selection-tool click on a group produces.
    @Test func aGroupSelectedAsOneEntryMovesItsChildren() {
        var d = Document(layers: [Layer(name: "Stage", children: [
            .group(Group(children: [rect(0), rect(20)])),
        ])])
        d = d.replacing(selection: [ElementSelection(path: [0, 0])])
        let model = Model(document: d)

        Controller(model: model).moveSelection(dx: 10, dy: 20)

        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("[0,0] should still be a Group"); return
        }
        guard case .rect(let r0) = g.children[0], case .rect(let r1) = g.children[1] else {
            Issue.record("the group's children should still be Rects"); return
        }
        #expect(r0.x == 10 && r0.y == 20,
                "first child should have moved with the group, is at (\(r0.x), \(r0.y))")
        #expect(r1.x == 30 && r1.y == 20,
                "second child should have moved with the group, is at (\(r1.x), \(r1.y))")
    }

    /// THE INVARIANT: for an `.all` selection, moving IS translating.
    ///
    /// `moveControlPoints` takes a control-point subset; `translated(dx:dy:)`
    /// always means the whole element. When the subset IS the whole element
    /// they must agree, for every kind. They did not: `moveControlPoints` had
    /// no arm for `.group`, `.layer`, the non-reference `.live` kinds, or
    /// `.polyline`, so all of them fell to `default: return self` and did not
    /// move — while `translated` moved them correctly.
    ///
    /// Asserted per KIND rather than per bug, so the next kind added to one
    /// function and forgotten in the other reds here instead of shipping.
    /// `.polyline` is in this list because the Rust twin found it that way,
    /// having been written to fix the containers.
    ///
    /// Twin: `move_all_equals_translate_for_every_kind` in
    /// `jas_dioxus/src/geometry/element.rs`.
    @Test func moveAllEqualsTranslateForEveryKind() {
        let leaf = rect(3)
        let line = Element.line(Line(x1: 0, y1: 0, x2: 5, y2: 5))
        let kinds: [(String, Element)] = [
            ("rect", leaf),
            ("line", line),
            ("polyline", .polyline(Polyline(points: [(0, 0), (1, 2)]))),
            ("group", .group(Group(children: [leaf, line]))),
            ("layer", .layer(Layer(name: "L", children: [leaf]))),
            ("nested group", .group(Group(children: [.group(Group(children: [leaf]))]))),
        ]
        var disagreed: [String] = []
        for (name, elem) in kinds {
            let moved = elem.moveControlPoints(.all, dx: 10, dy: 20)
            let translated = elem.translated(dx: 10, dy: 20)
            if moved != translated {
                disagreed.append(
                    "\(name): moveControlPoints(.all) != translated"
                    + (moved == elem ? " — it did not move AT ALL" : ""))
            }
        }
        let report = disagreed.joined(separator: "; ")
        #expect(disagreed.isEmpty,
                "moving with an .all selection must equal translating: \(report)")
    }
}

/// A CONTAINER'S FULL SELECTION MOVES IT, however that fullness is spelled.
///
/// Twin of Rust `a_container_moves_however_its_full_selection_is_spelled`.
/// DOCUMENT.md grants a Group four bbox-corner control points, so `.all` and
/// `.partial([0,1,2,3])` are both "fully selected". The GROUPMOVE repair
/// guarded on `isAll(total: 0)` and accepted only the first.
@Suite("Container full-selection spellings")
struct ContainerFullSelectionTests {

    private func group() -> Element {
        .group(Group(children: [
            .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
            .rect(Rect(x: 20, y: 0, width: 10, height: 10)),
        ]))
    }

    @Test func bothSpellingsOfFullyySelectedMoveTheGroup() {
        let g = group()
        #expect(g.controlPointCount == 4,
                "DOCUMENT.md grants a Group four bbox-corner control points")
        for kind in [SelectionKind.all, .partial(SortedCps(0..<4))] {
            let moved = g.moveControlPoints(kind, dx: 24, dy: 0)
            guard case .group(let mg) = moved, case .rect(let r) = mg.children[0] else {
                Issue.record("expected a Group of Rects"); return
            }
            #expect(r.x == 24, "a fully-selected container moves; got x=\(r.x)")
        }
    }

    /// One corner is a RESIZE gesture, and group resize does not exist. It must
    /// leave the group alone rather than translating it.
    @Test func onePartialCornerDoesNotTranslateTheGroup() {
        let g = group()
        #expect(g.moveControlPoints(.partial(SortedCps([0])), dx: 24, dy: 0) == g,
                "one corner selected is a resize gesture, not a translate")
    }
}
