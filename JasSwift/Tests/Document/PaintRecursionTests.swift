import Testing
@testable import JasLib

/// FILL AND STROKE RECURSE INTO A SELECTED CONTAINER. RULED 2026-07-29.
///
/// Selecting a group and clicking a swatch did NOTHING to its members. Driven
/// at council: both children came back with `fill == nil`. Both ports handled
/// containers EXPLICITLY (`case .group, .layer:` here, `Group(_) | Layer(_) =>`
/// in Rust), so nobody forgot — someone decided a container has no fill of its
/// own. True of the data model, false of the artist's intent.
///
/// Rust hid it behind `doc.set_selection`'s container expansion, which put the
/// MEMBERS in the selection so they got filled. JasSwift does not expand, so
/// there it was live; and §20 would have carried it into Rust.
///
/// Twin: Rust `fill_and_stroke_recurse_into_a_selected_container`.
@Suite("Paint recurses into containers")
struct PaintRecursionTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private func nestedModel() -> Model {
        // A group holding a leaf AND a nested group, so recursion is exercised
        // at two depths. Both containers carry ids, so the T4 bystander clause
        // is checked on the rebuild.
        let inner = Element.group(Group(children: [rect(40)], id: "inner"))
        let outer = Element.group(Group(children: [rect(0), inner], id: "outer"))
        let doc = Document(layers: [Layer(name: "L", children: [outer])])
        return Model(document: doc.replacing(selection: [ElementSelection.all([0, 0])]))
    }

    private func fills(_ model: Model) -> [Fill?] {
        guard case .group(let g) = model.document.getElement([0, 0]) else { return [] }
        var out: [Fill?] = []
        func walk(_ e: Element) {
            switch e {
            case .group(let gg): gg.children.forEach(walk)
            case .rect(let r): out.append(r.fill)
            default: break
            }
        }
        g.children.forEach(walk)
        return out
    }

    @Test func fillReachesEveryMemberAtEveryDepth() {
        let model = nestedModel()
        Controller(model: model).setSelectionFill(Fill(color: Color(r: 1, g: 0, b: 0, a: 1)))
        let f = fills(model)
        #expect(f.count == 2, "two leaves under the selected group; found \(f.count)")
        #expect(f.allSatisfy { $0 != nil },
                "every leaf is filled, including the one two levels down")
    }

    @Test func strokeReachesEveryMemberAtEveryDepth() {
        let model = nestedModel()
        Controller(model: model).setSelectionStroke(Stroke(color: Color(r: 0, g: 0, b: 1, a: 1), width: 3))
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        guard case .rect(let direct) = g.children[0] else {
            Issue.record("child 0 not a rect"); return
        }
        #expect(direct.stroke != nil, "the direct member is stroked")
        guard case .group(let ig) = g.children[1], case .rect(let deep) = ig.children[0] else {
            Issue.record("nested member missing"); return
        }
        #expect(deep.stroke != nil, "the member two levels down is stroked")
    }

    /// A BRUSH is stroke styling, so it recurses too. Found by the
    /// element-dispatch enumeration rather than by a report:
    /// `setSelectionStrokeBrush` looped the selection and `withStrokeBrush`
    /// returned a container unchanged, so applying a brush to a selected group
    /// did nothing — the same shape as fill and stroke, one ruling behind.
    @Test func aBrushReachesEveryMemberAtEveryDepth() {
        // A brush applies to Path/Line/Polyline only — a Rect carries no
        // stroke brush by design (`with_stroke_brush`), so the fixture uses
        // LINES. The first draft used the shared rect model and failed for
        // that reason: the fixture was wrong, not the code.
        let inner = Element.group(Group(children: [
            .line(Line(x1: 40, y1: 0, x2: 50, y2: 10))], id: "inner"))
        let outer = Element.group(Group(children: [
            .line(Line(x1: 0, y1: 0, x2: 10, y2: 10)), inner], id: "outer"))
        let doc = Document(layers: [Layer(name: "L", children: [outer])])
        let model = Model(document: doc.replacing(
            selection: [ElementSelection.all([0, 0])]))
        Controller(model: model).setSelectionStrokeBrush("charcoal")
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        // A brush PROMOTES a stroke-carrying leaf to a Path, so assert on the
        // brush slug rather than on the kind that carries it.
        var slugs: [String?] = []
        func walk(_ e: Element) {
            switch e {
            case .group(let gg): gg.children.forEach(walk)
            case .path(let p): slugs.append(p.strokeBrush)
            case .rect, .line, .polyline: slugs.append(nil)  // unpromoted = no brush
            default: break
            }
        }
        g.children.forEach(walk)
        #expect(slugs.count == 2, "two leaves under the selected group; found \(slugs.count)")
        #expect(slugs.allSatisfy { $0 == "charcoal" },
                "every leaf carries the brush, including the one two levels down; got \(slugs)")
    }

    /// T4 BYSTANDER: the walk REBUILDS every container it passes through, so a
    /// container's own fields must survive. Rebuilding by re-listing fields is
    /// the Swift copy-site omission class — it would drop `id` and `mask` on
    /// every swatch click. `withChildren` is what prevents that.
    @Test func containersKeepTheirOwnFieldsThroughTheWalk() {
        let model = nestedModel()
        Controller(model: model).setSelectionFill(Fill(color: Color(r: 1, g: 0, b: 0, a: 1)))
        guard case .group(let g) = model.document.getElement([0, 0]) else {
            Issue.record("not a group"); return
        }
        #expect(g.id == "outer", "the rebuilt container keeps its id; got \(g.id ?? "nil")")
        guard case .group(let ig) = g.children[1] else {
            Issue.record("nested group missing"); return
        }
        #expect(ig.id == "inner", "the nested container keeps ITS id; got \(ig.id ?? "nil")")
    }
}
