import Foundation
import Testing
@testable import JasLib

// ── Generic YAML menu builder ────────────────────────────────────
//
// These probe `menuItemsFromYaml` directly: the builder reads each
// panel's `menu:` block from the compiled bundle and maps it to
// PanelMenuItem (separator / checked->toggle / recurring-action->radio
// with folded params / else action). They mirror the Rust reference's
// panel_menu unit tests.

private func commands(_ items: [PanelMenuItem]) -> [String] {
    items.compactMap { item in
        switch item {
        case .action(_, let c, _), .toggle(_, let c), .radio(_, let c, _): return c
        case .separator: return nil
        }
    }
}

@Test func builderReadsBooleanPanel() {
    let items = menuItemsFromYaml("boolean_panel_content")
    let cmds = commands(items)
    #expect(cmds.contains("make_compound_shape"))
    #expect(cmds.contains("close_panel"))
    let seps = items.filter { if case .separator = $0 { return true }; return false }.count
    #expect(seps == 3)
    #expect(items.count == 10)
}

@Test func builderReadsSymbolsPanel() {
    // SYMBOLS.md §8: the Symbols panel menu has New Symbol / Place
    // Instance / Delete Symbol, a separator, and Close Symbols. Mirrors
    // the Rust lead's symbols_panel menu tests.
    let items = menuItemsFromYaml("symbols_panel_content")
    let labels: [String] = items.compactMap { item in
        switch item {
        case .action(let l, _, _), .toggle(let l, _), .radio(let l, _, _): return l
        case .separator: return nil
        }
    }
    #expect(labels.contains("New Symbol"))
    #expect(labels.contains("Place Instance"))
    #expect(labels.contains("Delete Symbol"))
    #expect(labels.contains("Close Symbols"))
    let cmds = commands(items)
    for cmd in ["new_symbol", "place_instance", "delete_symbol_action", "close_panel"] {
        #expect(cmds.contains(cmd), "Symbols menu should include command \(cmd)")
    }
}

@Test func builderFoldsColorRadioParamsIntoCommand() {
    // The Color panel's five mode rows share `action: set_color_panel_mode`,
    // so the builder treats them as a radio group and folds each
    // `params.mode` value into the command.
    let items = menuItemsFromYaml("color_panel_content")
    var radios: [(String, String)] = []
    for item in items {
        if case .radio(_, let cmd, let group) = item { radios.append((cmd, group)) }
    }
    #expect(radios.contains { $0 == ("set_color_panel_mode:grayscale", "set_color_panel_mode") })
    #expect(radios.contains { $0 == ("set_color_panel_mode:rgb", "set_color_panel_mode") })
    #expect(radios.contains { $0 == ("set_color_panel_mode:web_safe_rgb", "set_color_panel_mode") })
    // Plain actions keep their action verbatim (no param folding).
    #expect(commands(items).contains("invert_active_color"))
    // close_panel keeps its action even though the YAML carries
    // `params: { panel: color }`.
    #expect(commands(items).contains("close_panel"))
}

@Test func builderSwatchesSubmenuBecomesOpenLibraryAction() {
    // The dynamic "Open Swatch Library" submenu entry has an explicit
    // `action: open_swatch_library` in the YAML so the menu view's
    // submenu host fires.
    let items = menuItemsFromYaml("swatches_panel_content")
    let hasHost = items.contains { if case .action(_, "open_swatch_library", _) = $0 { return true }; return false }
    #expect(hasHost, "swatches menu should expose open_swatch_library host")
    // Thumbnail-size rows are a radio group with folded params.
    var radios: [String] = []
    for item in items { if case .radio(_, let cmd, _) = item { radios.append(cmd) } }
    #expect(radios.contains("set_swatch_thumbnail_size:small"))
    #expect(radios.contains("set_swatch_thumbnail_size:large"))
}

@Test func builderStandaloneCheckboxIsToggleNotRadio() {
    // The Align panel has a single `toggle_use_preview_bounds` checkbox;
    // its action does not recur, so it is a toggle, not a radio.
    let items = menuItemsFromYaml("align_panel_content")
    let isToggle = items.contains { if case .toggle(_, "toggle_use_preview_bounds") = $0 { return true }; return false }
    #expect(isToggle)
}

