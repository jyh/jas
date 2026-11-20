import Foundation
import Testing
@testable import JasLib

// Row 183 (WIDGET_EVENTS.md §Showing a number): a number_input shows its number
// with at most four decimals and no float noise, by the rule the web
// (`number_input_text`) and the panel plan's `display` share. The view itself
// is SwiftUI, so its source is read for the call instead.

@Test func aNumberInputShowsItsNumberWithoutFloatNoise() throws {
    #expect(numberInputText(15.999975000000001) == "16")
    #expect(numberInputText(14.399999999999999) == "14.4")
    #expect(numberInputText(100.0) == "100")
    #expect(numberInputText(0.125) == "0.125")
    let here = URL(fileURLWithPath: #filePath)
    let view = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Interpreter/YamlPanelBodyView.swift")
    let src = try String(contentsOf: view, encoding: .utf8)
    #expect(src.count > 10_000, "read the view")
    #expect(src.contains("externalValue: numberInputText(currentValue)"), "the number field shows the formatted text")
    #expect(!src.contains("externalValue: numberToCanonicalString(currentValue)"), "it shows the raw float")
}
