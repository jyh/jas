import Foundation

/// An input script's `app_state` (docs/TESTING.md section 6): the ruled form is
/// `app_state.panels.<content id>.<declared key>`, and inside a list an index
/// array is a PATH. ONE parse and ONE apply, used by the level-1 forms runner
/// and by the test FIFO's `seed` verb (row 275, the Mac slice (b)), so the
/// runner and the live app cannot disagree about which forms are ruled.
public enum ScriptPanelSeeds {
    /// One seeded key: the panel's content id, the key, and the value in the
    /// store's form (a path list item marked `__path__`).
    public struct Seed {
        public let panel: String
        public let key: String
        public let value: Any
    }

    /// The seeds `appState` names, or the refusal by name. `nil` and `{}` seed
    /// nothing. A key the panel's YAML `state:` does not declare is refused
    /// (`UndeclaredPanelKey`), as Rust's `script_seed_panel` refuses it.
    public static func parse(_ appState: Any?) -> Result<[Seed], FifoReadError> {
        guard let appState, !(appState is NSNull) else { return .success([]) }
        guard let app = appState as? [String: Any] else {
            return .failure(FifoReadError(description: "app_state is not an object"))
        }
        var seeds: [Seed] = []
        for (k, v) in app.sorted(by: { $0.key < $1.key }) {
            guard k == "panels" else {
                return .failure(FifoReadError(description:
                    "app_state.\(k) is not a ruled form; seed a panel's declared state as app_state.panels.<content id>.<key>"))
            }
            guard let panels = v as? [String: Any] else {
                return .failure(FifoReadError(description: "app_state.panels is not an object"))
            }
            for (pid, keys) in panels.sorted(by: { $0.key < $1.key }) {
                guard let keys = keys as? [String: Any] else {
                    return .failure(FifoReadError(description: "app_state.panels.\(pid) is not an object"))
                }
                let declared = WorkspaceData.load()?.panelStateDefaults(pid) ?? [:]
                for (key, val) in keys.sorted(by: { $0.key < $1.key }) {
                    guard declared[key] != nil else {
                        return .failure(FifoReadError(description:
                            "app_state.panels.\(pid).\(key): UndeclaredPanelKey \(pid).\(key)"))
                    }
                    let seeded: Any = (val as? [Any]).map { items in
                        items.map { item -> Any in
                            WidgetEvent.rowPath(item).map { p in ["__path__": p] as Any } ?? item
                        }
                    } ?? val
                    seeds.append(Seed(panel: pid, key: key, value: seeded))
                }
            }
        }
        return .success(seeds)
    }

    /// Write the seeds where the app holds each key: a key the app keeps on
    /// the Model (``modelHeldPanelState``) is seeded there, as `read: panel`
    /// reads it there; every other key goes to the panel's store scope.
    public static func apply(_ seeds: [Seed], model: Model) {
        for s in seeds {
            if let items = s.value as? [Any], modelHeldPanelState(s.panel, model: model)[s.key] != nil {
                let paths = items.compactMap { WidgetEvent.rowPath($0) }
                if paths.count == items.count, setModelHeldPanelState(s.panel, s.key, paths: paths, model: model) {
                    continue
                }
            }
            if !model.stateStore.hasPanel(s.panel) {
                model.stateStore.initPanel(s.panel, defaults: WorkspaceData.load()?.panelStateDefaults(s.panel) ?? [:])
            }
            model.stateStore.setPanel(s.panel, s.key, s.value)
        }
    }
}

/// `seed <json>`: an input script's `app_state`, seeded into the active
/// canvas's model through ``ScriptPanelSeeds``. Returns the receipt the app
/// logs (`<n> key(s): <panel>.<key>, …`); throws the refusal by name, and
/// seeds nothing when any key is refused.
public enum FifoSeed {
    public static func run(_ json: String, model: Model) throws -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FifoReadError(description: "seed: the app_state does not parse as JSON")
        }
        switch ScriptPanelSeeds.parse(obj) {
        case .failure(let why):
            throw why
        case .success(let seeds):
            ScriptPanelSeeds.apply(seeds, model: model)
            return "\(seeds.count) key(s): " + seeds.map { "\($0.panel).\($0.key)" }.joined(separator: ", ")
        }
    }
}
