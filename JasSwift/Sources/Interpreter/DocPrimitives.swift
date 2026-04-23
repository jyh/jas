// Document-aware evaluator primitives — the Swift analogue of
// jas_dioxus/src/interpreter/doc_primitives.rs.
//
// Tools written in YAML call `hit_test(x, y)`, `selection_contains(path)`,
// etc. The pure expression evaluator has no way to see a Document through
// its signature, so we stash the current Document here while a tool
// dispatch is running. Rust uses a thread_local; Swift's AppKit tool
// dispatch is single-threaded so a module-level var is sufficient.
//
// Nesting: `registerDocument` returns an ARC-managed handle whose
// deinit restores the prior registration. Callers keep the handle
// alive for the scope where the primitive should see the document;
// when the handle drops, the prior registration is restored.

import Foundation

private var _currentDocument: Document? = nil

/// ARC-managed registration. Save the handle to a `let` local — when
/// it goes out of scope, `deinit` restores the previously-registered
/// document. Matches the DocGuard RAII pattern from the Rust port.
final class DocRegistration {
    private let prior: Document?

    fileprivate init(doc: Document) {
        self.prior = _currentDocument
        _currentDocument = doc
    }

    deinit {
        _currentDocument = self.prior
    }
}

/// Install `doc` as the current-dispatch document. Returned handle
/// MUST be bound to a non-underscore local — `let _ = registerDocument(...)`
/// would destroy it immediately. Usually called at the start of a
/// tool dispatch.
func registerDocument(_ doc: Document) -> DocRegistration {
    DocRegistration(doc: doc)
}

/// Peek at the registered document for use by the primitives below.
/// Returns nil when no dispatch is active; callers return `.null` /
/// `.bool(false)` in that case, matching the Rust port's lenient
/// behavior.
private func withDoc<R>(_ default_: R, _ f: (Document) -> R) -> R {
    guard let d = _currentDocument else { return default_ }
    return f(d)
}

// MARK: - Primitives

/// `hit_test(x, y)` — topmost unlocked, visible element whose bounding
/// box contains the point. Stops at direct layer children (doesn't
/// recurse into groups).
func docHitTest(_ x: Double, _ y: Double) -> Value {
    withDoc(.null) { doc in
        for (li, layer) in doc.layers.enumerated().reversed() {
            if layer.locked || layer.visibility == .invisible { continue }
            for (ci, child) in layer.children.enumerated().reversed() {
                if child.isLocked || child.visibility == .invisible { continue }
                let b = child.bounds
                if x >= b.x && x <= b.x + b.width
                    && y >= b.y && y <= b.y + b.height {
                    return .path([li, ci])
                }
            }
        }
        return .null
    }
}

/// `hit_test_deep(x, y)` — recurses into groups so the returned path
/// points at the deepest leaf.
func docHitTestDeep(_ x: Double, _ y: Double) -> Value {
    func recurse(_ elem: Element, _ path: [Int],
                 _ x: Double, _ y: Double) -> [Int]? {
        if elem.isLocked || elem.visibility == .invisible { return nil }
        let children: [Element]
        switch elem {
        case .group(let g): children = g.children
        case .layer(let l): children = l.children
        default:
            let b = elem.bounds
            if x >= b.x && x <= b.x + b.width
                && y >= b.y && y <= b.y + b.height {
                return path
            }
            return nil
        }
        for (i, child) in children.enumerated().reversed() {
            if child.isLocked { continue }
            var childPath = path
            childPath.append(i)
            if let r = recurse(child, childPath, x, y) { return r }
        }
        return nil
    }
    return withDoc(.null) { doc in
        for (li, layer) in doc.layers.enumerated().reversed() {
            if layer.locked || layer.visibility == .invisible { continue }
            for (ci, child) in layer.children.enumerated().reversed() {
                if child.isLocked { continue }
                if let r = recurse(child, [li, ci], x, y) {
                    return .path(r)
                }
            }
        }
        return .null
    }
}

/// `selection_contains(path)` — true iff the given path is in the
/// current selection.
func docSelectionContains(_ path: [Int]) -> Value {
    withDoc(.bool(false)) { doc in
        .bool(doc.selection.contains { $0.path == path })
    }
}

/// `selection_empty()` — true iff nothing is selected.
func docSelectionEmpty() -> Value {
    withDoc(.bool(true)) { doc in
        .bool(doc.selection.isEmpty)
    }
}
