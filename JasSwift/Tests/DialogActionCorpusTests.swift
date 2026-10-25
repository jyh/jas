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
private func addressed(_ content: Any?, _ address: [String: Any],
                       context: [String: Any]) -> Result<[String: Any], DialogCorpusError> {
    var found: [[String: Any]] = []
    func walk(_ node: Any?) {
        guard let n = node as? [String: Any] else { return }
        if address.allSatisfy({ k, v in "\(n[k] ?? NSNull())" == "\(v)" && n[k] != nil }) {
            found.append(n)
        }
        for child in n["children"] as? [Any] ?? [] { walk(child) }
        // A `tabs` node renders only its ACTIVE page (`renderTabs`), so only
        // that page's widgets are addressable, as on the engine's route.
        if n["type"] as? String == "tabs" { walk(activeTabContent(n, context: context)) }
    }
    walk(content)
    guard found.count == 1 else {
        return .failure(DialogCorpusError(text: "the address \(address) matches \(found.count) widget(s), want exactly 1"))
    }
    return .success(found[0])
}

private struct DialogCorpusError: Error { let text: String }

/// The active page's content of a `tabs` node: `bind.value` evaluated when it
/// is a non-empty string, else the first tab (`renderTabs`' law).
private func activeTabContent(_ node: [String: Any], context: [String: Any]) -> [String: Any]? {
    let tabs = node["tabs"] as? [[String: Any]] ?? []
    var active = tabs.first?["id"] as? String ?? ""
    if let e = (node["bind"] as? [String: Any])?["value"] as? String,
       case .string(let s) = evaluate(e, context: context), !s.isEmpty {
        active = s
    }
    return tabs.first(where: { ($0["id"] as? String) == active })?["content"] as? [String: Any]
}

/// JSON equality with one number type (Rust's `json_value_eq`).
private func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (let x as Bool, let y as Bool): return x == y
    case (let x as NSNumber, let y as NSNumber):
        if CFGetTypeID(x) == CFBooleanGetTypeID() || CFGetTypeID(y) == CFBooleanGetTypeID() { return false }
        return x.doubleValue == y.doubleValue
    case (let x as String, let y as String): return x == y
    // Compound values compare structurally, as the engine's `json_value_eq`
    // does (`expected_data` pins a whole brush). Until then two equal objects
    // compared false.
    case (let x as [String: Any], let y as [String: Any]):
        return x.count == y.count && x.allSatisfy { k, v in y.keys.contains(k) && sameJSON(v, y[k]) }
    case (let x as [Any], let y as [Any]):
        return x.count == y.count && zip(x, y).allSatisfy { sameJSON($0, $1) }
    case (nil, nil), (is NSNull, is NSNull), (nil, is NSNull), (is NSNull, nil): return true
    default: return false
    }
}

/// The panel kind and menu command of a `panel_menu` step: the ONE row of the
/// panel's YAML `menu:` whose every `address` key equals its own (zero or two
/// refuse by name, as the engine runner does), taken at that row's index from
/// the menu the view draws (``panelMenu(_:)``), which must have one item per row.
private func panelMenuCommand(_ step: [String: Any], ws: WorkspaceData)
    -> Result<(PanelKind, String), DialogCorpusError> {
    let pid = step["panel"] as? String ?? ""
    let kinds = PanelKind.all + [.brushes, .gradient, .concepts]
    guard let kind = kinds.first(where: { panelKindToContentId($0) == pid }) else {
        return .failure(DialogCorpusError(text: "no panel kind for \(pid)"))
    }
    let address = step["address"] as? [String: Any] ?? [:]
    let rows = ws.panelMenuRaw(pid)
    let hits = rows.indices.filter { i in
        guard let n = rows[i] as? [String: Any] else { return false }
        return address.allSatisfy { k, v in n[k] != nil && "\(n[k]!)" == "\(v)" }
    }
    guard hits.count == 1 else {
        return .failure(DialogCorpusError(text: "the address \(address) matches \(hits.count) row(s) of \(pid)'s menu, want exactly 1"))
    }
    let items = panelMenu(kind)
    guard items.count == rows.count else {
        return .failure(DialogCorpusError(text: "\(pid)'s menu draws \(items.count) item(s) for \(rows.count) row(s)"))
    }
    switch items[hits[0]] {
    case .action(_, let cmd, _), .toggle(_, let cmd), .radio(_, let cmd, _): return .success((kind, cmd))
    case .separator: return .failure(DialogCorpusError(text: "row \(hits[0]) of \(pid)'s menu is a separator"))
    }
}

