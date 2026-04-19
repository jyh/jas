import Testing
@testable import JasLib

// MARK: - Selection → Paragraph panel text-kind gating (Phase 3a)

@Test func paragraphPanelLiveOverridesEmpty() {
    let model = Model()
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == false)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paragraphPanelLiveOverridesNonTextSelected() {
    let model = Model()
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10))
    model.document = Document(layers: [Layer(children: [rect])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == false)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paragraphPanelLiveOverridesPointText() {
    // Point text — width and height both zero → text_selected true,
    // area_text_selected false (JUSTIFY/indent/hyphenate disabled).
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 16, width: 0, height: 0))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paragraphPanelLiveOverridesAreaText() {
    // Area text — width > 0 and height > 0 → both flags true.
    let model = Model()
    let text = Element.text(Text(x: 0, y: 0, content: "hello",
                                  fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [text])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == true)
}

@Test func paragraphPanelLiveOverridesTextPath() {
    // Text-on-path is never area text.
    let model = Model()
    let tp = Element.textPath(TextPath(d: [], content: "path",
                                        fontFamily: "Helvetica", fontSize: 14))
    model.document = Document(layers: [Layer(children: [tp])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == false)
}

@Test func paragraphPanelLiveOverridesMixedAreaAndPoint() {
    // Multi-element selection: one area text + one point text.
    // PARAGRAPH.md: "a control is enabled iff every selected text
    // element supports it" — area_text_selected stays false.
    let model = Model()
    let area = Element.text(Text(x: 0, y: 0, content: "area",
                                  fontSize: 16, width: 200, height: 100))
    let point = Element.text(Text(x: 0, y: 0, content: "point",
                                   fontSize: 16, width: 0, height: 0))
    model.document = Document(layers: [Layer(children: [area, point])],
                              selectedLayer: 0,
                              selection: [
                                ElementSelection(path: [0, 0]),
                                ElementSelection(path: [0, 1]),
                              ])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == false)
}

// MARK: - Phase 3b paragraph attribute reads

@Test func paragraphPanelLiveOverridesReadsParaWrapper() {
    // Area text whose tspans contain a wrapper carrying the 5
    // panel-surface paragraph attrs. The reader picks them up and
    // populates panel.left_indent / panel.right_indent / etc.
    let model = Model()
    let wrapper = Tspan(id: 0, content: "",
                        jasRole: "paragraph",
                        jasLeftIndent: 18,
                        jasRightIndent: 9,
                        jasHyphenate: true,
                        jasHangingPunctuation: true,
                        jasListStyle: "bullet-disc")
    let content = Tspan(id: 1, content: "hello")
    let area = Element.text(Text(
        x: 0, y: 0, tspans: [wrapper, content],
        fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == true)
    #expect(o["left_indent"] as? Double == 18)
    #expect(o["right_indent"] as? Double == 9)
    #expect(o["hyphenate"] as? Bool == true)
    #expect(o["hanging_punctuation"] as? Bool == true)
    #expect(o["bullets"] as? String == "bullet-disc")
    #expect(o["numbered_list"] as? String == "")
}

@Test func paragraphPanelLiveOverridesNumListPopulatesNumberedDropdown() {
    // jas:list-style "num-*" routes to panel.numbered_list and
    // clears panel.bullets.
    let model = Model()
    let wrapper = Tspan(id: 0, content: "", jasRole: "paragraph",
                        jasListStyle: "num-decimal")
    let content = Tspan(id: 1, content: "1. item")
    let area = Element.text(Text(x: 0, y: 0, tspans: [wrapper, content],
                                  fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["numbered_list"] as? String == "num-decimal")
    #expect(o["bullets"] as? String == "")
}

@Test func paragraphPanelLiveOverridesAbsentWrapperLeavesDefaults() {
    // Area text without any wrapper tspan — text-kind flags fire,
    // but no paragraph-attr keys are inserted (panel keeps its
    // YAML defaults).
    let model = Model()
    let area = Element.text(Text(x: 0, y: 0, content: "hi",
                                  fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["text_selected"] as? Bool == true)
    #expect(o["area_text_selected"] as? Bool == true)
    #expect(o["left_indent"] == nil)
    #expect(o["bullets"] == nil)
    #expect(o["hyphenate"] == nil)
}

// MARK: - Phase 3c mixed-state aggregation

@Test func paragraphPanelLiveOverridesAgreesAcrossWrappers() {
    // Two wrapper tspans inside one text element, agreeing on every
    // attribute → those attributes appear in the override map.
    let model = Model()
    let w1 = Tspan(id: 0, content: "", jasRole: "paragraph",
                   jasLeftIndent: 12, jasHyphenate: true,
                   jasListStyle: "bullet-disc")
    let c1 = Tspan(id: 1, content: "first ")
    let w2 = Tspan(id: 2, content: "", jasRole: "paragraph",
                   jasLeftIndent: 12, jasHyphenate: true,
                   jasListStyle: "bullet-disc")
    let c2 = Tspan(id: 3, content: "second")
    let area = Element.text(Text(
        x: 0, y: 0, tspans: [w1, c1, w2, c2],
        fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["left_indent"] as? Double == 12)
    #expect(o["hyphenate"] as? Bool == true)
    #expect(o["bullets"] as? String == "bullet-disc")
}

@Test func paragraphPanelLiveOverridesMixedNumericOmitsKey() {
    // Two wrappers disagreeing on left_indent (12 vs 24) — the
    // override is omitted so the panel keeps its prior value rather
    // than misleadingly showing one of the two.
    let model = Model()
    let w1 = Tspan(id: 0, content: "", jasRole: "paragraph", jasLeftIndent: 12)
    let c1 = Tspan(id: 1, content: "first ")
    let w2 = Tspan(id: 2, content: "", jasRole: "paragraph", jasLeftIndent: 24)
    let c2 = Tspan(id: 3, content: "second")
    let area = Element.text(Text(
        x: 0, y: 0, tspans: [w1, c1, w2, c2],
        fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["left_indent"] == nil)
}

@Test func paragraphPanelLiveOverridesMixedListStyleOmitsBothDropdowns() {
    // Wrappers split bullet vs numbered → both dropdowns omitted.
    let model = Model()
    let w1 = Tspan(id: 0, content: "", jasRole: "paragraph",
                   jasListStyle: "bullet-disc")
    let c1 = Tspan(id: 1, content: "•")
    let w2 = Tspan(id: 2, content: "", jasRole: "paragraph",
                   jasListStyle: "num-decimal")
    let c2 = Tspan(id: 3, content: "1.")
    let area = Element.text(Text(
        x: 0, y: 0, tspans: [w1, c1, w2, c2],
        fontSize: 16, width: 200, height: 100))
    model.document = Document(layers: [Layer(children: [area])],
                              selectedLayer: 0,
                              selection: [ElementSelection(path: [0, 0])])
    let o = paragraphPanelLiveOverrides(model: model)
    #expect(o["bullets"] == nil)
    #expect(o["numbered_list"] == nil)
}
