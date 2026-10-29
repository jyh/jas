import Testing
@testable import JasLib

// `rename_element` stores `as_path(param.path).indices` (STATUS-flask §646):
// the name double-click passes a plain list, F2 / Enter a selection entry
// (the `__path__` marker), and both must store the plain list `lp_name_edit`
// compares to `node.path`. Mirrors the reference's
// test_every_rename_route_stores_the_rows_path_form.

@Test func renamePathFormIsThePlainListFromEitherRoute() {
    for input: Any in [[1, 0] as [Any], ["__path__": [1, 0]] as [String: Any]] {
        let v = evaluate("as_path(param.path).indices", context: ["param": ["path": input]])
        #expect(v == .list([AnyJSON(1), AnyJSON(0)]), "\(input)")
        let shown = evaluate("panel.renaming_element == node.path",
                             context: ["panel": ["renaming_element": [1, 0]], "node": ["path": [1, 0]]])
        #expect(shown == .bool(true))
    }
}

@Test func renamePathFormControlTheMarkerAloneIsNotTheList() {
    // The control: without the normalisation the stored marker is not equal
    // to the row's list, which is the defect.
    let shown = evaluate("panel.renaming_element == node.path",
                         context: ["panel": ["renaming_element": ["__path__": [1, 0]]], "node": ["path": [1, 0]]])
    #expect(shown != .bool(true))
}
