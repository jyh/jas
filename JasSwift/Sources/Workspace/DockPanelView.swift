/// SwiftUI views for rendering dock panels.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Payload Encoding

// `internal` (default) so the canvas-level drop-to-detach handler in
// ContentView.swift can decode the same payload format the dock-tab
// `.onDrag` modifier writes.
let dockDragUTType = UTType.plainText

func encodeGroupDrag(_ addr: GroupAddr) -> String {
    "group:\(addr.dockId.value):\(addr.groupIdx)"
}

func encodePanelDrag(_ addr: PanelAddr) -> String {
    "panel:\(addr.group.dockId.value):\(addr.group.groupIdx):\(addr.panelIdx)"
}

enum DecodedDrag {
    case group(GroupAddr)
    case panel(PanelAddr)
}

func decodeDrag(_ s: String) -> DecodedDrag? {
    let parts = s.split(separator: ":")
    if parts.count == 3, parts[0] == "group",
       let did = Int(parts[1]), let gi = Int(parts[2]) {
        return .group(GroupAddr(dockId: DockId(did), groupIdx: gi))
    }
    if parts.count == 4, parts[0] == "panel",
       let did = Int(parts[1]), let gi = Int(parts[2]), let pi = Int(parts[3]) {
        return .panel(PanelAddr(group: GroupAddr(dockId: DockId(did), groupIdx: gi), panelIdx: pi))
    }
    return nil
}

// MARK: - Dock Panel View (anchored dock)

public struct DockPanelView: View {
    @Binding var workspaceLayout: WorkspaceLayout
    let dockId: DockId
    let edge: DockEdge
    let theme: Theme
    var model: Model?
    /// Binding used to surface YAML dialogs that open via the
    /// ``open_dialog`` effect (e.g., the Artboard Options Dialogue).
    /// Optional so other call sites that don't care about dialogs
    /// can pass ``.constant(nil)``.
    var yamlDialogState: Binding<YamlDialogState?>? = nil

    private var dock: Dock? { workspaceLayout.dock(dockId) }

    public var body: some View {
        if let dock = dock {
            VStack(spacing: 0) {
                if dock.collapsed {
                    collapsedView(dock)
                } else {
                    expandedView(dock)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SwiftUI.Color(nsColor: theme.paneBg))
        }
    }

    private func collapsedView(_ dock: Dock) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(dock.groups.enumerated()), id: \.offset) { gi, group in
                ForEach(Array(group.panels.enumerated()), id: \.offset) { pi, kind in
                    collapsedIcon(kind: kind, gi: gi, pi: pi)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func collapsedIcon(kind: PanelKind, gi: Int, pi: Int) -> some View {
        let label = panelLabel(kind)
        let first = String(label.prefix(1))
        return Button(first) {
            // toggleDockCollapsed is not in the 15-verb dispatcher vocabulary,
            // so it stays direct; the set_active_panel verb routes through the
            // shared layout-op runtime (OP_LOG 3d-2).
            workspaceLayout.toggleDockCollapsed(dockId)
            layoutApply(&workspaceLayout, opSetActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: gi),
                panelIdx: pi
            )))
            workspaceLayout.saveIfNeeded()
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(SwiftUI.Color(nsColor: theme.textDim))
        .frame(width: 28, height: 28)
        .background(SwiftUI.Color(nsColor: theme.buttonChecked))
        .cornerRadius(3)
        .buttonStyle(.plain)
        .help(label)
    }

    private func expandedView(_ dock: Dock) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(dock.groups.enumerated()), id: \.offset) { gi, group in
                PanelGroupView(
                    workspaceLayout: $workspaceLayout,
                    dockId: dockId,
                    groupIdx: gi,
                    group: group,
                    theme: theme,
                    model: model,
                    yamlDialogState: yamlDialogState
                )
            }
            Spacer()
        }
    }

}

// MARK: - Panel Group View

public struct PanelGroupView: View {
    @Binding var workspaceLayout: WorkspaceLayout
    let dockId: DockId
    let groupIdx: Int
    let group: PanelGroup
    let theme: Theme
    var model: Model?
    /// Binding used to surface YAML dialogs opened via the
    /// ``open_dialog`` effect. Nil when the enclosing dock doesn't
    /// forward one (e.g., the floating-dock variant).
    var yamlDialogState: Binding<YamlDialogState?>? = nil

