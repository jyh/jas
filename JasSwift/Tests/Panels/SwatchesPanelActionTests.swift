import Testing
@testable import JasLib

/// THE FIVE SWATCHES VERBS, against jas_dioxus's behaviour.
///
/// All five worked in jas_dioxus (`panels/swatches_panel.rs`) and were Swift
/// NO-OPS: `SwatchesPanel.dispatch` fell to `default: runYamlActionByName(cmd)`,
/// which runs the action's declared effects — and all five declare a bare
/// `- log:`. Found by `check_action_implementations.py` on its first run;
/// council O1.3, 2026-07-30.
///
/// WHY THEY COULD NOT SIMPLY BE WRITTEN. Four of the five MUTATE a library, and
/// JasSwift had nowhere to put a mutation: `WorkspaceData` is the immutable
/// process-cached bundle and the panel re-read it every render. The store
/// (`AppSwatchLibraries`) had to exist first, app-global, following the
/// ratified `AppDefaults` precedent — per-canvas would fork the libraries per
/// tab, which Rust does not do, and every test here would still pass.
///
/// Semantics are transliterated from the Rust arms, including the parts that
/// look like accidents and are not:
///   * sort is CASE-SENSITIVE ASCII (`na.cmp(nb)`), so "Zinc" precedes "azure"
///   * unused-selection compares lowercase hex with the `#` stripped
///   * add-used appends in SORTED HEX order, for determinism
///   * delete iterates DESCENDING, so earlier removals do not shift later ones
///   * duplicate iterates ASCENDING with a running offset, and the selection
///     moves to the new copies
@Suite struct SwatchesPanelActionTests {

    private static let LIB = "test_lib"

    private func swatch(_ name: String, _ hex: String) -> [String: Any] {
        ["name": name, "color": hex, "color_mode": "rgb",
         "color_type": "process", "global": false]
    }

    /// A model whose swatch store holds one library, with the panel state the
    /// verbs read. `initPanel` first: `StateStore.setPanel` is
    /// `panels[id]?[key] = value` — optional chaining — so a write to a panel
    /// that was never initialised is DROPPED SILENTLY, and a test that forgot
    /// this would pass with both sides empty.
    private func model(_ swatches: [[String: Any]],
                       selected: [Int] = [],
                       doc: Document = Document()) -> Model {
        let m = Model(document: doc)
        m.swatchLibraries = AppSwatchLibraries(
            seed: [Self.LIB: ["name": "Test", "swatches": swatches]])
        m.stateStore.initPanel("swatches_panel_content", defaults: [:])
        m.stateStore.setPanel("swatches_panel_content", "selected_library", Self.LIB)
        m.stateStore.setPanel("swatches_panel_content", "selected_swatches", selected)
        return m
    }

    private func names(_ m: Model) -> [String] {
        (m.swatchLibraries.swatches(of: Self.LIB) ?? []).map { ($0["name"] as? String) ?? "" }
    }
    private func selection(_ m: Model) -> [Int] {
        (m.stateStore.getPanel("swatches_panel_content", "selected_swatches") as? [Int]) ?? []
    }

