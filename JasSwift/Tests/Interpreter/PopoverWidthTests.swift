import Testing
import CoreGraphics
@testable import JasLib

// A popover (`modal: false`) dialog DECLARES its width (STATUS-flask 692 (2),
// ruled 2026-10-31), and the Mac's popover honours it, as the web
// (`dialog_view.rs`) and the Windows plan (`ffi.rs` `width`) already do. Before
// this the Mac fixed every popover to its intrinsic size, so the same flyout
// was a different width in each shell. With no declared width the popover
// keeps its intrinsic size (`nil` here).

@Test func declaredDialogWidthReadsAPositiveNumber() {
    #expect(declaredDialogWidth(["width": 200]) == 200)
    #expect(declaredDialogWidth(["width": 340.5]) == 340.5)
}

@Test func declaredDialogWidthIsNilWhenAbsentOrNotAPositiveNumber() {
    #expect(declaredDialogWidth(nil) == nil)
    #expect(declaredDialogWidth([:]) == nil)
    #expect(declaredDialogWidth(["width": "200"]) == nil)
    #expect(declaredDialogWidth(["width": 0]) == nil)
    #expect(declaredDialogWidth(["width": -5]) == nil)
}

@Test func everyToolFlyoutDeclaresTheSameWidthTheYamlDoes() {
    let ws = WorkspaceData.load()
    let ids = ["arrow_alternates", "pen_alternates"]
    for id in ids {
        #expect(declaredDialogWidth(ws?.dialog(id)) == 200, "\(id)")
    }
}