@Test func builderStrokeCapJoinAreRadioGroups() {
    let items = menuItemsFromYaml("stroke_panel_content")
    var radios: [String] = []
    for item in items { if case .radio(_, let cmd, _) = item { radios.append(cmd) } }
    #expect(radios.contains("set_stroke_cap:butt"))
    #expect(radios.contains("set_stroke_cap:round"))
    #expect(radios.contains("set_stroke_join:miter"))
    #expect(radios.contains("set_stroke_join:bevel"))
    #expect(commands(items).contains("close_panel"))
}

@Test func panelLabelMatchesAllKinds() {
    #expect(panelLabel(.layers) == "Layers")
    #expect(panelLabel(.color) == "Color")
    #expect(panelLabel(.swatches) == "Swatches")
    #expect(panelLabel(.stroke) == "Stroke")
    #expect(panelLabel(.properties) == "Object properties")
}

@Test func panelKindAllCount() {
    #expect(PanelKind.all.count == 13)
}

@Test func panelKindAllContainsAllVariants() {
    #expect(PanelKind.all.contains(.layers))
    #expect(PanelKind.all.contains(.color))
    #expect(PanelKind.all.contains(.swatches))
    #expect(PanelKind.all.contains(.stroke))
    #expect(PanelKind.all.contains(.properties))
    #expect(PanelKind.all.contains(.character))
    #expect(PanelKind.all.contains(.paragraph))
    #expect(PanelKind.all.contains(.artboards))
    #expect(PanelKind.all.contains(.align))
    #expect(PanelKind.all.contains(.boolean))
    #expect(PanelKind.all.contains(.opacity))
    #expect(PanelKind.all.contains(.magicWand))
    #expect(PanelKind.all.contains(.symbols))
}

@Test func alignPanelMenuHasExpectedEntries() {
    let items = panelMenu(.align)
    // Three entries plus two separators per ALIGN.md Panel menu.
    #expect(items.count == 5)
    guard case .toggle(_, let togCmd) = items[0] else {
        Issue.record("first item should be a toggle")
        return
    }
    #expect(togCmd == "toggle_use_preview_bounds")
    if case .separator = items[1] {} else {
        Issue.record("second item should be a separator")
    }
    guard case .action(_, let resetCmd, _) = items[2] else {
        Issue.record("third item should be an action")
        return
    }
    #expect(resetCmd == "reset_align_panel")
    if case .separator = items[3] {} else {
        Issue.record("fourth item should be a separator")
    }
    guard case .action(let closeLabel, let closeCmd, _) = items[4] else {
        Issue.record("fifth item should be an action")
        return
    }
    #expect(closeCmd == "close_panel")
    #expect(closeLabel == "Close Align")
}

@Test func panelMenuNonEmptyForAllKinds() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        #expect(!items.isEmpty, "Menu for \(kind) is empty")
    }
}

@Test func everyPanelHasCloseAction() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        let hasClose = items.contains { item in
            if case .action(_, let cmd, _) = item { return cmd == "close_panel" }
            return false
        }
        #expect(hasClose, "Menu for \(kind) missing close_panel action")
    }
}

@Test func closeLabelMatchesPanelName() {
    for kind in PanelKind.all {
        let items = panelMenu(kind)
        let closeItem = items.first { item in
            if case .action(_, let cmd, _) = item { return cmd == "close_panel" }
            return false
        }
        if case .action(let label, _, _) = closeItem {
            #expect(label == "Close \(panelLabel(kind))",
                    "Close label mismatch for \(kind)")
        }
    }
}

@Test func panelDispatchCloseRemovesPanel() {
    var layout = WorkspaceLayout.defaultLayout()
    let dockId = layout.anchoredDock(.right)!.id
    // Color is at group 0, panel index 0
    let addr = PanelAddr(group: GroupAddr(dockId: dockId, groupIdx: 0), panelIdx: 0)
    #expect(layout.isPanelVisible(.color))
    panelDispatch(.color, cmd: "close_panel", addr: addr, layout: &layout)
    #expect(!layout.isPanelVisible(.color))
}

@Test func panelIsCheckedDefaultsFalse() {
    let layout = WorkspaceLayout.defaultLayout()
    for kind in PanelKind.all {
        #expect(!panelIsChecked(kind, cmd: "anything", layout: layout))
    }
}