    /// Case-SENSITIVE ASCII order, matching Rust's `na.cmp(nb)`. Swift's
    /// default `<` on String agrees for pure ASCII, so "Zinc" sorts BEFORE
    /// "azure" — a naive `localizedCompare` or `caseInsensitiveCompare` would
    /// look more correct and diverge.
    @Test func sortByNameIsCaseSensitiveAndClearsSelection() {
        let m = model([swatch("azure", "#00ffff"),
                       swatch("Zinc", "#7f7f7f"),
                       swatch("Beige", "#f5f5dc")],
                      selected: [0, 2])
        SwatchesPanel.dispatchSwatchAction("sort_swatches_by_name", model: m)
        #expect(names(m) == ["Beige", "Zinc", "azure"],
                "case-sensitive ASCII: uppercase sorts before lowercase")
        #expect(selection(m).isEmpty,
                "indices no longer point at the same swatch, so selection clears")
    }

    /// An empty document uses no colours, so every swatch is unused.
    @Test func selectAllUnusedOnAnEmptyDocumentSelectsEverything() {
        let m = model([swatch("a", "#ff0000"), swatch("b", "#00ff00")])
        SwatchesPanel.dispatchSwatchAction("select_all_unused_swatches", model: m)
        #expect(selection(m) == [0, 1])
    }

    /// A swatch whose colour appears in the document is NOT unused. Comparison
    /// is on lowercase hex with `#` stripped, so case and prefix must not
    /// matter.
    @Test func selectAllUnusedSkipsColoursTheDocumentUses() {
        let doc = Document(rawLayers: [Layer(name: "L", children: [
            .rect(Rect(x: 0, y: 0, width: 1, height: 1,
                       fill: Fill(color: Color(r: 255, g: 0, b: 0))))
        ])], rawSelectedLayer: 0, rawSelection: [], rawArtboards: [],
            rawArtboardOptions: .default)
        let m = model([swatch("red", "#FF0000"), swatch("green", "#00ff00")], doc: doc)
        SwatchesPanel.dispatchSwatchAction("select_all_unused_swatches", model: m)
        #expect(selection(m) == [1], "the red swatch is in use despite differing case")
    }

    /// Appends one swatch per used colour not already present, named in the
    /// `R=n G=n B=n` form, in sorted-hex order.
    @Test func addUsedColorsAppendsMissingOnesInHexOrder() {
        let doc = Document(rawLayers: [Layer(name: "L", children: [
            .rect(Rect(x: 0, y: 0, width: 1, height: 1,
                       fill: Fill(color: Color(r: 0, g: 0, b: 255)))),
            .rect(Rect(x: 1, y: 1, width: 1, height: 1,
                       fill: Fill(color: Color(r: 255, g: 0, b: 0)))),
        ])], rawSelectedLayer: 0, rawSelection: [], rawArtboards: [],
            rawArtboardOptions: .default)
        let m = model([swatch("blue", "#0000ff")], doc: doc)
        SwatchesPanel.dispatchSwatchAction("add_used_colors", model: m)
        #expect(names(m) == ["blue", "R=255 G=0 B=0"],
                "blue is already present; red is appended with its component name")
    }

    /// Descending removal, so an earlier delete cannot shift a later index.
    @Test func deleteRemovesEverySelectedSwatch() {
        let m = model([swatch("a", "#000000"), swatch("b", "#111111"),
                       swatch("c", "#222222"), swatch("d", "#333333")],
                      selected: [0, 2])
        SwatchesPanel.dispatchSwatchAction("delete_swatch", model: m)
        #expect(names(m) == ["b", "d"],
                "ascending removal would delete 'a' then shift, taking 'd' instead of 'c'")
        #expect(selection(m).isEmpty)
    }

    /// Each copy lands immediately after its original, with a running offset,
    /// and the selection moves to the copies.
    @Test func duplicateInsertsAfterEachOriginalAndSelectsTheCopies() {
        let m = model([swatch("a", "#000000"), swatch("b", "#111111"),
                       swatch("c", "#222222")],
                      selected: [0, 2])
        SwatchesPanel.dispatchSwatchAction("duplicate_swatch", model: m)
        #expect(names(m) == ["a", "a copy", "b", "c", "c copy"],
                "without the running offset the second copy lands in the wrong slot")
        #expect(selection(m) == [1, 4], "selection follows the new copies")
    }

    /// A duplicate keeps the original's colour and metadata — only the name
    /// changes. The preservation law, at swatch scale.
    @Test func duplicatePreservesColourAndMetadata() {
        let m = model([swatch("a", "#abcdef")], selected: [0])
        SwatchesPanel.dispatchSwatchAction("duplicate_swatch", model: m)
        let copy = (m.swatchLibraries.swatches(of: Self.LIB) ?? [])[1]
        #expect((copy["color"] as? String) == "#abcdef")
        #expect((copy["color_mode"] as? String) == "rgb")
        #expect((copy["color_type"] as? String) == "process")
        #expect((copy["name"] as? String) == "a copy")
    }

    /// An out-of-range selection index must be skipped, not trap. Rust launders
    /// a negative i64 into a huge usize that fails its bounds check; Swift's
    /// Int does not wrap, so the same input would reach `remove(at:)` and
    /// CRASH THE APP rather than diverge.
    @Test func outOfRangeSelectionIndicesAreIgnored() {
        let m = model([swatch("a", "#000000")], selected: [-1, 0, 99])
        SwatchesPanel.dispatchSwatchAction("delete_swatch", model: m)
        #expect(names(m).isEmpty, "the valid index deletes; the others are skipped")
    }
}
