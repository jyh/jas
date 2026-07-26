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
    model.setDocumentForTest(Document(layers: [layer],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
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
    model.setDocumentForTest(Document(layers: [layer],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))

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
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    let o = characterPanelLiveOverrides(model: model)!
    #expect((o["leading"] as? Double) == 24.0)
}

@Test func characterElementHasAutoLeadingTrueWhenLineHeightEmpty() {
    // Empty element line_height = Auto = 120% of font_size.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 20, lineHeight: ""))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    #expect(characterElementHasAutoLeading(model: model) == true)
}

@Test func characterElementHasAutoLeadingFalseWhenLineHeightSet() {
    // Explicit line_height override = no Auto.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 20, lineHeight: "30pt"))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    #expect(characterElementHasAutoLeading(model: model) == false)
}

@Test func characterElementHasAutoLeadingFalseWhenNoSelection() {
    let model = Model()
    #expect(characterElementHasAutoLeading(model: model) == false)
}

@Test func characterElementHasAutoLeadingFalseForNonText() {
    // Rect / other non-text element → false.
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    model.setDocumentForTest(Document(layers: [Layer(children: [rect])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    #expect(characterElementHasAutoLeading(model: model) == false)
}

@Test func characterElementHasAutoLeadingTrueForTextPath() {
    let model = Model()
    let tp = Element.textPath(TextPath(d: [], content: "x", fontSize: 20,
                                        lineHeight: ""))
    model.setDocumentForTest(Document(layers: [Layer(children: [tp])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    #expect(characterElementHasAutoLeading(model: model) == true)
}

// MARK: - The element-side sibling derivations

@Test func decorationFlagsToleratesAnyWhitespace() {
    // ONE derivation feeds the DECORATION sibling rule and the panel display
    // mirror, so its tolerance has to match its peers: Rust splits with
    // `split_whitespace()`, the reference with a bare `str.split()`. A tab,
    // a newline or a doubled space between tokens is legal CSS.
    #expect(decorationFlags("underline line-through") == (true, true))
    #expect(decorationFlags("line-through  underline") == (true, true))
    #expect(decorationFlags("underline\tline-through") == (true, true))
    #expect(decorationFlags("underline\nline-through") == (true, true))
    #expect(decorationFlags("  line-through  ") == (false, true))
    #expect(decorationFlags("none") == (false, false))
    #expect(decorationFlags("") == (false, false))
}

// MARK: - The Auto-leading post-write hook
//
// The hook keeps STORED panel state saying what the reference says by
// ABSENCE. It mirrors Rust's `AppState::character_panel_post_write` one for
// one, including where it sits in the sequence (field write → hook → apply);
// `characterPanelPostWriteBumpsLeadingWhenAuto` and Rust's
// `post_write_font_size_bumps_leading_when_auto` are the same vector, and
// `fontSizeCommitThenDeselectShowsTheBumpedAutoLeading` is the paired
// cross-port pin of the outcome that is VISIBLE — what the Leading field
// reads once the selection clears and there is no element to pull from.

/// A model with one 12pt Auto-leading Text selected, plus an initialised
/// Character panel scope holding the workspace-declared defaults for the two
/// fields the hook touches.
private func modelWithAutoLeadingTextAndPanel(
    lineHeight: String = ""
) -> Model {
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                 fontSize: 12, lineHeight: lineHeight))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                                      selectedLayer: 0,
                                      selection: [ElementSelection(path: [0, 0])]))
    model.stateStore.initPanel("character_panel_content",
                               defaults: ["font_size": 12.0, "leading": 14.4])
    return model
}

private func storedLeading(_ model: Model) -> Double? {
    model.stateStore.getPanel("character_panel_content", "leading") as? Double
}

@Test func characterPanelPostWriteBumpsLeadingWhenAuto() {
    let model = modelWithAutoLeadingTextAndPanel()
    model.stateStore.setPanel("character_panel_content", "font_size", 24.0)
    characterPanelPostWrite(store: model.stateStore, model: model,
                            key: "font_size")
    #expect(storedLeading(model) == 24.0 * 1.2)
}

@Test func characterPanelPostWriteDoesNothingForOtherKeys() {
    let model = modelWithAutoLeadingTextAndPanel()
    model.stateStore.setPanel("character_panel_content", "font_size", 24.0)
    characterPanelPostWrite(store: model.stateStore, model: model,
                            key: "tracking")
    #expect(storedLeading(model) == 14.4)
}

@Test func characterPanelPostWriteDoesNothingWhenLeadingIsExplicit() {
    // The element carries an explicit line-height, so leading is NOT in Auto
    // mode and the stored number is the user's own override — untouchable.
    let model = modelWithAutoLeadingTextAndPanel(lineHeight: "20pt")
    model.stateStore.setPanel("character_panel_content", "leading", 20.0)
    model.stateStore.setPanel("character_panel_content", "font_size", 24.0)
    characterPanelPostWrite(store: model.stateStore, model: model,
                            key: "font_size")
    #expect(storedLeading(model) == 20.0)
}

@Test func fontSizeCommitThenDeselectShowsTheBumpedAutoLeading() {
    // THE CROSS-PORT PIN. Commit font_size 24 on an Auto-leading element
    // through the real funnel, then clear the selection: with nothing
    // selected the panel has no element to pull from and the Leading field
    // reads STORED state, so both ports must store 28.8. Paired with Rust's
    // `font_size_commit_then_deselect_shows_the_bumped_auto_leading`.
    let model = modelWithAutoLeadingTextAndPanel()
    model.stateStore.setPanel("character_panel_content", "font_size", 24.0)
    notifyPanelStateChanged("character_panel_content", store: model.stateStore,
                            model: model, edited: "font_size")
    // The apply is field-scoped, so Auto survives on the element itself.
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        Issue.record("expected Text"); return
    }
    #expect(t.fontSize == 24.0)
    #expect(t.lineHeight == "", "Auto is an ABSENT line-height")
    // Now the selection clears — the display falls back to stored state.
    model.setDocumentForTest(Document(layers: model.document.layers,
                                      selectedLayer: 0, selection: []))
    #expect(characterPanelLiveOverrides(model: model) == nil,
            "no selection means no pull, so the stored value is what shows")
    // Spelled as the product, not as 28.8: both ports evaluate `24.0 * 1.2`
    // in IEEE double and land on the same bits (28.799999999999997), and the
    // pin is that they agree, not that the decimal reads prettily.
    #expect(storedLeading(model) == 24.0 * 1.2)
}

@Test func applyCharacterPanelLeadingNilPreservesAutoLineHeight() {
    // End-to-end nullable-clear: when the user clears the leading
    // input the renderer drops panel.leading from the store. The
    // apply pipeline must re-derive line_height = "" (empty Auto)
    // rather than write a stale numeric override. Mirrors the Rust
    // `render_length_input` Character branch where clearing leading
    // sets panel.leading = font_size * 1.2 and re-applies.
    let model = Model()
    // Element starts with an explicit leading (non-Auto). After the
    // clear, line_height should round-trip back to empty.
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 20, lineHeight: "30pt"))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    // Seed the production-id panel with a font_size and *no* leading
    // entry (the clear path's effective state once setPanel(...,
    // "leading", nil) removes the key).
    model.stateStore.initPanel("character_panel_content", defaults: [
        "font_family": "sans-serif",
        "font_size": 20.0,
        "style_name": "Regular",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "anti_aliasing": "Sharp",
        "tracking": 0.0,
        "kerning": "Auto",
        "vertical_scale": 100.0, "horizontal_scale": 100.0,
        "baseline_shift": 0.0, "character_rotation": 0.0,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: "leading")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        #expect(Bool(false), "expected Text"); return
    }
    #expect(t.lineHeight == "",
            "leading missing from panel state must round-trip to empty Auto line_height")
}

