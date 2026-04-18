/// SwiftUI views for rendering dock panels.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag Payload Encoding

private let dockDragUTType = UTType.plainText

private func encodeGroupDrag(_ addr: GroupAddr) -> String {
    "group:\(addr.dockId.value):\(addr.groupIdx)"
}

private func encodePanelDrag(_ addr: PanelAddr) -> String {
    "panel:\(addr.group.dockId.value):\(addr.group.groupIdx):\(addr.panelIdx)"
}

private enum DecodedDrag {
    case group(GroupAddr)
    case panel(PanelAddr)
}

private func decodeDrag(_ s: String) -> DecodedDrag? {
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
            workspaceLayout.toggleDockCollapsed(dockId)
            workspaceLayout.setActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: gi),
                panelIdx: pi
            ))
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
                    model: model
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
                        let ctx = buildPanelCtx(ws: ws, contentId: contentId)
                        YamlPanelBodyView(contentSpec: content, context: ctx, model: model, panelId: contentId)
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
        if contentId == "character_panel", let m = model,
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
        return [
            "state": stateMap,
            "panel": panelMap,
            "icons": icons,
            "data": ["swatch_libraries": swatchLibs] as [String: Any]
        ]
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let decoded = decodeDrag(s) else { return }
            DispatchQueue.main.async {
                let targetGroup = GroupAddr(dockId: dockId, groupIdx: groupIdx)
                switch decoded {
                case .group(let from):
                    if from.dockId == dockId {
                        workspaceLayout.moveGroupWithinDock(dockId, from: from.groupIdx, to: groupIdx)
                    } else {
                        workspaceLayout.moveGroupToDock(from, toDock: dockId, toIdx: groupIdx)
                    }
                case .panel(let from):
                    if from.group == targetGroup {
                        // Reorder within same group — drop at end
                        workspaceLayout.reorderPanel(targetGroup, from: from.panelIdx, to: group.panels.count)
                    } else {
                        workspaceLayout.movePanelToGroup(from, to: targetGroup)
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
        return Button(label) {
            workspaceLayout.setActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: groupIdx),
                panelIdx: pi
            ))
            workspaceLayout.saveIfNeeded()
        }
        .font(.system(size: 11, weight: isActive ? .bold : .regular))
        .foregroundColor(SwiftUI.Color(nsColor: theme.text))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SwiftUI.Color(nsColor: bg))
        .buttonStyle(.plain)
    }

    private func chevronButton() -> some View {
        let label = group.collapsed ? "\u{00BB}" : "\u{00AB}"
        return Button(label) {
            workspaceLayout.toggleGroupCollapsed(GroupAddr(dockId: dockId, groupIdx: groupIdx))
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
        return Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .action(let label, let command, _):
                    Button(label) {
                        panelDispatch(activeKind, cmd: command, addr: addr, layout: &workspaceLayout, model: model)
                        workspaceLayout.saveIfNeeded()
                    }
                case .toggle(let label, let command):
                    let checked = panelIsChecked(activeKind, cmd: command, layout: workspaceLayout)
                    Button {
                        panelDispatch(activeKind, cmd: command, addr: addr, layout: &workspaceLayout, model: model)
                        workspaceLayout.saveIfNeeded()
                    } label: {
                        if checked {
                            SwiftUI.Label(label, systemImage: "checkmark")
                        } else {
                            SwiftUI.Text(label)
                        }
                    }
                case .radio(let label, let command, _):
                    let selected = panelIsChecked(activeKind, cmd: command, layout: workspaceLayout)
                    Button {
                        panelDispatch(activeKind, cmd: command, addr: addr, layout: &workspaceLayout, model: model)
                        workspaceLayout.saveIfNeeded()
                    } label: {
                        if selected {
                            SwiftUI.Label(label, systemImage: "checkmark")
                        } else {
                            SwiftUI.Text(label)
                        }
                    }
                case .separator:
                    Divider()
                }
            }
        } label: {
            SwiftUI.Text(verbatim: "\u{2261}")
                .font(.system(size: 18))
                .foregroundColor(SwiftUI.Color(nsColor: theme.textButton))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
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
                workspaceLayout.redock(fid)
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
