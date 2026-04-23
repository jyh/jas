import Testing
@testable import JasLib

// MARK: - Set effect

@Test func setEffect() {
    let store = StateStore(defaults: ["x": 0])
    runEffects([["set": ["x": "5"]]], ctx: [:], store: store)
    #expect(store.get("x") as? Int == 5)
}

@Test func setStringValue() {
    let store = StateStore(defaults: ["name": ""])
    runEffects([["set": ["name": "\"hello\""]]], ctx: [:], store: store)
    #expect(store.get("name") as? String == "hello")
}

@Test func setFromExpression() {
    let store = StateStore(defaults: ["a": 10, "b": 0])
    runEffects([["set": ["b": "state.a"]]], ctx: [:], store: store)
    #expect(store.get("b") as? Int == 10)
}

// MARK: - Toggle effect

@Test func toggleTrueToFalse() {
    let store = StateStore(defaults: ["flag": true])
    runEffects([["toggle": "flag"]], ctx: [:], store: store)
    #expect(store.get("flag") as? Bool == false)
}

@Test func toggleFalseToTrue() {
    let store = StateStore(defaults: ["flag": false])
    runEffects([["toggle": "flag"]], ctx: [:], store: store)
    #expect(store.get("flag") as? Bool == true)
}

// MARK: - Swap effect

@Test func swapEffect() {
    let store = StateStore(defaults: ["a": "#ff0000", "b": "#00ff00"])
    runEffects([["swap": ["a", "b"]]], ctx: [:], store: store)
    #expect(store.get("a") as? String == "#00ff00")
    #expect(store.get("b") as? String == "#ff0000")
}

// MARK: - Increment / Decrement

@Test func incrementEffect() {
    let store = StateStore(defaults: ["count": 5])
    runEffects([["increment": ["key": "count", "by": 3]]], ctx: [:], store: store)
    #expect(store.get("count") as? Double == 8.0)
}

@Test func decrementEffect() {
    let store = StateStore(defaults: ["count": 5])
    runEffects([["decrement": ["key": "count", "by": 2]]], ctx: [:], store: store)
    #expect(store.get("count") as? Double == 3.0)
}

// MARK: - If effect

@Test func ifTrueBranch() {
    let store = StateStore(defaults: ["flag": true, "result": ""])
    runEffects([["if": [
        "condition": "state.flag",
        "then": [["set": ["result": "\"yes\""]]],
        "else": [["set": ["result": "\"no\""]]],
    ] as [String: Any]]], ctx: [:], store: store)
    #expect(store.get("result") as? String == "yes")
}

@Test func ifFalseBranch() {
    let store = StateStore(defaults: ["flag": false, "result": ""])
    runEffects([["if": [
        "condition": "state.flag",
        "then": [["set": ["result": "\"yes\""]]],
        "else": [["set": ["result": "\"no\""]]],
    ] as [String: Any]]], ctx: [:], store: store)
    #expect(store.get("result") as? String == "no")
}

// MARK: - Dispatch effect

@Test func dispatchEffect() {
    let store = StateStore(defaults: ["x": 0])
    let actions: [String: Any] = [
        "set_x_to_42": ["effects": [["set": ["x": "42"]]]]
    ]
    runEffects([["dispatch": "set_x_to_42"]], ctx: [:], store: store, actions: actions)
    #expect(store.get("x") as? Int == 42)
}

// MARK: - Sequential effects

@Test func sequentialEffects() {
    let store = StateStore(defaults: ["a": 0, "b": 0])
    runEffects([
        ["set": ["a": "10"]],
        ["set": ["b": "state.a"]],
    ], ctx: [:], store: store)
    #expect(store.get("a") as? Int == 10)
    #expect(store.get("b") as? Int == 10)
}

// MARK: - Open dialog

