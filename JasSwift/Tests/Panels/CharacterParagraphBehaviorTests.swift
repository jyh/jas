import Testing
@testable import JasLib

// Cross-language SEAM BEHAVIOR tests for the Character and Paragraph
// panels' panel->element mapping. Ported from the Python reference
// tests jas/panels/character_panel_state_test.py and
// paragraph_panel_state_test.py so the SAME input->output values gate
// the Swift apply pipeline. See CLAUDE.md (equivalence prime directive).
//
// The Swift apply seam has no exported pure "_attrs_from_panel" helper
// (attrs are built inline in applyCharacterPanelToSelection before
// Controller.setSelectionTextAttributes writes them onto the element),
// so every Character case here is exercised END-TO-END: seed the
// production panel scope, run apply against a document with a selected
// Text, then assert the resulting element attribute. This mirrors
// Python's _attrs_from_panel + TestApplyEndToEnd cases with identical
// values.

// MARK: - Character helpers

/// Build a Model whose single selected element is a Text with the
/// given baseline attributes, ready for applyCharacterPanelToSelection.
private func charModelWithSelectedText(
    fontSize: Double = 12
) -> Model {
    let model = Model()
    let text = Element.text(Text(
        x: 0, y: 0, content: "hello",
        fontFamily: "serif", fontSize: fontSize,
        fontWeight: "normal", fontStyle: "normal",
        textDecoration: "", textTransform: "", fontVariant: "",
        baselineShift: "", lineHeight: "", letterSpacing: "",
        xmlLang: "", aaMode: "", rotate: "",
        horizontalScale: "", verticalScale: "", kerning: ""))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [text])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

/// Seed the production Character panel scope with `keys`, run apply,
/// and return the resulting selected Text element.
private func applyCharPanel(
    _ model: Model, _ keys: [String: Any]
) -> Text {
    model.stateStore.initPanel("character_panel_content", defaults: keys)
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        fatalError("expected Text at [0,0]")
    }
    return t
}

// MARK: - font_size

@Test func charFontSize24On12pt() {
    // panel font_size=24 on a 12pt text -> element font_size == 24.
    let m = charModelWithSelectedText(fontSize: 12)
    let t = applyCharPanel(m, ["font_size": 24.0])
    #expect(t.fontSize == 24)
}

// MARK: - style_name -> font_weight + font_style

@Test func charStyleBold() {
    let t = applyCharPanel(charModelWithSelectedText(), ["style_name": "Bold"])
    #expect(t.fontWeight == "bold")
    #expect(t.fontStyle == "normal")
}

@Test func charStyleItalic() {
    let t = applyCharPanel(charModelWithSelectedText(), ["style_name": "Italic"])
    #expect(t.fontWeight == "normal")
    #expect(t.fontStyle == "italic")
}

@Test func charStyleBoldItalic() {
    let t = applyCharPanel(charModelWithSelectedText(), ["style_name": "Bold Italic"])
    #expect(t.fontWeight == "bold")
    #expect(t.fontStyle == "italic")
}

@Test func charStyleRegular() {
    // Element starts normal/normal; Regular keeps it explicit.
    let m = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontWeight: "bold", fontStyle: "italic"))
    m.setDocumentForTest(Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])]))
    let t = applyCharPanel(m, ["style_name": "Regular"])
    #expect(t.fontWeight == "normal")
    #expect(t.fontStyle == "normal")
}

// MARK: - all_caps / small_caps -> text_transform / font_variant

@Test func charAllCaps() {
    let t = applyCharPanel(charModelWithSelectedText(), ["all_caps": true])
    #expect(t.textTransform == "uppercase")
    #expect(t.fontVariant == "")
}

@Test func charSmallCaps() {
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["small_caps": true, "all_caps": false])
    #expect(t.fontVariant == "small-caps")
    #expect(t.textTransform == "")
}

@Test func charAllCapsWinsOverSmallCaps() {
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["all_caps": true, "small_caps": true])
    #expect(t.textTransform == "uppercase")
    #expect(t.fontVariant == "")
}

// MARK: - underline / strikethrough -> text_decoration

@Test func charUnderline() {
    let t = applyCharPanel(charModelWithSelectedText(), ["underline": true])
    #expect(t.textDecoration == "underline")
}

@Test func charStrikethrough() {
    let t = applyCharPanel(charModelWithSelectedText(), ["strikethrough": true])
    #expect(t.textDecoration == "line-through")
}

