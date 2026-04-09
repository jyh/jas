/// Dock and panel infrastructure.
///
/// A `DockLayout` manages multiple docks: anchored docks snapped to screen
/// edges and floating docks at arbitrary positions. Each `Dock` contains a
/// vertical list of `PanelGroup`s. Each group has tabbed `PanelKind`
/// entries, one of which is active at a time.
///
/// This file contains only pure data types and state operations — no
/// rendering code.

import Foundation

// MARK: - Constants

public let minDockWidth: Double = 150.0
public let maxDockWidth: Double = 500.0
public let minGroupHeight: Double = 40.0
public let minCanvasWidth: Double = 200.0
public let defaultDockWidth: Double = 240.0
public let defaultFloatingWidth: Double = 220.0
public let snapDistance: Double = 20.0
public let defaultLayoutName = "Default"

/// Current layout format version. Saved layouts with a different version
/// are rejected and replaced with the default layout.
public let layoutVersion: Int = 1

// MARK: - Core Types

public struct DockId: Hashable, Codable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public enum DockEdge: Hashable, Codable {
    case left, right, bottom
}

public enum PanelKind: Hashable, Codable {
    case layers, color, stroke, properties
}

public struct PanelGroup: Codable {
    public var panels: [PanelKind]
    public var active: Int
    public var collapsed: Bool
    public var height: Double?

    public init(panels: [PanelKind]) {
        self.panels = panels
        self.active = 0
        self.collapsed = false
        self.height = nil
    }

    public func activePanel() -> PanelKind? {
        guard active < panels.count else { return nil }
        return panels[active]
    }
}

public struct Dock: Codable {
    public var id: DockId
    public var groups: [PanelGroup]
    public var collapsed: Bool
    public var autoHide: Bool
    public var width: Double
    public var minWidth: Double

    init(id: DockId, groups: [PanelGroup], width: Double) {
        self.id = id
        self.groups = groups
        self.collapsed = false
        self.autoHide = false
        self.width = width
        self.minWidth = minDockWidth
    }
}

public struct FloatingDock: Codable {
    public var dock: Dock
    public var x: Double
    public var y: Double
}

// MARK: - Addressing

public struct GroupAddr: Equatable, Codable {
    public var dockId: DockId
    public var groupIdx: Int

    public init(dockId: DockId, groupIdx: Int) {
        self.dockId = dockId
        self.groupIdx = groupIdx
    }
}

public struct PanelAddr: Equatable, Codable {
    public var group: GroupAddr
    public var panelIdx: Int

    public init(group: GroupAddr, panelIdx: Int) {
        self.group = group
        self.panelIdx = panelIdx
    }
}

// MARK: - Drag State Types

public enum DragPayload: Equatable {
    case group(GroupAddr)
    case panel(PanelAddr)
}

public enum DropTarget: Equatable {
    case groupSlot(dockId: DockId, groupIdx: Int)
    case tabBar(group: GroupAddr, index: Int)
    case edge(DockEdge)
}

// MARK: - AppConfig

public struct AppConfig: Codable {
    public var activeLayout: String
    public var savedLayouts: [String]

    public static let storageKey = "jas_app_config"

    public init() {
        self.activeLayout = defaultLayoutName
        self.savedLayouts = [defaultLayoutName]
    }

    public init(activeLayout: String, savedLayouts: [String]) {
        self.activeLayout = activeLayout
        self.savedLayouts = savedLayouts
    }

    public func toJson() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJson(_ json: String) -> AppConfig {
        guard let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    public mutating func registerLayout(_ name: String) {
        if !savedLayouts.contains(name) {
            savedLayouts.append(name)
        }
    }

    public func save() {
        if let json = toJson() {
            UserDefaults.standard.set(json, forKey: AppConfig.storageKey)
        }
    }

    public static func load() -> AppConfig {
        guard let json = UserDefaults.standard.string(forKey: AppConfig.storageKey) else {
            return AppConfig()
        }
        return fromJson(json)
    }
}

// MARK: - DockLayout

public struct DockLayout: Codable {
    public var version: Int
    public var name: String
    public var anchored: [(DockEdge, Dock)]
    public var floating: [FloatingDock]
    public var hiddenPanels: [PanelKind]
    public var zOrder: [DockId]
    public var focusedPanel: PanelAddr?
    public var paneLayout: PaneLayout?
    var nextId: Int
    // Generation tracking (not serialized)
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0

