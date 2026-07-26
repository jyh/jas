import Testing
import Foundation
@testable import JasLib

// CHARPANEL: the field-scoped Character-panel apply law (Swift arm).
//
// Runs test_fixtures/character_apply/panel_edit.json — the shared corpus that
// pins this law across the three LIVE implementations (the
// workspace_interpreter reference, Rust jas_dioxus, and this port). The
// reference states the field -> attribute-group table
// (workspace_interpreter/character_law.py); `CharacterEditGroup` mirrors it.
//
// A vector's `expected` is a DELTA over its base: the keys it names are what
// the edit changed, and every key it omits must come back unchanged. That is
// the whole point of the law, so the corpus states it directly rather than
// re-listing whole attribute sets.

private func characterApplyCorpus() -> [String: Any] {
    let thisFile = #filePath
    let panelsDir = (thisFile as NSString).deletingLastPathComponent
    let testsDir = (panelsDir as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let fixtures = (jasSwiftDir as NSString).appendingPathComponent("../test_fixtures")
    let full = (fixtures as NSString)
        .appendingPathComponent("character_apply/panel_edit.json")
    let path = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        fatalError("Failed to read character_apply corpus: \(path)")
    }
    return dict
}

/// Shallow merge with the `_comment` keys dropped: the override map over the
/// base map.
private func charMerged(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in base where !k.hasPrefix("_") { out[k] = v }
    for (k, v) in over where !k.hasPrefix("_") { out[k] = v }
    return out
}

/// A fixture attribute map as `CharacterAttrs`. Every key is present in the
/// merged map (the corpus's `element_defaults` names all sixteen), so no
/// port's element-constructor defaults leak into the corpus.
private func charAttrsFromFixture(_ attrs: [String: Any]) -> CharacterAttrs {
    func s(_ k: String) -> String { (attrs[k] as? String) ?? "" }
    return CharacterAttrs(
        fontFamily: s("font_family"),
        fontSize: (attrs["font_size"] as? NSNumber)?.doubleValue ?? 12.0,
        fontWeight: s("font_weight"), fontStyle: s("font_style"),
        textDecoration: s("text_decoration"),
        textTransform: s("text_transform"), fontVariant: s("font_variant"),
        baselineShift: s("baseline_shift"), lineHeight: s("line_height"),
        letterSpacing: s("letter_spacing"), xmlLang: s("xml_lang"),
        aaMode: s("aa_mode"), rotate: s("rotate"),
        horizontalScale: s("horizontal_scale"),
        verticalScale: s("vertical_scale"), kerning: s("kerning"))
}

/// Whether two stored workspace values are the same declared default.
/// Numbers and bools both arrive boxed as `NSNumber`, so compare numerically
/// (a bool reads as 0 / 1) and fall back to string equality.
private func sameWorkspaceValue(_ a: Any, _ b: Any) -> Bool {
    func asNum(_ v: Any) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as Bool: return f ? 1 : 0
        default: return nil
        }
    }
    if let x = asNum(a), let y = asNum(b) { return x == y }
    if let x = a as? String, let y = b as? String { return x == y }
    return false
}

/// Seed the production Character-panel scope from a fixture panel map.
/// `characterWithGroup` reads that scope, so this is the seam the law reads.
/// Unlike the Stroke corpus there is no panel-vs-global scope question: every
/// Character control binds `panel.<field>` only.
private func seedCharacterPanel(_ store: StateStore, _ panel: [String: Any]) {
    store.initPanel("character_panel_content", defaults: [:])
    for (key, value) in panel where !key.hasPrefix("_") {
        if value is NSNull { continue }
        store.setPanel("character_panel_content", key, value)
    }
}

@Suite("CHARPANEL character-apply corpus")
struct CharacterApplyCorpusTests {

