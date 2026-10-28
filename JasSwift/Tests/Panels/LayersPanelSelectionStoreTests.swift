import Foundation
import Testing
@testable import JasLib

// The Layers panel selection's stored form is `__path__` markers (STATUS-jas
// item 38 step 3c): the YAML's own writes take it (`[as_path(param.path)]`,
// `list_toggle`) and the native mirror writes it. The one reader takes both
// forms, so `active_document.layers_panel_selection_count` counts a row the
// YAML selected (it read 0 when the reader knew bare lists only).
@Test func theLayersPanelSelectionReadsMarkersAndBareLists() {
    let model = Model()
    model.stateStore.initPanel("layers_panel_content", defaults: [:])
    model.stateStore.setPanel("layers_panel_content", "layers_panel_selection",
                              [["__path__": [1, 0]], [2]] as [Any])
    #expect(layersPanelSelection(model: model) == [[1, 0], [2]])
}
