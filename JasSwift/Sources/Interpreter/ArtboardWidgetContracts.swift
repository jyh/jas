/// Data contracts for the two artboard widget kinds.
///
/// Lifted out of `YamlPanelBodyView` so the ORDERING can be asserted without
/// constructing a SwiftUI view. The ordering is exactly what can diverge from
/// jas_dioxus silently: the widget's output is a panel-state string, not document
/// geometry, so no canonical-JSON golden would ever see it.

/// The 3x3 reference-point anchors, ROW-MAJOR, matching Rust's
/// `render_reference_point_widget`.
let referencePointAnchorRowsForTest: [[String]] = [
    ["top_left", "top", "top_right"],
    ["left", "center", "right"],
    ["bottom_left", "bottom", "bottom_right"],
]