@Test func openDialogSetsDefaults() {
    let store = StateStore()
    let dialogs: [String: Any] = [
        "simple": [
            "summary": "Simple",
            "state": ["name": ["type": "string", "default": ""]],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects(
        [["open_dialog": ["id": "simple"]]],
        ctx: [:], store: store, dialogs: dialogs
    )
    #expect(store.getDialogId() == "simple")
    #expect(store.getDialog("name") as? String == "")
}

@Test func openDialogWithParamsAndInit() {
    let store = StateStore(defaults: ["fill_color": "#00ff00", "stroke_color": "#0000ff"])
    let dialogs: [String: Any] = [
        "picker": [
            "summary": "Pick",
            "params": ["target": ["type": "enum", "values": ["fill", "stroke"]]],
            "state": [
                "h": ["type": "number", "default": 0],
                "color": ["type": "color", "default": "#ffffff"],
            ] as [String: Any],
            "init": [
                "color": "if param.target == \"fill\" then state.fill_color else state.stroke_color",
                "h": "hsb_h(dialog.color)",
            ] as [String: Any],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects(
        [["open_dialog": ["id": "picker", "params": ["target": "\"fill\""]]]],
        ctx: [:], store: store, dialogs: dialogs
    )
    #expect(store.getDialogId() == "picker")
    #expect(store.getDialog("color") as? String == "#00ff00")
    // hsb_h("#00ff00") = 120
    #expect(store.getDialog("h") as? Int == 120)
}

// MARK: - Close dialog

@Test func closeDialogClearsState() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["p": "v"])
    runEffects([["close_dialog": nil as Any? as Any]], ctx: [:], store: store)
    #expect(store.getDialogId() == nil)
    #expect(store.getDialog("x") == nil)
}

// MARK: - Preview snapshot/restore (Phase 0)

@Test func openDialogCapturesPreviewSnapshot() {
    let store = StateStore(defaults: ["left_indent": 12, "right_indent": 0])
    let dialogs: [String: Any] = [
        "para_indent": [
            "summary": "Indents",
            "state": [
                "left": ["type": "number", "default": 0],
                "right": ["type": "number", "default": 0],
            ] as [String: Any],
            "preview_targets": [
                "left": "left_indent",
                "right": "right_indent",
            ] as [String: Any],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects([["open_dialog": ["id": "para_indent"]]],
               ctx: [:], store: store, dialogs: dialogs)
    let snap = store.getDialogSnapshot()
    #expect(snap?["left_indent"] as? Int == 12)
    #expect(snap?["right_indent"] as? Int == 0)
}

@Test func openDialogWithoutPreviewTargetsNoSnapshot() {
    let store = StateStore()
    let dialogs: [String: Any] = [
        "plain": [
            "summary": "Plain",
            "state": ["name": ["type": "string", "default": ""]],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects([["open_dialog": ["id": "plain"]]],
               ctx: [:], store: store, dialogs: dialogs)
    #expect(!store.hasDialogSnapshot())
}

@Test func closeDialogRestoresFromSnapshot() {
    let store = StateStore(defaults: ["left_indent": 12])
    let dialogs: [String: Any] = [
        "para_indent": [
            "summary": "Indents",
            "state": ["left": ["type": "number", "default": 0]],
            "preview_targets": ["left": "left_indent"],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects([["open_dialog": ["id": "para_indent"]]],
               ctx: [:], store: store, dialogs: dialogs)
    // Simulate Preview live-applying an edit
    store.set("left_indent", 99)
    // Cancel restores
    runEffects([["close_dialog": nil as Any? as Any]], ctx: [:], store: store)
    #expect(store.get("left_indent") as? Int == 12)
    #expect(store.getDialogId() == nil)
    #expect(!store.hasDialogSnapshot())
}

@Test func clearDialogSnapshotPreventsRestore() {
    let store = StateStore(defaults: ["left_indent": 12])
    let dialogs: [String: Any] = [
        "para_indent": [
            "summary": "Indents",
            "state": ["left": ["type": "number", "default": 0]],
            "preview_targets": ["left": "left_indent"],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects([["open_dialog": ["id": "para_indent"]]],
               ctx: [:], store: store, dialogs: dialogs)
    store.set("left_indent", 99)
    // OK action equivalent: clear snapshot, then close
    runEffects([
        ["clear_dialog_snapshot": nil as Any? as Any],
        ["close_dialog": nil as Any? as Any],
    ], ctx: [:], store: store)
    #expect(store.get("left_indent") as? Int == 99)
    #expect(store.getDialogId() == nil)
}

// MARK: - Phase 3: let and foreach effects

@Test func letBindsForSubsequentEffect() {
    let store = StateStore(defaults: ["x": 0])
    runEffects([
        ["let": ["n": "5"]],
        ["set": ["x": "n"]],
    ], ctx: [:], store: store)
    #expect(store.get("x") as? Int == 5)
}

@Test func letShadowsOuterScope() {
    let store = StateStore(defaults: ["x": 0])
    runEffects([
        ["let": ["v": "1"]],
        ["let": ["v": "2"]],
        ["set": ["x": "v"]],
    ], ctx: [:], store: store)
    #expect(store.get("x") as? Int == 2)
}

@Test func foreachIteratesOverList() {
    let store = StateStore(defaults: ["sum": 0])
    runEffects([
        ["foreach": ["source": "[1, 2, 3]", "as": "n"],
         "do": [["set": ["sum": "state.sum + n"]]]],
    ], ctx: [:], store: store)
    #expect(store.get("sum") as? Int == 6)
}

@Test func foreachEmptyListDoesNothing() {
    let store = StateStore(defaults: ["touched": false])
    runEffects([
        ["foreach": ["source": "[]", "as": "x"],
         "do": [["set": ["touched": "true"]]]],
    ], ctx: [:], store: store)
    #expect(store.get("touched") as? Bool == false)
}

// MARK: - Pop effect

@Test func popPanelRemovesLast() {
    let store = StateStore()
    store.initPanel("layers", defaults: ["isolation_stack": [["id": "a"], ["id": "b"]] as [[String: String]]])
    store.setActivePanel("layers")
    runEffects([["pop": "panel.isolation_stack"]], ctx: [:], store: store)
    let result = store.getPanel("layers", "isolation_stack") as? [[String: String]]
    #expect(result?.count == 1)
    #expect(result?.first?["id"] == "a")
}

@Test func popPanelEmptyIsNoop() {
    let store = StateStore()
    store.initPanel("layers", defaults: ["isolation_stack": [] as [Any]])
    store.setActivePanel("layers")
    runEffects([["pop": "panel.isolation_stack"]], ctx: [:], store: store)
    let result = store.getPanel("layers", "isolation_stack") as? [Any]
    #expect(result?.count == 0)
}

@Test func popGlobalList() {
    let store = StateStore(defaults: ["my_stack": [1, 2, 3] as [Int]])
    runEffects([["pop": "my_stack"]], ctx: [:], store: store)
    let result = store.get("my_stack") as? [Int]
    #expect(result == [1, 2])
}

// MARK: - Dialog + global effects

@Test func setFromDialogState() {
    let store = StateStore(defaults: ["fill_color": nil as Any? as Any])
    let dialogs: [String: Any] = [
        "picker": [
            "summary": "Pick",
            "state": ["color": ["type": "color", "default": "#aabbcc"]],
            "content": ["type": "container"],
        ] as [String: Any]
    ]
    runEffects([["open_dialog": ["id": "picker"]]], ctx: [:], store: store, dialogs: dialogs)
    #expect(store.getDialog("color") as? String == "#aabbcc")
    runEffects([["set": ["fill_color": "dialog.color"]]], ctx: [:], store: store)
    #expect(store.get("fill_color") as? String == "#aabbcc")
}

// MARK: - notify_panel_state_changed hook

@Test func setPanelStateFiresNotifyHook() {
    let store = StateStore()
    store.initPanel("character_panel", defaults: ["font_family": "sans-serif"])
    var notified: [String] = []
    let hook: PlatformEffect = { panelIdAny, _, _ in
        if let pid = panelIdAny as? String { notified.append(pid) }
        return nil
    }
    runEffects(
        [["set_panel_state": ["key": "font_family", "value": "\"Arial\"", "panel": "character_panel"]]],
        ctx: [:], store: store,
        platformEffects: ["notify_panel_state_changed": hook]
    )
    #expect(store.getPanel("character_panel", "font_family") as? String == "Arial")
    #expect(notified == ["character_panel"])
}

@Test func setPanelXFiresNotifyHookForActivePanel() {
    let store = StateStore()
    store.initPanel("stroke_panel", defaults: ["cap": "butt"])
    store.setActivePanel("stroke_panel")
    var notified: [String] = []
    let hook: PlatformEffect = { panelIdAny, _, _ in
        if let pid = panelIdAny as? String { notified.append(pid) }
        return nil
    }
    // Non-schema path: writes directly to the store keyed by "panel.cap".
    // The hook detects the `panel.` prefix and fires for the active panel.
    runEffects(
        [["set": ["panel.cap": "\"round\""]]],
        ctx: [:], store: store,
        platformEffects: ["notify_panel_state_changed": hook]
    )
    #expect(notified == ["stroke_panel"])
}

@Test func notifyHookSilentWhenUnregistered() {
    let store = StateStore()
    store.initPanel("character_panel", defaults: ["font_family": "sans-serif"])
    // Should not crash or error when no hook is registered.
    runEffects(
        [["set_panel_state": ["key": "font_family", "value": "\"Arial\"", "panel": "character_panel"]]],
        ctx: [:], store: store
    )
    #expect(store.getPanel("character_panel", "font_family") as? String == "Arial")
}

// MARK: - Scope-routed set targets (Phase 1 of Swift YAML tool runtime)

@Test func setRoutesToolScopedTarget() {
    let store = StateStore()
    runEffects(
        [["set": ["tool.selection.mode": "\"marquee\""]]],
        ctx: [:], store: store
    )
    #expect(store.getTool("selection", "mode") as? String == "marquee")
}

@Test func setStripsLeadingDollarFromTarget() {
    let store = StateStore()
    runEffects(
        [["set": ["$tool.selection.mode": "\"idle\""]]],
        ctx: [:], store: store
    )
    #expect(store.getTool("selection", "mode") as? String == "idle")
}

@Test func setRoutesStateScopedTarget() {
    let store = StateStore()
    runEffects(
        [["set": ["state.fill_color": "\"#ff0000\""]]],
        ctx: [:], store: store
    )
    #expect(store.get("fill_color") as? String == "#ff0000")
}

@Test func setBareKeyStaysGlobalState() {
    // Backward compat: existing callers pass bare keys like "x"
    // and expect them in global state, not in a tool scope.
    let store = StateStore()
    runEffects(
        [["set": ["x": "42"]]],
        ctx: [:], store: store
    )
    #expect(store.get("x") as? Int == 42)
    #expect(store.getToolScopes().isEmpty)
}

@Test func setPanelScopedTargetWritesToActivePanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    runEffects(
        [["set": ["panel.mode": "\"rgb\""]]],
        ctx: [:], store: store
    )
    #expect(store.getPanel("color", "mode") as? String == "rgb")
}

@Test func evalContextReadsToolScope() {
    // After writing to tool.sel.mode, the evaluator should resolve
    // `tool.sel.mode` through the scope built by evalContext().
    let store = StateStore()
    runEffects(
        [["set": ["tool.sel.mode": "\"drag\""]]],
        ctx: [:], store: store
    )
    let ctx = store.evalContext()
    let toolDict = ctx["tool"] as? [String: [String: Any]]
    #expect(toolDict?["sel"]?["mode"] as? String == "drag")
}

@Test func toolWriteThenExpressionRead() {
    // End-to-end: handler writes $tool.sel.mode, a later expression
    // reads it.
    let store = StateStore()
    runEffects(
        [["set": ["tool.sel.mode": "\"marquee\""]]],
        ctx: [:], store: store
    )
    let v = evaluate("tool.sel.mode == \"marquee\"", context: store.evalContext())
    if case .bool(let b) = v {
        #expect(b == true)
    } else {
        Issue.record("expected Value.bool, got \(v)")
    }
}

@Test func setRoutesMultipleScopesInOneEffect() {
    let store = StateStore()
    runEffects(
        [[
            "set": [
                "tool.sel.mode": "\"idle\"",
                "state.fill_color": "\"#000000\"",
                "recent_count": "5",
            ]
        ]],
        ctx: [:], store: store
    )
    #expect(store.getTool("sel", "mode") as? String == "idle")
    #expect(store.get("fill_color") as? String == "#000000")
    #expect(store.get("recent_count") as? Int == 5)
}

// MARK: - StateStore tool-scope API

@Test func initToolSeedsDefaults() {
    let store = StateStore()
    store.initTool("pen", defaults: ["mode": "idle", "count": 0])
    #expect(store.getTool("pen", "mode") as? String == "idle")
    #expect(store.getTool("pen", "count") as? Int == 0)
}

@Test func setToolAutoCreatesNamespace() {
    // Callers that haven't run initTool still get their write
    // accepted — matches Rust's set_tool behavior.
    let store = StateStore()
    store.setTool("fresh_tool", "value", 42)
    #expect(store.getTool("fresh_tool", "value") as? Int == 42)
}

@Test func destroyToolRemovesScope() {
    let store = StateStore()
    store.setTool("pen", "x", 1)
    store.destroyTool("pen")
    #expect(store.getTool("pen", "x") == nil)
    #expect(store.hasTool("pen") == false)
}
