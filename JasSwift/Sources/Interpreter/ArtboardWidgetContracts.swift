/// Data contracts for the two artboard widget kinds.
///
/// Lifted out of `YamlPanelBodyView` so the ORDERING can be asserted without
/// constructing a SwiftUI view. The ordering is exactly what can diverge from
/// jas_dioxus silently: the widget's output is a panel-state string, not document
/// geometry, so no canonical-JSON golden would ever see it.

/// The 3x3 reference-point anchors, ROW-MAJOR: the KIND's nine
/// (`WidgetEvent.referencePointAnchors`, WIDGET_EVENTS.md Parsing), three to a
/// row. Until 2026-10-15 this was typed here as `top`/`left`/`right`/`bottom`,
/// names no `anchor_offset_*` case and no spec enum member carries.
let referencePointAnchorRowsForTest: [[String]] = stride(from: 0, to: 9, by: 3).map {
    Array(WidgetEvent.referencePointAnchors[$0..<$0 + 3])
}