@Test func layersMenuHasNewLayer() {
    let items = panelMenu(.layers)
    let has = items.contains { if case .action(_, "new_layer", _) = $0 { return true }; return false }
    #expect(has, "Layers menu missing new_layer")
}

@Test func layersMenuHasNewGroup() {
    let items = panelMenu(.layers)
    let has = items.contains { if case .action(_, "new_group", _) = $0 { return true }; return false }
    #expect(has, "Layers menu missing new_group")
}

@Test func layersMenuHasVisibilityToggles() {
    let items = panelMenu(.layers)
    for cmd in ["toggle_all_layers_visibility", "toggle_all_layers_outline", "toggle_all_layers_lock"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersMenuHasIsolationMode() {
    let items = panelMenu(.layers)
    for cmd in ["enter_isolation_mode", "exit_isolation_mode"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersMenuHasFlattenAndCollect() {
    let items = panelMenu(.layers)
    for cmd in ["flatten_artwork", "collect_in_new_layer"] {
        let has = items.contains { if case .action(_, let c, _) = $0 { return c == cmd }; return false }
        #expect(has, "Layers menu missing \(cmd)")
    }
}

@Test func layersDispatchTier3NoError() {
    var layout = WorkspaceLayout.defaultLayout()
    let dockId = layout.anchoredDock(.right)!.id
    let addr = PanelAddr(group: GroupAddr(dockId: dockId, groupIdx: 2), panelIdx: 0)
    for cmd in ["new_layer", "new_group", "toggle_all_layers_visibility",
                "toggle_all_layers_outline", "toggle_all_layers_lock",
                "enter_isolation_mode", "exit_isolation_mode",
                "flatten_artwork", "collect_in_new_layer"] {
        panelDispatch(.layers, cmd: cmd, addr: addr, layout: &layout)
    }
}

@Test func pushRecentColorMoveToFront() {
    let m = Model()
    m.recentColors = []
    ColorPanel.pushRecentColor("#ff0000", model: m)
    #expect(m.recentColors == ["#ff0000"])
    ColorPanel.pushRecentColor("#00ff00", model: m)
    #expect(m.recentColors == ["#00ff00", "#ff0000"])
    ColorPanel.pushRecentColor("#ff0000", model: m)  // dedup, move to front
    #expect(m.recentColors == ["#ff0000", "#00ff00"])
}

@Test func pushRecentColorCapsAtTen() {
    let m = Model()
    m.recentColors = []
    for i in 0..<15 {
        ColorPanel.pushRecentColor(String(format: "#0000%02x", i), model: m)
    }
    #expect(m.recentColors.count == 10)
    #expect(m.recentColors[0] == "#00000e")
}

@Test func pushRecentColorListenerFires() {
    // Use a sentinel hex unlikely to collide with other parallel tests.
    let sentinel = "#abcdef"
    let m = Model()
    m.recentColors = []
    let box = NSMutableArray()  // reference type so the closure mutates a shared array
    ColorPanel.addRecentColorsListener { _, hex in
        if hex == sentinel { box.add(hex) }
    }
    ColorPanel.pushRecentColor(sentinel, model: m)
    #expect(box.count >= 1)
}

// ── Generic panel-menu ENABLED state ──────────────────────────────
//
// The `enabled` half of what `test_fixtures/algorithms/panel_menu_state.json`
// pins, driven through this app's LIVE context rather than a seeded one.
// Until this landed `panelIsEnabled` answered `true` for every panel but
// Color, whose native hook restated a rule color.yaml already states; the
// other forty-odd `enabled_when` rows were never evaluated live in EITHER
// active port. Mirrors the Rust `panel_is_enabled_*` tests.

/// A model whose document holds a layer with a rect at `[0, 0]` — SELECTED on
/// the canvas — and a group at `[0, 1]` for the layers-panel rollups.
private func modelWithOneSelectedRectAndAGroup() -> Model {
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let inner = Element.rect(Rect(x: 20, y: 0, width: 10, height: 10))
    let group = Element.group(Group(children: [inner]))
    let layer = Layer(name: "L0", children: [rect, group])
    let doc = Document(layers: [layer], selection: [ElementSelection.all([0, 0])])
    return Model(document: doc)
}

/// Seed a panel's store scope from its declared defaults and write one key.
private func writePanel(_ model: Model, _ contentId: String, _ key: String, _ value: Any) {
    let store = model.stateStore
    if !store.hasPanel(contentId) {
        store.initPanel(contentId, defaults: WorkspaceData.load()?.panelStateDefaults(contentId) ?? [:])
    }
    store.setPanel(contentId, key, value)
}

@Test func panelIsEnabledEvaluatesTheYamlPredicates() {
    let layout = WorkspaceLayout.defaultLayout()
    let m = Model()

    // brushes.yaml: "New Brush" reads `active_document.has_selection`.
    #expect(!panelIsEnabled(.brushes, cmd: "open_brush_options:create", layout: layout, model: m),
            "New Brush needs a canvas selection")
    // `panel.selected_brushes.length > 0`, from the shared store.
    #expect(!panelIsEnabled(.brushes, cmd: "duplicate_brush", layout: layout, model: m))
    #expect(!panelIsEnabled(.brushes, cmd: "delete_brush", layout: layout, model: m))
    writePanel(m, "brushes_panel_content", "selected_brushes", [0])
    #expect(panelIsEnabled(.brushes, cmd: "duplicate_brush", layout: layout, model: m))
    #expect(panelIsEnabled(.brushes, cmd: "delete_brush", layout: layout, model: m))

    // symbols.yaml / concepts.yaml: `panel.selected_* != null`.
    #expect(!panelIsEnabled(.symbols, cmd: "place_instance", layout: layout, model: m))
    writePanel(m, "symbols_panel_content", "selected_symbol", "star")
    #expect(panelIsEnabled(.symbols, cmd: "place_instance", layout: layout, model: m))
    #expect(!panelIsEnabled(.concepts, cmd: "place_concept_instance", layout: layout, model: m))
    writePanel(m, "concepts_panel_content", "selected_concept", "chair")
    #expect(panelIsEnabled(.concepts, cmd: "place_concept_instance", layout: layout, model: m))

    // layers.yaml: "Exit Isolation Mode" reads `panel.isolation_stack.length`,
    // which this app keeps on the Model.
    #expect(!panelIsEnabled(.layers, cmd: "exit_isolation_mode", layout: layout, model: m))
    m.layersIsolationStack.append([0])
    #expect(panelIsEnabled(.layers, cmd: "exit_isolation_mode", layout: layout, model: m))
    m.layersIsolationStack.removeAll()

    // artboards.yaml: `active_document.artboards_panel_selection_ids.length`,
    // from the scope the artboard verbs write.
    #expect(!panelIsEnabled(.artboards, cmd: "open_artboard_options", layout: layout, model: m))
    writePanel(m, "artboards", "artboards_panel_selection", ["ab-1"])
    #expect(panelIsEnabled(.artboards, cmd: "open_artboard_options", layout: layout, model: m))

    // gradient.yaml: a literal `enabled_when: "false"` is a disabled row.
    #expect(!panelIsEnabled(.gradient, cmd: "gradient_reverse", layout: layout, model: m))

    // No predicate, and no entry at all: enabled — `MenuState`'s default.
    #expect(panelIsEnabled(.brushes, cmd: "select_all_unused_brushes", layout: layout, model: m))
    #expect(panelIsEnabled(.brushes, cmd: "no_such_command", layout: layout, model: m))
    // …and with no model at all, the same defaults.
    #expect(!panelIsEnabled(.brushes, cmd: "open_brush_options:create", layout: layout, model: nil))
    #expect(panelIsEnabled(.brushes, cmd: "no_such_command", layout: layout, model: nil))

    // With a real selection on the canvas: New Brush lights, a mask can be
    // made but not released, and New Symbol's `selection_count == 1`.
    var sel = modelWithOneSelectedRectAndAGroup()
    #expect(panelIsEnabled(.brushes, cmd: "open_brush_options:create", layout: layout, model: sel))
    #expect(panelIsEnabled(.opacity, cmd: "make_opacity_mask", layout: layout, model: sel))
    #expect(!panelIsEnabled(.opacity, cmd: "release_opacity_mask", layout: layout, model: sel))
    #expect(panelIsEnabled(.symbols, cmd: "new_symbol", layout: layout, model: sel))
    // Put a mask on the selection: the four mask rows flip together.
    var opLayout = layout
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    OpacityPanel.dispatch("make_opacity_mask", addr: addr, layout: &opLayout, model: sel)
    #expect(!panelIsEnabled(.opacity, cmd: "make_opacity_mask", layout: layout, model: sel))
    #expect(panelIsEnabled(.opacity, cmd: "release_opacity_mask", layout: layout, model: sel))
    #expect(panelIsEnabled(.opacity, cmd: "disable_opacity_mask", layout: layout, model: sel))
    #expect(panelIsEnabled(.opacity, cmd: "unlink_opacity_mask", layout: layout, model: sel))

    // layers.yaml's rollups over the LAYERS-PANEL selection on that document
    // (runtime_contexts.yaml: is_container = the sole selected item is a group
    // or layer; has_group = any selected item is a group). `[0]` is the layer,
    // `[0, 0]` the rect, `[0, 1]` the group. The selection is read from the
    // store key the tree view mirrors into.
    sel = modelWithOneSelectedRectAndAGroup()
    writePanel(sel, "layers_panel_content", "panel_selection", [[0]])
    #expect(panelIsEnabled(.layers, cmd: "new_group", layout: layout, model: sel))
    #expect(panelIsEnabled(.layers, cmd: "enter_isolation_mode", layout: layout, model: sel),
            "a layer is a container")
    #expect(!panelIsEnabled(.layers, cmd: "flatten_artwork", layout: layout, model: sel),
            "a layer is not a group")
    #expect(panelIsEnabled(.layers, cmd: "collect_in_new_layer", layout: layout, model: sel))
    sel.layersIsolationStack.append([0])
    #expect(!panelIsEnabled(.layers, cmd: "collect_in_new_layer", layout: layout, model: sel),
            "not while isolated: the conjunction's second half")
    sel.layersIsolationStack.removeAll()
    writePanel(sel, "layers_panel_content", "panel_selection", [[0, 0]])
    #expect(!panelIsEnabled(.layers, cmd: "enter_isolation_mode", layout: layout, model: sel),
            "a rect is not a container")
    #expect(!panelIsEnabled(.layers, cmd: "flatten_artwork", layout: layout, model: sel))
    writePanel(sel, "layers_panel_content", "panel_selection", [[0, 1]])
    #expect(panelIsEnabled(.layers, cmd: "enter_isolation_mode", layout: layout, model: sel),
            "a group is a container")
    #expect(panelIsEnabled(.layers, cmd: "flatten_artwork", layout: layout, model: sel),
            "a group is a group")
    writePanel(sel, "layers_panel_content", "panel_selection", [[0, 0], [0, 1]])
    #expect(!panelIsEnabled(.layers, cmd: "enter_isolation_mode", layout: layout, model: sel),
            "two items: not the SOLE selected item")
    #expect(panelIsEnabled(.layers, cmd: "flatten_artwork", layout: layout, model: sel),
            "at least one of them is a group")
    writePanel(sel, "layers_panel_content", "panel_selection", [] as [[Int]])
    #expect(!panelIsEnabled(.layers, cmd: "new_group", layout: layout, model: sel))
}

