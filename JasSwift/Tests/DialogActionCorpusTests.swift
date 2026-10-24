import Foundation
import Testing
@testable import JasLib

// THE ACTION CORPUS, INSIDE AN OPEN DIALOG (`test_fixtures/dialog_actions/`),
// on the Mac's store route: the dialog opens in the model's StateStore (the
// `open_dialog` effect, with the tool table's `doc.preview.capture`), a field
// commit is ``PanelWidgetEvents`` with the overlay's write
// (``DialogWidgetActions/write(_:_:store:)``), and a button is the overlay's
// act (``DialogWidgetActions/run(_:params:model:)``) with its params resolved
// as the view resolves them. Rust drives the same cases through the engine's
// `jas_dialog_event` (`ffi.rs`, `dialog_action_corpus_runs_on_the_engine_route`);
// the `expected_json` goldens are shared.

private func dialogFixtures() -> String {
    let testsDir = (#filePath as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    return ((jasSwiftDir as NSString)
        .appendingPathComponent("../test_fixtures") as NSString).standardizingPath
}

private func readText(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
}

/// The path of the ONE static node whose every `address` key equals its own;
/// zero or two matches is a failure that names the count (Rust's
/// `dialog_address_path`).
private func addressed(_ content: Any?, _ address: [String: Any]) -> Result<[String: Any], DialogCorpusError> {
    var found: [[String: Any]] = []
    func walk(_ node: Any?) {
        guard let n = node as? [String: Any] else { return }
        if address.allSatisfy({ k, v in "\(n[k] ?? NSNull())" == "\(v)" && n[k] != nil }) {
            found.append(n)
        }
        for child in n["children"] as? [Any] ?? [] { walk(child) }
    }
    walk(content)
    guard found.count == 1 else {
        return .failure(DialogCorpusError(text: "the address \(address) matches \(found.count) widget(s), want exactly 1"))
    }
    return .success(found[0])
}

private struct DialogCorpusError: Error { let text: String }

/// JSON equality with one number type (Rust's `json_value_eq`).
private func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (let x as Bool, let y as Bool): return x == y
    case (let x as NSNumber, let y as NSNumber):
        if CFGetTypeID(x) == CFBooleanGetTypeID() || CFGetTypeID(y) == CFBooleanGetTypeID() { return false }
        return x.doubleValue == y.doubleValue
    case (let x as String, let y as String): return x == y
    case (nil, nil), (is NSNull, is NSNull), (nil, is NSNull), (is NSNull, nil): return true
    default: return false
    }
}