@Test func charUnderlineAndStrikethroughAlphabetical() {
    // Both flags -> "line-through underline" (alphabetical order).
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["underline": true, "strikethrough": true])
    #expect(t.textDecoration == "line-through underline")
}

// MARK: - leading -> line_height

@Test func charLeadingAutoEmpties() {
    // leading == font_size*1.2 (Auto) -> line_height "".
    let t = applyCharPanel(charModelWithSelectedText(fontSize: 12),
                           ["font_size": 12.0, "leading": 14.4])
    #expect(t.lineHeight == "")
}

@Test func charLeadingNumeric() {
    // leading=20 (off Auto) -> "20pt".
    let m = charModelWithSelectedText(fontSize: 12)
    // Element carries an explicit line_height so we can see it change.
    let t = applyCharPanel(m, ["font_size": 12.0, "leading": 20.0])
    #expect(t.lineHeight == "20pt")
}

// MARK: - tracking -> letter_spacing

@Test func charTrackingZeroEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(), ["tracking": 0.0])
    #expect(t.letterSpacing == "")
}

@Test func charTrackingPositive() {
    // tracking=25 -> 25/1000 em = "0.025em".
    let t = applyCharPanel(charModelWithSelectedText(), ["tracking": 25.0])
    #expect(t.letterSpacing == "0.025em")
}

// MARK: - kerning

@Test func charKerningPositive() {
    // kerning=50 (numeric string, combo_box commits strings) -> "0.05em".
    let t = applyCharPanel(charModelWithSelectedText(), ["kerning": "50"])
    #expect(t.kerning == "0.05em")
}

@Test func charKerningAutoEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(), ["kerning": "Auto"])
    #expect(t.kerning == "")
}

@Test func charKerningNamedPassesThrough() {
    let t = applyCharPanel(charModelWithSelectedText(), ["kerning": "Optical"])
    #expect(t.kerning == "Optical")
}

// MARK: - baseline_shift

@Test func charBaselineShiftZeroEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(), ["baseline_shift": 0.0])
    #expect(t.baselineShift == "")
}

@Test func charBaselineShiftNumeric() {
    // baseline_shift=3 -> "3pt".
    let t = applyCharPanel(charModelWithSelectedText(), ["baseline_shift": 3.0])
    #expect(t.baselineShift == "3pt")
}

@Test func charBaselineShiftSuperWins() {
    // superscript wins over numeric -> "super".
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["superscript": true, "baseline_shift": 5.0])
    #expect(t.baselineShift == "super")
}

@Test func charBaselineShiftSub() {
    let t = applyCharPanel(charModelWithSelectedText(), ["subscript": true])
    #expect(t.baselineShift == "sub")
}

// MARK: - character_rotation -> rotate

@Test func charRotationZeroEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(), ["character_rotation": 0.0])
    #expect(t.rotate == "")
}

@Test func charRotationNumeric() {
    // character_rotation=15 -> "15".
    let t = applyCharPanel(charModelWithSelectedText(), ["character_rotation": 15.0])
    #expect(t.rotate == "15")
}

// MARK: - horizontal / vertical scale

@Test func charScaleIdentityEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["horizontal_scale": 100.0, "vertical_scale": 100.0])
    #expect(t.horizontalScale == "")
    #expect(t.verticalScale == "")
}

@Test func charScaleOffIdentity() {
    // horizontal_scale=120, vertical_scale=90 -> "120" / "90".
    let t = applyCharPanel(charModelWithSelectedText(),
                           ["horizontal_scale": 120.0, "vertical_scale": 90.0])
    #expect(t.horizontalScale == "120")
    #expect(t.verticalScale == "90")
}

// MARK: - language -> xml_lang

@Test func charLanguage() {
    let t = applyCharPanel(charModelWithSelectedText(), ["language": "fr"])
    #expect(t.xmlLang == "fr")
}

// MARK: - anti_aliasing -> aa_mode

@Test func charAntiAliasingSharpEmpties() {
    let t = applyCharPanel(charModelWithSelectedText(), ["anti_aliasing": "Sharp"])
    #expect(t.aaMode == "")
}

@Test func charAntiAliasingNonDefault() {
    let t = applyCharPanel(charModelWithSelectedText(), ["anti_aliasing": "Crisp"])
    #expect(t.aaMode == "Crisp")
}

// MARK: - end-to-end (mirror Python TestApplyEndToEnd)

@Test func charEndToEndFontFamilyWrite() {
    let m = charModelWithSelectedText()
    let t = applyCharPanel(m, ["font_family": "Arial", "font_size": 12.0])
    #expect(t.fontFamily == "Arial")
}