/// A seeded isolation stack as the Mac's model holds it: a list of paths.
private func macIsolationStack(_ v: Any) -> [[Int]] {
    (v as? [Any] ?? []).compactMap { e in
        (e as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
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
    // `panel_state`: a panel's own state as the artist left it (a selection
    // made by clicking tiles, which no verb sets), seeded over the panel's
    // declared defaults. The engine runner seeds it the same way.
    for (pid, keys) in tc["panel_state"] as? [String: Any] ?? [:] {
        if !store.hasPanel(pid) { store.initPanel(pid, defaults: ws.panelStateDefaults(pid)) }
        for (k, v) in keys as? [String: Any] ?? [:] {
            store.setPanel(pid, k, v)
            if pid == "layers_panel_content", k == "isolation_stack" {
                m.layersIsolationStack = macIsolationStack(v)
            }
        }
    }
    var atOpen: String? = nil
    for step in tc["actions"] as? [[String: Any]] ?? [] {
        if let pm = step["panel_menu"] as? [String: Any] {
            // A panel-menu click, through the menu's own route (``panelDispatch``)
            // with the command the menu view holds for that row.
            switch panelMenuCommand(pm, ws: ws) {
            case .success(let (kind, cmd)):
                var layout = WorkspaceLayout.defaultLayout()
                panelDispatch(kind, cmd: cmd,
                              addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                              layout: &layout, model: m)
            case .failure(let e): return ["\(name): \(e.text)"]
            }
        } else if let od = step["open_dialog"] {
            if atOpen == nil { atOpen = documentToTestJson(m.document) }
            runEffects([["open_dialog": od]], ctx: [:], store: store,
                       actions: ws.actions(), dialogs: ws.dialogs(),
                       platformEffects: buildYamlToolEffects(model: m), model: m)
        } else if let ev = step["dialog_event"] as? [String: Any] {
            guard let id = store.getDialogId(), let spec = ws.dialog(id) else {
                return ["\(name): a dialog_event with no dialog open"]
            }
            let ctx = buildDialogEvalContextWithGetters(
                store: store, state: store.getDialogState(),
                params: store.getDialogParams() ?? [:], outer: [:])
            let node: [String: Any]
            switch addressed(spec["content"], ev["address"] as? [String: Any] ?? [:], context: ctx) {
            case .success(let n): node = n
            case .failure(let e): return ["\(name): \(e.text)"]
            }
            let route = PanelWidgetEvents(model: m, panelId: nil, scope: ctx,
                                          onDialogWrite: { k, v in DialogWidgetActions.write(k, v, store: store) })
            switch ev["event"] as? String {
            case "commit":
                let r = route.commit(node, text: ev["value"] as? String)
                if r.outcome == "refused" { return ["\(name): the commit was refused (\(r.reason ?? "-"))"] }
            case "click":
                // By the widget's KIND, as the view routes it: a boolean kind is
                // pressed, a click kind with a node action runs the overlay's
                // act, any other click kind is the contract's click. A refusal
                // is a failure, never swallowed (the engine reports its own).
                let kind = node["type"] as? String ?? ""
                if WidgetEvent.booleanKinds.contains(kind) {
                    let r = route.press(node)
                    if r.outcome == "refused" { return ["\(name): the press was refused (\(r.reason ?? "-"))"] }
                } else if WidgetEvent.clickKinds.contains(kind) {
                    if WidgetEvent.clickRunsNodeAction(node), let action = node["action"] as? String {
                        DialogWidgetActions.run(
                            action,
                            params: DialogWidgetActions.resolveParams(node["params"] as? [String: Any] ?? [:], context: ctx),
                            model: m)
                    } else {
                        let r = route.click(node)
                        if r.outcome == "refused" { return ["\(name): the click was refused (\(r.reason ?? "-"))"] }
                    }
                } else {
                    return ["\(name): a click on a \(kind), which this runner does not route"]
                }
            case "change" where node["type"] as? String == "tabs":
                // A tab pick, as `renderTabs` writes it: the tab id through a
                // `dialog.` bind. Any other bind, or an id no tab has, refuses.
                let tabIds = (node["tabs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                let expr = (node["bind"] as? [String: Any])?["value"] as? String ?? ""
                guard expr.hasPrefix("dialog."), let tab = ev["value"] as? String, tabIds.contains(tab) else {
                    return ["\(name): the tab pick was refused (bind \(expr), value \(ev["value"] ?? "nil"))"]
                }
                DialogWidgetActions.write(String(expr.dropFirst("dialog.".count)), tab, store: store)
            default:
                return ["\(name): unknown dialog event \(ev["event"] ?? "nil")"]
            }
        } else if let action = step["action"] as? String {
            // A dialog an action opens (`open_boolean_options`) is compared
            // from the document as it opened, as the engine runner does.
            let before = documentToTestJson(m.document)
            if action == "select_all" {
                MenuActions.selectAll(m)
            } else {
                LayersPanel.dispatchYamlAction(action, model: m, params: step["params"] as? [String: Any] ?? [:])
            }
            if atOpen == nil, store.getDialogId() != nil { atOpen = before }
        } else {
            return ["\(name): a step this runner does not know: \(step)"]
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
    // `expected_data`: a dotted path into the store's `data` namespace, where
    // an integer segment indexes an array and -1 is its last item; a path that
    // does not resolve is a failure. The engine runner reads it the same way.
    // The swatch libraries are not in the store on the Mac: they are app-global
    // (``AppSwatchLibraries``, `model.swatchLibraries`), so `data.swatch_libraries`
    // is read from there.
    var dataRoot = store.getDataPath("") as? [String: Any] ?? [:]
    dataRoot["swatch_libraries"] = m.swatchLibraries.libs
    for (path, value) in tc["expected_data"] as? [String: Any] ?? [:] {
        var cur: Any? = dataRoot
        for seg in path.split(separator: ".").map(String.init) {
            if let a = cur as? [Any], let i = Int(seg) {
                let j = i < 0 ? a.count + i : i
                cur = (0..<a.count).contains(j) ? a[j] : nil
            } else {
                cur = (cur as? [String: Any])?[seg]
            }
            if cur == nil { break }
        }
        if cur == nil {
            failures.append("\(name): data.\(path) does not resolve")
        } else if !sameJSON(cur, value) {
            failures.append("\(name): data.\(path) is \(String(describing: cur)), the corpus pins \(value)")
        }
    }
    // `expected_panel`: a subset of a panel's own state after the last step.
    for (pid, keys) in tc["expected_panel"] as? [String: Any] ?? [:] {
        for (key, value) in keys as? [String: Any] ?? [:] {
            // The Mac keeps the Layers isolation stack on the model
            // (`Model.layersIsolationStack`, read by the panel and the tools),
            // so that key is read from there.
            let have: Any? = pid == "layers_panel_content" && key == "isolation_stack"
                ? m.layersIsolationStack : store.getPanel(pid, key)
            if have == nil || !sameJSON(have, value) {
                failures.append("\(name): panel \(pid).\(key) is \(String(describing: have)), the corpus pins \(value)")
            }
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
    "dialog_actions/tool_options.json",
    "dialog_actions/boolean_options.json",
    "dialog_actions/paragraph_dialogs.json",
    "dialog_actions/brush_options.json",
    "dialog_actions/artboard_options.json",
    "dialog_actions/document_setup.json",
    "dialog_actions/print.json",
    "dialog_actions/panel_menu_actions.json",
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
private let swiftDialogGaps: [String: String] = [:]
