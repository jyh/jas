import Foundation

/// The `preferences` namespace: the bundle's defaults
/// (`workspace/preferences.yaml`, compiled into `workspace.json`) with the
/// user's overrides applied (STATUS-jas item 37). Mirrors Rust
/// `interpreter::preferences` and the reference's `StateStore.preferences` /
/// `toggle_preference_member`.
///
/// One store per process, behind a lock: the readers include
/// ``readPrefNumber(_:default:)``, which has no model. Persisting the overrides
/// across launches is the launch half of item 37, not built here.
public enum Preferences {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: Any] = [:]

    private static func bundled() -> [String: Any]? {
        WorkspaceData.load()?.data["preferences"] as? [String: Any]
    }

    private static func at(_ root: Any?, _ key: String) -> Any? {
        key.split(separator: ".").reduce(root) { node, p in (node as? [String: Any])?[String(p)] }
    }

    private static func setting(_ root: [String: Any], _ parts: ArraySlice<Substring>, _ value: Any) -> [String: Any] {
        var out = root
        guard let head = parts.first else { return out }
        if parts.count == 1 {
            out[String(head)] = value
        } else {
            out[String(head)] = setting(out[String(head)] as? [String: Any] ?? [:], parts.dropFirst(), value)
        }
        return out
    }

    /// The bundle's preferences with the overrides applied; nil when there is
    /// no bundle.
    public static func current() -> [String: Any]? {
        guard var prefs = bundled() else { return nil }
        lock.lock(); let o = overrides; lock.unlock()
        for (key, value) in o {
            prefs = setting(prefs, key.split(separator: ".")[...], value)
        }
        return prefs
    }

    /// `state.brushes_open_libraries` at startup (state.yaml; STATUS-jas item
    /// 37): one open, expanded section per slug of
    /// `preferences.brushes.persistent_libraries`, in order, or the declared
    /// fallback when the list is empty. Mirrors the reference's
    /// `open_libraries_at_launch`; shared fixture
    /// `test_fixtures/preferences/open_libraries_at_launch.json`.
    public static func openLibrariesAtLaunch(_ slugs: Any?) -> [[String: Any]] {
        var ids = (slugs as? [Any] ?? []).compactMap { $0 as? String }
        if ids.isEmpty { ids = ["default_brushes"] }
        return ids.map { ["id": $0, "collapsed": false] }
    }

    /// Add `value` to the LIST preference at `key` when absent, remove it when
    /// present, as an override; an override equal to the bundle's default is
    /// dropped. Refuses (false) a key the bundle does not declare as a list.
    @discardableResult
    public static func toggleMember(_ key: String, _ value: Any) -> Bool {
        guard let defaults = at(bundled(), key) as? [Any],
              let now = at(current(), key) as? [Any] else { return false }
        let same = { (a: Any) in (a as AnyObject).isEqual(value) }
        let next: [Any] = now.contains(where: same) ? now.filter { !same($0) } : now + [value]
        lock.lock(); defer { lock.unlock() }
        if (next as NSArray).isEqual(to: defaults) {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = next
        }
        return true
    }
}