    public var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                // Grip handle (drag to reorder/detach group)
                SwiftUI.Text(verbatim: "\u{2801}\u{2801}")
                    .font(.system(size: 10))
                    .foregroundColor(SwiftUI.Color(nsColor: theme.textHint))
                    .padding(.horizontal, 4)
                    .onDrag {
                        NSItemProvider(object: encodeGroupDrag(GroupAddr(dockId: dockId, groupIdx: groupIdx)) as NSString)
                    }

                // Tab buttons (drag to reorder/move panels)
                ForEach(Array(group.panels.enumerated()), id: \.offset) { pi, kind in
                    tabButton(pi: pi, kind: kind)
                        .onDrag {
                            NSItemProvider(object: encodePanelDrag(PanelAddr(group: GroupAddr(dockId: dockId, groupIdx: groupIdx), panelIdx: pi)) as NSString)
                        }
                }

                Spacer()

                // Collapse chevron
                chevronButton()

                // Hamburger menu button — hidden when collapsed
                if !group.collapsed, let activeKind = group.activePanel() {
                    hamburgerButton(activeKind: activeKind)
                }
            }
            .frame(maxWidth: .infinity)
            .background(SwiftUI.Color(nsColor: theme.paneBgDark))
            .overlay(alignment: .bottom) {
                Rectangle().fill(SwiftUI.Color(nsColor: theme.border)).frame(height: 1)
            }

            // Panel body
            if !group.collapsed {
                if let kind = group.activePanel() {
                    let contentId = panelKindToContentId(kind)
                    if let ws = WorkspaceData.load(),
                       let content = ws.panelContent(contentId) {
                        // Wrap in a model-observing view so widget
                        // edits (which bump model.panelStateVersion
                        // via commitPanelWrite) trigger a re-render
                        // of the body. Without this the slider's
                        // sibling number_input never refreshes after
                        // the user drags.
                        if let m = model {
                            PanelBodyObserver(
                                model: m,
                                contentSpec: content,
                                panelId: contentId,
                                theme: theme,
                                contextProvider: { buildPanelCtx(ws: ws, contentId: contentId) },
                                yamlDialogState: yamlDialogState
                            )
                        } else {
                            let ctx = buildPanelCtx(ws: ws, contentId: contentId)
                            YamlPanelBodyView(contentSpec: content, context: ctx, model: nil, panelId: contentId, theme: theme)
                        }
                    } else {
                        SwiftUI.Text(verbatim: panelLabel(kind))
                            .font(.system(size: 12))
                            .foregroundColor(SwiftUI.Color(nsColor: theme.textBody))
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                            .padding(12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SwiftUI.Color(nsColor: theme.border)).frame(height: 1)
        }
        .onDrop(of: [dockDragUTType], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    /// Build the evaluation context for a panel body. Ensures the
    /// StateStore has a scope for this panel (seeded from yaml
    /// defaults on first render) and marks it active so `panel.X`
    /// resolves here. When no model is present (unit tests) falls
    /// back to fresh yaml defaults.
    private func buildPanelCtx(ws: WorkspaceData, contentId: String) -> [String: Any] {
        let stateMap = ws.stateDefaults()
        let icons = ws.icons()
        let swatchLibs = ws.swatchLibraries()
        var panelMap: [String: Any]
        if let store = model?.stateStore {
            if !store.hasPanel(contentId) {
                store.initPanel(contentId, defaults: ws.panelStateDefaults(contentId))
            }
            store.setActivePanel(contentId)
            panelMap = store.getPanelState(contentId)
        } else {
            panelMap = ws.panelStateDefaults(contentId)
        }
        // Selection-driven overrides: when a Text / TextPath is
        // selected, the Character panel reflects its attributes rather
        // than the stored panel defaults. Mirrors the Rust dock
        // `build_live_panel_overrides` block.
        if contentId == "character_panel_content", let m = model,
           let overrides = characterPanelLiveOverrides(model: m) {
            for (k, v) in overrides { panelMap[k] = v }
        }
        // Paragraph panel — Phase 3a text-kind gating. Always emits
        // text_selected / area_text_selected (even false / false for
        // an empty selection) so the bind.disabled expressions in
        // paragraph.yaml resolve to the live values rather than the
        // YAML defaults of true.
        if contentId == "paragraph_panel_content", let m = model {
            let overrides = paragraphPanelLiveOverrides(model: m)
            for (k, v) in overrides { panelMap[k] = v }
        }
        // Color panel — sliders / hex must reflect the active color
        // (selection's fill/stroke or tab default), not the stored
        // panel state. Without this, switching to a differently-
        // coloured selection leaves the sliders stuck on the YAML
        // init values from first open. Mirrors the Rust dock's
        // build_live_panel_overrides color block.
        if contentId == "color_panel_content", let m = model,
           let overrides = colorPanelLiveOverrides(model: m) {
            for (k, v) in overrides { panelMap[k] = v }
        }
        // Stroke panel — the Weight field must reflect the selection's
        // stroke width (its baked / effective width after the scale
        // counter-scale work), not the stored panel default. Mirrors the
        // color block above and the Rust dock build_live_panel_overrides
        // stroke block. Display-only: merged into the render scope, never
        // written to the selection, so it can't clobber other stroke props.
        if contentId == "stroke_panel_content", let m = model {
            let overrides = strokePanelLiveOverrides(model: m)
            for (k, v) in overrides { panelMap[k] = v }
        }
        // Properties panel — X/Y/W/H reflect the selection's evaluated
        // bounding box (document space, post-transform), decision-5 Part B.1.
        // Display-only merge into the render scope; never written to the
        // selection. prop_-prefixed keys match properties.yaml.
        if contentId == "properties_panel_content", let m = model {
            let overrides = propertiesPanelLiveOverrides(model: m)
            for (k, v) in overrides { panelMap[k] = v }
        }
        // Render-time layers-panel selection, if the layers panel is
        // currently initialised in the shared store. buildPanelCtx runs
        // for whichever panel is being rendered, so it may not be the
        // layers panel; pass [] when absent — only the selection
        // scalars (has_selection / selection_count / element_selection)
        // are consulted by non-layers bind predicates.
        let layersPanelSelection: [[Int]] = {
            guard let sel = model?.stateStore.getPanel("layers", "layers_panel_selection") as? [[Int]] else {
                return []
            }
            return sel
        }()
        // document namespace — exposes per-document fields the YAML
        // reads but the StateStore has no native source for. Currently
        // just recent_colors, used by panel init expressions (color,
        // swatches) so the recent-color strip seeds with the model's
        // actual recent colors rather than the YAML default of [].
        let documentMap: [String: Any] = [
            "recent_colors": model?.recentColors ?? []
        ]
        // theme.colors namespace — the active theme's colors map.
        // YAML expressions like `style: { color: "{{theme.colors.text}}" }`
        // resolve through this. Without it, panel labels have no
        // explicit foreground color and SwiftUI's default Text color
        // washes out against the dark pane background.
        let themeColors: [String: Any] = {
            guard let theme = ws.theme(),
                  let base = theme["base"] as? [String: Any],
                  let colors = base["colors"] as? [String: Any] else {
                return [:]
            }
            return colors
        }()
        var ctx: [String: Any] = [
            "state": stateMap,
            "panel": panelMap,
            "icons": icons,
            "data": ["swatch_libraries": swatchLibs, "concepts": ws.conceptsList()] as [String: Any],
            "active_document": buildActiveDocumentView(
                model: model,
                layersPanelSelection: layersPanelSelection
            ),
            "document": documentMap,
            "theme": ["colors": themeColors] as [String: Any]
        ]
        // OPACITY.md § States predicates at top level so yaml
        // expressions like `bind.disabled: "!selection_has_mask"` and
        // `bind.checked: "selection_mask_clip"` resolve uniformly.
        // Mirrors `build_selection_predicates` in jas_dioxus.
        for (k, v) in buildSelectionPredicates(model: model) { ctx[k] = v }
        // Expose the Opacity panel's new-mask preferences so the
        // op_make_mask button can read them at click time (they live
        // on WorkspaceLayout.opacityPanel, not in the shared panel
        // store).
        ctx["_opacity_new_masks_clipping"] = workspaceLayout.opacityPanel.newMasksClipping
        ctx["_opacity_new_masks_inverted"] = workspaceLayout.opacityPanel.newMasksInverted
        return ctx
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let decoded = decodeDrag(s) else { return }
            DispatchQueue.main.async {
                let targetGroup = GroupAddr(dockId: dockId, groupIdx: groupIdx)
                switch decoded {
                case .group(let from):
                    // Deferred (OP_LOG 3d-2): the dock GROUP-MOVE verbs
                    // (moveGroupWithinDock / moveGroupToDock) are NOT in the
                    // 15-verb dispatcher vocabulary, so they stay direct.
                    if from.dockId == dockId {
                        workspaceLayout.moveGroupWithinDock(dockId, from: from.groupIdx, to: groupIdx)
                    } else {
                        workspaceLayout.moveGroupToDock(from, toDock: dockId, toIdx: groupIdx)
                    }
                case .panel(let from):
                    // reorder_panel / move_panel_to_group ARE dispatcher verbs;
                    // route through the shared layout-op runtime (OP_LOG 3d-2).
                    if from.group == targetGroup {
                        // Reorder within same group — drop at end
                        layoutApply(&workspaceLayout,
                                    opReorderPanel(targetGroup, from: from.panelIdx, to: group.panels.count))
                    } else {
                        layoutApply(&workspaceLayout, opMovePanelToGroup(from, to: targetGroup))
                    }
                }
                workspaceLayout.saveIfNeeded()
            }
        }
        return true
    }

    private func tabButton(pi: Int, kind: PanelKind) -> some View {
        let isActive = pi == group.active
        let label = panelLabel(kind)
        let bg = isActive ? theme.tabActive : theme.tabInactive
        // SwiftUI's Button consumes the mouse-down phase before
        // .onDrag has a chance to recognize a drag, so attaching
        // .onDrag to a Button silently never fires. Render the tab
        // as a plain Text + onTapGesture; the gesture order
        // (TapGesture < drag) lets .onDrag at the call site work
        // while still treating a click without a drag as a tab
        // selection.
        return SwiftUI.Text(label)
            .font(.system(size: 11, weight: isActive ? .bold : .regular))
            .foregroundColor(SwiftUI.Color(nsColor: theme.text))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SwiftUI.Color(nsColor: bg))
            .contentShape(Rectangle())
            .onTapGesture {
                // OP_LOG 3d-2: route through the shared layout-op runtime.
                layoutApply(&workspaceLayout, opSetActivePanel(PanelAddr(
                    group: GroupAddr(dockId: dockId, groupIdx: groupIdx),
                    panelIdx: pi
                )))
                workspaceLayout.saveIfNeeded()
            }
    }

    private func chevronButton() -> some View {
        // Right-edge dock convention: when expanded, the chevron
        // points toward the dock edge (»); when collapsed, it points
        // away (« — "expand back out"). The previous mapping was
        // inverted, so the arrow looked wrong.
        let label = group.collapsed ? "\u{00AB}" : "\u{00BB}"
        return Button(label) {
            // OP_LOG 3d-2: route through the shared layout-op runtime.
            layoutApply(&workspaceLayout,
                        opToggleGroupCollapsed(GroupAddr(dockId: dockId, groupIdx: groupIdx)))
            workspaceLayout.saveIfNeeded()
        }
        .font(.system(size: 18))
        .foregroundColor(SwiftUI.Color(nsColor: theme.textButton))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .buttonStyle(.plain)
    }

    private func hamburgerButton(activeKind: PanelKind) -> some View {
        let addr = PanelAddr(
            group: GroupAddr(dockId: dockId, groupIdx: groupIdx),
            panelIdx: group.active
        )
        let items = panelMenu(activeKind)
        // Run a menu command, then bridge any store dialog transition
        // to the overlay binding so `open_dialog` effects become a
        // visible modal. Captures the pre-dispatch dialog id on the
        // active model's store and compares against the post-dispatch
        // id; an edge from nil to something triggers the binding
        // update. No-op for models without a store dialog change.
        let capturedModel = model
        let capturedDialog = yamlDialogState
        let dispatchWithDialogBridge: (String) -> Void = { command in
            let beforeDlg = capturedModel?.stateStore.getDialogId()
            panelDispatch(activeKind, cmd: command, addr: addr,
                          layout: &workspaceLayout, model: capturedModel)
            workspaceLayout.saveIfNeeded()
            if let m = capturedModel,
               let binding = capturedDialog,
               m.stateStore.getDialogId() != beforeDlg,
               let newState = yamlDialogStateFromStore(m.stateStore) {
                binding.wrappedValue = newState
            }
        }
        // SwiftUI's `Menu` primitive ignores `foregroundColor` on its
        // label and reserves space for an indicator chevron we can't
        // suppress, so the hamburger came out dark and over-wide
        // (pushing the dock chevron off the edge). Build it from a
        // plain Button that pops an NSMenu programmatically; that
        // gives full control over color and width.
        let capturedKind = activeKind
        let capturedLabelModel = model
        return HamburgerMenuButton(
            items: items,
            color: theme.text,
            // The YAML carries `{{if …}}` label expressions for a few
            // rows (e.g. Layers' Hide/Show All Layers); resolve those at
            // render time, falling back to the static YAML label.
            displayLabel: { cmd, label in
                panelDynamicLabel(capturedKind, cmd: cmd,
                                  model: capturedLabelModel) ?? label
            },
            isChecked: { cmd in
                panelIsChecked(activeKind, cmd: cmd,
                               layout: workspaceLayout, model: model)
            },
            isEnabled: { cmd in
                panelIsEnabled(activeKind, cmd: cmd, model: model)
            },
            onSelect: dispatchWithDialogBridge
        )
    }
}