private func runCase(_ tc: [String: Any], root: String) -> [String] {
    let name = tc["name"] as? String ?? "?"
    guard let ws = WorkspaceData.load(),
          let svg = readText("\(root)/svg/\(tc["setup_svg"] as? String ?? "")") else {
        return ["\(name): cannot load the workspace or the setup svg"]
    }
    let m = Model(document: svgToDocument(svg))
    let store = m.stateStore
    var atOpen: String? = nil
    for step in tc["actions"] as? [[String: Any]] ?? [] {
        if let od = step["open_dialog"] {
            if atOpen == nil { atOpen = documentToTestJson(m.document) }
            runEffects([["open_dialog": od]], ctx: [:], store: store,
                       actions: ws.actions(), dialogs: ws.dialogs(),
                       platformEffects: buildYamlToolEffects(model: m), model: m)
        } else if let ev = step["dialog_event"] as? [String: Any] {
            guard let id = store.getDialogId(), let spec = ws.dialog(id) else {
                return ["\(name): a dialog_event with no dialog open"]
            }
            let node: [String: Any]
            switch addressed(spec["content"], ev["address"] as? [String: Any] ?? [:]) {
            case .success(let n): node = n
            case .failure(let e): return ["\(name): \(e.text)"]
            }
            let ctx = buildDialogEvalContextWithGetters(
                store: store, state: store.getDialogState(),
                params: store.getDialogParams() ?? [:], outer: [:])
            let route = PanelWidgetEvents(model: m, panelId: nil, scope: ctx,
                                          onDialogWrite: { k, v in DialogWidgetActions.write(k, v, store: store) })
            switch ev["event"] as? String {
            case "commit":
                let r = route.commit(node, text: ev["value"] as? String)
                if r.outcome == "refused" { return ["\(name): the commit was refused (\(r.reason ?? "-"))"] }
            case "click":
                if WidgetEvent.clickRunsNodeAction(node), let action = node["action"] as? String {
                    DialogWidgetActions.run(
                        action,
                        params: DialogWidgetActions.resolveParams(node["params"] as? [String: Any] ?? [:], context: ctx),
                        model: m)
                } else {
                    route.click(node)
                }
            default:
                return ["\(name): unknown dialog event \(ev["event"] ?? "nil")"]
            }
        } else if let action = step["action"] as? String {
            if action == "select_all" {
                MenuActions.selectAll(m)
            } else {
                LayersPanel.dispatchYamlAction(action, model: m, params: step["params"] as? [String: Any] ?? [:])
            }
        }
    }
    var failures: [String] = []
    if tc.keys.contains("expected_dialog") {
        if let want = tc["expected_dialog"] as? [String: Any] {
            if store.getDialogId() != want["id"] as? String {
                failures.append("\(name): the open dialog is \(store.getDialogId() ?? "none"), want \(want["id"] ?? "?")")
            } else {
                let ctx = buildDialogEvalContextWithGetters(
                    store: store, state: store.getDialogState(),
                    params: store.getDialogParams() ?? [:], outer: [:])
                let dialog = ctx["dialog"] as? [String: Any] ?? [:]
                for (key, value) in want["state"] as? [String: Any] ?? [:] {
                    if !dialog.keys.contains(key) || !sameJSON(dialog[key], value) {
                        failures.append("\(name): dialog.\(key) is \(String(describing: dialog[key])), the corpus pins \(value)")
                    }
                }
            }
        } else if let id = store.getDialogId() {
            failures.append("\(name): dialog \(id) is still open, want none")
        }
    }
    for (key, value) in tc["expected_state"] as? [String: Any] ?? [:] {
        if !sameJSON(store.get(key), value) {
            failures.append("\(name): state.\(key) is \(String(describing: store.get(key))), the corpus pins \(value)")
        }
    }
    let after = documentToTestJson(m.document)
    if let want = tc["expected_document"] as? String {
        switch (want, atOpen) {
        case (_, nil): failures.append("\(name): expected_document needs an open_dialog step to compare from")
        case ("unchanged", let before?) where after != before:
            failures.append("\(name): the document changed, want unchanged:\n\(after)")
        case ("changed", let before?) where after == before:
            failures.append("\(name): the document is unchanged, want changed")
        case ("unchanged", _), ("changed", _): break
        default: failures.append("\(name): expected_document \(want) is neither unchanged nor changed")
        }
    }
    if let file = tc["expected_json"] as? String {
        let want = readText("\(root)/dialog_actions/\(file)")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if want != after {
            failures.append("\(name): canonical JSON mismatch against \(file); ACTUAL:\n\(after)")
        }
    }
    return failures
}

/// The dialog-action corpus's files, by name (the corpus-completeness gate reads
/// this list as the claim; Rust's `DIALOG_ACTION_FIXTURES` is its twin).
private let dialogActionFixtures = [
    "dialog_actions/transform_options.json",
]

@Test func dialogActionCorpusRunsOnTheStoreRoute() throws {
    let root = dialogFixtures()
    var cases: [[String: Any]] = []
    for f in dialogActionFixtures {
        let data = try #require(FileManager.default.contents(atPath: "\(root)/\(f)"))
        cases += (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }
    // The floor: the count on the day the file was cut. A floor is a minimum.
    #expect(cases.count >= 6, "the dialog-action corpus holds \(cases.count) case(s)")
    var failures: [String] = []
    var gapsHeld: Set<String> = []
    for tc in cases {
        let name = tc["name"] as? String ?? "?"
        let found = runCase(tc, root: root)
        if swiftDialogGaps[name] != nil {
            if !found.isEmpty { gapsHeld.insert(name) }
        } else {
            failures += found
        }
    }
    #expect(failures.isEmpty, "\(failures.count) failure(s) over \(cases.count) case(s):\n\(failures.joined(separator: "\n"))")
    // TWO-SIDED: a declared gap that now passes reds until it is removed.
    let closed = Set(swiftDialogGaps.keys).subtracting(gapsHeld).sorted()
    #expect(closed.isEmpty, "these declared gaps now pass: remove them from swiftDialogGaps: \(closed)")
}

/// The cases this port fails for a reason measured and named, not yet repaired.
/// The list can only shrink (the test above reds on a gap that passes).
private let swiftDialogGaps: [String: String] = [
    // The Model's StateStore is created empty (Model.swift, `StateStore()`),
    // where the reference's and the engine's carry the bundle's `state`
    // defaults. Scale Options' init `uniform: state.scale_uniform` then reads
    // null, so `so_uniform_pct` (`disabled: not dialog.uniform`) refuses the
    // commit. Measured 2026-10-24.
    "scale_reset_restores_the_dialog_defaults":
        "the store is not seeded with the bundle's state defaults",
]
