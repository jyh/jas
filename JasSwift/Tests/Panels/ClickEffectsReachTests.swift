import Foundation
import Testing
@testable import JasLib

// STATUS-jas row 288, the class gate for #1143: a panel click must never name
// an effect its route cannot run. #1143's defect was static: New Artboard held
// `doc.create_artboard` inside an `if:`, `dispatchPanelAction` ran it on
// Align's table, and the click reported committed and did nothing for six
// weeks. This walks every shipped click-kind panel widget's click, at any
// depth and through named actions, picks the table the route hands each action
// (as `dispatchPanelAction` decides), and asks the INTERPRETER whether each
// effect is one it runs: a key the table holds, or one `runEffects` takes
// itself (an effect nothing takes reports `unhandled effect`).

/// The table `dispatchPanelAction` hands a named action: the Layers registry
/// when its category is `layers` or any `doc.*` effect needs it, else Align's.
private func routeTable(for actionDef: [String: Any], model: Model) -> (name: String, keys: Set<String>) {
    let align = alignPlatformEffects(model: model)
    let effects = actionDef["effects"] as? [Any] ?? []
    if actionDef["category"] as? String == "layers" || effectsNeedDocRegistry(effects, table: align) {
        return ("layers", Set(LayersPanel.layersPanelPlatformEffects(model: model, onCloseDialog: nil, onLayoutOp: nil).keys))
    }
    return ("align", Set(align.keys))
}

/// Keys that are structure, and where each one's EFFECTS are (never its
/// names: a `foreach`'s `as:` and a `let`'s keys are bindings, not effects).
private func effectBodies(_ key: String, _ value: Any) -> [Any]? {
    switch key {
    case "if": let d = value as? [String: Any]; return [d?["then"] as Any, d?["else"] as Any]
    case "do", "in": return [value]
    case "start_timer": return [(value as? [String: Any])?["effects"] as Any]
    case "foreach", "let", "as": return []
    default: return nil
    }
}

/// Whether `runEffects` takes `[key: value]` itself (with an empty table).
private func interpreterRuns(_ key: String, _ value: Any) -> Bool {
    var diags: [Diagnostic] = []
    let model = Model()
    runEffects([[key: value]], ctx: [:], store: StateStore(), platformEffects: [:], model: model, diagnostics: &diags)
    return !diags.contains { $0.reason == "unhandled effect" && $0.key == key }
}

private struct Miss: CustomStringConvertible {
    let widget: String, via: String, key: String
    var description: String { "\(widget) via \(via): \(key)" }
}

@Test func everyShippedPanelClickNamesOnlyEffectsItsRouteRuns() throws {
    let ws = try #require(WorkspaceData.load())
    let actions = ws.actions()
    let model = Model()
    let alignKeys = Set(alignPlatformEffects(model: model).keys)
    var misses: [Miss] = []
    var walkedWidgets = 0, walkedEffects = 0
    var verdictCache: [String: Bool] = [:]

    func check(_ effects: Any?, table: Set<String>, widget: String, via: String, seen: inout Set<String>) {
        if let list = effects as? [Any] {
            for e in list { check(e, table: table, widget: widget, via: via, seen: &seen) }
            return
        }
        if let key = effects as? String {  // a bare-string effect: `snapshot`
            walkedEffects += 1
            if !table.contains(key) && !(verdictCache[key] ?? { let v = interpreterRuns(key, NSNull()); verdictCache[key] = v; return v }()) {
                misses.append(Miss(widget: widget, via: via, key: key))
            }
            return
        }
        guard let d = effects as? [String: Any] else { return }
        for (k, v) in d {
            if k == "dispatch" {
                let name = (v as? String) ?? ((v as? [String: Any])?["action"] as? String)
                if let name, !seen.contains(name), let def = actions[name] as? [String: Any] {
                    seen.insert(name)
                    let t = routeTable(for: def, model: model)
                    check(def["effects"], table: t.keys, widget: widget, via: "\(via)>\(name)(\(t.name))", seen: &seen)
                }
                continue
            }
            if let bodies = effectBodies(k, v) {
                for b in bodies { check(b, table: table, widget: widget, via: via, seen: &seen) }
                continue
            }
            walkedEffects += 1
            let ok = table.contains(k) || (verdictCache[k] ?? { let r = interpreterRuns(k, v); verdictCache[k] = r; return r }())
            if !ok { misses.append(Miss(widget: widget, via: via, key: k)) }
        }
    }

    func walk(_ node: Any) {
        if let d = node as? [String: Any] {
            if let kind = d["type"] as? String, WidgetEvent.clickKinds.contains(kind) {
                let id = d["id"] as? String ?? "?"
                var behaviors = ((d["behavior"] as? [[String: Any]]) ?? []).filter { ($0["event"] as? String) == "click" }
                if behaviors.isEmpty, let a = d["action"] as? String { behaviors = [["action": a]] }
                if !behaviors.isEmpty { walkedWidgets += 1 }
                for b in behaviors {
                    var seen = Set<String>()
                    // Inline effects run on the widget route's table (Align's).
                    check(b["effects"], table: alignKeys, widget: id, via: "inline(align)", seen: &seen)
                    if let name = b["action"] as? String, let def = actions[name] as? [String: Any] {
                        seen.insert(name)
                        let t = routeTable(for: def, model: model)
                        check(def["effects"], table: t.keys, widget: id, via: "\(name)(\(t.name))", seen: &seen)
                    }
                }
            }
            for v in d.values { walk(v) }
        } else if let a = node as? [Any] {
            for v in a { walk(v) }
        }
    }
    walk(ws.panels() ?? [:])
    // The population, printed so a reader sees what the gate walked; and a
    // floor, so a walk that found nothing cannot pass.
    print("click-effects gate: \(walkedWidgets) widgets, \(walkedEffects) effects, \(misses.count) misses")
    #expect(walkedWidgets >= 80, "the walk found the shipped click widgets (\(walkedWidgets))")
    #expect(walkedEffects >= 100, "and their effects (\(walkedEffects))")
    #expect(misses.isEmpty, "panel clicks naming an effect their route cannot run: \(misses)")
}

/// The gate's own control: an effect nothing takes is reported, and a verb the
/// interpreter takes is not.
@Test func theInterpreterReportsAnEffectNothingTakes() {
    #expect(!interpreterRuns("zz_no_such_effect", ["x": 1]))
    #expect(interpreterRuns("set", ["x": 1]))
    #expect(interpreterRuns("log", "hello"))
}