/// Hamburger menu button used in the panel-group header. Built from
/// a plain SwiftUI Button + native NSMenu so we can force the color
/// (theme.text) and keep the hit area tight to the glyph — SwiftUI's
/// own `Menu` primitive overrode both. The NSMenu is rebuilt on each
/// click so toggle/radio checkmarks reflect the current layout state.
private struct HamburgerMenuButton: View {
    let items: [PanelMenuItem]
    let color: NSColor
    /// Resolve an item's display label from its (command, YAML label).
    /// Lets dynamic `{{if …}}` labels render their resolved text.
    let displayLabel: (String, String) -> String
    let isChecked: (String) -> Bool
    let isEnabled: (String) -> Bool
    let onSelect: (String) -> Void

    var body: some View {
        Button(action: showMenu) {
            SwiftUI.Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SwiftUI.Color(nsColor: color))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showMenu() {
        let menu = NSMenu()
        // Without this, NSMenu auto-enables items whose target
        // responds to the selector and overrides our explicit
        // `isEnabled = false` for disabled commands like Invert /
        // Complement when the active attribute is none.
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .action(let label, let command, _):
                menu.addItem(buildItem(label: displayLabel(command, label),
                                       command: command,
                                       checked: false, enabled: isEnabled(command)))
            case .toggle(let label, let command):
                menu.addItem(buildItem(label: displayLabel(command, label),
                                       command: command,
                                       checked: isChecked(command),
                                       enabled: isEnabled(command)))
            case .radio(let label, let command, _):
                menu.addItem(buildItem(label: displayLabel(command, label),
                                       command: command,
                                       checked: isChecked(command),
                                       enabled: isEnabled(command)))
            case .separator:
                menu.addItem(NSMenuItem.separator())
            }
        }
        // Pop at the current event location so the menu drops below
        // the hamburger button. Falls back to NSApp.currentEvent when
        // the click event isn't directly available.
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    private func buildItem(label: String, command: String,
                           checked: Bool, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(
            title: label,
            action: #selector(MenuActionTarget.fire(_:)),
            keyEquivalent: ""
        )
        let target = MenuActionTarget(callback: { onSelect(command) })
        item.target = target
        item.representedObject = target  // retain
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }
}