@Test func applyCharacterPanelLeadingAtAutoValueWritesEmpty() {
    // Equivalent of the explicit Rust behavior: when the panel
    // carries leading = font_size * 1.2 the apply still writes
    // line_height = "" (Auto preserved).
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 20, lineHeight: "30pt"))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    model.stateStore.initPanel("character_panel_content", defaults: [
        "font_family": "sans-serif",
        "font_size": 20.0,
        "style_name": "Regular",
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
        "language": "",
        "anti_aliasing": "Sharp",
        "leading": 24.0,   // = 20 * 1.2 → Auto
        "tracking": 0.0,
        "kerning": "Auto",
        "vertical_scale": 100.0, "horizontal_scale": 100.0,
        "baseline_shift": 0.0, "character_rotation": 0.0,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: "leading")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        #expect(Bool(false), "expected Text"); return
    }
    #expect(t.lineHeight == "",
            "leading at the Auto ratio must write line_height = \"\"")
}

@Test func characterPanelLiveOverridesTextPath() {
    let model = Model()
    let tp = Element.textPath(TextPath(
        d: [], content: "path",
        fontFamily: "Courier", fontSize: 14,
        fontVariant: "small-caps"))
    model.setDocumentForTest(Document(layers: [Layer(children: [tp])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
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
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    model.stateStore.initPanel("character_panel_content",
                               defaults: ["font_family": "Arial", "font_size": 12.0])
    notifyPanelStateChanged("character_panel_content", store: model.stateStore,
                            model: model, edited: "font_family")
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
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    let o = characterPanelLiveOverrides(model: model)!
    #expect(o["kerning"] as? String == "Optical")
}

@Test func characterPanelLiveOverridesKerningEmptyShowsAuto() {
    // Empty element attribute → "Auto" in the panel (spec default).
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi", fontSize: 12, kerning: ""))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    let o = characterPanelLiveOverrides(model: model)!
    #expect(o["kerning"] as? String == "Auto")
}

@Test func applyCharacterPanelKerningNamedModesPassThrough() {
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi"))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    // Auto / "" / "0" all produce an empty element attribute.
    for mode in ["Auto", "", "0"] {
        model.stateStore.initPanel("character_panel_content", defaults: ["kerning": mode])
        applyCharacterPanelToSelection(store: model.stateStore,
                                        controller: Controller(model: model),
                                        edited: "kerning")
        if case .text(let t) = model.document.getElement([0, 0]) {
            #expect(t.kerning == "", "mode \(mode) should clear kerning")
        }
    }
    // Named mode passes through verbatim.
    model.stateStore.initPanel("character_panel_content", defaults: ["kerning": "Optical"])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: "kerning")
    if case .text(let t) = model.document.getElement([0, 0]) {
        #expect(t.kerning == "Optical")
    }
    // Numeric string converts to "{N}em".
    model.stateStore.initPanel("character_panel_content", defaults: ["kerning": "25"])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: "kerning")
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

@Test func applyCharacterPanelLanguageFlowsToElement() {
    // Production panel id ("character_panel_content") flow: changing
    // panel.language should update the selected element's xmlLang.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi", xmlLang: ""))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    model.stateStore.initPanel("character_panel_content", defaults: [
        "font_family": "sans-serif",
        "font_size": 16.0,
        "style_name": "Regular",
        "language": "fr",
        "anti_aliasing": "Sharp",
        "leading": 19.2,
        "tracking": 0.0,
        "kerning": "Auto",
        "vertical_scale": 100.0, "horizontal_scale": 100.0,
        "baseline_shift": 0.0, "character_rotation": 0.0,
        "all_caps": false, "small_caps": false,
        "superscript": false, "subscript": false,
        "underline": false, "strikethrough": false,
    ])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model),
                                    edited: "language")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        #expect(Bool(false), "expected Text"); return
    }
    #expect(t.xmlLang == "fr")
}