/// The panels whose enabled state ALREADY worked natively must keep working
/// once the hooks are gone — the generic evaluator has to read the same live
/// values the hooks read (the colour tiers for Color, the store's swatch
/// selection for Swatches), not the bundle defaults.
@Test func panelIsEnabledStillFollowsLiveStateForTheNativePanels() {
    let layout = WorkspaceLayout.defaultLayout()
    let m = Model(document: Document.newEmptyDocument())
    // color.yaml: `if state.fill_on_top then state.fill_color != null else
    // state.stroke_color != null`. A fresh model's app tier holds a fill and a
    // stroke, fill on top.
    m.appDefaultFill = Fill(color: .white)
    m.appDefaultStroke = Stroke(color: .black)
    m.defaultFill = nil
    m.fillOnTop = true
    #expect(panelIsEnabled(.color, cmd: "invert_active_color", layout: layout, model: m))
    #expect(panelIsEnabled(.color, cmd: "complement_active_color", layout: layout, model: m))
    m.appDefaultFill = nil
    #expect(!panelIsEnabled(.color, cmd: "invert_active_color", layout: layout, model: m),
            "no fill in any tier, fill on top: nothing to invert")
    m.fillOnTop = false
    #expect(panelIsEnabled(.color, cmd: "invert_active_color", layout: layout, model: m),
            "stroke on top, and the stroke tier holds black")
    // swatches.yaml: `panel.selected_swatches.length > 0`.
    #expect(!panelIsEnabled(.swatches, cmd: "delete_swatch", layout: layout, model: m))
    #expect(!panelIsEnabled(.swatches, cmd: "duplicate_swatch", layout: layout, model: m))
    writePanel(m, "swatches_panel_content", "selected_swatches", [2])
    #expect(panelIsEnabled(.swatches, cmd: "delete_swatch", layout: layout, model: m))
    #expect(panelIsEnabled(.swatches, cmd: "duplicate_swatch", layout: layout, model: m))
}

