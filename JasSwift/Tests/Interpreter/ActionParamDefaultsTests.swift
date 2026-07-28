import Foundation
import Testing
@testable import JasLib

/// Gate for ``mergeDeclaredParamDefaults`` — the merge Swift's generic action
/// dispatchers were missing, so an omitted param arrived as null (and, through
/// `evalNumber`, as 0) rather than as the default `workspace/actions.yaml`
/// declares. RULED 2026-07-27, transcripts/ZOOM_TOOL.md.
///
/// The zoom half is gated end-to-end by `test_fixtures/actions/view_state.json`
/// (`zoom_in_default_anchor` / `zoom_out_default_anchor`). What this file adds is
/// the LAW itself — precedence, shapes, and absence — plus the third verb the
/// ruling flagged as unwatched.

// MARK: - The law

@Test func declaredDefaultFillsAnAbsentParam() {
    let def: [String: Any] = ["params": [
        "anchor_x": ["type": "number", "default": -1],
    ]]
    let merged = mergeDeclaredParamDefaults([:], actionDef: def)
    #expect((merged["anchor_x"] as? NSNumber)?.doubleValue == -1)
}

@Test func callerSuppliedValueBeatsTheDeclaredDefault() {
    let def: [String: Any] = ["params": [
        "anchor_x": ["type": "number", "default": -1],
    ]]
    let merged = mergeDeclaredParamDefaults(["anchor_x": 300.0], actionDef: def)
    #expect((merged["anchor_x"] as? NSNumber)?.doubleValue == 300.0)
}

/// An EXPLICIT null is an argument, not an absence. Coalescing the two would let
/// a declared default silently overwrite a caller that meant "no anchor", which
/// is the same absent-is-not-null rule `expected_panel_state` enforces in the
/// action corpus.
@Test func explicitNullIsNotOverwrittenByTheDeclaredDefault() {
    let def: [String: Any] = ["params": [
        "anchor_x": ["type": "number", "default": -1],
    ]]
    let merged = mergeDeclaredParamDefaults(["anchor_x": NSNull()], actionDef: def)
    #expect(merged["anchor_x"] is NSNull)
}

/// A declared param with NO default contributes nothing, so a `param.x == null`
/// guard in the YAML still sees null (`artboards_panel_select.artboard_id` is
/// declared `{ type: string }` with no default and must stay absent).
@Test func declaredParamWithoutDefaultStaysAbsent() {
    let def: [String: Any] = ["params": ["artboard_id": ["type": "string"]]]
    let merged = mergeDeclaredParamDefaults([:], actionDef: def)
    #expect(merged.index(forKey: "artboard_id") == nil)
}

/// A scalar declaration is read as the default itself.
@Test func scalarDeclarationIsTakenAsTheDefault() {
    let def: [String: Any] = ["params": ["mode": "solid"]]
    let merged = mergeDeclaredParamDefaults([:], actionDef: def)
    #expect((merged["mode"] as? String) == "solid")
}

@Test func actionWithNoParamBlockIsUntouched() {
    let merged = mergeDeclaredParamDefaults(["a": 1], actionDef: ["effects": []])
    #expect(merged.count == 1)
    #expect((merged["a"] as? NSNumber)?.intValue == 1)
}

// MARK: - The live workspace: which verbs this actually reaches

/// The blast radius, read off the COMPILED workspace rather than asserted in
/// prose: exactly three of the declared actions carry a param default, and they
/// are the two zoom verbs plus `artboards_panel_select`. If a fourth appears,
/// this fails and whoever added it is told to gate it — which is the whole
/// reason the ruling called the third verb out.
@Test func exactlyThreeActionsDeclareParamDefaults() {
    let actions = WorkspaceData.load()?.data["actions"] as? [String: Any] ?? [:]
    #expect(!actions.isEmpty)
    var withDefaults: [String] = []
    for (name, defAny) in actions {
        guard let def = defAny as? [String: Any],
              let params = def["params"] as? [String: Any] else { continue }
        let anyDefault = params.values.contains { spec in
            (spec as? [String: Any])?.index(forKey: "default") != nil
        }
        if anyDefault { withDefaults.append(name) }
    }
    #expect(withDefaults.sorted()
            == ["artboards_panel_select", "zoom_in", "zoom_out"])
}

/// `artboards_panel_select` dispatched WITHOUT `modifier` — the third verb, and
/// the one no corpus vector reaches. It cannot be expressed in the action corpus
/// today: its effect writes PANEL-scoped state (`set_panel_state` on the
/// artboards panel), and Swift's `buildLiveStateMap` — the reader
/// `expected_panel_state` asserts against — does not publish
/// `artboards_panel_selection` at all (Rust's `build_live_state_map` does). So
/// the gate lives here, per port, until that asymmetry is closed.
///
/// MEASURED, and narrower than the ruling predicted: merging the default does
/// NOT change this verb's behaviour, because the YAML condition is already
/// null-tolerant (`param.modifier == 'none' or param.modifier == null`). The
/// value of the test is that the replace path is now PINNED across the merge
/// change instead of merely believed.
@Test func artboardsPanelSelectWithNoModifierReplacesTheSelection() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("ab1"), Artboard.defaultWithId("ab2")]
    ))
    // `set_panel_state: { panel: artboards }` normalises the short panel name
    // to the StateStore's content id, which is the scope the Artboards panel
    // body itself renders from.
    let scope = "artboards_panel_content"
    let defaults = WorkspaceData.load()?.panelStateDefaults(scope) ?? [:]
    model.stateStore.initPanel(scope, defaults: defaults)
    model.stateStore.setPanel(scope, "artboards_panel_selection", ["ab1"])

    LayersPanel.dispatchYamlAction("artboards_panel_select", model: model,
                                   params: ["artboard_id": "ab2"])

    #expect((model.stateStore.getPanel(scope, "artboards_panel_selection")
                as? [Any])?.compactMap { $0 as? String } == ["ab2"],
            "modifier=none (declared default) REPLACES the selection")
    #expect((model.stateStore.getPanel(scope, "panel_selection_anchor")
                as? String) == "ab2",
            "the anchor follows the replace")
}

/// The declared default arrives as the string "none", not as null — the merge
/// actually happening at this verb, asserted on the merged params rather than
/// inferred from the branch it happened to take.
@Test func artboardsPanelSelectReceivesTheDeclaredModifierDefault() {
    let actions = WorkspaceData.load()?.data["actions"] as? [String: Any] ?? [:]
    guard let def = actions["artboards_panel_select"] as? [String: Any] else {
        Issue.record("artboards_panel_select is not in the compiled workspace")
        return
    }
    let merged = mergeDeclaredParamDefaults(["artboard_id": "ab2"], actionDef: def)
    #expect((merged["modifier"] as? String) == "none")
    #expect((merged["artboard_id"] as? String) == "ab2")
}