/// Retained target for NSMenuItem callbacks — NSMenuItem holds a weak
/// `target`, so without an external owner the action target would
/// deallocate before the click fires. Stored in `representedObject`
/// to extend its lifetime to the menu's.
private final class MenuActionTarget: NSObject {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func fire(_ sender: Any) { callback() }
}

// MARK: - Floating Dock View

public struct FloatingDockView: View {
    @Binding var workspaceLayout: WorkspaceLayout
    let floatingDock: FloatingDock
    let theme: Theme
    var model: Model?
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    public var body: some View {
        let fid = floatingDock.dock.id
        let x = floatingDock.x + (isDragging ? Double(dragOffset.width) : 0)
        let y = floatingDock.y + (isDragging ? Double(dragOffset.height) : 0)
        let w = floatingDock.dock.width
        let zIdx = workspaceLayout.zIndexFor(fid)

        VStack(spacing: 0) {
            // Title bar
            HStack {
                Spacer()
            }
            .frame(height: 20)
            .background(SwiftUI.Color(nsColor: theme.titleBarBg))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = .zero
                        workspaceLayout.setFloatingPosition(fid,
                            x: floatingDock.x + Double(value.translation.width),
                            y: floatingDock.y + Double(value.translation.height))
                        workspaceLayout.saveIfNeeded()
                    }
            )
            .onTapGesture(count: 2) {
                // OP_LOG 3d-2: route through the shared layout-op runtime.
                layoutApply(&workspaceLayout, opRedock(fid))
                workspaceLayout.saveIfNeeded()
            }

