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
