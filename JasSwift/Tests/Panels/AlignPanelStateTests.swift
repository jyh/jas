/// Tests for Align panel state loading from the workspace.
///
/// In Swift, panel state is untyped — values live as entries in
/// the shared StateStore (see `JasSwift/Sources/Interpreter/
/// StateStore.swift`), written by yaml-driven effects. This file
/// verifies that the four Align state keys load with their
/// expected defaults from workspace/state.yaml.

import Foundation
import Testing
@testable import JasLib

/// Coerce an Any to a Double, accepting NSNumber, Int, Double — the
/// exact concrete type depends on how the YAML parser bridged it
/// into the dict. Returns nil if no numeric bridge is possible.
private func asDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    if let d = v as? Double { return d }
    return nil
}

/// Similarly for Bool — JSON/YAML parsing can yield either a Bool or
/// an NSNumber wrapping true/false.
private func asBool(_ v: Any?) -> Bool? {
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return nil
}

@Test func alignStateKeysLoadWithExpectedDefaults() {
    let ws = WorkspaceData.load()
    guard let ws else {
        Issue.record("workspace failed to load")
        return
    }
    let defaults = ws.stateDefaults()
    #expect(defaults["align_to"] as? String == "selection")
    // key_object_path default is null; load returns NSNull.
    #expect(defaults["align_key_object_path"] is NSNull)
    #expect(asDouble(defaults["align_distribute_spacing"]) == 0.0)
    #expect(asBool(defaults["align_use_preview_bounds"]) == false)
}

@Test func alignPanelStateDefaultsMatchSpec() {
    let ws = WorkspaceData.load()
    guard let ws else {
        Issue.record("workspace failed to load")
        return
    }
    let defaults = ws.panelStateDefaults("align_panel_content")
    #expect(defaults["align_to"] as? String == "selection")
    #expect(defaults["key_object_path"] is NSNull)
    #expect(asDouble(defaults["distribute_spacing_value"]) == 0.0)
    #expect(asBool(defaults["use_preview_bounds"]) == false)
}