            // Panel groups
            ForEach(Array(floatingDock.dock.groups.enumerated()), id: \.offset) { gi, group in
                PanelGroupView(
                    workspaceLayout: $workspaceLayout,
                    dockId: fid,
                    groupIdx: gi,
                    group: group,
                    theme: theme,
                    model: model
                )
            }
        }
        .frame(width: w)
        .background(SwiftUI.Color(nsColor: theme.paneBg))
        .cornerRadius(4)
        .shadow(color: .black.opacity(0.2), radius: 6, x: 2, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(SwiftUI.Color.gray.opacity(0.4), lineWidth: 1))
        .position(x: x + w / 2, y: y + 50)
        .zIndex(Double(900 + zIdx))
        .onTapGesture {
            workspaceLayout.bringToFront(fid)
            workspaceLayout.saveIfNeeded()
        }
    }
}

/// Wraps `YamlPanelBodyView` with `@ObservedObject` model so widget
/// writes that bump `model.panelStateVersion` re-render the body —
/// otherwise a slider's sibling number_input wouldn't refresh after
/// the user drags. Rebuilds the eval context on every render so the
/// new panel state is reflected in `bind.value` lookups.
private struct PanelBodyObserver: View {
    @ObservedObject var model: Model
    let contentSpec: [String: Any]
    let panelId: String
    let theme: Theme
    let contextProvider: () -> [String: Any]
    /// Forwarded from PanelGroupView so a widget-level `open_dialog`
    /// effect (e.g., double-clicking a library swatch) can copy the
    /// store dialog state into the SwiftUI overlay binding owned by
    /// ContentView. Mirrors the menu-path bridge in
    /// ``PanelGroupView/hamburgerButton``.
    var yamlDialogState: Binding<YamlDialogState?>? = nil

