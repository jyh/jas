import Foundation

/// Swatches panel menu definition.
///
/// Mirrors `workspace/panels/swatches.yaml`'s `menu:` section. Each
/// entry maps to a YAML action (in `actions.yaml`) which is dispatched
/// through `runYamlActionByName` — the shared effects pipeline opens
/// dialogs, writes panel state, etc. The Swift menu hardcodes the
/// labels and the params (e.g. {size: small}) because PanelMenuItem
/// can't carry arbitrary param maps yet; per-variant commands keep
/// the wiring contained until that refactor lands.

public enum SwatchesPanel {
    /// Source of truth is workspace/panels/swatches.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    ///
    /// The three thumbnail-size rows share `action:
    /// set_swatch_thumbnail_size`, so the builder folds each `params.size`
    /// into the command (`set_swatch_thumbnail_size:small`, …) — `dispatch`
    /// splits that suffix back off. The "Open Swatch Library" dynamic submenu carries an explicit `action:
    /// open_swatch_library` in the YAML; the menu view renders it as a
    /// plain item whose dispatch is the placeholder below until the
    /// library-load plumbing lands.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("swatches_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        if cmd == "close_panel" { layoutApply(&layout, opClosePanel(addr)); return }
        guard let model = model else { return }
        // Thumbnail-size radio arrives param-folded from the generic menu
        // builder (`set_swatch_thumbnail_size:small`); split the value
        // back off and run the underlying YAML action.
        if let size = strip(cmd, prefix: "set_swatch_thumbnail_size:") {
            runYamlActionByName("set_swatch_thumbnail_size", params: ["size": size], model: model)
            return
        }
        switch cmd {
        case "open_swatch_options":
            // The menu variant edits the first selected swatch. Without a
            // selection it is a no-op in the YAML
            // (`enabled_when: panel.selected_swatches.length > 0`), so we
            // pass mode=edit and let the dialog read the selection from
            // panel state.
            runYamlActionByName("open_swatch_options", params: ["mode": "edit"], model: model)
        case "open_swatch_library":
            // Dynamic library submenu host — placeholder until the
            // library-load plumbing lands (mirrors the Rust reference's
            // open_swatch_library no-op).
            break
        // The five verbs that MUTATE a library or the selection. They were
        // reaching `default:` below, whose YAML effects are a bare `- log:`,
        // so all five were silent no-ops against working jas_dioxus verbs.
        case "sort_swatches_by_name", "select_all_unused_swatches",
             "add_used_colors", "delete_swatch", "duplicate_swatch":
            dispatchSwatchAction(cmd, model: model)
        default:
            runYamlActionByName(cmd, params: [:], model: model)
        }
    }

    private static func strip(_ s: String, prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
}

/// Run a YAML-defined action by name, looking up its effects in the
/// workspace actions catalog and dispatching them through the shared
/// pipeline. Sets the active panel id so panel-scoped writes (and
/// dialog opens) target the right state container. Uses the same
/// platform-effects registry as canvas-button clicks
/// (`alignPlatformEffects`, which despite the name covers Align,
/// Boolean, snapshot, etc.) so menu-driven actions take the same
/// `- snapshot` and platform-op steps a button click would — without
/// this, hamburger-menu "Make Compound Shape" mutated the doc but
/// never pushed an undo entry.
public func runYamlActionByName(_ name: String, params: [String: Any], model: Model) {
    guard let ws = WorkspaceData.load() else { return }
    let actions = ws.data["actions"] as? [String: Any]
    guard let actionDef = actions?[name] as? [String: Any],
          let effects = actionDef["effects"] as? [Any] else { return }
    let store = model.stateStore
    var ctx: [String: Any] = ws.stateDefaults()
    // Declared param defaults under the caller's params, same law as the other
    // two generic dispatchers (``LayersPanel/dispatchYamlAction``, the panel
    // body's `dispatchYamlAction`) and as Rust's `dispatch_action`. Stated once
    // in ``mergeDeclaredParamDefaults``.
    ctx["param"] = mergeDeclaredParamDefaults(params, actionDef: actionDef)
    let dialogs = ws.data["dialogs"] as? [String: Any]
    let platformEffects = alignPlatformEffects(model: model)
    runEffects(effects, ctx: ctx, store: store,
               actions: actions, dialogs: dialogs,
               platformEffects: platformEffects)
    model.panelStateVersion &+= 1
}

// MARK: - The five mutating verbs (council O1.3, 2026-07-30)

extension SwatchesPanel {