    private enum CodingKeys: String, CodingKey {
        case version, name, anchored, floating, hiddenPanels, zOrder, focusedPanel, paneLayout, nextId
    }

    // Custom Codable for tuple array
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        name = try container.decode(String.self, forKey: .name)
        let anchoredPairs = try container.decode([AnchoredEntry].self, forKey: .anchored)
        anchored = anchoredPairs.map { ($0.edge, $0.dock) }
        floating = try container.decode([FloatingDock].self, forKey: .floating)
        hiddenPanels = try container.decode([PanelKind].self, forKey: .hiddenPanels)
        zOrder = try container.decode([DockId].self, forKey: .zOrder)
        focusedPanel = try container.decodeIfPresent(PanelAddr.self, forKey: .focusedPanel)
        paneLayout = try container.decodeIfPresent(PaneLayout.self, forKey: .paneLayout)
        nextId = try container.decode(Int.self, forKey: .nextId)
        generation = 0
        savedGeneration = 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        let anchoredPairs = anchored.map { AnchoredEntry(edge: $0.0, dock: $0.1) }
        try container.encode(anchoredPairs, forKey: .anchored)
        try container.encode(floating, forKey: .floating)
        try container.encode(hiddenPanels, forKey: .hiddenPanels)
        try container.encode(zOrder, forKey: .zOrder)
        try container.encodeIfPresent(focusedPanel, forKey: .focusedPanel)
        try container.encodeIfPresent(paneLayout, forKey: .paneLayout)
        try container.encode(nextId, forKey: .nextId)
    }

    private struct AnchoredEntry: Codable {
        let edge: DockEdge
        let dock: Dock
    }

    // MARK: - Construction

    public static func defaultLayout() -> DockLayout {
        named(defaultLayoutName)
    }

    public static func named(_ name: String) -> DockLayout {
        DockLayout(
            version: layoutVersion,
            name: name,
            anchored: [(.right, Dock(id: DockId(0), groups: [
                PanelGroup(panels: [.layers]),
                PanelGroup(panels: [.color, .stroke, .properties]),
            ], width: defaultDockWidth))],
            floating: [],
            hiddenPanels: [],
            zOrder: [],
            focusedPanel: nil,
            paneLayout: nil,
            nextId: 1,
            generation: 0,
            savedGeneration: 0
        )
    }

    private init(version: Int, name: String, anchored: [(DockEdge, Dock)], floating: [FloatingDock],
                 hiddenPanels: [PanelKind], zOrder: [DockId], focusedPanel: PanelAddr?,
                 paneLayout: PaneLayout?, nextId: Int, generation: UInt64, savedGeneration: UInt64) {
        self.version = version
        self.name = name
        self.anchored = anchored
        self.floating = floating
        self.hiddenPanels = hiddenPanels
        self.zOrder = zOrder
        self.focusedPanel = focusedPanel
        self.paneLayout = paneLayout
        self.nextId = nextId
        self.generation = generation
        self.savedGeneration = savedGeneration
    }

    // MARK: - Generation

    private mutating func bump() { generation += 1 }
    public func needsSave() -> Bool { generation != savedGeneration }
    public mutating func markSaved() { savedGeneration = generation }

    // MARK: - Dock Lookup

    public func dock(_ id: DockId) -> Dock? {
        for (_, d) in anchored { if d.id == id { return d } }
        for fd in floating { if fd.dock.id == id { return fd.dock } }
        return nil
    }

    public mutating func dockMut(_ id: DockId, _ body: (inout Dock) -> Void) {
        for i in anchored.indices {
            if anchored[i].1.id == id { body(&anchored[i].1); return }
        }
        for i in floating.indices {
            if floating[i].dock.id == id { body(&floating[i].dock); return }
        }
    }

    public func anchoredDock(_ edge: DockEdge) -> Dock? {
        anchored.first(where: { $0.0 == edge })?.1
    }

    public func floatingDock(_ id: DockId) -> FloatingDock? {
        floating.first(where: { $0.dock.id == id })
    }

    private mutating func nextDockId() -> DockId {
        let id = DockId(nextId)
        nextId += 1
        return id
    }

