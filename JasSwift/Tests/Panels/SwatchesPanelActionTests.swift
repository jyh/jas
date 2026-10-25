import Testing
@testable import JasLib

/// THE FIVE SWATCHES VERBS, through the route the panel menu takes.
///
/// Since 2026-10-25 all five are `swatch.*` effects in actions.yaml (the
/// reference is workspace_interpreter/effects.py, its table
/// test_swatch_verbs.py), run by ``runYamlActionByName`` like every other
/// YAML action, over the app-global libraries (``AppSwatchLibraries``; a
/// per-canvas home would fork them per tab). Until then they were a native
/// Swift copy of jas_dioxus's native arms (council O1.3, 2026-07-30), and
/// before that, `- log:` no-ops.
///
/// The laws, which the YAML now states:
///   * sort is by CODE POINT and STABLE, so "Zinc" precedes "azure"
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

    /// The panel menu's own route (``panelDispatch``), with ANOTHER panel
    /// active: in the app the active panel is whichever panel rendered last,
    /// so a menu that does not make its own panel active reads another
    /// panel's `panel.selected_library` and does nothing.
    private func menu(_ cmd: String, _ m: Model) {
        m.stateStore.initPanel("layers_panel_content", defaults: [:])
        m.stateStore.setActivePanel("layers_panel_content")
        var layout = WorkspaceLayout.defaultLayout()
        panelDispatch(.swatches, cmd: cmd,
                      addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                      layout: &layout, model: m)
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
        menu("sort_swatches_by_name", m)
        #expect(names(m) == ["Beige", "Zinc", "azure"],
                "case-sensitive ASCII: uppercase sorts before lowercase")
        #expect(selection(m).isEmpty,
                "indices no longer point at the same swatch, so selection clears")
    }

    /// An empty document uses no colours, so every swatch is unused.
    @Test func selectAllUnusedOnAnEmptyDocumentSelectsEverything() {
        let m = model([swatch("a", "#ff0000"), swatch("b", "#00ff00")])
        menu("select_all_unused_swatches", m)
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
        menu("select_all_unused_swatches", m)
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
        menu("add_used_colors", m)
        #expect(names(m) == ["blue", "R=255 G=0 B=0"],
                "blue is already present; red is appended with its component name")
    }

    /// Descending removal, so an earlier delete cannot shift a later index.
    @Test func deleteRemovesEverySelectedSwatch() {
        let m = model([swatch("a", "#000000"), swatch("b", "#111111"),
                       swatch("c", "#222222"), swatch("d", "#333333")],
                      selected: [0, 2])
        menu("delete_swatch", m)
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
        menu("duplicate_swatch", m)
        #expect(names(m) == ["a", "a copy", "b", "c", "c copy"],
                "without the running offset the second copy lands in the wrong slot")
        #expect(selection(m) == [1, 4], "selection follows the new copies")
    }

    /// A duplicate keeps the original's colour and metadata — only the name
    /// changes. The preservation law, at swatch scale.
    @Test func duplicatePreservesColourAndMetadata() {
        let m = model([swatch("a", "#abcdef")], selected: [0])
        menu("duplicate_swatch", m)
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
        menu("delete_swatch", m)
        #expect(names(m).isEmpty, "the valid index deletes; the others are skipped")
    }

    /// Code point, not String `<` (canonical equivalence): a decomposed
    /// "e" + U+0301 sorts with the "e"s, a precomposed "é" after "z". The old
    /// native copy used `<`, which reads the two as equal and diverged from the
    /// engine here.
    @Test func sortIsByCodePointNotCanonicalEquivalence() {
        let m = model([swatch("\u{e9}", "#000000"), swatch("z", "#000000"),
                       swatch("e\u{301}", "#000000"), swatch("f", "#000000")])
        menu("sort_swatches_by_name", m)
        #expect(names(m) == ["e\u{301}", "f", "z", "\u{e9}"])
    }

    /// Stable at a size where an unstable sort reorders (Rust's and Swift's
    /// unstable sorts behave stably on small arrays): 64 swatches over three
    /// names, each colour its position; equal names keep library order.
    @Test func sortIsStableOnALargeLibrary() {
        let m = model((0..<64).map { i in
            swatch(["Y", "X", "Z"][(i * 7) % 3], "#" + String(format: "%06x", i)) })
        menu("sort_swatches_by_name", m)
        let lib = m.swatchLibraries.swatches(of: Self.LIB) ?? []
        for name in ["X", "Y", "Z"] {
            let order = lib.filter { ($0["name"] as? String) == name }.map { $0["color"] as? String ?? "" }
            #expect(order == order.sorted(), "\(name)")
        }
    }

    /// Swatch Options from the panel menu, which passes only `{mode: edit}`:
    /// the dialog opens on the FIRST selected swatch (it opened empty on every
    /// route before), and OK, with the params its button resolves, replaces
    /// that swatch (OK wrote only on the web before).
    @Test func swatchOptionsFromTheMenuEditsTheFirstSelectedSwatch() {
        let m = model([swatch("A", "#ff0000"), swatch("B", "#00ff00"), swatch("C", "#0000ff")],
                      selected: [1, 2])
        menu("open_swatch_options", m)
        #expect(m.stateStore.getDialogId() == "swatch_options")
        #expect(m.stateStore.getDialog("swatch_name") as? String == "B")
        m.stateStore.setDialog("swatch_name", "Bee")
        func okButton(_ n: Any?) -> [String: Any]? {
            guard let d = n as? [String: Any] else { return nil }
            if d["type"] as? String == "button", d["label"] as? String == "OK" { return d }
            for c in d["children"] as? [Any] ?? [] { if let b = okButton(c) { return b } }
            return nil
        }
        let ok = okButton(WorkspaceData.load()?.dialog("swatch_options")?["content"])
        #expect(ok != nil)
        let ctx = buildDialogEvalContextWithGetters(
            store: m.stateStore, state: m.stateStore.getDialogState(),
            params: m.stateStore.getDialogParams() ?? [:], outer: [:])
        _ = DialogWidgetActions.run(
            "swatch_options_confirm",
            params: DialogWidgetActions.resolveParams(ok?["params"] as? [String: Any] ?? [:], context: ctx),
            model: m)
        #expect(m.stateStore.getDialogId() == nil)
        #expect(names(m) == ["A", "Bee", "C"])
        #expect((m.swatchLibraries.swatches(of: Self.LIB)?[1]["color"] as? String) == "#00ff00")
    }
}