    var body: some View {
        // Read panelStateVersion so SwiftUI re-evaluates this view
        // whenever a widget commits a panel-state write.
        _ = model.panelStateVersion
        let ctx = contextProvider()
        let capturedModel = model
        let capturedDialog = yamlDialogState
        let onStoreDialogOpened: (CGPoint?) -> Void = { anchor in
            if let binding = capturedDialog,
               var newState = yamlDialogStateFromStore(capturedModel.stateStore) {
                // Panel-opened dialogs are modal (anchor is nil here);
                // the field is carried through for type parity with the
                // toolbar long-press path.
                newState.anchor = anchor
                binding.wrappedValue = newState
            }
        }
        return YamlPanelBodyView(
            contentSpec: contentSpec, context: ctx,
            model: model, panelId: panelId, theme: theme,
            onStoreDialogOpened: onStoreDialogOpened
        )
    }
}

// MARK: - Canvas-level drop-to-detach

/// SwiftUI DropDelegate bound to the canvas root. Catches dock-tab /
/// dock-grip drags that release outside any dock area and converts the
/// drop into a detach-into-floating-dock at the cursor position.
///
/// The dock's own `.onDrop` handles tab-into-tab reordering and group
/// movement; this delegate fires only when the drop lands on the
/// canvas (an area with no dock-side drop handler), giving the
/// "drag a tab onto the canvas to float it" gesture.
struct DockDetachDropDelegate: DropDelegate {
    @Binding var workspaceLayout: WorkspaceLayout

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [dockDragUTType])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [dockDragUTType]).first else {
            return false
        }
        let location = info.location
        // Capture a binding to the workspace layout so the async
        // load-completion handler can mutate it back on the main
        // thread; SwiftUI bindings are not thread-safe.
        let layoutBinding = $workspaceLayout
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let payload = item as? String,
                  let decoded = decodeDrag(payload) else { return }
            DispatchQueue.main.async {
                // Deferred (OP_LOG 3d-2, mirrors the Rust detach deferral): the
                // detach verbs are NOT routed through `layoutApply` here.
                // `detachGroup` returns the new floating-dock id (which the
                // edge-snap path consumes in the Rust reference), and the
                // dispatcher arm discards that return; promoting it would need an
                // op-return pattern, so it stays direct with the drag sites.
                // `detachPanel` is intentionally not a dispatcher verb at all.
                switch decoded {
                case .panel(let addr):
                    _ = layoutBinding.wrappedValue.detachPanel(
                        addr, x: Double(location.x), y: Double(location.y))
                case .group(let addr):
                    _ = layoutBinding.wrappedValue.detachGroup(
                        addr, x: Double(location.x), y: Double(location.y))
                }
            }
        }
        return true
    }
}