    // MARK: - Collapse

    public mutating func toggleDockCollapsed(_ id: DockId) {
        dockMut(id) { $0.collapsed.toggle() }
        bump()
    }

    public mutating func toggleGroupCollapsed(_ addr: GroupAddr) {
        dockMut(addr.dockId) { dock in
            guard addr.groupIdx < dock.groups.count else { return }
            dock.groups[addr.groupIdx].collapsed.toggle()
        }
        bump()
    }

    // MARK: - Active Panel

    public mutating func setActivePanel(_ addr: PanelAddr) {
        dockMut(addr.group.dockId) { dock in
            guard addr.group.groupIdx < dock.groups.count else { return }
            let g = dock.groups[addr.group.groupIdx]
            guard addr.panelIdx < g.panels.count else { return }
            dock.groups[addr.group.groupIdx].active = addr.panelIdx
        }
        bump()
    }

    // MARK: - Move Group Within Dock

    public mutating func moveGroupWithinDock(_ dockId: DockId, from: Int, to: Int) {
        dockMut(dockId) { dock in
            guard from < dock.groups.count else { return }
            let group = dock.groups.remove(at: from)
            let clampedTo = min(to, dock.groups.count)
            dock.groups.insert(group, at: clampedTo)
        }
        bump()
    }

    // MARK: - Move Group Between Docks

    public mutating func moveGroupToDock(_ from: GroupAddr, toDock: DockId, toIdx: Int) {
        guard var srcDock = dock(from.dockId), from.groupIdx < srcDock.groups.count else { return }
        let group = srcDock.groups.remove(at: from.groupIdx)
        setDockGroups(from.dockId, srcDock.groups)

        guard var dstDock = dock(toDock) else {
            // Put it back
            srcDock.groups.insert(group, at: min(from.groupIdx, srcDock.groups.count))
            setDockGroups(from.dockId, srcDock.groups)
            return
        }
        let idx = min(toIdx, dstDock.groups.count)
        dstDock.groups.insert(group, at: idx)
        setDockGroups(toDock, dstDock.groups)
        cleanup(from.dockId)
        bump()
    }

    private mutating func setDockGroups(_ id: DockId, _ groups: [PanelGroup]) {
        for i in anchored.indices {
            if anchored[i].1.id == id { anchored[i].1.groups = groups; return }
        }
        for i in floating.indices {
            if floating[i].dock.id == id { floating[i].dock.groups = groups; return }
        }
    }

    // MARK: - Detach Group

    @discardableResult
    public mutating func detachGroup(_ from: GroupAddr, x: Double, y: Double) -> DockId? {
        guard var srcDock = dock(from.dockId), from.groupIdx < srcDock.groups.count else { return nil }
        let group = srcDock.groups.remove(at: from.groupIdx)
        setDockGroups(from.dockId, srcDock.groups)
        let id = nextDockId()
        floating.append(FloatingDock(dock: Dock(id: id, groups: [group], width: defaultFloatingWidth), x: x, y: y))
        zOrder.append(id)
        cleanup(from.dockId)
        bump()
        return id
    }

    // MARK: - Reorder Panel

    public mutating func reorderPanel(_ group: GroupAddr, from: Int, to: Int) {
        dockMut(group.dockId) { dock in
            guard group.groupIdx < dock.groups.count else { return }
            guard from < dock.groups[group.groupIdx].panels.count else { return }
            let panel = dock.groups[group.groupIdx].panels.remove(at: from)
            let clampedTo = min(to, dock.groups[group.groupIdx].panels.count)
            dock.groups[group.groupIdx].panels.insert(panel, at: clampedTo)
            dock.groups[group.groupIdx].active = clampedTo
        }
        bump()
    }

    // MARK: - Move Panel Between Groups

