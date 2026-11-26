/// Swift's Path B render plan names each foreach repeat it expands (row 281).
///
/// The Rust panel plan (`panel_plan.rs`, #1131) lists each expanded foreach
/// as `{path, id, rows, elements}`, with iteration k's widgets under
/// `path + [k]`. The Mac draws Path B panels (the Artboards list among them)
/// as flat absolutely placed leaves, so the per-iteration accessibility layer
/// a level-2 driver addresses by `at` (`ap_list#1`) can only be built from
/// this: each leaf's path and the repeats above it. The case below is Rust's
/// `the_plan_names_each_repeat_it_expands_with_its_row_count`, ported
/// verbatim, so the two ports pin one scheme.

import Foundation
import Testing
@testable import JasLib

@Suite struct RenderPlanRepeatsTests {
    static let panel: [String: Any] = ["content": ["type": "col", "children": [
        ["type": "text", "id": "head", "content": "x"],
        ["type": "col", "id": "list", "foreach": ["source": "items", "as": "it"],
         "do": ["type": "row", "children": [["type": "text", "id": "name", "content": "{{it.name}}"]]]],
        ["type": "col", "id": "tree", "foreach": ["source": "els", "as": "e"],
         "do": ["type": "text", "id": "el", "content": "{{e.name}}"]],
        ["type": "col", "id": "gone", "visible": false, "foreach": ["source": "items", "as": "g"],
         "do": ["type": "text", "id": "g", "content": "{{g.name}}"]],
    ] as [Any]] as [String: Any]]
    static let ctx: [String: Any] = [
        "items": [["name": "a"], ["name": "b"]],
        "els": [["name": "p", "path": [0]], ["name": "q", "path": [1]], ["name": "r", "path": [1, 0]]],
    ]

    @Test func thePlanNamesEachRepeatItExpandsWithItsRowCount() {
        let plan = PanelLayout.renderPlan(Self.panel, availW: 228, availH: 0, ctx: Self.ctx)
        #expect(plan.repeats == [
            PanelLayout.RenderRepeat(path: [1], id: "list", rows: 2, elements: false),
            PanelLayout.RenderRepeat(path: [2], id: "tree", rows: 3, elements: true),
        ], "\(plan.repeats)")
    }

    @Test func eachIterationsLeafSitsUnderTheRepeatPathPlusItsIndex() {
        let plan = PanelLayout.renderPlan(Self.panel, availW: 228, availH: 0, ctx: Self.ctx)
        let names = plan.leaves.filter { $0.node["id"] as? String == "name" }.map(\.path)
        #expect(names.count == 2, "two iterations, two name leaves: \(names)")
        for (k, p) in names.enumerated() {
            #expect(Array(p.prefix(2)) == [1, k], "iteration \(k)'s leaf \(p) sits under repeat [1] + [\(k)]")
        }
    }

    @Test func aPlanThatExpandsNoRepeatListsNone() {
        let flat: [String: Any] = ["content": ["type": "col", "children": [
            ["type": "text", "id": "head", "content": "x"]] as [Any]] as [String: Any]]
        #expect(PanelLayout.renderPlan(flat, availW: 228, availH: 0, ctx: Self.ctx).repeats.isEmpty)
    }

    @Test func anExpandedRepeatWithNoRowsIsStillNamedWithRowsZero() {
        let plan = PanelLayout.renderPlan(Self.panel, availW: 228, availH: 0,
                                          ctx: ["items": [] as [Any], "els": [] as [Any]])
        #expect(plan.repeats == [
            PanelLayout.RenderRepeat(path: [1], id: "list", rows: 0, elements: false),
            PanelLayout.RenderRepeat(path: [2], id: "tree", rows: 0, elements: false),
        ], "\(plan.repeats)")
    }
}

/// The identified iteration layers a Path B leaf is drawn in, outermost
/// first: `<foreach id>#<k>` for each repeat whose `path + [k]` prefixes the
/// leaf's path. A repeat with no id contributes no layer (the driver refuses
/// `at` there by name, never guesses by layout).
@Suite struct IterationChainTests {
    let reps = [
        PanelLayout.RenderRepeat(path: [0], id: "outer", rows: 2, elements: false),
        PanelLayout.RenderRepeat(path: [0, 1, 2], id: "inner", rows: 3, elements: false),
        PanelLayout.RenderRepeat(path: [1], id: nil, rows: 2, elements: false),
    ]

    @Test func aLeafOutsideEveryRepeatHasNoLayer() {
        #expect(iterationChain(leafPath: [2, 0], repeats: reps) == [])
    }

    @Test func aLeafInOneIterationIsInThatLayer() {
        #expect(iterationChain(leafPath: [0, 1, 0], repeats: reps) == ["outer#1"])
    }

    @Test func nestedIterationsAreListedOutermostFirst() {
        #expect(iterationChain(leafPath: [0, 1, 2, 2, 0], repeats: reps) == ["outer#1", "inner#2"])
    }

    @Test func aLeafAtExactlyTheIterationNodeIsInItsLayer() {
        // A template that is itself a leaf sits at exactly path + [k].
        #expect(iterationChain(leafPath: [0, 0], repeats: reps) == ["outer#0"])
    }

    @Test func aRepeatWithNoIdContributesNoLayer() {
        #expect(iterationChain(leafPath: [1, 1, 0], repeats: reps) == [])
    }

    @Test func aRepeatPathIsMatchedWholeNotAsATextPrefix() {
        // [0, 1, 2] is not under [0, 12]; compare components, never strings.
        let r = [PanelLayout.RenderRepeat(path: [0, 1], id: "a", rows: 30, elements: false)]
        #expect(iterationChain(leafPath: [0, 12, 0], repeats: r) == [])
    }

    @Test func theRepeatNodeItselfIsInNoLayerOfItsOwn() {
        #expect(iterationChain(leafPath: [0], repeats: reps) == [])
    }
}
