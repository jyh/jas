/// SwiftUI views for rendering dock panels.

import SwiftUI

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
            .background(SwiftUI.Color(nsColor: NSColor(white: 0.94, alpha: 1.0)))
            .overlay(alignment: edge == .right ? .leading : .trailing) {
                Rectangle().fill(SwiftUI.Color.gray.opacity(0.3)).frame(width: 1)
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
        .foregroundColor(.gray)
        .frame(width: 28, height: 28)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.88, alpha: 1.0)))
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
        .foregroundColor(.gray)
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SwiftUI.Color.gray.opacity(0.3)).frame(height: 1)
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
                // Grip handle
                SwiftUI.Text(verbatim: "\u{2801}\u{2801}")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)

                // Tab buttons
                ForEach(Array(group.panels.enumerated()), id: \.offset) { pi, kind in
                    tabButton(pi: pi, kind: kind)
                }

                Spacer()

                // Collapse chevron
                chevronButton()
            }
            .background(SwiftUI.Color(nsColor: NSColor(white: 0.85, alpha: 1.0)))
            .overlay(alignment: .bottom) {
                Rectangle().fill(SwiftUI.Color.gray.opacity(0.3)).frame(height: 1)
            }

            // Panel body (placeholder)
            if !group.collapsed {
                if let kind = group.activePanel() {
                    SwiftUI.Text(verbatim: DockLayout.panelLabel(kind))
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                        .padding(12)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SwiftUI.Color.gray.opacity(0.2)).frame(height: 1)
        }
    }

    private func tabButton(pi: Int, kind: PanelKind) -> some View {
        let isActive = pi == group.active
        let label = DockLayout.panelLabel(kind)
        let bg = isActive ? NSColor(white: 0.94, alpha: 1.0) : NSColor(white: 0.85, alpha: 1.0)
        return Button(label) {
            dockLayout.setActivePanel(PanelAddr(
                group: GroupAddr(dockId: dockId, groupIdx: groupIdx),
                panelIdx: pi
            ))
            dockLayout.saveIfNeeded()
        }
        .font(.system(size: 11, weight: isActive ? .bold : .regular))
        .foregroundColor(.primary)
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
        .foregroundColor(.gray)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .buttonStyle(.plain)
    }
}