    public mutating func movePanelToGroup(_ from: PanelAddr, to: GroupAddr) {
        guard from.group != to else { return }
        guard var srcDock = dock(from.group.dockId),
              from.group.groupIdx < srcDock.groups.count,
              from.panelIdx < srcDock.groups[from.group.groupIdx].panels.count else { return }
        let panel = srcDock.groups[from.group.groupIdx].panels.remove(at: from.panelIdx)
        setDockGroups(from.group.dockId, srcDock.groups)

        guard var dstDock = dock(to.dockId), to.groupIdx < dstDock.groups.count else {
            // Put it back
            srcDock.groups[from.group.groupIdx].panels.insert(panel, at: min(from.panelIdx, srcDock.groups[from.group.groupIdx].panels.count))
            setDockGroups(from.group.dockId, srcDock.groups)
            return
        }
        dstDock.groups[to.groupIdx].panels.append(panel)
        dstDock.groups[to.groupIdx].active = dstDock.groups[to.groupIdx].panels.count - 1
        setDockGroups(to.dockId, dstDock.groups)
        cleanup(from.group.dockId)
        bump()
    }

    // MARK: - Insert Panel as New Group

    public mutating func insertPanelAsNewGroup(_ from: PanelAddr, toDock: DockId, atIdx: Int) {
        guard var srcDock = dock(from.group.dockId),
              from.group.groupIdx < srcDock.groups.count,
              from.panelIdx < srcDock.groups[from.group.groupIdx].panels.count else { return }
        let panel = srcDock.groups[from.group.groupIdx].panels.remove(at: from.panelIdx)
        setDockGroups(from.group.dockId, srcDock.groups)

        guard var dstDock = dock(toDock) else {
            srcDock.groups[from.group.groupIdx].panels.insert(panel, at: min(from.panelIdx, srcDock.groups[from.group.groupIdx].panels.count))
            setDockGroups(from.group.dockId, srcDock.groups)
            return
        }
        let idx = min(atIdx, dstDock.groups.count)
        dstDock.groups.insert(PanelGroup(panels: [panel]), at: idx)
        setDockGroups(toDock, dstDock.groups)
        cleanup(from.group.dockId)
        bump()
    }

    // MARK: - Detach Panel

    @discardableResult
    public mutating func detachPanel(_ from: PanelAddr, x: Double, y: Double) -> DockId? {
        guard var srcDock = dock(from.group.dockId),
              from.group.groupIdx < srcDock.groups.count,
              from.panelIdx < srcDock.groups[from.group.groupIdx].panels.count else { return nil }
        let panel = srcDock.groups[from.group.groupIdx].panels.remove(at: from.panelIdx)
        setDockGroups(from.group.dockId, srcDock.groups)
        let id = nextDockId()
        floating.append(FloatingDock(dock: Dock(id: id, groups: [PanelGroup(panels: [panel])], width: defaultFloatingWidth), x: x, y: y))
        zOrder.append(id)
        cleanup(from.group.dockId)
        bump()
        return id
    }

    // MARK: - Floating Position

    public mutating func setFloatingPosition(_ id: DockId, x: Double, y: Double) {
        if let i = floating.firstIndex(where: { $0.dock.id == id }) {
            floating[i].x = x
            floating[i].y = y
        }
        bump()
    }

    // MARK: - Resize

    public mutating func resizeGroup(_ addr: GroupAddr, height: Double) {
        dockMut(addr.dockId) { dock in
            guard addr.groupIdx < dock.groups.count else { return }
            dock.groups[addr.groupIdx].height = max(height, minGroupHeight)
        }
        bump()
    }

    public mutating func setDockWidth(_ id: DockId, width: Double) {
        dockMut(id) { dock in
            dock.width = max(dock.minWidth, min(width, maxDockWidth))
        }
        bump()
    }

    // MARK: - Labels

    public static func panelLabel(_ kind: PanelKind) -> String {
        switch kind {
        case .layers: return "Layers"
        case .color: return "Color"
        case .stroke: return "Stroke"
        case .properties: return "Properties"
        }
    }

    // MARK: - Close / Show Panels

    public mutating func closePanel(_ addr: PanelAddr) {
        guard var srcDock = dock(addr.group.dockId),
              addr.group.groupIdx < srcDock.groups.count,
              addr.panelIdx < srcDock.groups[addr.group.groupIdx].panels.count else { return }
        let panel = srcDock.groups[addr.group.groupIdx].panels.remove(at: addr.panelIdx)
        setDockGroups(addr.group.dockId, srcDock.groups)
        if !hiddenPanels.contains(panel) { hiddenPanels.append(panel) }
        cleanup(addr.group.dockId)
        bump()
    }

