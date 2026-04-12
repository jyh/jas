/// Unified panel menu lookup functions.
///
/// Each panel kind delegates to its own module for label, menu items,
/// dispatch, and checked-state queries.

/// Human-readable label for a panel kind.
public func panelLabel(_ kind: PanelKind) -> String {
    switch kind {
    case .layers: return LayersPanel.label
    case .color: return ColorPanel.label
    case .stroke: return StrokePanel.label
    case .properties: return PropertiesPanel.label
    }
}

/// Menu items for a panel kind.
public func panelMenu(_ kind: PanelKind) -> [PanelMenuItem] {
    switch kind {
    case .layers: return LayersPanel.menuItems()
    case .color: return ColorPanel.menuItems()
    case .stroke: return StrokePanel.menuItems()
    case .properties: return PropertiesPanel.menuItems()
    }
}

/// Dispatch a menu command for a panel kind.
public func panelDispatch(_ kind: PanelKind, cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
    switch kind {
    case .layers: LayersPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .color: ColorPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .stroke: StrokePanel.dispatch(cmd, addr: addr, layout: &layout)
    case .properties: PropertiesPanel.dispatch(cmd, addr: addr, layout: &layout)
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
public func panelIsChecked(_ kind: PanelKind, cmd: String, layout: WorkspaceLayout) -> Bool {
    switch kind {
    case .layers: return LayersPanel.isChecked(cmd, layout: layout)
    case .color: return ColorPanel.isChecked(cmd, layout: layout)
    case .stroke: return StrokePanel.isChecked(cmd, layout: layout)
    case .properties: return PropertiesPanel.isChecked(cmd, layout: layout)
    }
}
