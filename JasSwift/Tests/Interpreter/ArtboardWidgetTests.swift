import Testing
@testable import JasLib

/// The two widget kinds JasSwift did not dispatch until 2026-07-29.
///
/// Found by the jas/windows seat counting dispatch arms against the 38 canonical
/// kinds in `workspace_interpreter/widget_tree.py`. Rust dispatched all 38; this
/// port dispatched 35, and the missing ones fell through to
/// `renderPlaceholder()` — which renders the widget's `summary`, so an absent
/// control appeared as a text label.
///
/// `check_widget_kind_dispatch.py` now asserts the ARM exists. These tests cover
/// what a syntactic gate cannot: the widgets' DATA contracts, which are where a
/// silent divergence from Rust would live.
@Suite("Artboard widget contracts")
struct ArtboardWidgetTests {

    /// The 3×3 anchor grid is ROW-MAJOR and matches Rust's ordering. If the two
    /// ports disagree here, clicking the same cell sets a different anchor in
    /// each — a divergence no golden would catch, because the widget's output is
    /// a panel-state string, not document geometry.
    @Test func referencePointAnchorsAreRowMajorAndMatchRust() {
        let rows = referencePointAnchorRowsForTest
        #expect(rows.count == 3, "three rows")
        #expect(rows.allSatisfy { $0.count == 3 }, "three cells each")
        #expect(rows[0] == ["top_left", "top", "top_right"], "top row")
        #expect(rows[1] == ["left", "center", "right"], "middle row")
        #expect(rows[2] == ["bottom_left", "bottom", "bottom_right"], "bottom row")
        // Exactly nine distinct anchors, no duplicate cell.
        #expect(Set(rows.flatMap { $0 }).count == 9, "nine distinct anchors")
        // "center" is the widget's declared default and must be present.
        #expect(rows.flatMap { $0 }.contains("center"), "center is the default anchor")
    }

    /// The workspace declares both kinds, which is what makes their absence a
    /// defect rather than a hypothetical. If a future edit removes them from the
    /// YAML, this test says so rather than the dispatch gate quietly passing.
    @Test func bothKindsAreDeclaredInTheShippingWorkspace() {
        guard let ws = WorkspaceData.load() else {
            Issue.record("workspace bundle failed to load"); return
        }
        var kinds: Set<String> = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let t = d["type"] as? String { kinds.insert(t) }
                d.values.forEach(walk)
            } else if let a = node as? [Any] {
                a.forEach(walk)
            }
        }
        walk(ws.data)
        #expect(kinds.contains("icon_button_group"),
                "artboard_options declares icon_button_group")
        #expect(kinds.contains("reference_point_widget"),
                "artboard_options declares reference_point_widget")
    }
}
