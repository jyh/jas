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
    @Binding var dockLayout: DockLayout
    let dockId: DockId
    let edge: DockEdge

    private var dock: Dock? { dockLayout.dock(dockId) }

    public var body: some View {
        if let dock = dock {
            let width = dock.collapsed ? 36.0 : dock.width
            VStack(spacing: 0) {
                if dock.collapsed {
                    collapsedView(dock)
                } else {
                    expandedView(dock)
                }
            }
            .frame(width: width)
            .background(SwiftUI.Color(nsColor: NSColor(red: 0.235, green: 0.235, blue: 0.235, alpha: 1.0))) // #3c3c3c
            .overlay(alignment: edge == .right ? .leading : .trailing) {
                Rectangle().fill(SwiftUI.Color(nsColor: NSColor(white: 0.33, alpha: 1.0))).frame(width: 1) // #555
            }
        }
    }

    private func collapsedView(_ dock: Dock) -> some View {
        VStack(spacing: 2) {
            collapseToggle()
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
        let label = DockLayout.panelLabel(kind)
        let first = String(label.prefix(1))
        return Button(first) {
            dockLayout.toggleDockCollapsed(dockId)
            dockLayout.setActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: gi),
                panelIdx: pi
            ))
            dockLayout.saveIfNeeded()
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.6, alpha: 1.0))) // #999
        .frame(width: 28, height: 28)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.314, alpha: 1.0))) // #505050
        .cornerRadius(3)
        .buttonStyle(.plain)
        .help(label)
    }

    private func expandedView(_ dock: Dock) -> some View {
        VStack(spacing: 0) {
            collapseToggle()
            ForEach(Array(dock.groups.enumerated()), id: \.offset) { gi, group in
                PanelGroupView(
                    dockLayout: $dockLayout,
                    dockId: dockId,
                    groupIdx: gi,
                    group: group
                )
            }
            Spacer()
        }
    }

    private func collapseToggle() -> some View {
        let isCollapsed = dock?.collapsed ?? false
        let label = isCollapsed ? "\u{25C0}" : "\u{25B6}"
        return Button(label) {
            dockLayout.toggleDockCollapsed(dockId)
            dockLayout.saveIfNeeded()
        }
        .font(.system(size: 10))
        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.53, alpha: 1.0))) // #888
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SwiftUI.Color(nsColor: NSColor(white: 0.33, alpha: 1.0))).frame(height: 1)
        }
    }
}

// MARK: - Panel Group View

public struct PanelGroupView: View {
    @Binding var dockLayout: DockLayout
    let dockId: DockId
    let groupIdx: Int
    let group: PanelGroup

    public var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                // Grip handle (drag to reorder/detach group)
                SwiftUI.Text(verbatim: "\u{2801}\u{2801}")
                    .font(.system(size: 10))
                    .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.47, alpha: 1.0))) // #777
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
            }
            .background(SwiftUI.Color(nsColor: NSColor(white: 0.2, alpha: 1.0))) // #333
            .overlay(alignment: .bottom) {
                Rectangle().fill(SwiftUI.Color(nsColor: NSColor(white: 0.33, alpha: 1.0))).frame(height: 1) // #555
            }

            // Panel body (placeholder)
            if !group.collapsed {
                if let kind = group.activePanel() {
                    SwiftUI.Text(verbatim: DockLayout.panelLabel(kind))
                        .font(.system(size: 12))
                        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.67, alpha: 1.0))) // #aaa
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                        .padding(12)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SwiftUI.Color(nsColor: NSColor(white: 0.33, alpha: 1.0))).frame(height: 1) // #555
        }
        .onDrop(of: [dockDragUTType], isTargeted: nil) { providers in
            handleDrop(providers)
        }
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
                        dockLayout.moveGroupWithinDock(dockId, from: from.groupIdx, to: groupIdx)
                    } else {
                        dockLayout.moveGroupToDock(from, toDock: dockId, toIdx: groupIdx)
                    }
                case .panel(let from):
                    if from.group == targetGroup {
                        // Reorder within same group — drop at end
                        dockLayout.reorderPanel(targetGroup, from: from.panelIdx, to: group.panels.count)
                    } else {
                        dockLayout.movePanelToGroup(from, to: targetGroup)
                    }
                }
                dockLayout.saveIfNeeded()
            }
        }
        return true
    }

    private func tabButton(pi: Int, kind: PanelKind) -> some View {
        let isActive = pi == group.active
        let label = DockLayout.panelLabel(kind)
        let bg = isActive ? NSColor(white: 0.29, alpha: 1.0) : NSColor(white: 0.21, alpha: 1.0) // #4a4a4a / #353535
        return Button(label) {
            dockLayout.setActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: groupIdx),
                panelIdx: pi
            ))
            dockLayout.saveIfNeeded()
        }
        .font(.system(size: 11, weight: isActive ? .bold : .regular))
        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.8, alpha: 1.0))) // #ccc
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SwiftUI.Color(nsColor: bg))
        .buttonStyle(.plain)
    }

    private func chevronButton() -> some View {
        let label = group.collapsed ? "\u{25BC}" : "\u{25B2}"
        return Button(label) {
            dockLayout.toggleGroupCollapsed(GroupAddr(dockId: dockId, groupIdx: groupIdx))
            dockLayout.saveIfNeeded()
        }
        .font(.system(size: 9))
        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.53, alpha: 1.0))) // #888
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .buttonStyle(.plain)
    }
}

// MARK: - Floating Dock View

public struct FloatingDockView: View {
    @Binding var dockLayout: DockLayout
    let floatingDock: FloatingDock
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    public var body: some View {
        let fid = floatingDock.dock.id
        let x = floatingDock.x + (isDragging ? Double(dragOffset.width) : 0)
        let y = floatingDock.y + (isDragging ? Double(dragOffset.height) : 0)
        let w = floatingDock.dock.width
        let zIdx = dockLayout.zIndexFor(fid)

        VStack(spacing: 0) {
            // Title bar
            HStack {
                Spacer()
            }
            .frame(height: 20)
            .background(SwiftUI.Color(nsColor: NSColor(white: 0.81, alpha: 1.0)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = .zero
                        dockLayout.setFloatingPosition(fid,
                            x: floatingDock.x + Double(value.translation.width),
                            y: floatingDock.y + Double(value.translation.height))
                        dockLayout.saveIfNeeded()
                    }
            )
            .onTapGesture(count: 2) {
                dockLayout.redock(fid)
                dockLayout.saveIfNeeded()
            }

            // Panel groups
            ForEach(Array(floatingDock.dock.groups.enumerated()), id: \.offset) { gi, group in
                PanelGroupView(
                    dockLayout: $dockLayout,
                    dockId: fid,
                    groupIdx: gi,
                    group: group
                )
            }
        }
        .frame(width: w)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.94, alpha: 1.0)))
        .cornerRadius(4)
        .shadow(color: .black.opacity(0.2), radius: 6, x: 2, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(SwiftUI.Color.gray.opacity(0.4), lineWidth: 1))
        .position(x: x + w / 2, y: y + 50)
        .zIndex(Double(900 + zIdx))
        .onTapGesture {
            dockLayout.bringToFront(fid)
            dockLayout.saveIfNeeded()
        }
    }
}