/// The namespace reads a panel-menu predicate string makes: every
/// `<head>.<key>` whose head is one of the four namespaces the menu context
/// publishes, plus the bare OPACITY.md selection predicates. The scanner is a
/// receiver assumption, stated: it skips string literals, keeps two segments
/// (`panel.selected_brushes`, not `.length`), and a bare identifier outside
/// the listed five is invisible to it — the reference's own parser censuses
/// bare names in `workspace_interpreter/tests/test_panel_menu_state.py`, so a
/// new one reds there. Mirrors the Rust `predicate_reads`.
private func predicateReads(_ expr: String) -> [String] {
    let heads: Set<String> = ["state", "panel", "active_document", "preferences"]
    let bare: Set<String> = ["selection_has_mask", "selection_mask_clip",
                             "selection_mask_invert", "selection_mask_linked",
                             "editing_target_is_mask"]
    var out: [String] = []
    var inQuote = false
    var ident = ""
    func flush() {
        defer { ident = "" }
        guard !ident.isEmpty else { return }
        let segs = ident.split(separator: ".").map(String.init)
        if segs.count >= 2, heads.contains(segs[0]) {
            out.append("\(segs[0]).\(segs[1])")
        } else if segs.count == 1, bare.contains(segs[0]) {
            out.append(segs[0])
        }
    }
    for c in expr {
        if c == "\"" || c == "'" { flush(); inQuote.toggle(); continue }
        if inQuote { continue }
        if c.isLetter || c.isNumber || c == "_" || c == "." { ident.append(c) } else { flush() }
    }
    flush()
    return out
}

