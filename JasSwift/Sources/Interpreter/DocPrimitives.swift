// Document-aware evaluator primitives — the Swift analogue of
// jas_dioxus/src/interpreter/doc_primitives.rs.
//
// Tools written in YAML call `hit_test(x, y)`, `selection_contains(path)`,
// etc. The pure expression evaluator has no way to see a Document through
// its signature, so we stash the current Document here while a tool
// dispatch is running. Rust uses a thread_local, and so do we: the
// registration is per-thread, so a tool dispatch on the main thread is
// unaffected by anything on another thread. (A plain module-level var
// looks fine for the single-threaded app, but the parallel test runner
// dispatches many tools concurrently — concurrent writes to one global
// Document? corrupt it and reads see another test's document. The
// thread-local keeps each thread's registration isolated, exactly like
// the Rust port.)
//
// Nesting: `registerDocument` returns an ARC-managed handle whose
// deinit restores the prior registration. Callers keep the handle
// alive for the scope where the primitive should see the document;
// when the handle drops, the prior registration is restored.

import Foundation

private let _currentDocumentTLSKey = "JasLib._currentDocument"

/// Box so a value-type `Document` can live in the thread dictionary
/// (which stores reference types only).
private final class DocumentBox {
    let doc: Document?
    init(_ doc: Document?) { self.doc = doc }
}

private var _currentDocument: Document? {
    get {
        (Thread.current.threadDictionary[_currentDocumentTLSKey]
            as? DocumentBox)?.doc
    }
    set {
        Thread.current.threadDictionary[_currentDocumentTLSKey] =
            DocumentBox(newValue)
    }
}

/// ARC-managed registration. Save the handle to a `let` local — when
/// it goes out of scope, `deinit` restores the previously-registered
/// document. Matches the DocGuard RAII pattern from the Rust port.
/// Registration is thread-local: the prior value captured on `init`
/// and restored on `deinit` is this thread's prior document.
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

/// `hit_test(x, y)` — `[li, ci]` of the topmost unlocked, visible layer
/// child whose PAINTED geometry is under the point. The law is
/// `HitLaw.swift` (SELECTION_TOOL.md § Hit test: painted geometry); a
/// group is hit when any child is. Layers are tried topmost first too.
func docHitTest(_ x: Double, _ y: Double) -> Value {
    withDoc(.null) { doc in
        for (li, layer) in doc.layers.enumerated().reversed() {
            let le = Element.layer(layer)
            guard let vis = hitLawBlocksHit(le, .preview),
                  let (lx, ly) = hitLawToLocal(le, x, y) else { continue }
            for (ci, child) in layer.children.enumerated().reversed()
            where hitLawPaintedHit(child, lx, ly, vis) {
                return .path([li, ci])
            }
        }
        return .null
    }
}

/// `hit_test_deep(x, y)` — recurses into groups so the returned path
/// points at the deepest PAINTED leaf.
func docHitTestDeep(_ x: Double, _ y: Double) -> Value {
    withDoc(.null) { doc in
        for (li, layer) in doc.layers.enumerated().reversed() {
            if let r = hitLawDeepHit(.layer(layer), [li], x, y, .preview) {
                return .path(r)
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