    @Test("the shared field-scoped apply corpus")
    func panelEditCorpus() {
        let corpus = characterApplyCorpus()
        let vectors = corpus["vectors"] as! [[String: Any]]
        let elementDefaults = corpus["element_defaults"] as! [String: Any]
        let panelDefaults = corpus["panel_defaults"] as! [String: Any]
        var ran = 0
        for vec in vectors {
            let name = vec["name"] as! String
            #expect(vec["op"] as? String == "panel_edit",
                    "character_apply '\(name)': unknown op")
            // `base` is a literal attribute delta or the NAME of a shared
            // one; either way it is a delta over `element_defaults`.
            let baseDelta: [String: Any] = {
                if let n = vec["base"] as? String {
                    return corpus[n] as! [String: Any]
                }
                return vec["base"] as! [String: Any]
            }()
            let baseAttrs = charMerged(elementDefaults, baseDelta)
            let base = charAttrsFromFixture(baseAttrs)
            let edited = vec["edited"] as! String
            let group = CharacterEditGroup.fromField(edited)
            if vec["expected"] is NSNull {
                #expect(group == nil,
                        "character_apply '\(name)': '\(edited)' must own no group")
                ran += 1
                continue
            }
            guard let group else {
                Issue.record("character_apply '\(name)': '\(edited)' must own a group")
                continue
            }
            let store = StateStore()
            seedCharacterPanel(store, charMerged(panelDefaults,
                                                 vec["panel"] as! [String: Any]))
            let got = characterWithGroup(base, store: store, group: group)
            let want = charAttrsFromFixture(
                charMerged(baseAttrs, vec["expected"] as! [String: Any]))
            #expect(got == want, "character_apply panel_edit '\(name)'")
            ran += 1
        }
        #expect(ran >= 30, "character_apply corpus ran only \(ran) vectors")
    }

    @Test("every group writes only its own attributes")
    func groupsStayInsideTheirOwnAttributes() {
        // The law's invariant, stated independently of any vector's expected
        // values: running a group over the rich run may change only the
        // attributes `characterGroupAttrKeys` claims for it.
        let corpus = characterApplyCorpus()
        let base = charAttrsFromFixture(charMerged(
            corpus["element_defaults"] as! [String: Any],
            corpus["rich_run"] as! [String: Any]))
        let store = StateStore()
        seedCharacterPanel(store, corpus["panel_defaults"] as! [String: Any])
        let fields = [
            "font_family", "style_name", "font_size", "leading", "kerning",
            "tracking", "vertical_scale", "horizontal_scale", "baseline_shift",
            "superscript", "subscript", "character_rotation", "all_caps",
            "small_caps", "underline", "strikethrough", "language",
            "anti_aliasing",
        ]
        for field in fields {
            guard let group = CharacterEditGroup.fromField(field) else {
                Issue.record("\(field) must own a group"); continue
            }
            let got = characterWithGroup(base, store: store, group: group)
            let allowed = Set(characterGroupAttrKeys(group))
            for (key, value) in got.asAttrDict {
                let before = base.asAttrDict[key]
                let same = "\(value)" == "\(before ?? "")"
                if !same {
                    #expect(allowed.contains(key),
                            "\(field) wrote outside its group: \(key)")
                }
            }
        }
    }

    @Test("a UI-only field owns no group")
    func uiOnlyFieldsOwnNoGroup() {
        for field in ["snap_baseline", "snap_x_height", "snap_glyph_bounds",
                      "snap_proximity_guides", "snap_angular_guides",
                      "snap_anchor_point", "snap_to_glyph_visible",
                      "touch_type_enabled", "in_menu_font_previews"] {
            #expect(CharacterEditGroup.fromField(field) == nil, "\(field)")
        }
    }

    @Test("the panel-default fallbacks match the workspace bundle")
    func fallbacksMatchTheWorkspace() {
        // The value the law reads when a field is absent from panel state has
        // to be the panel default the workspace declares, not a hand-written
        // literal. Mirrors the reference's
        // TestTheFallbacksAreTheWorkspaceDefaults.
        guard let ws = WorkspaceData.load() else {
            Issue.record("workspace bundle must load"); return
        }
        let declared = ws.panelStateDefaults("character_panel_content")
        for (field, fallback) in characterPanelDefaults {
            guard let want = declared[field] else {
                Issue.record("\(field) is not a declared panel field"); continue
            }
            // Compare by VALUE, not by description: the bundle boxes a bool
            // as a number and an integral default as an Int, so "false" vs
            // "0" and "12.0" vs "12" are the same declared default.
            #expect(sameWorkspaceValue(fallback, want),
                    "\(field): fallback \(fallback) != workspace default \(want)")
        }
        // `leading` is deliberately absent from the fallback table: no
        // committed leading means the element's own Auto value.
        #expect(characterPanelDefaults["leading"] == nil)
    }
}

// MARK: - The end-to-end repro

/// A deliberately RICH text element — every character attribute differs from
/// the Character panel's default, so a whole-rebuild apply shows up as a diff
/// on every one of them. Mirrors the corpus's shared `rich_run`.
private func richText() -> Text {
    Text(x: 0, y: 0, tspans: [Tspan(id: 1, content: "hello")],
         fontFamily: "Georgia", fontSize: 30,
         fontWeight: "bold", fontStyle: "italic",
         textDecoration: "underline",
         textTransform: "uppercase", fontVariant: "",
         baselineShift: "4pt", lineHeight: "40pt",
         letterSpacing: "0.08em", xmlLang: "fr",
         aaMode: "Crisp", rotate: "15",
         horizontalScale: "120", verticalScale: "90",
         kerning: "Optical")
}