    /// Every colour used as a fill or stroke anywhere in the document, as
    /// lowercase hex WITHOUT the `#`.
    ///
    /// Mirrors jas_dioxus's `collect_document_colors` / `walk_element`: fills
    /// and strokes only, recursing through containers. The normalization is
    /// load-bearing — a swatch declares `"#FF0000"` and an element carries a
    /// Color, so both sides must reduce to one spelling or nothing ever matches.
    static func documentColors(_ doc: Document) -> Set<String> {
        var out: Set<String> = []
        func walk(_ el: Element) {
            if let f = el.fill { out.insert(normalizeHex(f.color.toHex())) }
            if let s = el.stroke { out.insert(normalizeHex(s.color.toHex())) }
            switch el {
            case .group(let g): for c in g.children { walk(c) }
            case .layer(let l): for c in l.children { walk(c) }
            default: break
            }
        }
        for layer in doc.layers { walk(.layer(layer)) }
        return out
    }

    static func normalizeHex(_ s: String) -> String {
        var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        h = h.lowercased()
        return h
    }

    /// The five verbs jas_dioxus implements natively in
    /// `panels/swatches_panel.rs` and JasSwift answered with a `- log:`.
    ///
    /// `internal` rather than `private` so `SwatchesPanelActionTests` can drive
    /// them without rendering a panel — the same reason `layersTypeValue` sits
    /// at module scope.
    static func dispatchSwatchAction(_ cmd: String, model: Model) {
        let store = model.stateStore
        let libId = (store.getPanel("swatches_panel_content", "selected_library")
                     as? String) ?? ""
        let selected = (store.getPanel("swatches_panel_content", "selected_swatches")
                        as? [Int]) ?? []
        guard var swatches = model.swatchLibraries.swatches(of: libId) else { return }

        func setSelection(_ v: [Int]) {
            store.setPanel("swatches_panel_content", "selected_swatches", v)
        }

        switch cmd {
        case "sort_swatches_by_name":
            // CASE-SENSITIVE ASCII, matching Rust's `na.cmp(nb)`. Swift's `<`
            // on String agrees for ASCII; `localizedCompare` would not, and
            // would look more correct while diverging.
            swatches.sort { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }
            model.swatchLibraries.setSwatches(swatches, of: libId)
            // Indices no longer point at the same swatch.
            setSelection([])

        case "select_all_unused_swatches":
            let used = documentColors(model.document)
            var unused: [Int] = []
            for (i, sw) in swatches.enumerated() {
                let hex = normalizeHex((sw["color"] as? String) ?? "")
                if !used.contains(hex) { unused.append(i) }
            }
            setSelection(unused)

        case "add_used_colors":
            let used = documentColors(model.document)
            let existing = Set(swatches.map { normalizeHex(($0["color"] as? String) ?? "") })
            // Sorted, so the appended order is deterministic across runs and
            // across ports — Rust sorts the hex set for the same reason.
            for hex in used.sorted() {
                guard !existing.contains(hex), hex.count == 6,
                      let r = UInt8(hex.prefix(2), radix: 16),
                      let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                      let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
                else { continue }
                swatches.append([
                    "name": "R=\(r) G=\(g) B=\(b)",
                    "color": "#\(hex)",
                    "color_mode": "rgb",
                    "color_type": "process",
                    "global": false,
                ])
            }
            model.swatchLibraries.setSwatches(swatches, of: libId)

        case "delete_swatch":
            // DESCENDING, so an earlier removal cannot shift a later index.
            // The bounds check is not defensive padding: Rust launders a
            // negative i64 into a huge usize that fails its own check, while
            // Swift's Int does not wrap — the same input would reach
            // `remove(at:)` and TRAP. A divergence there is a crash, not a
            // wrong answer.
            for idx in selected.sorted(by: >) where idx >= 0 && idx < swatches.count {
                swatches.remove(at: idx)
            }
            model.swatchLibraries.setSwatches(swatches, of: libId)
            setSelection([])

        case "duplicate_swatch":
            // ASCENDING with a running offset: each insert shifts every later
            // original by one.
            var offset = 0
            var newSelection: [Int] = []
            for orig in selected.sorted() where orig >= 0 {
                let pos = orig + offset
                guard pos < swatches.count else { continue }
                var copy = swatches[pos]
                copy["name"] = "\((copy["name"] as? String) ?? "") copy"
                swatches.insert(copy, at: pos + 1)
                newSelection.append(pos + 1)
                offset += 1
            }
            model.swatchLibraries.setSwatches(swatches, of: libId)
            setSelection(newSelection)

        default:
            return
        }
        // The panel reads its rows through the render context, so a mutation
        // is invisible until the panel-state version moves.
        model.panelStateVersion += 1
    }
}
