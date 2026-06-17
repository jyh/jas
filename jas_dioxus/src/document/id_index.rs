//! The persistent id->element index and its builders (REFERENCE_GRAPH.md §2.4).
//!
//! This is CORE (non-web) code: the `Model` (also core) carries an `IdIndex`
//! paired with its document snapshot, so it must not depend on the web-gated
//! `canvas` module. The render-scoped *installation* of an index for a paint
//! (the thread-local `CURRENT_REF_INDEX`, `install_ref_index`, the
//! `RenderResolver`) stays in `canvas::render`, which is web-only; only the
//! index DATA and its pure builders live here.
//!
//! The map values are bit-identical to the old per-paint rebuild (same walk,
//! same first-occurrence-wins discipline, same sorted-symbols order), so
//! resolve() results are unchanged — this is a pure perf substrate.

use crate::document::document::Document;
use crate::geometry::element::*;

/// Persistent id->element index (REFERENCE_GRAPH.md §2.4). `RedBlackTreeMap`
/// gives O(log n) lookup/insert, O(1) structure-sharing clone (so each undo
/// snapshot carries the index cheaply), and sorted iteration. `PartialEq` is
/// available because `Element` is `PartialEq`, which lets the debug-assert gate
/// compare a maintained index against a from-scratch rebuild by value.
pub type IdIndex = rpds::RedBlackTreeMap<String, std::rc::Rc<Element>>;

fn collect_ref_ids(elem: &std::rc::Rc<Element>, out: &mut IdIndex) {
    if let Some(id) = &elem.common().id {
        // first-occurrence wins (the unique-id invariant means there are no
        // collisions in practice; this just makes the build deterministic).
        if !out.contains_key(id) {
            out.insert_mut(id.clone(), elem.clone());
        }
    }
    if let Some(children) = elem.children() {
        for child in children {
            collect_ref_ids(child, out);
        }
    }
}

/// Build the persistent id->element index from `doc`. This is the SINGLE
/// canonical walk: it is both the builder used to populate the Model's
/// companion index (so paint can read it without rebuilding) and the oracle
/// the debug-assert gate compares against (REFERENCE_GRAPH.md §2.3 trust
/// mechanism). The walk is identical to the pre-Phase-4b per-paint rebuild, so
/// the resulting map's values are bit-identical.
///
/// Indexes id-bearing descendants (which are `Rc`-held); top-level layer ids
/// are not resolution targets in Phase 1 (references target shapes).
///
/// Also indexes `doc.symbols` (SYMBOLS.md §2): each master is walked with the
/// same operands-opaque discipline so a `ReferenceElem` instance can resolve a
/// master by its `common.id`. Unlike layers, a master's OWN id is a valid
/// target (a master is reached only through a reference), so each master is
/// indexed directly (its own id + id-bearing descendants), not skipped like a
/// top-level layer. Masters live off-canvas (not in `layers`), so indexing them
/// here makes them resolvable WITHOUT ever making them painted — the whole
/// point of the off-canvas store. Masters are sorted by id before indexing so a
/// duplicate-id master resolves deterministically (first-by-id wins), matching
/// the §2 deterministic-order rule (the unique-id invariant means there are no
/// collisions in a well-formed document).
pub fn rebuild_id_index(doc: &Document) -> IdIndex {
    let mut index = IdIndex::new();
    for layer in &doc.layers {
        if let Some(children) = layer.children() {
            for child in children {
                collect_ref_ids(child, &mut index);
            }
        }
    }
    let mut sorted_masters: Vec<&Element> = doc.symbols.iter().collect();
    sorted_masters.sort_by(|a, b| {
        a.common().id.as_deref().unwrap_or("")
            .cmp(b.common().id.as_deref().unwrap_or(""))
    });
    for master in sorted_masters {
        collect_ref_ids(&std::rc::Rc::new(master.clone()), &mut index);
    }
    index
}

/// Remove every id contributed by `elem`'s subtree from `idx` (the inverse of
/// [`collect_ref_ids`]). Walks Group/Layer children only, exactly mirroring the
/// builder's descent so the set of touched ids matches. Under the unique-id
/// invariant each id is owned by a single live node, so removing the ids of a
/// vanished subtree never drops an id another live node still owns.
fn remove_ref_ids(elem: &std::rc::Rc<Element>, idx: &mut IdIndex) {
    if let Some(id) = &elem.common().id {
        idx.remove_mut(id);
    }
    if let Some(children) = elem.children() {
        for child in children {
            remove_ref_ids(child, idx);
        }
    }
}

