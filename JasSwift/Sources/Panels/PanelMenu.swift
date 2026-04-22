/// Unified panel menu lookup functions.
///
/// Each panel kind delegates to its own module for menu items, dispatch,
/// and checked-state queries. Labels are read from the workspace YAML
/// `summary:` field of the panel's content spec.

/// Human-readable label for a panel kind, read from the workspace YAML
/// `summary:` field of the panel's content spec.
public func panelLabel(_ kind: PanelKind) -> String {
    let contentId = panelKindToContentId(kind)
    if let summary = WorkspaceData.load()?.panel(contentId)?["summary"] as? String {
        return summary
    }
    return contentId.replacingOccurrences(of: "_panel_content", with: "")
}

/// Menu items for a panel kind.
public func panelMenu(_ kind: PanelKind) -> [PanelMenuItem] {
    switch kind {
    case .layers: return LayersPanel.menuItems()
    case .color: return ColorPanel.menuItems()
    case .swatches: return SwatchesPanel.menuItems()
    case .stroke: return StrokePanel.menuItems()
    case .properties: return PropertiesPanel.menuItems()
    case .character: return CharacterPanel.menuItems()
    case .paragraph: return ParagraphPanel.menuItems()
    case .artboards: return ArtboardsPanel.menuItems()
    case .align: return AlignPanel.menuItems()
    case .boolean: return BooleanPanel.menuItems()
    case .opacity: return OpacityPanel.menuItems()
    }
}

/// Dispatch a menu command for a panel kind.
public func panelDispatch(_ kind: PanelKind, cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
    switch kind {
    case .layers: LayersPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .color: ColorPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .swatches: SwatchesPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .stroke: StrokePanel.dispatch(cmd, addr: addr, layout: &layout)
    case .properties: PropertiesPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .character: CharacterPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .paragraph: ParagraphPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .artboards: ArtboardsPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .align: AlignPanel.dispatch(cmd, addr: addr, layout: &layout)
    case .boolean: BooleanPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    case .opacity: OpacityPanel.dispatch(cmd, addr: addr, layout: &layout, model: model)
    }
}

/// Query whether a toggle/radio command is checked for a panel kind.
public func panelIsChecked(_ kind: PanelKind, cmd: String, layout: WorkspaceLayout) -> Bool {
    switch kind {
    case .layers: return LayersPanel.isChecked(cmd, layout: layout)
    case .color: return ColorPanel.isChecked(cmd, layout: layout)
    case .swatches: return SwatchesPanel.isChecked(cmd, layout: layout)
    case .stroke: return StrokePanel.isChecked(cmd, layout: layout)
    case .properties: return PropertiesPanel.isChecked(cmd, layout: layout)
    case .character: return CharacterPanel.isChecked(cmd, layout: layout)
    case .paragraph: return ParagraphPanel.isChecked(cmd, layout: layout)
    case .artboards: return ArtboardsPanel.isChecked(cmd, layout: layout)
    case .align: return AlignPanel.isChecked(cmd, layout: layout)
    case .boolean: return BooleanPanel.isChecked(cmd, layout: layout)
    case .opacity: return OpacityPanel.isChecked(cmd, layout: layout)
    }
}
