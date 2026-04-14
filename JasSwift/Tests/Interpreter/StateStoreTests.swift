import Testing
@testable import JasLib

// MARK: - Global state

@Test func getSetGlobal() {
    let store = StateStore()
    store.set("x", 5)
    #expect(store.get("x") as? Int == 5)
}

@Test func getMissingReturnsNil() {
    let store = StateStore()
    #expect(store.get("missing") == nil)
}

@Test func initFromDefaults() {
    let store = StateStore(defaults: ["x": 10, "y": "hello"])
    #expect(store.get("x") as? Int == 10)
    #expect(store.get("y") as? String == "hello")
}

@Test func getAll() {
    let store = StateStore(defaults: ["a": 1, "b": 2])
    let all = store.getAll()
    #expect(all["a"] as? Int == 1)
    #expect(all["b"] as? Int == 2)
}

// MARK: - Panel state

@Test func initPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb", "h": 0])
    #expect(store.getPanel("color", "mode") as? String == "hsb")
    #expect(store.getPanel("color", "h") as? Int == 0)
}

@Test func setPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setPanel("color", "mode", "rgb")
    #expect(store.getPanel("color", "mode") as? String == "rgb")
}

@Test func panelScoping() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.initPanel("swatches", defaults: ["mode": "grid"])
    #expect(store.getPanel("color", "mode") as? String == "hsb")
    #expect(store.getPanel("swatches", "mode") as? String == "grid")
}

@Test func activePanelState() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    let state = store.getActivePanelState()
    #expect(state["mode"] as? String == "hsb")
}

@Test func destroyPanel() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.destroyPanel("color")
    #expect(store.getPanel("color", "mode") == nil)
}

// MARK: - Dialog state

@Test func initDialog() {
    let store = StateStore()
    store.initDialog("color_picker",
                     defaults: ["h": 0, "color": "#ffffff"],
                     params: ["target": "fill"])
    #expect(store.getDialogId() == "color_picker")
    #expect(store.getDialog("h") as? Int == 0)
    #expect(store.getDialog("color") as? String == "#ffffff")
    #expect(store.getDialogParams()?["target"] as? String == "fill")
}

@Test func getSetDialog() {
    let store = StateStore()
    store.initDialog("test", defaults: ["name": ""])
    store.setDialog("name", "hello")
    #expect(store.getDialog("name") as? String == "hello")
}

@Test func getDialogNoDialogReturnsNil() {
    let store = StateStore()
    #expect(store.getDialog("anything") == nil)
    #expect(store.getDialogId() == nil)
    #expect(store.getDialogParams() == nil)
}

@Test func closeDialog() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["p": "v"])
    store.closeDialog()
    #expect(store.getDialogId() == nil)
    #expect(store.getDialog("x") == nil)
    #expect(store.getDialogParams() == nil)
    #expect(store.getDialogState().isEmpty)
}

@Test func dialogStateReturnsCopy() {
    let store = StateStore()
    store.initDialog("test", defaults: ["a": 1, "b": 2])
    var state = store.getDialogState()
    state["a"] = 999
    #expect(store.getDialog("a") as? Int == 1)
}

@Test func initDialogReplacesPrevious() {
    let store = StateStore()
    store.initDialog("first", defaults: ["x": 1])
    store.initDialog("second", defaults: ["y": 2])
    #expect(store.getDialogId() == "second")
    #expect(store.getDialog("x") == nil)
    #expect(store.getDialog("y") as? Int == 2)
}

// MARK: - Eval context

@Test func evalContextBasic() {
    let store = StateStore(defaults: ["fill_color": "#ff0000"])
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    let ctx = store.evalContext()
    let stateDict = ctx["state"] as? [String: Any]
    let panelDict = ctx["panel"] as? [String: Any]
    #expect(stateDict?["fill_color"] as? String == "#ff0000")
    #expect(panelDict?["mode"] as? String == "hsb")
}

@Test func evalContextIncludesDialog() {
    let store = StateStore(defaults: ["fill_color": "#ff0000"])
    store.initDialog("test", defaults: ["h": 180, "s": 50])
    let ctx = store.evalContext()
    let dialogDict = ctx["dialog"] as? [String: Any]
    #expect(dialogDict?["h"] as? Int == 180)
    #expect(dialogDict?["s"] as? Int == 50)
}

@Test func evalContextIncludesDialogParams() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["target": "fill"])
    let ctx = store.evalContext()
    let paramDict = ctx["param"] as? [String: Any]
    #expect(paramDict?["target"] as? String == "fill")
}

@Test func evalContextExtraOverridesDialogParams() {
    let store = StateStore()
    store.initDialog("test", defaults: ["x": 1], params: ["target": "fill"])
    let ctx = store.evalContext(extra: ["param": ["target": "stroke"]])
    let paramDict = ctx["param"] as? [String: Any]
    #expect(paramDict?["target"] as? String == "stroke")
}

@Test func evalContextNoDialogOmitsKey() {
    let store = StateStore(defaults: ["x": 1])
    let ctx = store.evalContext()
    #expect(ctx["dialog"] == nil)
}

@Test func dialogAndPanelCoexist() {
    let store = StateStore()
    store.initPanel("color", defaults: ["mode": "hsb"])
    store.setActivePanel("color")
    store.initDialog("picker", defaults: ["h": 270])
    let ctx = store.evalContext()
    let panelDict = ctx["panel"] as? [String: Any]
    let dialogDict = ctx["dialog"] as? [String: Any]
    #expect(panelDict?["mode"] as? String == "hsb")
    #expect(dialogDict?["h"] as? Int == 270)
}

// MARK: - List push

@Test func listPushToFront() {
    let store = StateStore()
    store.initPanel("color", defaults: ["recent": ["a", "b", "c"]])
    store.listPush("color", "recent", "d")
    let result = store.getPanel("color", "recent") as? [String]
    #expect(result == ["d", "a", "b", "c"])
}

@Test func listPushMaxLength() {
    let store = StateStore()
    store.initPanel("color", defaults: ["recent": ["a", "b", "c"]])
    store.listPush("color", "recent", "d", maxLength: 3)
    let result = store.getPanel("color", "recent") as? [String]
    #expect(result == ["d", "a", "b"])
}