private func modelWithRichText() -> Model {
    let model = Model()
    model.setDocumentForTest(Document(
        layers: [Layer(children: [.text(richText())])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    return model
}

/// The Character panel sitting at the defaults
/// `workspace/panels/character.yaml` declares — the state that used to be
/// stamped over the whole selection on every edit.
private let charPanelDefaults: [String: Any] = [
    "font_family": "sans-serif", "style_name": "Regular",
    "font_size": 12.0, "leading": 14.4, "kerning": "Auto",
    "tracking": 0.0, "vertical_scale": 100.0, "horizontal_scale": 100.0,
    "baseline_shift": 0.0, "character_rotation": 0.0,
    "all_caps": false, "small_caps": false,
    "superscript": false, "subscript": false,
    "underline": false, "strikethrough": false,
    "language": "en", "anti_aliasing": "Sharp",
]

@Test func charTrackingEditPreservesEveryOtherAttr() {
    // JYH's repro, end to end through the production apply: rich run
    // selected, panel at its defaults, user commits ONE field.
    let rich = richText()
    let model = modelWithRichText()
    var panel = charPanelDefaults
    panel["tracking"] = 50.0
    model.stateStore.initPanel("character_panel_content", defaults: panel)
    applyCharacterPanelToSelection(store: model.stateStore,
                                   controller: Controller(model: model),
                                   edited: "tracking")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        Issue.record("expected Text"); return
    }
    #expect(t.letterSpacing == "0.05em", "the edited field lands")
    #expect(t.fontFamily == rich.fontFamily, "font_family preserved")
    #expect(t.fontSize == rich.fontSize, "font_size preserved")
    #expect(t.fontWeight == rich.fontWeight, "font_weight preserved")
    #expect(t.fontStyle == rich.fontStyle, "font_style preserved")
    #expect(t.textDecoration == rich.textDecoration, "text_decoration preserved")
    #expect(t.textTransform == rich.textTransform, "text_transform preserved")
    #expect(t.fontVariant == rich.fontVariant, "font_variant preserved")
    #expect(t.baselineShift == rich.baselineShift, "baseline_shift preserved")
    #expect(t.lineHeight == rich.lineHeight, "line_height preserved")
    #expect(t.xmlLang == rich.xmlLang, "xml_lang preserved")
    #expect(t.aaMode == rich.aaMode, "aa_mode preserved")
    #expect(t.rotate == rich.rotate, "rotate preserved")
    #expect(t.horizontalScale == rich.horizontalScale, "horizontal_scale preserved")
    #expect(t.verticalScale == rich.verticalScale, "vertical_scale preserved")
    #expect(t.kerning == rich.kerning, "kerning preserved")
}

@Test func charUiOnlyToggleWritesNothingAtAll() {
    // A UI-only flag must not reach the document — no edit, so no undo step
    // that changes nothing.
    let rich = richText()
    let model = modelWithRichText()
    model.stateStore.initPanel("character_panel_content",
                               defaults: charPanelDefaults)
    applyCharacterPanelToSelection(store: model.stateStore,
                                   controller: Controller(model: model),
                                   edited: "snap_baseline")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        Issue.record("expected Text"); return
    }
    #expect(t == rich, "a UI-only toggle must leave the element untouched")
    #expect(!model.canUndo, "and must push no undo step")
}

@Test func charRangeEditWritesOnlyTheEditedGroupOntoTheRange() {
    // The per-range route is field-scoped too: a Tracking edit on a selected
    // range must not stamp the panel's family / size / weight over it.
    let model = Model()
    let text = Element.text(Text(
        x: 0, y: 0, tspans: [Tspan(id: 1, content: "hello")],
        fontFamily: "Georgia", fontSize: 30,
        fontWeight: "bold", fontStyle: "italic"))
    model.setDocumentForTest(Document(
        layers: [Layer(children: [text])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0])]))
    let session = TextEditSession(path: [0, 0], target: .text,
                                  content: "hello", insertion: 1)
    session.setInsertion(4, extend: true)  // selection [1, 4) -> "ell"
    model.currentEditSession = session
    var panel = charPanelDefaults
    panel["tracking"] = 50.0
    model.stateStore.initPanel("character_panel_content", defaults: panel)
    applyCharacterPanelToSelection(store: model.stateStore,
                                   controller: Controller(model: model),
                                   edited: "tracking")
    guard case .text(let t) = model.document.getElement([0, 0]) else {
        Issue.record("expected Text"); return
    }
    // The range picked up the tracking...
    let ranged = t.tspans.first { $0.content == "ell" }
    #expect(ranged != nil, "the range was split out")
    #expect(ranged?.letterSpacing == 0.05)
    // ...and NOTHING else. The panel's 12pt sans-serif Regular must not have
    // landed as a tspan override on the range.
    #expect(ranged?.fontFamily == nil, "family must not be stamped on the range")
    #expect(ranged?.fontSize == nil, "size must not be stamped on the range")
    #expect(ranged?.fontWeight == nil, "weight must not be stamped on the range")
    #expect(ranged?.textDecoration == nil,
            "decoration must not be stamped on the range")
    #expect(ranged?.lineHeight == nil, "leading must not be stamped on the range")
    // The element level is untouched either way.
    #expect(t.fontFamily == "Georgia")
    #expect(t.fontSize == 30)
}
