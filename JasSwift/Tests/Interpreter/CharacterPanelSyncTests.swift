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

// MARK: - Phase 3: Character panel → pending override routing

@Test func templateEmptyWhenPanelMatchesElement() {
    let text = Element.text(Text(
        x: 0, y: 0, content: "",
        fontFamily: "sans-serif", fontSize: 16,
        fontWeight: "normal", fontStyle: "normal",
        textDecoration: "", textTransform: "", fontVariant: "",
        xmlLang: "", rotate: ""))
    let panel: [String: Any] = [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Regular",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ]
    #expect(buildPanelPendingTemplate(panel, text) == nil)
}

@Test func templateBoldSetsFontWeightOnly() {
    let text = Element.text(Text(
        x: 0, y: 0, content: "",
        fontFamily: "sans-serif", fontSize: 16,
        fontWeight: "normal", fontStyle: "normal",
        textDecoration: "", textTransform: "", fontVariant: "",
        xmlLang: "", rotate: ""))
    let panel: [String: Any] = [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Bold",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ]
    let tpl = buildPanelPendingTemplate(panel, text)
    #expect(tpl != nil)
    #expect(tpl?.fontWeight == "bold")
    #expect(tpl?.fontStyle == nil)
    #expect(tpl?.fontSize == nil)
    #expect(tpl?.fontFamily == nil)
}

@Test func templateTextDecorationNormalizesNoneToEmpty() {
    // Element stores "none" (CSS default). Panel has both flags off.
    // These represent the same state — template should be nil.
    let text = Element.text(Text(
        x: 0, y: 0, content: "",
        fontFamily: "sans-serif", fontSize: 16,
        textDecoration: "none"))
    let panel: [String: Any] = [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Regular",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ]
    #expect(buildPanelPendingTemplate(panel, text) == nil)
}

@Test func panelWriteWithBareCaretSetsPendingOnSession() {
    let model = Model()
    let text = Element.text(Text(
        x: 0, y: 0, content: "hello",
        fontFamily: "sans-serif", fontSize: 16,
        fontWeight: "normal", fontStyle: "normal"))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    // Install an active session with a bare caret at char 3.
    let session = TextEditSession(path: [0, 0], target: .text,
                                   content: "hello", insertion: 3)
    model.currentEditSession = session

    model.stateStore.initPanel("character_panel", defaults: [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Bold",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    // Session picked up pending; element untouched.
    #expect(session.hasPendingOverride)
    #expect(session.pendingCharStart == 3)
    #expect(session.pendingOverride?.fontWeight == "bold")
    if case .text(let t) = model.document.getElement([0, 0]) {
        #expect(t.fontWeight == "normal")  // unchanged
    }
}

@Test func panelWriteWithRangeSelectionWritesToRange() {
    let model = Model()
    // Text with three plain tspans' worth of content (single tspan).
    let text = Element.text(Text(
        x: 0, y: 0, content: "hello",
        fontFamily: "sans-serif", fontSize: 16,
        fontWeight: "normal", fontStyle: "normal"))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let session = TextEditSession(path: [0, 0], target: .text,
                                   content: "hello", insertion: 1)
    session.setInsertion(4, extend: true)  // selection [1, 4) → "ell"
    model.currentEditSession = session

    model.stateStore.initPanel("character_panel", defaults: [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Bold",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    // Bare caret pending stays empty.
    #expect(!session.hasPendingOverride)
    // Element-level weight is unchanged; the range picks up bold via
    // a tspan override.
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        Issue.record("expected Text"); return
    }
    #expect(t.fontWeight == "normal")
    // Three tspans now: "h" plain, "ell" bold, "o" plain.
    #expect(t.tspans.count == 3)
    #expect(t.tspans[0].content == "h")
    #expect(t.tspans[0].fontWeight != "bold")
    #expect(t.tspans[1].content == "ell")
    #expect(t.tspans[1].fontWeight == "bold")
    #expect(t.tspans[2].content == "o")
    #expect(t.tspans[2].fontWeight != "bold")
}

// MARK: - full-overrides builder and range applier

@Test func fullOverridesSetsEveryScopeField() {
    let panel: [String: Any] = [
        "font_family": "sans-serif",
        "font_size": 12.0,
        "style_name": "Bold",
        "all_caps": true,
        "small_caps": false,
        "superscript": false,
        "subscript": false,
        "underline": true,
        "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ]
    let t = buildPanelFullOverrides(panel)
    #expect(t.fontFamily == "sans-serif")
    #expect(t.fontSize == 12.0)
    #expect(t.fontWeight == "bold")
    #expect(t.fontStyle == "normal")
    #expect(t.textTransform == "uppercase")
    #expect(t.textDecoration == ["underline"])
}

@Test func fullOverridesRegularStyleForcesNormalNotNil() {
    let panel: [String: Any] = [
        "style_name": "Regular",
        "font_family": "sans-serif",
        "font_size": 12.0,
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
    ]
    let t = buildPanelFullOverrides(panel)
    #expect(t.fontWeight == "normal")
    #expect(t.fontStyle == "normal")
}

@Test func applyOverridesToRangeBoldsPartialWord() {
    let base = [Tspan(id: 0, content: "hello")]
    let overrides = Tspan(id: 0, content: "", fontWeight: "bold")
    let out = applyOverridesToTspanRange(base, charStart: 1, charEnd: 4,
                                          overrides: overrides)
    #expect(out.count == 3)
    #expect(out[0].content == "h")
    #expect(out[1].content == "ell")
    #expect(out[1].fontWeight == "bold")
    #expect(out[2].content == "o")
    #expect(out[2].fontWeight != "bold")
}

@Test func applyOverridesToEmptyRangeIsPassthrough() {
    let base = [Tspan(id: 0, content: "hello")]
    let overrides = Tspan(id: 0, content: "", fontWeight: "bold")
    let out = applyOverridesToTspanRange(base, charStart: 2, charEnd: 2,
                                          overrides: overrides)
    #expect(out == base)
}

@Test func applyOverridesMergesAdjacentEqual() {
    let base = [
        Tspan(id: 0, content: "foo"),
        Tspan(id: 1, content: "bar"),
    ]
    let overrides = Tspan(id: 0, content: "", fontWeight: "bold")
    let out = applyOverridesToTspanRange(base, charStart: 0, charEnd: 6,
                                          overrides: overrides)
    #expect(out.count == 1)
    #expect(out[0].content == "foobar")
    #expect(out[0].fontWeight == "bold")
}

// MARK: - Phase 3 complex attrs (line-height, tracking, baseline-shift, aa)

private func _defaultElemText() -> Element {
    .text(Text(x: 0, y: 0, content: "",
                fontFamily: "sans-serif", fontSize: 16,
                fontWeight: "normal", fontStyle: "normal",
                textDecoration: "", textTransform: "", fontVariant: "",
                baselineShift: "", lineHeight: "", letterSpacing: "",
                xmlLang: "", aaMode: "", rotate: ""))
}

private func _alignedPanelSwift() -> [String: Any] {
    return [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Regular",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "character_rotation": 0.0,
        "leading": 16.0 * 1.2,   // auto default
        "tracking": 0.0,
        "baseline_shift": 0.0,
        "anti_aliasing": "Sharp",
    ]
}

@Test func templateLeadingDiffersFromAuto() {
    var panel = _alignedPanelSwift()
    panel["leading"] = 32.0  // 2× font_size → non-auto
    let tpl = buildPanelPendingTemplate(panel, _defaultElemText())
    #expect(tpl != nil)
    #expect(tpl?.lineHeight == 32.0)
}

@Test func templateTrackingDiffersFromZero() {
    var panel = _alignedPanelSwift()
    panel["tracking"] = 50.0
    let tpl = buildPanelPendingTemplate(panel, _defaultElemText())
    #expect(tpl != nil)
    #expect(abs((tpl?.letterSpacing ?? 0) - 0.05) < 1e-9)
}

@Test func templateBaselineShiftNumeric() {
    var panel = _alignedPanelSwift()
    panel["baseline_shift"] = 3.0
    let tpl = buildPanelPendingTemplate(panel, _defaultElemText())
    #expect(tpl != nil)
    #expect(tpl?.baselineShift == 3.0)
}

@Test func templateBaselineShiftSkippedWhenSuperOn() {
    var panel = _alignedPanelSwift()
    panel["superscript"] = true
    panel["baseline_shift"] = 3.0  // should be ignored
    let tpl = buildPanelPendingTemplate(panel, _defaultElemText())
    if let t = tpl {
        #expect(t.baselineShift == nil)
    }
}

@Test func templateAntiAliasingDiffersFromSharp() {
    var panel = _alignedPanelSwift()
    panel["anti_aliasing"] = "Smooth"
    let tpl = buildPanelPendingTemplate(panel, _defaultElemText())
    #expect(tpl != nil)
    #expect(tpl?.jasAaMode == "Smooth")
}

@Test func fullOverridesIncludesComplexAttrs() {
    let panel = _alignedPanelSwift()
    let t = buildPanelFullOverrides(panel)
    // Full builder always writes these fields.
    #expect(t.lineHeight != nil)
    #expect(t.letterSpacing != nil)
    #expect(t.baselineShift != nil)
    #expect(t.jasAaMode != nil)
}