    public mutating func showPanel(_ kind: PanelKind) {
        guard let pos = hiddenPanels.firstIndex(of: kind) else { return }
        hiddenPanels.remove(at: pos)
        if !anchored.isEmpty {
            if anchored[0].1.groups.isEmpty {
                anchored[0].1.groups.append(PanelGroup(panels: [kind]))
            } else {
                anchored[0].1.groups[0].panels.append(kind)
                anchored[0].1.groups[0].active = anchored[0].1.groups[0].panels.count - 1
            }
        }
        bump()
    }

    public func isPanelVisible(_ kind: PanelKind) -> Bool {
        !hiddenPanels.contains(kind)
    }

    public func panelMenuItems() -> [(PanelKind, Bool)] {
        let all: [PanelKind] = [.layers, .color, .stroke, .properties]
        return all.map { ($0, isPanelVisible($0)) }
    }

    // MARK: - Z-Index

    public mutating func bringToFront(_ id: DockId) {
        if let pos = zOrder.firstIndex(of: id) {
            zOrder.remove(at: pos)
            zOrder.append(id)
        }
        bump()
    }

    public func zIndexFor(_ id: DockId) -> Int {
        zOrder.firstIndex(of: id) ?? 0
    }

    // MARK: - Snap & Re-dock

    public mutating func snapToEdge(_ id: DockId, edge: DockEdge) {
        guard let pos = floating.firstIndex(where: { $0.dock.id == id }) else { return }
        let fdock = floating.remove(at: pos)
        zOrder.removeAll(where: { $0 == id })
        if let ai = anchored.firstIndex(where: { $0.0 == edge }) {
            anchored[ai].1.groups.append(contentsOf: fdock.dock.groups)
        } else {
            anchored.append((edge, fdock.dock))
        }
        bump()
    }

    public mutating func redock(_ id: DockId) {
        snapToEdge(id, edge: .right)
    }

    public static func isNearEdge(x: Double, y: Double, viewportW: Double, viewportH: Double) -> DockEdge? {
        if x <= snapDistance { return .left }
        if x >= viewportW - snapDistance { return .right }
        if y >= viewportH - snapDistance { return .bottom }
        return nil
    }

    // MARK: - Multi-Edge

    @discardableResult
    public mutating func addAnchoredDock(_ edge: DockEdge) -> DockId {
        if let existing = anchored.first(where: { $0.0 == edge }) { return existing.1.id }
        let id = nextDockId()
        anchored.append((edge, Dock(id: id, groups: [], width: defaultDockWidth)))
        bump()
        return id
    }

    public mutating func removeAnchoredDock(_ edge: DockEdge) -> DockId? {
        guard let pos = anchored.firstIndex(where: { $0.0 == edge }) else { return nil }
        let dock = anchored.remove(at: pos).1
        guard !dock.groups.isEmpty else { return nil }
        let fid = nextDockId()
        floating.append(FloatingDock(dock: Dock(id: fid, groups: dock.groups, width: dock.width), x: 100, y: 100))
        zOrder.append(fid)
        bump()
        return fid
    }

    // MARK: - Context-Sensitive

    public static func panelsForSelection(hasSelection: Bool, hasText: Bool) -> [PanelKind] {
        var panels: [PanelKind] = [.layers]
        if hasSelection {
            panels.append(contentsOf: [.properties, .color, .stroke])
        }
        return panels
    }

    // MARK: - Persistence

    public mutating func resetToDefault() {
        let n = name
        self = DockLayout.named(n)
        bump()
    }

    public func toJson() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJson(_ json: String) -> DockLayout {
        guard let data = json.data(using: .utf8),
              let layout = try? JSONDecoder().decode(DockLayout.self, from: data),
              layout.version == layoutVersion else {
            return defaultLayout()
        }
        return layout
    }

    static let storagePrefix = "jas_layout:"

    public func storageKey() -> String {
        "\(DockLayout.storagePrefix)\(name)"
    }

    public static func storageKeyFor(_ name: String) -> String {
        "\(storagePrefix)\(name)"
    }

    public func save() {
        if let json = toJson() {
            UserDefaults.standard.set(json, forKey: storageKey())
        }
    }

    public static func load(name: String) -> DockLayout {
        guard let json = UserDefaults.standard.string(forKey: storageKeyFor(name)) else {
            return named(name)
        }
        return fromJson(json)
    }

