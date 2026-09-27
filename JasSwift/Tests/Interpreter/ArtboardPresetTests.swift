import Foundation
import Testing
@testable import JasLib

// `apply_artboard_preset` (actions.yaml): the preset dropdown sets
// dialog.width / dialog.height to the preset's size. The expected sizes are
// parsed from the dropdown's own option labels in the compiled bundle, never
// typed here, so a label and the action cannot drift apart. Twin of
// `workspace_interpreter/tests/test_artboard_preset.py` and Rust's
// `artboard_preset_tests`.

private func presetFind(_ n: Any, _ id: String) -> [String: Any]? {
    if let m = n as? [String: Any] {
        if m["id"] as? String == id { return m }
        for v in m.values { if let hit = presetFind(v, id) { return hit } }
    } else if let a = n as? [Any] {
        for v in a { if let hit = presetFind(v, id) { return hit } }
    }
    return nil
}

/// (value, (w, h)) per option; nil size for Custom.
private func presetOptions() -> [(String, (Double, Double)?)] {
    guard let ws = WorkspaceData.load(),
          let dlg = ws.dialogs()["artboard_options"],
          let sel = presetFind(dlg, "ao_preset"),
          let opts = sel["options"] as? [[String: Any]] else { return [] }
    return opts.map { o in
        let label = o["label"] as? String ?? ""
        var size: (Double, Double)? = nil
        if let open = label.lastIndex(of: "("), label.hasSuffix(")") {
            let inner = label[label.index(after: open)..<label.index(before: label.endIndex)]
            let parts = inner.components(separatedBy: " × ")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) { size = (w, h) }
        }
        return (o["value"] as? String ?? "", size)
    }
}

private func presetApply(_ preset: String) -> (Any?, Any?) {
    guard let ws = WorkspaceData.load(),
          let action = ws.actions()["apply_artboard_preset"] as? [String: Any],
          let effects = action["effects"] as? [Any] else { return (nil, nil) }
    let store = StateStore()
    store.initDialog("artboard_options", defaults: ["width": 123.0, "height": 45.0, "preset": preset])
    runEffects(effects, ctx: ["param": ["preset": preset]], store: store,
               actions: ws.actions(), dialogs: ws.dialogs())
    return (store.getDialog("width"), store.getDialog("height"))
}

private func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return nil
}

@Test func artboardPresetOptionListIsWhatThisArmExpects() {
    let opts = presetOptions()
    #expect(opts.count == 11, "\(opts.map(\.0))")
    #expect(opts.filter { $0.1 == nil }.map(\.0) == ["custom"])
}

@Test func artboardPresetEverySizedPresetSetsItsLabelledSize() {
    for (value, size) in presetOptions() {
        guard let (w, h) = size else { continue }
        let (gw, gh) = presetApply(value)
        #expect(num(gw) == w && num(gh) == h, "\(value): dialog \(String(describing: gw)) x \(String(describing: gh))")
    }
}

@Test func artboardPresetCustomLeavesTheSizeAlone() {
    let (w, h) = presetApply("custom")
    #expect(num(w) == 123 && num(h) == 45)
}
