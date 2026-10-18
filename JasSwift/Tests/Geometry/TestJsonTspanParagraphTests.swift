import Testing
import Foundation
@testable import JasLib

/// The paragraph attributes ride the tspan, and the canonical JSON used to
/// emit none of them, so justify, the indents and the spacing ranges reached
/// no read-back. Mirrors Rust's
/// `tspan_paragraph_attributes_round_trip_through_test_json` and
/// `tspan_json_writes_every_tspan_field`.

private let paragraphStrs = ["jas_role", "jas_list_style", "text_align", "text_align_last",
                             "jas_single_word_justify"]
private let paragraphBools = ["jas_hyphenate", "jas_hanging_punctuation", "jas_hyphenate_capitalized"]
private let paragraphNums = ["jas_left_indent", "jas_right_indent", "text_indent", "jas_space_before",
                             "jas_space_after", "jas_word_spacing_min", "jas_word_spacing_desired",
                             "jas_word_spacing_max", "jas_letter_spacing_min", "jas_letter_spacing_desired",
                             "jas_letter_spacing_max", "jas_glyph_scaling_min", "jas_glyph_scaling_desired",
                             "jas_glyph_scaling_max", "jas_auto_leading", "jas_hyphenate_min_word",
                             "jas_hyphenate_min_before", "jas_hyphenate_min_after", "jas_hyphenate_limit",
                             "jas_hyphenate_zone", "jas_hyphenate_bias"]

private func firstTspan(_ json: String) -> [String: Any]? {
    guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let layer = (d["layers"] as? [[String: Any]])?.first,
          let text = (layer["children"] as? [[String: Any]])?.first,
          let tspan = (text["tspans"] as? [[String: Any]])?.first else { return nil }
    return tspan
}

private func textDocJson(_ tspan: [String: Any]) -> String {
    let text: [String: Any] = ["type": "text", "x": 0.0, "y": 0.0, "font_size": 12.0, "tspans": [tspan]]
    let doc: [String: Any] = ["layers": [["type": "layer", "name": "L", "children": [text]]],
                              "selected_layer": 0, "selection": []]
    let data = try! JSONSerialization.data(withJSONObject: doc)
    return String(decoding: data, as: UTF8.self)
}

@Test func tspanParagraphAttributesRoundTripThroughTestJson() {
    // Each field gets its OWN value, so a key written under a sibling's name
    // cannot pass.
    var tspan: [String: Any] = ["id": 1, "content": "t"]
    for k in paragraphStrs { tspan[k] = "v_\(k)" }
    for k in paragraphBools { tspan[k] = true }
    for (i, k) in paragraphNums.enumerated() { tspan[k] = 1.5 + Double(i) }
    guard let back = firstTspan(documentToTestJson(testJsonToDocument(textDocJson(tspan)))) else {
        Issue.record("no tspan in the emitted document"); return
    }
    for k in paragraphStrs { #expect(back[k] as? String == "v_\(k)", "tspan key \(k): \(back[k] ?? "absent")") }
    for k in paragraphBools { #expect(back[k] as? Bool == true, "tspan key \(k): \(back[k] ?? "absent")") }
    for (i, k) in paragraphNums.enumerated() {
        #expect((back[k] as? NSNumber)?.doubleValue == 1.5 + Double(i), "tspan key \(k): \(back[k] ?? "absent")")
    }
}

@Test func tspanJsonWritesEveryTspanField() {
    // The writer's key set is the Tspan struct's field set, read at runtime, so
    // a field added to Tspan without a writer line reds here.
    func snake(_ s: String) -> String {
        s.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }
    let fields = Set(Mirror(reflecting: Tspan(content: "t")).children.compactMap { $0.label.map(snake) })
    #expect(fields.count > 40, "the field census read too little of Tspan: \(fields.sorted())")
    guard let back = firstTspan(documentToTestJson(testJsonToDocument(textDocJson(["id": 1, "content": "t"])))) else {
        Issue.record("no tspan in the emitted document"); return
    }
    let keys = Set(back.keys)
    #expect(keys == fields, "writer only: \(keys.subtracting(fields).sorted()); struct only: \(fields.subtracting(keys).sorted())")
}