    /// Save if generation changed, then reset saved_generation.
    public mutating func saveIfNeeded() {
        if needsSave() {
            save()
            markSaved()
        }
    }

    // MARK: - Focus

    public mutating func setFocusedPanel(_ addr: PanelAddr?) {
        focusedPanel = addr
    }

    private func allPanelAddrs() -> [PanelAddr] {
        var addrs: [PanelAddr] = []
        for (_, dock) in anchored {
            for (gi, group) in dock.groups.enumerated() {
                for pi in 0..<group.panels.count {
                    addrs.append(PanelAddr(group: GroupAddr(dockId: dock.id, groupIdx: gi), panelIdx: pi))
                }
            }
        }
        for fd in floating {
            for (gi, group) in fd.dock.groups.enumerated() {
                for pi in 0..<group.panels.count {
                    addrs.append(PanelAddr(group: GroupAddr(dockId: fd.dock.id, groupIdx: gi), panelIdx: pi))
                }
            }
        }
        return addrs
    }

    public mutating func focusNextPanel() {
        let addrs = allPanelAddrs()
        guard !addrs.isEmpty else { focusedPanel = nil; return }
        let curIdx = focusedPanel.flatMap { fp in addrs.firstIndex(of: fp) }
        let next = curIdx.map { ($0 + 1) % addrs.count } ?? 0
        focusedPanel = addrs[next]
    }

    public mutating func focusPrevPanel() {
        let addrs = allPanelAddrs()
        guard !addrs.isEmpty else { focusedPanel = nil; return }
        let curIdx = focusedPanel.flatMap { fp in addrs.firstIndex(of: fp) }
        let prev = curIdx.map { $0 == 0 ? addrs.count - 1 : $0 - 1 } ?? (addrs.count - 1)
        focusedPanel = addrs[prev]
    }

    // MARK: - Pane Layout Integration

    /// Create the default pane layout if absent, and repair configs
    /// for layouts deserialized from old JSON without config fields.
    public mutating func ensurePaneLayout(viewportW: Double, viewportH: Double) {
        if paneLayout == nil {
            paneLayout = PaneLayout.defaultThreePane(viewportW: viewportW, viewportH: viewportH)
            bump()
        }
        // Sync PaneConfig for panes deserialized from old format
        if paneLayout != nil {
            for i in paneLayout!.panes.indices {
                let expected = PaneConfig.forKind(paneLayout!.panes[i].kind)
                if paneLayout!.panes[i].config.label != expected.label {
                    paneLayout!.panes[i].config = expected
                }
            }
        }
    }

    /// Read-only access to the pane layout.
    public func panes() -> PaneLayout? { paneLayout }

    /// Mutating access to the pane layout.
    public mutating func panesMut(_ body: (inout PaneLayout) -> Void) {
        if paneLayout != nil {
            body(&paneLayout!)
            bump()
        }
    }

    // MARK: - Safety

    public mutating func clampFloatingDocks(viewportW: Double, viewportH: Double) {
        let minVisible = 50.0
        for i in floating.indices {
            floating[i].x = max(-floating[i].dock.width + minVisible, min(floating[i].x, viewportW - minVisible))
            floating[i].y = max(0, min(floating[i].y, viewportH - minVisible))
        }
        paneLayout?.clampPanes(viewportW: viewportW, viewportH: viewportH)
        bump()
    }

    public mutating func setAutoHide(_ id: DockId, autoHide: Bool) {
        dockMut(id) { $0.autoHide = autoHide }
        bump()
    }

    // MARK: - Cleanup

    private mutating func cleanup(_ dockId: DockId) {
        dockMut(dockId) { dock in
            dock.groups.removeAll(where: { $0.panels.isEmpty })
            for i in dock.groups.indices {
                if dock.groups[i].active >= dock.groups[i].panels.count && !dock.groups[i].panels.isEmpty {
                    dock.groups[i].active = dock.groups[i].panels.count - 1
                }
            }
        }
        let removed = floating.filter { $0.dock.groups.isEmpty }.map { $0.dock.id }
        floating.removeAll(where: { $0.dock.groups.isEmpty })
        zOrder.removeAll(where: { removed.contains($0) })
    }
}
