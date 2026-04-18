import Testing
@testable import JasLib

// MARK: - Selection → Character panel live overrides

@Test func characterPanelLiveOverridesEmpty() {
    let model = Model()
    // No selection, no overrides.
    #expect(characterPanelLiveOverrides(model: model) == nil)
}

@Test func characterPanelLiveOverridesNonTextSelected() {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    let layer = Layer(children: [rect])
    model.document = Document(layers: [layer],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    #expect(characterPanelLiveOverrides(model: model) == nil)
}

@Test func characterPanelLiveOverridesText() {
    let model = Model()
    let text = Element.text(Text(
        x: 0, y: 0, content: "hello",
        fontFamily: "Helvetica", fontSize: 18,
        fontWeight: "bold", fontStyle: "italic",
        textDecoration: "underline line-through",
        textTransform: "uppercase", fontVariant: "",
        baselineShift: "super", lineHeight: "",
        letterSpacing: "0.05em", xmlLang: "en",
        aaMode: "Smooth", rotate: "15",
        horizontalScale: "120", verticalScale: "110",
        kerning: "0.02em"))
    let layer = Layer(children: [text])
    model.document = Document(layers: [layer],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])

    guard let o = characterPanelLiveOverrides(model: model) else {
        #expect(Bool(false), "expected overrides from text selection")
        return
    }
    #expect(o["font_family"] as? String == "Helvetica")
    #expect((o["font_size"] as? Double) == 18)
    #expect(o["style_name"] as? String == "Bold Italic")
    #expect(o["underline"] as? Bool == true)
    #expect(o["strikethrough"] as? Bool == true)
    #expect(o["all_caps"] as? Bool == true)
    #expect(o["superscript"] as? Bool == true)
    #expect(o["subscript"] as? Bool == false)
    // super/sub suppress numeric baseline-shift.
    #expect((o["baseline_shift"] as? Double) == 0.0)
    // tracking = 0.05em → 50 thousandths.
    #expect((o["tracking"] as? Double) == 50.0)
    // kerning combo_box display: numeric "0.02em" → "20" (1/1000 em).
    #expect(o["kerning"] as? String == "20")
    #expect((o["character_rotation"] as? Double) == 15.0)
    #expect((o["horizontal_scale"] as? Double) == 120.0)
    #expect((o["vertical_scale"] as? Double) == 110.0)
    #expect(o["language"] as? String == "en")
    #expect(o["anti_aliasing"] as? String == "Smooth")
}

@Test func characterPanelLiveOverridesLeadingAuto() {
    // Empty line_height → panel shows 120% Auto (font_size * 1.2).
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 20, lineHeight: ""))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = characterPanelLiveOverrides(model: model)!
    #expect((o["leading"] as? Double) == 24.0)
}

@Test func characterPanelLiveOverridesTextPath() {
    let model = Model()
    let tp = Element.textPath(TextPath(
        d: [], content: "path",
        fontFamily: "Courier", fontSize: 14,
        fontVariant: "small-caps"))
    model.document = Document(layers: [Layer(children: [tp])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = characterPanelLiveOverrides(model: model)!
    #expect(o["font_family"] as? String == "Courier")
    #expect(o["small_caps"] as? Bool == true)
}

// MARK: - notifyPanelStateChanged routing

@Test func notifyPanelStateChangedCharacterRoute() {
    // End-to-end: set panel.font_family → notifyPanelStateChanged →
    // applyCharacterPanelToSelection writes to selected text.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hello", fontFamily: "Helvetica"))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    model.stateStore.initPanel("character_panel",
                               defaults: ["font_family": "Arial", "font_size": 12.0])
    notifyPanelStateChanged("character_panel", store: model.stateStore, model: model)
    if case .text(let t) = model.document.getElement([0, 0]) {
        #expect(t.fontFamily == "Arial")
    } else {
        #expect(Bool(false), "expected Text element")
    }
}

@Test func characterPanelLiveOverridesKerningNamedMode() {
    // Element kerning "Optical" passes through verbatim to the panel.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 12, kerning: "Optical"))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = characterPanelLiveOverrides(model: model)!
    #expect(o["kerning"] as? String == "Optical")
}

@Test func characterPanelLiveOverridesKerningEmptyShowsAuto() {
    // Empty element attribute → "Auto" in the panel (spec default).
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi", fontSize: 12, kerning: ""))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = characterPanelLiveOverrides(model: model)!
    #expect(o["kerning"] as? String == "Auto")
}

@Test func applyCharacterPanelKerningNamedModesPassThrough() {
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi"))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    // Auto / "" / "0" all produce an empty element attribute.
    for mode in ["Auto", "", "0"] {
        model.stateStore.initPanel("character_panel", defaults: ["kerning": mode])
        applyCharacterPanelToSelection(store: model.stateStore,
                                        controller: Controller(model: model))
        if case .text(let t) = model.document.getElement([0, 0]) {
            #expect(t.kerning == "", "mode \(mode) should clear kerning")
        }
    }
    // Named mode passes through verbatim.
    model.stateStore.initPanel("character_panel", defaults: ["kerning": "Optical"])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    if case .text(let t) = model.document.getElement([0, 0]) {
        #expect(t.kerning == "Optical")
    }
    // Numeric string converts to "{N}em".
    model.stateStore.initPanel("character_panel", defaults: ["kerning": "25"])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    if case .text(let t) = model.document.getElement([0, 0]) {
        #expect(t.kerning == "0.025em")
    }
}

@Test func notifyPanelStateChangedUnknownPanelIsNoOp() {
    // No crash and no mutation for panels without a subscriber.
    let model = Model()
    model.stateStore.initPanel("something_else", defaults: ["k": "v"])
    notifyPanelStateChanged("something_else", store: model.stateStore, model: model)
    #expect(model.stateStore.getPanel("something_else", "k") as? String == "v")
}

@Test func applyCharacterPanelWritesAttrsToSelection() {
    // Direct test of the pipeline: seed panel scope with new values,
    // call apply — the selected text picks them up.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontFamily: "Helvetica", fontSize: 12))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    model.stateStore.initPanel("character_panel", defaults: [
        "font_family": "Arial",
        "font_size": 18.0,
        "all_caps": true,
        "superscript": false, "subscript": false,
        "underline": true, "strikethrough": false,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        #expect(Bool(false), "expected Text"); return
    }
    #expect(t.fontFamily == "Arial")
    #expect(t.fontSize == 18.0)
    #expect(t.textTransform == "uppercase")
    #expect(t.textDecoration == "underline")
}
