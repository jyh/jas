/// Immutable lexical scope for expression evaluation.
///
/// Bindings are stored as an immutable dictionary. New scopes are created
/// via extend() (push child scope) or merge() (add bindings at same level).
/// The scope chain implements static scoping — inner scopes shadow outer
/// bindings without mutating them.

import Foundation

final class Scope {
    private let bindings: [String: Any]
    private let parent: Scope?

    init(_ bindings: [String: Any] = [:], parent: Scope? = nil) {
        self.bindings = bindings
        self.parent = parent
    }

    /// Resolve a top-level key through the scope chain.
    func get(_ key: String) -> Any? {
        if let v = bindings[key] { return v }
        return parent?.get(key)
    }

    /// Push a child scope. Self becomes the parent.
    func extend(_ newBindings: [String: Any]) -> Scope {
        Scope(newBindings, parent: self)
    }

    /// Merge: create a new scope at the same level with additional bindings.
    func merge(_ extra: [String: Any]) -> Scope {
        var merged = bindings
        for (k, v) in extra { merged[k] = v }
        return Scope(merged, parent: parent)
    }

    /// Flatten the scope chain to a plain dict for the expression evaluator.
    func toDict() -> [String: Any] {
        var result = parent?.toDict() ?? [:]
        for (k, v) in bindings { result[k] = v }
        return result
    }
}
