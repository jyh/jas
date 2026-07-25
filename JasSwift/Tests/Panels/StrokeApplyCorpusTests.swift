import Testing
import Foundation
@testable import JasLib

// STROKEWIDTH: the field-scoped Stroke-panel apply law (Swift arm).
//
// Runs test_fixtures/stroke_apply/panel_edit.json — the shared corpus that
// pins this law across the three LIVE implementations (the
// workspace_interpreter reference, Rust jas_dioxus, and this port). The
// reference states the field -> attribute-group table
// (workspace_interpreter/stroke_law.py); `StrokeEditGroup` mirrors it.
//
// A vector's `expected` is a DELTA over its effective base: the keys it
// names are what the edit changed, and every key it omits must come back
// unchanged. That is the whole point of the law, so the corpus states it
// directly rather than re-listing whole strokes.

private func strokeApplyCorpus() -> [String: Any] {
    let thisFile = #filePath
    let panelsDir = (thisFile as NSString).deletingLastPathComponent
    let testsDir = (panelsDir as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let fixtures = (jasSwiftDir as NSString).appendingPathComponent("../test_fixtures")
    let full = (fixtures as NSString)
        .appendingPathComponent("stroke_apply/panel_edit.json")
    let path = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        fatalError("Failed to read stroke_apply corpus: \(path)")
    }
    return dict
}

/// A fixture colour: 6-char hex, or the `{space, components, a}` object
/// form. The object form exists because a stroke colour is NOT hex — hex
/// flattens the space, drops the alpha and quantises to 8 bits, and a panel
/// edit must hand the colour back bit-for-bit.
private func colorFromAttrs(_ spec: Any) -> Color {
    if let hex = spec as? String {
        guard let c = Color.fromHex(hex) else {
            fatalError("fixture colour must parse: \(hex)")
        }
        return c
    }
    guard let map = spec as? [String: Any] else {
        fatalError("unknown fixture colour \(spec)")
    }
    func f(_ k: String) -> Double {
        guard let n = map[k] as? NSNumber else {
            fatalError("fixture colour missing '\(k)'")
        }
        return n.doubleValue
    }
    let a = (map["a"] as? NSNumber)?.doubleValue ?? 1.0
    switch map["space"] as? String {
    case "cmyk": return .cmyk(c: f("c"), m: f("m"), y: f("y"), k: f("k"), a: a)
    case "hsb": return .hsb(h: f("h"), s: f("s"), b: f("b"), a: a)
    case "rgb": return .rgb(r: f("r"), g: f("g"), b: f("b"), a: a)
    default: fatalError("unknown fixture colour space \(map)")
    }
}

/// The Stroke a fixture attribute map describes, taking anything it omits
/// from `base`.
private func strokeFromAttrs(_ base: Stroke, _ attrs: [String: Any]) -> Stroke {
    func num(_ k: String) -> Double? { (attrs[k] as? NSNumber)?.doubleValue }
    var linecap = base.linecap
    if let v = attrs["linecap"] as? String {
        linecap = v == "round" ? .round : v == "square" ? .square : .butt
    }
    var linejoin = base.linejoin
    if let v = attrs["linejoin"] as? String {
        linejoin = v == "round" ? .round : v == "bevel" ? .bevel : .miter
    }
    var align = base.align
    if let v = attrs["align"] as? String {
        align = v == "inside" ? .inside : v == "outside" ? .outside : .center
    }
    var arrowAlign = base.arrowAlign
    if let v = attrs["arrow_align"] as? String {
        arrowAlign = v == "center_at_end" ? .centerAtEnd : .tipAtEnd
    }
    var dash = base.dashPattern
    if let v = attrs["dash"] as? [NSNumber] { dash = v.map { $0.doubleValue } }
    var color = base.color
    if let v = attrs["color"], !(v is NSNull) { color = colorFromAttrs(v) }
    return Stroke(
        color: color,
        width: num("width") ?? base.width,
        linecap: linecap,
        linejoin: linejoin,
        miterLimit: num("miter_limit") ?? base.miterLimit,
        align: align,
        dashPattern: dash,
        dashAlignAnchors: (attrs["dash_align_anchors"] as? Bool) ?? base.dashAlignAnchors,
        startArrow: (attrs["start_arrow"] as? String).map { Arrowhead(fromString: $0) }
            ?? base.startArrow,
        endArrow: (attrs["end_arrow"] as? String).map { Arrowhead(fromString: $0) }
            ?? base.endArrow,
        startArrowScale: num("start_arrow_scale") ?? base.startArrowScale,
        endArrowScale: num("end_arrow_scale") ?? base.endArrowScale,
        arrowAlign: arrowAlign,
        opacity: num("opacity") ?? base.opacity)
}