private func ctxHasPath(_ ctx: [String: Any], _ path: String) -> Bool {
    var cur: Any = ctx
    for seg in path.split(separator: ".") {
        guard let obj = cur as? [String: Any], let next = obj[String(seg)] else { return false }
        cur = next
    }
    return true
}

/// Every read a panel-menu predicate makes resolves to a key the LIVE menu
/// context publishes. A key may legitimately be NSNull
/// (`panel.selected_symbol`), so presence is the assertion, not truthiness.
/// The positive control is the read count: a scanner that matched nothing
/// would pass an empty census. Mirrors the Rust
/// `every_panel_menu_predicate_read_is_published_to_the_menu_context`.
@Test func everyPanelMenuPredicateReadIsPublishedToTheMenuContext() {
    guard let ws = WorkspaceData.load(),
          let panels = ws.data["panels"] as? [String: Any] else {
        Issue.record("Failed to load the workspace bundle")
        return
    }
    let layout = WorkspaceLayout.defaultLayout()
    let model = modelWithOneSelectedRectAndAGroup()
    var reads = 0
    var missing: [String] = []
    for (contentId, spec) in panels {
        guard let panel = spec as? [String: Any],
              let menu = panel["menu"] as? [Any] else { continue }
        let ctx = panelMenuContext(contentId, layout: layout, model: model)
        for entry in menu {
            guard let obj = entry as? [String: Any] else { continue }
            for key in ["enabled_when", "checked_when", "checked"] {
                guard let expr = obj[key] as? String else { continue }
                for path in predicateReads(expr) {
                    reads += 1
                    if !ctxHasPath(ctx, path) {
                        missing.append("\(contentId): \(key): \(expr) reads \(path)")
                    }
                }
            }
        }
    }
    #expect(reads >= 40, "positive control: only \(reads) predicate reads found")
    #expect(missing.isEmpty,
            "panel-menu predicate reads the menu context does not publish:\n\(missing.joined(separator: "\n"))")
}
