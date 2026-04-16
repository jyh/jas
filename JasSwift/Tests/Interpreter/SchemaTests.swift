import Testing
@testable import JasLib

// MARK: - coerceValue: bool

@Test func coerceBoolFromBool() {
    let entry = getSchemaEntry("fill_on_top")!
    let (val, err) = coerceValue(true, entry: entry)
    #expect(val as? Bool == true)
    #expect(err == nil)
}

@Test func coerceBoolFromString() {
    let entry = getSchemaEntry("fill_on_top")!
    let (t, _) = coerceValue("true", entry: entry)
    let (f, _) = coerceValue("false", entry: entry)
    #expect(t as? Bool == true)
    #expect(f as? Bool == false)
}

@Test func coerceBoolRejectsInvalid() {
    let entry = getSchemaEntry("fill_on_top")!
    let (_, err1) = coerceValue("yes", entry: entry)
    let (_, err2) = coerceValue(1, entry: entry)
    #expect(err1 == "type_mismatch")
    #expect(err2 == "type_mismatch")
}

// MARK: - coerceValue: number

@Test func coerceNumberFromDouble() {
    let entry = getSchemaEntry("stroke_width")!
    let (val, err) = coerceValue(3.5, entry: entry)
    #expect(val as? Double == 3.5)
    #expect(err == nil)
}

@Test func coerceNumberFromInt() {
    let entry = getSchemaEntry("stroke_width")!
    let (val, err) = coerceValue(2, entry: entry)
    #expect(val as? Double == 2.0)
    #expect(err == nil)
}

@Test func coerceNumberFromNumericString() {
    let entry = getSchemaEntry("stroke_width")!
    let (val, err) = coerceValue("2.5", entry: entry)
    #expect(val as? Double == 2.5)
    #expect(err == nil)
}

@Test func coerceNumberRejectsBool() {
    let entry = getSchemaEntry("stroke_width")!
    let (_, err) = coerceValue(true, entry: entry)
    #expect(err == "type_mismatch")
}

// MARK: - coerceValue: color

@Test func coerceColorValidHex() {
    let entry = getSchemaEntry("fill_color")!
    let (val, err) = coerceValue("#ff0000", entry: entry)
    #expect(val as? String == "#ff0000")
    #expect(err == nil)
}

@Test func coerceColorNullNullable() {
    let entry = getSchemaEntry("fill_color")!
    let (val, err) = coerceValue(nil, entry: entry)
    #expect(val == nil)
    #expect(err == nil)
}

@Test func coerceColorRejectsInvalidHex() {
    let entry = getSchemaEntry("fill_color")!
    let (_, err1) = coerceValue("red", entry: entry)
    let (_, err2) = coerceValue("#gg0000", entry: entry)
    #expect(err1 == "type_mismatch")
    #expect(err2 == "type_mismatch")
}

// MARK: - coerceValue: enum

@Test func coerceEnumValid() {
    let entry = getSchemaEntry("stroke_cap")!
    let (val, err) = coerceValue("round", entry: entry)
    #expect(val as? String == "round")
    #expect(err == nil)
}

@Test func coerceEnumInvalid() {
    let entry = getSchemaEntry("stroke_cap")!
    let (_, err) = coerceValue("triangle", entry: entry)
    #expect(err == "enum_value_not_in_values")
}

// MARK: - coerceValue: null on non-nullable

@Test func nullOnNonNullableIsError() {
    let entry = getSchemaEntry("stroke_width")!
    let (_, err) = coerceValue(nil, entry: entry)
    #expect(err == "null_on_non_nullable")
}

// MARK: - writable flag

@Test func dragPaneIsNotWritable() {
    let entry = getSchemaEntry("_drag_pane")!
    #expect(!entry.writable)
}

@Test func fillColorIsWritable() {
    let entry = getSchemaEntry("fill_color")!
    #expect(entry.writable)
}

// MARK: - unknown key

@Test func unknownKeyReturnsNil() {
    #expect(getSchemaEntry("nonexistent_field") == nil)
}

// MARK: - applySetSchemadriven

private func makeStore(_ initial: [String: Any] = [:]) -> StateStore {
    StateStore(defaults: initial)
}

@Test func applySetSchemadrivenValidKey() {
    let store = makeStore()
    var diags: [Diagnostic] = []
    applySetSchemadriven(["fill_on_top": true], store: store, diagnostics: &diags)
    #expect(store.get("fill_on_top") as? Bool == true)
    #expect(diags.isEmpty)
}

@Test func applySetSchemadrivenUnknownKeyWarning() {
    let store = makeStore()
    var diags: [Diagnostic] = []
    applySetSchemadriven(["unknown_xyz": "val"], store: store, diagnostics: &diags)
    #expect(diags.count == 1)
    #expect(diags[0].level == "warning")
    #expect(diags[0].reason == "unknown_key")
}

@Test func applySetSchemadrivenNonWritableWarning() {
    let store = makeStore()
    var diags: [Diagnostic] = []
    applySetSchemadriven(["_drag_pane": "left"], store: store, diagnostics: &diags)
    #expect(diags.count == 1)
    #expect(diags[0].level == "warning")
    #expect(diags[0].reason == "field_not_writable")
}

@Test func applySetSchemadrivenTypeMismatchError() {
    let store = makeStore()
    var diags: [Diagnostic] = []
    applySetSchemadriven(["stroke_width": "not-a-number"], store: store, diagnostics: &diags)
    #expect(diags.count == 1)
    #expect(diags[0].level == "error")
    #expect(diags[0].reason == "type_mismatch")
}

@Test func applySetSchemadrivenBatchSemanticsPartialSuccess() {
    let store = makeStore(["fill_on_top": false])
    var diags: [Diagnostic] = []
    // One valid, one invalid — valid should apply, invalid should not
    applySetSchemadriven(
        ["fill_on_top": true, "stroke_width": "bad"],
        store: store,
        diagnostics: &diags
    )
    #expect(store.get("fill_on_top") as? Bool == true)
    #expect(diags.count == 1)
    #expect(diags[0].key == "stroke_width")
}