/// Seed the store's Stroke-panel scope from a fixture panel map (the
/// corpus defaults plus the vector's overrides). `strokeWithGroup` reads
/// the panel scope first, so this is the seam the law reads.
private func seedStrokePanel(_ store: StateStore, _ panel: [String: Any]) {
    for (key, value) in panel where !key.hasPrefix("_") {
        if value is NSNull { continue }
        store.setPanel("stroke_panel_content", key, value)
    }
}

/// Seed the flat GLOBAL scope instead — a `"scope": "global"` vector, which
/// is how an out-of-panel `set:` effect delivers a stroke field.
///
/// The global spellings are NOT a mechanical `stroke_` prefix: the weight
/// field's global is `stroke_width` and `align_stroke`'s is `stroke_align`
/// (workspace/panels/stroke.yaml `init:`, workspace/actions.yaml
/// `reset_fill_stroke`). That table is stated here from the workspace YAML
/// rather than borrowed from production, so the port's own resolver is what
/// is under test.
private func seedStrokeGlobals(_ store: StateStore, _ panel: [String: Any]) {
    for (key, value) in panel where !key.hasPrefix("_") {
        if value is NSNull { continue }
        let global = key == "weight" ? "stroke_width"
            : key == "align_stroke" ? "stroke_align" : "stroke_\(key)"
        store.set(global, value)
    }
}

/// Shallow merge: the override map over the base map.
private func merged(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var out = base
    for (k, v) in over { out[k] = v }
    return out
}

@Suite("STROKEWIDTH stroke-apply corpus")
struct StrokeApplyCorpusTests {

    @Test("the shared field-scoped apply corpus")
    func panelEditCorpus() {
        let corpus = strokeApplyCorpus()
        let vectors = corpus["vectors"] as! [[String: Any]]
        let panelDefaults = corpus["panel_defaults"] as! [String: Any]
        let plain = Stroke(color: Color.fromHex("#000000")!, width: 1.0)
        var ran = 0
        for vec in vectors {
            let name = vec["name"] as! String
            // `base`: a literal attribute map, the NAME of a shared map, or
            // null (an element with no stroke, which takes `fallback`).
            var baseAttrs: [String: Any]? = nil
            let hasBase = !(vec["base"] is NSNull) && vec["base"] != nil
            if let n = vec["base"] as? String {
                baseAttrs = corpus[n] as? [String: Any]
            } else if let m = vec["base"] as? [String: Any] {
                baseAttrs = m
            } else {
                baseAttrs = vec["fallback"] as? [String: Any]
            }
            let base = baseAttrs.map { strokeFromAttrs(plain, $0) }

            if (vec["op"] as! String) == "color_pick" {
                let hex = vec["color"] as! String
                let got = ColorPanel.recolorStroke(hasBase ? base : nil,
                                                  Color.fromHex(hex)!)
                let want = strokeFromAttrs(
                    base ?? plain,
                    merged(baseAttrs ?? [:], vec["expected"] as! [String: Any]))
                #expect(got == want, "stroke_apply color_pick '\(name)'")
                ran += 1
                continue
            }

            let edited = vec["edited"] as! String
            let group = StrokeEditGroup.fromField(edited)
            if vec["expected"] is NSNull {
                #expect(group == nil,
                        "stroke_apply '\(name)': '\(edited)' must own no group")
                ran += 1
                continue
            }
            guard let group else {
                Issue.record("stroke_apply '\(name)': '\(edited)' must own a group")
                continue
            }
            let store = StateStore()
            store.initPanel("stroke_panel_content", defaults: [:])
            let panelMap = merged(panelDefaults, vec["panel"] as! [String: Any])
            let committed = (vec["committed_width"] as! NSNumber).doubleValue
            if (vec["scope"] as? String) == "global" {
                seedStrokeGlobals(store, panelMap)
                // A global vector pins the SCOPE RESOLUTION, not just the key
                // normalization: the port must find the value in the flat
                // globals. `strokePanelField` looked the weight up as
                // `stroke_weight` — a key nothing writes — so this returned
                // nil and the width fell through to the default stroke.
                #expect(strokePanelNumber(store, "weight") == committed,
                        "stroke_apply '\(name)': the weight must resolve from the global scope")
            } else {
                seedStrokePanel(store, panelMap)
            }
            let got = strokeWithGroup(base!, store: store, group: group,
                                      committedWidth: committed)
            let want = strokeFromAttrs(
                base!, merged(baseAttrs!, vec["expected"] as! [String: Any]))
            #expect(got == want, "stroke_apply panel_edit '\(name)'")
            ran += 1
        }
        #expect(ran >= 25, "stroke_apply corpus ran only \(ran) vectors")
    }
}