@Test func applyCharacterPanelWritesAttrsToSelection() {
    // Direct test of the pipeline: seed panel scope with new values, then
    // commit each field in turn. The apply is FIELD-SCOPED, so four
    // attributes take four commits — one apply can only write the group the
    // named field owns. (That is the point: the panel no longer stamps the
    // other three on every edit.)
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontFamily: "Helvetica", fontSize: 12))
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    model.stateStore.initPanel("character_panel_content", defaults: [
        "font_family": "Arial",
        "font_size": 18.0,
        "all_caps": true,
        "superscript": false, "subscript": false,
        "underline": true, "strikethrough": false,
    ])
    for field in ["font_family", "font_size", "all_caps", "underline"] {
        applyCharacterPanelToSelection(store: model.stateStore,
                                        controller: Controller(model: model),
                                        edited: field)
    }
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
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    // Install an active session with a bare caret at char 3.
    let session = TextEditSession(path: [0, 0], target: .text,
                                   content: "hello", insertion: 3)
    model.currentEditSession = session

    model.stateStore.initPanel("character_panel_content", defaults: [
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
                                    controller: Controller(model: model),
                                    edited: "style_name")
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
    model.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    let session = TextEditSession(path: [0, 0], target: .text,
                                   content: "hello", insertion: 1)
    session.setInsertion(4, extend: true)  // selection [1, 4) → "ell"
    model.currentEditSession = session

    model.stateStore.initPanel("character_panel_content", defaults: [
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
                                    controller: Controller(model: model),
                                    edited: "style_name")
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

// MARK: - identity-omission

@Test func identityOmitClearsFontWeightMatchingElement() {
    let t = Tspan(id: 0, content: "X", fontWeight: "normal")
    let elem = Element.text(emptyTextElem(x: 0, y: 0, width: 0, height: 0))
    // empty_text_elem has fontWeight="normal", so Some("normal") is redundant.
    let out = identityOmitTspan(t, elem)
    #expect(out.fontWeight == nil)
}

@Test func identityOmitKeepsFontWeightDifferingFromElement() {
    let t = Tspan(id: 0, content: "X", fontWeight: "bold")
    let elem = Element.text(emptyTextElem(x: 0, y: 0, width: 0, height: 0))
    let out = identityOmitTspan(t, elem)
    #expect(out.fontWeight == "bold")
}

@Test func identityOmitClearsLineHeightMatchingAutoDefault() {
    // Element's empty line_height = auto = 120% of fontSize.
    let t = Tspan(id: 0, content: "X", lineHeight: 16.0 * 1.2)
    let elem = Element.text(emptyTextElem(x: 0, y: 0, width: 0, height: 0))
    let out = identityOmitTspan(t, elem)
    #expect(out.lineHeight == nil)
}

@Test func identityOmitEndToEndPerRangeWrite() {
    // Applying fontWeight=normal to a bold range where the element
    // is also normal should collapse all the way to a single plain
    // tspan via identity-omission + merge.
    let base = [Tspan(id: 0, content: "foo", fontWeight: "bold")]
    let overrides = Tspan(id: 0, content: "", fontWeight: "normal")
    let elem = Element.text(emptyTextElem(x: 0, y: 0, width: 0, height: 0))
    let out = applyOverridesToTspanRange(
        base, charStart: 0, charEnd: 3, overrides: overrides, elem: elem)
    #expect(out.count == 1)
    #expect(out[0].content == "foo")
    #expect(out[0].fontWeight == nil)
}
