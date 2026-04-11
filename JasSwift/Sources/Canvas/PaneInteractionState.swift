/// Transient interaction state for pane drag, resize, and snap operations.
///
/// Extracted from ContentView to reduce @State property count.
public struct PaneInteractionState {
    var paneDrag: (paneId: PaneId, offX: Double, offY: Double)?
    var borderDrag: (snapIdx: Int, startCoord: Double)?
    var edgeResize: (paneId: PaneId, edge: EdgeSide, startX: Double, startY: Double, startW: Double, startH: Double)?
    var edgeSnappedCoord: Double?
    var hoveredBorder: Int?
    var snapPreview: [SnapConstraint] = []
}
