import Foundation
import Testing
@testable import JasLib

// Row 181: the Paragraph menu's Hanging Punctuation check shows the SELECTION.
// The menu context read the store, which holds what the last write left, so
// after selecting a different paragraph the check showed the previous flag.
// The toggle itself already syncs from the selection (`ParagraphPanel.dispatch`);
// this pins both. The web's arm is `paragraph_panel::tests`.

private let twoParagraphs = #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:jas="urn:jas:1" width="200" height="100"><text x="0" y="20" font-size="12" style="inline-size: 180px; white-space: pre-wrap;" xml:space="preserve"><tspan jas:role="paragraph"></tspan><tspan>First</tspan></text><text x="0" y="60" font-size="12" style="inline-size: 180px; white-space: pre-wrap;" xml:space="preserve"><tspan jas:role="paragraph" jas:hanging-punctuation="true" jas:left-indent="12"></tspan><tspan>Second</tspan></text></svg>"#

private func select(_ model: Model, _ i: Int) {
    model.setDocumentForTest(model.document.replacing(selection: [ElementSelection(path: [0, i])]))
}

/// (hanging punctuation, left indent) on text `i`'s paragraph wrapper.
private func wrapper(_ model: Model, _ i: Int) -> [String] {
    guard case .text(let t) = model.document.getElement([0, i]),
          let w = t.tspans.first(where: { $0.jasRole == "paragraph" }) else { return ["no wrapper"] }
    return ["\(w.jasHangingPunctuation.map { "\($0)" } ?? "nil")", "\(w.jasLeftIndent.map { "\($0)" } ?? "nil")"]
}

@Test func theHangingPunctuationCheckReadsTheSelectionAfterASelectionChange() {
    let model = Model()
    model.setDocumentForTest(svgToDocument(twoParagraphs))
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    let checked: () -> Bool = {
        panelIsChecked(.paragraph, cmd: "toggle_hanging_punctuation", layout: layout, model: model)
    }
    #expect(wrapper(model, 1) == ["true", "12.0"], "the control: the fixture's flagged paragraph")
    select(model, 0)
    #expect(!checked(), "the first paragraph has no hanging punctuation")
    select(model, 1)
    #expect(checked(), "the second paragraph has it: the check shows the selection")
    panelDispatch(.paragraph, cmd: "toggle_hanging_punctuation", addr: addr, layout: &layout, model: model)
    #expect(wrapper(model, 1) == ["nil", "12.0"], "the toggle turns it OFF and keeps the indent")
    #expect(!checked(), "and the check follows")
    select(model, 0)
    #expect(!checked(), "back to the first paragraph: unchecked")
    panelDispatch(.paragraph, cmd: "toggle_hanging_punctuation", addr: addr, layout: &layout, model: model)
    #expect(wrapper(model, 0) == ["true", "nil"], "the first paragraph gains the flag and NOT the second's indent")
}