/// Incrementally bring `idx` (the index paired with `old_doc`) into agreement
/// with `new_doc`, walking only the regions that changed — O(changed) rather
/// than the O(N) full [`rebuild_id_index`]. The result is value-equal to
/// `rebuild_id_index(new_doc)`; the Model's debug-assert gate enforces this on
/// every edit, which is the correctness proof (REFERENCE_GRAPH.md §2.4).
///
/// The key is CoW structure sharing: a deep edit clones (via `Rc::make_mut`)
/// only the root-to-edit path, so untouched sibling subtrees keep their `Rc`
/// pointer. Diffing each child list by `Rc::ptr_eq` therefore isolates the
/// edit: a child `Rc` present (pointer-identical) in BOTH old and new is a
/// fully-unchanged subtree and is skipped; a child only in OLD is removed
/// (walk-remove its ids); a child only in NEW is added (walk-add its ids). A
/// modified node appears as both old-only and new-only, so its ids are removed
/// then re-added against the new value (net: re-pointed, or removed+added if
/// the id changed). Removals run before additions so that when a node is
/// modified, the new value wins (matching rebuild's first-occurrence-wins
/// discipline reached via `collect_ref_ids`).
///
/// Top-level `layers` and `symbols` are owned `Vec<Element>` (no `Rc` at the
/// top), so structure sharing lives in their children. Layers' own ids are not
/// resolution targets, so only their child `Rc` lists are diffed (across all
/// layers as one pool — order is irrelevant under the unique-id invariant).
/// Symbols' OWN ids ARE targets and each master is re-cloned into a fresh `Rc`
/// by the builder, so masters are diffed by value (their subtrees are small);
/// removed masters walk-remove and added masters walk-add through the same
/// `collect_ref_ids` used by rebuild, preserving identical values and the
/// sorted-order / first-occurrence discipline.
pub fn incremental_update_index(mut idx: IdIndex, old_doc: &Document, new_doc: &Document) -> IdIndex {
    use std::collections::HashSet;

    // --- Layers: diff the combined pool of all top-level layers' child Rcs. ---
    let old_layer_children: Vec<&std::rc::Rc<Element>> = old_doc
        .layers
        .iter()
        .filter_map(|l| l.children())
        .flatten()
        .collect();
    let new_layer_children: Vec<&std::rc::Rc<Element>> = new_doc
        .layers
        .iter()
        .filter_map(|l| l.children())
        .flatten()
        .collect();
    let new_ptrs: HashSet<*const Element> =
        new_layer_children.iter().map(|c| std::rc::Rc::as_ptr(c)).collect();
    let old_ptrs: HashSet<*const Element> =
        old_layer_children.iter().map(|c| std::rc::Rc::as_ptr(c)).collect();
    // Removals first (old-only subtrees), then additions (new-only subtrees).
    for c in &old_layer_children {
        if !new_ptrs.contains(&std::rc::Rc::as_ptr(c)) {
            remove_ref_ids(c, &mut idx);
        }
    }
    for c in &new_layer_children {
        if !old_ptrs.contains(&std::rc::Rc::as_ptr(c)) {
            collect_ref_ids(c, &mut idx);
        }
    }

    // --- Symbols: owned masters re-cloned by the builder; diff by value. ---
    // Masters whose value is unchanged contribute identically (skip). The
    // symbols set is small, so the O(symbols) value diff is negligible and
    // mirrors rebuild's per-master `collect_ref_ids(Rc::new(clone))`.
    let symbols_changed = old_doc.symbols != new_doc.symbols;
    if symbols_changed {
        // Remove the contribution of masters that are gone (value not present
        // in new), then add the contribution of masters that are new (value
        // not present in old). Value-equal masters in both are left untouched.
        let mut new_remaining: Vec<&Element> = new_doc.symbols.iter().collect();
        for master in &old_doc.symbols {
            if let Some(pos) = new_remaining.iter().position(|m| *m == master) {
                // Unchanged master: keep its existing index entries.
                new_remaining.remove(pos);
            } else {
                remove_ref_ids(&std::rc::Rc::new(master.clone()), &mut idx);
            }
        }
        // Whatever remains in `new_remaining` is genuinely new; add it.
        // Sorted-by-id add to mirror rebuild's deterministic order (matters
        // only if duplicate ids ever appear, which the invariant forbids).
        let mut additions = new_remaining;
        additions.sort_by(|a, b| {
            a.common().id.as_deref().unwrap_or("")
                .cmp(b.common().id.as_deref().unwrap_or(""))
        });
        for master in additions {
            collect_ref_ids(&std::rc::Rc::new(master.clone()), &mut idx);
        }
    }

    idx
}