@Test func charEndToEndUnderlineWrite() {
    let m = charModelWithSelectedText()
    let t = applyCharPanel(m, ["underline": true, "font_size": 12.0])
    #expect(t.textDecoration == "underline")
}

@Test func charNoOpWhenSelectionEmpty() {
    // Empty selection -> apply must not mutate any element.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi", fontFamily: "serif"))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [text])],
        selectedLayer: 0,
        selection: []))
    model.stateStore.initPanel("character_panel_content",
                               defaults: ["font_family": "Arial"])
    applyCharacterPanelToSelection(store: model.stateStore,
                                    controller: Controller(model: model))
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        #expect(Bool(false), "expected Text"); return
    }
    #expect(t.fontFamily == "serif")  // unchanged
}

// MARK: - Paragraph text-kind classification (panel -> flags)

/// Build a Model with a single selected element.
private func paraModel(_ elem: Element) -> Model {
    let model = Model()
    model.setDocumentForTest(Document(
        layers: [Layer(children: [elem])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

@Test func paraPointTextSelected() {
    // point text (width/height 0) -> text_selected true, area false.
    let m = paraModel(.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 12, width: 0, height: 0)))
    let o = paragraphPanelLiveOverrides(model: m)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paraAreaTextSelected() {
    // area text (width>0, height>0) -> both true.
    let m = paraModel(.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 12, width: 200, height: 100)))
    let o = paragraphPanelLiveOverrides(model: m)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == true)
}

@Test func paraTextPathSelected() {
    // text-on-path -> text_selected true, area false.
    let m = paraModel(.textPath(TextPath(d: [], content: "path", fontSize: 14)))
    let o = paragraphPanelLiveOverrides(model: m)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paraEmptySelection() {
    let o = paragraphPanelLiveOverrides(model: Model())
    #expect(o["text_selected"] as? Bool == false)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paraNonTextSelection() {
    let m = paraModel(.rect(Rect(x: 0, y: 0, width: 10, height: 10)))
    let o = paragraphPanelLiveOverrides(model: m)
    #expect(o["text_selected"] as? Bool == false)
    #expect(o["area_text_selected"] as? Bool == false)
}

// MARK: - Paragraph indent read-back (element -> panel)

@Test func paraIndentReadBack() {
    // Area/para element with left/right indent -> panel left/right_indent.
    let wrapper = Tspan(id: 0, content: "", jasRole: "paragraph",
                        jasLeftIndent: 18, jasRightIndent: 9)
    let body = Tspan(id: 1, content: "hello")
    let m = paraModel(.text(Text(x: 0, y: 0, tspans: [wrapper, body],
                                  fontSize: 12, width: 200, height: 100)))
    let o = paragraphPanelLiveOverrides(model: m)
    #expect(o["left_indent"] as? Double == 18)
    #expect(o["right_indent"] as? Double == 9)
}

// MARK: - Paragraph mutual exclusion (panel -> panel)

@Test func paraMutualExclusionAlignmentClearsOthers() {
    // Setting one alignment radio clears the other six.
    let store = StateStore()
    store.initPanel("paragraph_panel_content", defaults: [
        "align_left": true, "align_center": false, "align_right": false,
        "justify_left": false, "justify_center": false,
        "justify_right": false, "justify_all": false,
    ])
    applyParagraphPanelMutualExclusion(
        store: store, key: "align_right", value: true)
    for k in ["align_left", "align_center", "justify_left",
              "justify_center", "justify_right", "justify_all"] {
        #expect(store.getPanel("paragraph_panel_content", k) as? Bool == false)
    }
}

@Test func paraMutualExclusionBulletsClearsNumbered() {
    let store = StateStore()
    store.initPanel("paragraph_panel_content", defaults: [
        "bullets": "", "numbered_list": "num-decimal",
    ])
    applyParagraphPanelMutualExclusion(
        store: store, key: "bullets", value: "bullet-disc")
    #expect(store.getPanel("paragraph_panel_content", "numbered_list") as? String == "")
}

@Test func paraMutualExclusionNumberedClearsBullets() {
    let store = StateStore()
    store.initPanel("paragraph_panel_content", defaults: [
        "bullets": "bullet-disc", "numbered_list": "",
    ])
    applyParagraphPanelMutualExclusion(
        store: store, key: "numbered_list", value: "num-decimal")
    #expect(store.getPanel("paragraph_panel_content", "bullets") as? String == "")
}
