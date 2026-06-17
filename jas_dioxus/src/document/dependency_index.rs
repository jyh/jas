//! Derived DEPENDENCY INDEX over the by-id reference graph
//! (REFERENCE_GRAPH.md §3 — Phase 3 graph structure).
//!
//! A **pure function of the `Document`**: it carries no authoritative state,
//! is never stored on the `Model`, never serialized, and never compared. It is
//! rebuilt on demand (the Phase 1–3 strategy per REFERENCE_GRAPH.md §2.4); no
//! consumer caches it yet.
//!
//! It exposes, for the **by-id reference graph only**:
//!
//! - `deps`     — `id -> sorted list of target ids it directly references`
//! - `rdeps`    — `id -> sorted list of ids that reference it` (reverse of deps)
//! - `dangling` — sorted list of *referencing* ids whose target id is not
//!                present/targetable
//! - `cycles`   — sorted list of ids that participate in a cycle
//!
//! ## Operands are OPAQUE to the by-id graph (locked design)
//!
//! The node walk recurses into Group/Layer children **only**, never into a
//! `CompoundShape`'s operands. Per REFERENCE_GRAPH.md a compound's operands are
//! *owned* (`children()`), and `CompoundShape::dependencies()` is `[]`. So the
//! **targetable set** of ids is exactly the ids found by walking
//! `layers + Group/Layer children` — *not* operand-nested ids. This mirrors the
//! render-time resolver (`canvas::render::collect_ref_ids`), which likewise does
//! not recurse into Live operands because `Element::children()` returns `None`
//! for `Element::Live`. A reference whose target is an operand-nested id is
//! therefore **dangling** (it is not in the targetable set) — this is what pins
//! the operands-opaque decision.
//!
//! ## Determinism
//!
//! Every map is a `BTreeMap` and every value list is a sorted `Vec`, so the
//! output is inherently ordered. The cycle DFS iterates neighbors in **sorted**
//! order. No part of the output relies on `HashMap` iteration order.
//!
//! ## Deferred (NOT implemented here)
//!
//! - **`topo_order`** — the Phase 4 recompute ordering (a topological sort of
//!   the deps DAG, with cycles broken). Deferred until a consumer needs a
//!   recompute schedule; it would live alongside `deps`/`rdeps` here.
//! - **Write-time cycle rejection** — no authoring op can form a cycle yet
//!   (`create_reference` only links to an existing target), and eval-time
//!   cycle-break (the threaded visited-set in `geometry::live`) already handles
//!   imported cycles. A write-time guard is an additive Phase-3+ nicety.

// Module-wide allow: the dependency index is a Phase-3 derived structure with
// no production consumer yet (rebuild-on-demand per REFERENCE_GRAPH.md §2.4 —
// no consumer stores it). Its entire public surface
// (`DependencyIndex`/`dependency_index`/`dependency_index_to_test_json`) is
// exercised only by tests and the cross-language harness today; the UI wiring
// (the dependency-graph consumers of Phase 3+) lands in a later increment.
// Mirrors the same not-yet-wired rationale on `geometry::live`.
#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};

use crate::document::document::Document;
use crate::geometry::element::Element;
use crate::geometry::live::{ElementRef, LiveElement, LiveVariant};

/// The derived dependency index of a `Document`'s by-id reference graph.
///
/// All maps and lists are inherently sorted (`BTreeMap` / sorted `Vec`) so the
/// structure serializes deterministically. Rebuilt on demand via
/// [`dependency_index`] / [`DependencyIndex::build`]; never stored or compared.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DependencyIndex {
    /// `id -> sorted list of target ids it directly references` (out-edges).
    /// Only id-bearing elements with non-empty `dependencies()` appear.
    pub deps: BTreeMap<String, Vec<String>>,
    /// `id -> sorted list of ids that reference it` (in-edges; reverse of
    /// `deps`). Only **targetable** ids (present in the node walk) appear, so a
    /// reference to an absent or operand-nested id contributes no `rdeps` entry.
    pub rdeps: BTreeMap<String, Vec<String>>,
    /// Sorted list of *referencing* ids at least one of whose `dependencies()`
    /// targets is not in the targetable set (absent, or operand-opaque).
    pub dangling: Vec<String>,
    /// Sorted, de-duplicated list of ids that lie on a cycle in the `deps`
    /// graph (a node that can reach itself). A self-target (`R -> R`) is a cycle.
    pub cycles: Vec<String>,
}

impl DependencyIndex {
    /// Build the dependency index for `doc`. Alias for [`dependency_index`].
    pub fn build(doc: &Document) -> Self {
        dependency_index(doc)
    }
}

/// Out-edges of a single element: a `Reference`'s target, or empty for every
/// other kind. `CompoundShape::dependencies()` is `[]` (its operands are owned),
/// so a compound contributes no out-edges even though it owns id-bearing
/// operands.
fn element_dependencies(elem: &Element) -> Vec<ElementRef> {
    match elem {
        Element::Live(v) => match v {
            // Be explicit about both arms so a future LiveVariant forces a
            // decision here rather than silently defaulting to no edges.
            LiveVariant::Reference(_) | LiveVariant::CompoundShape(_) => v.dependencies(),
        },
        _ => Vec::new(),
    }
}

/// Walk `elem` in canonical pre-order, recursing into **Group/Layer children
/// only** (`Element::children()` returns `None` for `Element::Live`, so operands
/// are never entered — the operands-opaque rule). Records, for every id-bearing
/// element, its id in `targetable` and its out-edges in `out_edges`.
///
/// First-occurrence-wins on a duplicate id (matches the resolver and the
/// import-time uniqueness invariant; duplicates do not occur in a well-formed
/// document).
fn walk(
    elem: &Element,
    targetable: &mut BTreeSet<String>,
    out_edges: &mut BTreeMap<String, Vec<String>>,
) {
    if let Some(id) = &elem.common().id {
        // Insert the node into the targetable set (first occurrence wins).
        let is_first = targetable.insert(id.clone());
        if is_first {
            let edges: Vec<String> = element_dependencies(elem)
                .into_iter()
                .map(|r| r.0)
                .collect();
            if !edges.is_empty() {
                out_edges.insert(id.clone(), edges);
            }
        }
    }
    if let Some(children) = elem.children() {
        for child in children {
            walk(child, targetable, out_edges);
        }
    }
}

/// Build the [`DependencyIndex`] for `doc`. A pure, allocation-only function;
/// no document state is mutated. See the module docs for the locked semantics.
pub fn dependency_index(doc: &Document) -> DependencyIndex {
    // Phase 1: gather the node set (targetable ids) and raw out-edges by
    // walking layers + Group/Layer children (operands stay opaque).
    let mut targetable: BTreeSet<String> = BTreeSet::new();
    let mut out_edges: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for layer in &doc.layers {
        walk(layer, &mut targetable, &mut out_edges);
    }

    // Phase 2: build `deps` (sorted out-edges) and `rdeps` (reverse), and
    // collect `dangling` (any out-edge target missing from the targetable set).
    let mut deps: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut rdeps: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut dangling: BTreeSet<String> = BTreeSet::new();

    for (id, edges) in &out_edges {
        let mut sorted = edges.clone();
        sorted.sort();
        sorted.dedup();
        for target in &sorted {
            if targetable.contains(target) {
                // Reverse edge: only targetable ids get an `rdeps` entry, so an
                // absent / operand-nested target contributes none.
                rdeps.entry(target.clone()).or_default().push(id.clone());
            } else {
                // Target not in the node walk -> this referencing id is dangling
                // (absent target, or operand-nested = operands-opaque).
                dangling.insert(id.clone());
            }
        }
        deps.insert(id.clone(), sorted);
    }

    // Normalize rdeps value lists to sorted + deduped.
    for v in rdeps.values_mut() {
        v.sort();
        v.dedup();
    }

    // Phase 3: cycles — every id that can reach itself in the `deps` graph.
    let cycles = find_cycle_members(&deps);

    DependencyIndex {
        deps,
        rdeps,
        dangling: dangling.into_iter().collect(),
        cycles,
    }
}

/// Return the sorted, de-duplicated set of node ids that lie on a cycle in the
/// `deps` graph (a node that can reach itself).
///
/// Algorithm: a single DFS over the deps edges with **sorted** neighbor
/// iteration (for determinism), tracking the current recursion stack. When an
/// edge reaches a node already on the stack, every node from that node to the
/// top of the stack is a cycle member; they are collected. A self-target
/// (`R -> R`) is detected the same way (the neighbor equals the current node,
/// which is on the stack). Output is sorted and de-duplicated by virtue of the
/// `BTreeSet`. Edges to non-`deps` ids (leaf or dangling targets) are skipped —
/// they cannot start a cycle.
///
/// Complexity is O(V + E) over the deps graph: `visited` guarantees each node
/// is explored once, and `on_stack` membership turns cycle detection into O(1).
fn find_cycle_members(deps: &BTreeMap<String, Vec<String>>) -> Vec<String> {
    let mut on_cycle: BTreeSet<String> = BTreeSet::new();
    let mut visited: BTreeSet<String> = BTreeSet::new();

    // Iterating the BTreeMap keys yields sorted roots; each DFS visits in
    // sorted neighbor order (deps values are pre-sorted in `dependency_index`).
    for start in deps.keys() {
        if !visited.contains(start) {
            let mut stack: Vec<String> = Vec::new();
            dfs_cycles(start, deps, &mut visited, &mut stack, &mut on_cycle);
        }
    }

    on_cycle.into_iter().collect()
}

fn dfs_cycles(
    node: &str,
    deps: &BTreeMap<String, Vec<String>>,
    visited: &mut BTreeSet<String>,
    stack: &mut Vec<String>,
    on_cycle: &mut BTreeSet<String>,
) {
    visited.insert(node.to_string());
    stack.push(node.to_string());

    if let Some(neighbors) = deps.get(node) {
        // `neighbors` is already sorted; iterate it directly for determinism.
        for next in neighbors {
            if let Some(pos) = stack.iter().position(|n| n == next) {
                // Back-edge into the current stack: everything from `pos` to the
                // top of the stack is on this cycle (covers self-target too,
                // where `next == node` and `pos` is the top).
                for member in &stack[pos..] {
                    on_cycle.insert(member.clone());
                }
            } else if !visited.contains(next) {
                dfs_cycles(next, deps, visited, stack, on_cycle);
            }
            // else: already fully explored, not on the current stack -> no cycle
            // reachable through it that we have not already recorded.
        }
    }

    stack.pop();
}

// ---------------------------------------------------------------------------
// Reference-aware delete: orphaned-references predicate
// ---------------------------------------------------------------------------
//
// REFERENCE_GRAPH.md — the equivalence-critical core of reference-aware delete
// (the confirm dialog is a later step). A pure graph query over the same by-id
// reference graph the index exposes, so it lives here next to `rdeps`.

/// Collect every id-bearing element id within `elem`'s subtree, recursing into
/// **Group/Layer children only** — the SAME walk discipline as [`walk`]: a
/// `CompoundShape`'s operands are opaque (`Element::children()` is `None` for
/// `Element::Live`), so an id that exists only inside an operand is not a node
/// and is not collected. First occurrence of a duplicate id still inserts it
/// (the set de-dups inherently).
fn collect_ids(elem: &Element, ids: &mut BTreeSet<String>) {
    if let Some(id) = &elem.common().id {
        ids.insert(id.clone());
    }
    if let Some(children) = elem.children() {
        for child in children {
            collect_ids(child, ids);
        }
    }
}

/// Answer "if I delete these elements, which live references (instances)
/// elsewhere would be orphaned — left pointing at a now-deleted target?".
///
/// Returns the **sorted, de-duplicated** ids of references that point at an
/// id which is being deleted but are not themselves in the deletion set.
///
/// Algorithm (REFERENCE_GRAPH.md, locked semantics):
/// 1. `deleted_ids` — the id-bearing ids within every deletion subtree.
///    Each path is resolved via `doc.get_element` (invalid paths skipped),
///    then walked with the operands-opaque discipline ([`collect_ids`]); an id
///    only inside a `CompoundShape` operand is therefore NOT a deleted target.
/// 2. Build `idx = dependency_index(doc)`. For each deleted target `t`, its
///    referrers are `idx.rdeps[t]` (only **targetable** ids ever get an rdeps
///    entry, so an operand-nested target contributes none).
/// 3. `orphaned = { r in rdeps[t] for all deleted t : r not in deleted_ids }` —
///    references whose target is being deleted but which survive the delete.
///
/// Consequences: deleting an element with no external referrers returns `[]`;
/// deleting a target together with its only referrer returns `[]` for that pair
/// (the referrer is itself deleted); deleting an instance returns `[]` (an
/// instance has no `rdeps`); deleting a group orphans the external referrers of
/// any referenced element it contains.
pub fn orphaned_references(doc: &Document, deletion_paths: &[Vec<usize>]) -> Vec<String> {
    // Step 1: gather the id-bearing ids inside every deletion subtree.
    let mut deleted_ids: BTreeSet<String> = BTreeSet::new();
    for path in deletion_paths {
        if let Some(elem) = doc.get_element(path) {
            collect_ids(elem, &mut deleted_ids);
        }
        // Invalid paths are skipped (no element resolves).
    }

    // Step 2/3: for each deleted target, collect its referrers that are NOT
    // themselves being deleted.
    let idx = dependency_index(doc);
    let mut orphaned: BTreeSet<String> = BTreeSet::new();
    for t in &deleted_ids {
        if let Some(referrers) = idx.rdeps.get(t) {
            for r in referrers {
                if !deleted_ids.contains(r) {
                    orphaned.insert(r.clone());
                }
            }
        }
    }
    orphaned.into_iter().collect()
}

// ---------------------------------------------------------------------------
// Canonical JSON serializer
// ---------------------------------------------------------------------------
//
// Mirrors the hand-rolled canonical-JSON pattern used by
// `geometry::test_json` (sorted keys, sorted arrays). Deliberately NOT
// `serde_json::to_string`: the four sibling apps hand-roll the identical shape,
// and the output must be byte-identical. There are no floats here, but the
// object/array/string-escape conventions match the test_json serializer
// exactly (compact, sorted keys, `\\`/`"` escaped).

/// Escape a string for embedding in a canonical-JSON string literal. Matches
/// `geometry::test_json::JsonObj::str_val` (backslash then double-quote).
fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Render `{id: [sorted ids]}` with sorted keys (the map is already a
/// `BTreeMap`, so iteration is sorted; value lists are sorted at build time).
fn map_json(m: &BTreeMap<String, Vec<String>>) -> String {
    let entries: Vec<String> = m
        .iter()
        .map(|(k, v)| {
            let items: Vec<String> = v.iter().map(|s| format!("\"{}\"", escape(s))).collect();
            format!("\"{}\":[{}]", escape(k), items.join(","))
        })
        .collect();
    format!("{{{}}}", entries.join(","))
}

/// Render a sorted string array (the input `Vec` is already sorted).
fn array_json(v: &[String]) -> String {
    let items: Vec<String> = v.iter().map(|s| format!("\"{}\"", escape(s))).collect();
    format!("[{}]", items.join(","))
}

/// Serialize a [`DependencyIndex`] to canonical JSON: an object with the sorted
/// keys `cycles`, `dangling`, `deps`, `rdeps`; `deps`/`rdeps` as objects of
/// sorted id keys to sorted id arrays; `cycles`/`dangling` as sorted arrays.
///
/// Byte-identical to what the sibling apps hand-roll (and the
/// `dependency_index.json` fixture). The top-level keys appear in alphabetical
/// order to match the `JsonObj` sorted-key convention.
pub fn dependency_index_to_test_json(idx: &DependencyIndex) -> String {
    // Keys emitted in sorted (alphabetical) order: cycles, dangling, deps, rdeps.
    format!(
        "{{\"cycles\":{},\"dangling\":{},\"deps\":{},\"rdeps\":{}}}",
        array_json(&idx.cycles),
        array_json(&idx.dangling),
        map_json(&idx.deps),
        map_json(&idx.rdeps),
    )
}

/// Serialize one orphaned-references fixture case to canonical JSON:
/// `{"delete_paths":[[..],..],"orphaned":[sorted ids]}`. Object keys are in
/// sorted (alphabetical) order — `delete_paths` then `orphaned` — matching the
/// `JsonObj` sorted-key convention; `orphaned` is already sorted. `delete_paths`
/// preserves the caller's path/index order (it is the case's input, not output).
/// Reuses the same string escaping as [`dependency_index_to_test_json`].
fn orphaned_case_json(delete_paths: &[Vec<usize>], orphaned: &[String]) -> String {
    let paths: Vec<String> = delete_paths
        .iter()
        .map(|p| {
            let items: Vec<String> = p.iter().map(|i| i.to_string()).collect();
            format!("[{}]", items.join(","))
        })
        .collect();
    format!(
        "{{\"delete_paths\":[{}],\"orphaned\":{}}}",
        paths.join(","),
        array_json(orphaned),
    )
}

/// Serialize a list of orphaned-references fixture cases to a canonical JSON
/// array. The case array order is the file's order (NOT sorted) and is shared
/// verbatim with the sibling apps.
pub fn orphaned_references_cases_to_test_json(cases: &[(Vec<Vec<usize>>, Vec<String>)]) -> String {
    let entries: Vec<String> = cases
        .iter()
        .map(|(paths, orphaned)| orphaned_case_json(paths, orphaned))
        .collect();
    format!("[{}]", entries.join(","))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{CommonProps, Element, LayerElem, RectElem};
    use crate::geometry::live::{CompoundOperation, CompoundShape, ElementRef, ReferenceElem};
    use std::rc::Rc;

    fn rect_with_id(id: Option<&str>) -> Rc<Element> {
        Rc::new(Element::Rect(RectElem {
            x: 0.0,
            y: 0.0,
            width: 10.0,
            height: 10.0,
            rx: 0.0,
            ry: 0.0,
            fill: None,
            stroke: None,
            common: CommonProps {
                id: id.map(String::from),
                ..Default::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
        }))
    }

    fn reference(id: &str, target: &str) -> Rc<Element> {
        Rc::new(Element::Live(LiveVariant::Reference(ReferenceElem::new(
            ElementRef(target.to_string()),
            CommonProps {
                id: Some(id.to_string()),
                ..Default::default()
            },
        ))))
    }

    /// Wrap `children` in a single layer named "Layer".
    fn layer(children: Vec<Rc<Element>>) -> Element {
        Element::Layer(LayerElem {
            children,
            common: CommonProps {
                name: Some("Layer".to_string()),
                ..Default::default()
            },
            isolated_blending: false,
            knockout_group: false,
        })
    }

    fn doc_with_layer(children: Vec<Rc<Element>>) -> Document {
        Document {
            layers: vec![layer(children)],
            selected_layer: 0,
            selection: Vec::new(),
            artboards: Vec::new(),
            artboard_options: Default::default(),
            document_setup: Default::default(),
            print_preferences: Default::default(),
        }
    }

    #[test]
    fn empty_document_has_empty_index() {
        let doc = doc_with_layer(vec![]);
        let idx = dependency_index(&doc);
        assert!(idx.deps.is_empty());
        assert!(idx.rdeps.is_empty());
        assert!(idx.dangling.is_empty());
        assert!(idx.cycles.is_empty());
    }

    #[test]
    fn deps_and_rdeps_for_two_references_to_one_target() {
        // a <- r1, a <- r2.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.deps.get("r1"), Some(&vec!["a".to_string()]));
        assert_eq!(idx.deps.get("r2"), Some(&vec!["a".to_string()]));
        // rdeps of `a` lists r1, r2 sorted; `a` is targetable (a plain rect node).
        assert_eq!(
            idx.rdeps.get("a"),
            Some(&vec!["r1".to_string(), "r2".to_string()])
        );
        assert!(idx.dangling.is_empty());
        assert!(idx.cycles.is_empty());
    }

    #[test]
    fn id_less_element_is_not_a_node() {
        // The rect has no id; only the reference is a node, and its target is
        // absent -> dangling. The id-less rect appears nowhere in the index.
        let doc = doc_with_layer(vec![rect_with_id(None), reference("r", "ghost")]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.deps.len(), 1);
        assert_eq!(idx.deps.get("r"), Some(&vec!["ghost".to_string()]));
        assert!(idx.rdeps.is_empty(), "ghost is not targetable -> no rdeps");
        assert_eq!(idx.dangling, vec!["r".to_string()]);
    }

    #[test]
    fn dangling_when_target_absent() {
        let doc = doc_with_layer(vec![reference("r3", "ghost")]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.dangling, vec!["r3".to_string()]);
        assert!(idx.rdeps.is_empty());
        assert!(idx.cycles.is_empty());
    }

    #[test]
    fn two_cycle_is_detected() {
        // c1 -> c2 -> c1.
        let doc = doc_with_layer(vec![reference("c1", "c2"), reference("c2", "c1")]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.cycles, vec!["c1".to_string(), "c2".to_string()]);
        // Both are targetable references, so each appears in the other's rdeps.
        assert_eq!(idx.rdeps.get("c1"), Some(&vec!["c2".to_string()]));
        assert_eq!(idx.rdeps.get("c2"), Some(&vec!["c1".to_string()]));
        // Neither is dangling: each target exists as a node.
        assert!(idx.dangling.is_empty());
    }

    #[test]
    fn self_target_is_a_cycle() {
        // R -> R counts as a cycle.
        let doc = doc_with_layer(vec![reference("self", "self")]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.cycles, vec!["self".to_string()]);
        assert_eq!(idx.rdeps.get("self"), Some(&vec!["self".to_string()]));
        assert!(idx.dangling.is_empty());
    }

    #[test]
    fn three_cycle_collects_all_members() {
        // x -> y -> z -> x.
        let doc = doc_with_layer(vec![
            reference("x", "y"),
            reference("y", "z"),
            reference("z", "x"),
        ]);
        let idx = dependency_index(&doc);
        assert_eq!(
            idx.cycles,
            vec!["x".to_string(), "y".to_string(), "z".to_string()]
        );
    }

    #[test]
    fn node_off_a_cycle_is_not_reported() {
        // tail -> c1, and c1 <-> c2 is a 2-cycle. `tail` reaches the cycle but
        // is not itself on it, so it must NOT be in `cycles`.
        let doc = doc_with_layer(vec![
            reference("tail", "c1"),
            reference("c1", "c2"),
            reference("c2", "c1"),
        ]);
        let idx = dependency_index(&doc);
        assert_eq!(idx.cycles, vec!["c1".to_string(), "c2".to_string()]);
        assert!(!idx.cycles.contains(&"tail".to_string()));
    }

    #[test]
    fn compound_operand_id_is_opaque() {
        // A CompoundShape with one operand carrying id="op1". The walk does NOT
        // recurse into operands, so op1 is NOT targetable. A reference r4->op1
        // must therefore come out DANGLING, and op1 gets NO rdeps entry. This
        // pins the operands-opaque decision.
        let op1 = rect_with_id(Some("op1"));
        let op2 = rect_with_id(None);
        let compound = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![op1, op2],
            fill: None,
            stroke: None,
            common: CommonProps {
                id: Some("cs".to_string()),
                ..Default::default()
            },
        })));
        let doc = doc_with_layer(vec![compound, reference("r4", "op1")]);
        let idx = dependency_index(&doc);

        // The compound contributes no out-edge (dependencies() == []), so it is
        // not in `deps`; op1 is invisible to the index entirely.
        assert!(!idx.deps.contains_key("cs"));
        assert!(!idx.deps.contains_key("op1"));
        // r4's edge to op1 is dangling because op1 is operand-nested/opaque.
        assert_eq!(idx.deps.get("r4"), Some(&vec!["op1".to_string()]));
        assert_eq!(idx.dangling, vec!["r4".to_string()]);
        assert!(
            idx.rdeps.get("op1").is_none(),
            "op1 is not targetable -> no rdeps entry"
        );
        // The compound IS targetable (top-level layer child) but unreferenced,
        // so it has no rdeps entry either.
        assert!(idx.rdeps.get("cs").is_none());
    }

    #[test]
    fn group_children_are_walked_but_operands_are_not() {
        use crate::geometry::element::GroupElem;
        // A group nesting a reference proves the walk recurses into Group/Layer.
        let inner_ref = reference("g_ref", "a");
        let group = Rc::new(Element::Group(GroupElem {
            children: vec![inner_ref],
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        }));
        let doc = doc_with_layer(vec![rect_with_id(Some("a")), group]);
        let idx = dependency_index(&doc);
        // The reference nested inside the group is discovered.
        assert_eq!(idx.deps.get("g_ref"), Some(&vec!["a".to_string()]));
        assert_eq!(idx.rdeps.get("a"), Some(&vec!["g_ref".to_string()]));
    }

    // -----------------------------------------------------------------------
    // orphaned_references predicate (reference-aware delete core)
    // -----------------------------------------------------------------------

    #[test]
    fn orphaned_target_with_two_refs_returns_both() {
        // a <- r1, r2. Deleting `a` (at [0,0]) orphans both r1 and r2.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        assert_eq!(
            orphaned_references(&doc, &[vec![0, 0]]),
            vec!["r1".to_string(), "r2".to_string()]
        );
    }

    #[test]
    fn orphaned_target_plus_one_ref_returns_the_other() {
        // Deleting `a` AND r1 ([0,0]+[0,1]) leaves only r2 orphaned; r1 is
        // itself deleted, so it is not orphaned.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        assert_eq!(
            orphaned_references(&doc, &[vec![0, 0], vec![0, 1]]),
            vec!["r2".to_string()]
        );
    }

    #[test]
    fn orphaned_non_referenced_element_returns_empty() {
        // `lonely` has no referrers; deleting it orphans nothing.
        let doc = doc_with_layer(vec![rect_with_id(Some("lonely")), rect_with_id(Some("other"))]);
        assert!(orphaned_references(&doc, &[vec![0, 0]]).is_empty());
    }

    #[test]
    fn orphaned_deleting_an_instance_returns_empty() {
        // Deleting a reference (an instance) orphans nothing: an instance has
        // no rdeps (nothing points AT it).
        let doc = doc_with_layer(vec![rect_with_id(Some("a")), reference("r1", "a")]);
        assert!(orphaned_references(&doc, &[vec![0, 1]]).is_empty());
    }

    #[test]
    fn orphaned_group_containing_referenced_element() {
        use crate::geometry::element::GroupElem;
        // A group at [0,1] contains the referenced rect `a`; an external
        // reference r1 -> a sits outside the group. Deleting the group orphans
        // r1 (its target `a` vanishes with the group).
        let group = Rc::new(Element::Group(GroupElem {
            children: vec![rect_with_id(Some("a"))],
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        }));
        let doc = doc_with_layer(vec![reference("r1", "a"), group]);
        assert_eq!(
            orphaned_references(&doc, &[vec![0, 1]]),
            vec!["r1".to_string()]
        );
    }

    #[test]
    fn orphaned_compound_operand_target_is_not_orphaned_by_delete() {
        // op1 lives only inside a CompoundShape operand (operand-opaque), so it
        // is never a targetable node and r4 -> op1 is already dangling, not
        // orphaned-by-this-delete. Deleting the compound `cs` (no rdeps of its
        // own) therefore orphans nothing.
        let op1 = rect_with_id(Some("op1"));
        let op2 = rect_with_id(None);
        let compound = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![op1, op2],
            fill: None,
            stroke: None,
            common: CommonProps {
                id: Some("cs".to_string()),
                ..Default::default()
            },
        })));
        let doc = doc_with_layer(vec![compound, reference("r4", "op1")]);
        assert!(orphaned_references(&doc, &[vec![0, 0]]).is_empty());
    }

    #[test]
    fn orphaned_invalid_path_is_skipped() {
        // An out-of-range path resolves to no element and is skipped; the valid
        // path still produces its orphans.
        let doc = doc_with_layer(vec![rect_with_id(Some("a")), reference("r1", "a")]);
        assert_eq!(
            orphaned_references(&doc, &[vec![0, 99], vec![0, 0]]),
            vec!["r1".to_string()]
        );
    }

    // -----------------------------------------------------------------------
    // Reference-aware delete CONFIRM gate (warn-then-orphan)
    //
    // The delete handlers (menu_bar.rs "delete" arm; keyboard.rs
    // Delete/Backspace) branch on `orphaned_references(...).is_empty()`:
    //   empty     -> delete inline, no dialog
    //   non-empty -> open the confirm dialog with N = orphaned.len()
    // The dialog UI is not unit-testable, but the gate predicate and the
    // count N that drives the dialog param ARE. These two tests pin that
    // decision so a regression in the gate is caught here.
    // -----------------------------------------------------------------------

    #[test]
    fn delete_gate_empty_orphans_means_delete_inline() {
        // `lonely` has no referrers -> deleting it orphans nothing -> the
        // handler takes the inline-delete branch (no dialog).
        let doc = doc_with_layer(vec![rect_with_id(Some("lonely"))]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert!(
            orphaned.is_empty(),
            "no orphans -> handler deletes inline, no confirm dialog"
        );
    }

    #[test]
    fn delete_gate_nonempty_orphans_means_confirm_with_count() {
        // a <- r1, r2. Deleting `a` would orphan both -> the handler takes
        // the confirm-dialog branch. N (the dialog `count` param) is the
        // orphan count, here 2.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert!(
            !orphaned.is_empty(),
            "orphans exist -> handler opens the confirm dialog"
        );
        assert_eq!(
            orphaned.len(),
            2,
            "N passed as the dialog count param equals the orphan count"
        );
    }

    #[test]
    fn delete_gate_single_orphan_count_is_one() {
        // a <- r1 only. Deleting `a` orphans exactly one referrer; N == 1
        // drives the dialog's singular wording ("instance", not
        // "instances").
        let doc = doc_with_layer(vec![rect_with_id(Some("a")), reference("r1", "a")]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert_eq!(orphaned.len(), 1, "single orphan -> N == 1 (singular wording)");
    }

    // -----------------------------------------------------------------------
    // Reference-aware CUT gate (warn-then-orphan). Cut is copy-to-clipboard
    // plus delete the selection, so it can orphan live instances exactly like
    // delete. The cut handlers (menu_bar.rs "cut" arm; keyboard.rs Cmd/Ctrl+X)
    // use the SAME orphaned_references(...) predicate over the current
    // selection, branching identically:
    //   empty     -> cut inline (copy + snapshot + delete), no dialog
    //   non-empty -> open cut_orphan_confirm with N = orphaned.len()
    // The dialog UI is not unit-testable, but the shared gate predicate and
    // the count N that drives the dialog param ARE. These tests pin that the
    // cut gate behaves identically to the delete gate over the same selection.
    // -----------------------------------------------------------------------

    #[test]
    fn cut_gate_empty_orphans_means_cut_inline() {
        // `lonely` has no referrers -> cutting it orphans nothing -> the cut
        // handler takes the inline-cut branch (copy + delete, no dialog).
        let doc = doc_with_layer(vec![rect_with_id(Some("lonely"))]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert!(
            orphaned.is_empty(),
            "no orphans -> cut handler cuts inline, no confirm dialog"
        );
    }

    #[test]
    fn cut_gate_nonempty_orphans_means_confirm_with_count() {
        // a <- r1, r2. Cutting `a` would orphan both -> the cut handler takes
        // the confirm-dialog branch. N (the dialog `count` param) is the
        // orphan count, here 2. Identical to the delete gate over the same
        // selection, since cut reuses the same predicate.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert!(
            !orphaned.is_empty(),
            "orphans exist -> cut handler opens the confirm dialog"
        );
        assert_eq!(
            orphaned.len(),
            2,
            "N passed as the cut dialog count param equals the orphan count"
        );
    }

    #[test]
    fn cut_gate_single_orphan_count_is_one() {
        // a <- r1 only. Cutting `a` orphans exactly one referrer; N == 1
        // drives the cut dialog's singular wording ("instance", not
        // "instances").
        let doc = doc_with_layer(vec![rect_with_id(Some("a")), reference("r1", "a")]);
        let orphaned = orphaned_references(&doc, &[vec![0, 0]]);
        assert_eq!(orphaned.len(), 1, "single orphan -> N == 1 (singular wording)");
    }

    // -----------------------------------------------------------------------
    // Reference-aware LAYERS-PANEL delete gate (warn-then-orphan). Deleting
    // elements from the Layers panel can orphan live instances exactly like
    // the primary delete, so the panel delete (context-menu "Delete Selection"
    // item AND the in-panel Delete/Backspace key) is gated by the native
    // intercept in dispatch_action with the SAME orphaned_references(...)
    // predicate — but over the PANEL selection paths (st.layers_panel_selection)
    // rather than doc.selection:
    //   empty     -> run delete_layer_selection inline, no dialog
    //   non-empty -> open delete_layer_orphan_confirm with N = orphaned.len()
    // The intercept/dialog UI is not unit-testable, but the gate predicate and
    // the count N over a panel-style selection ARE. These pin that the panel
    // delete gate behaves identically to the main delete gate over the same
    // set of paths (the predicate is selection-source-agnostic — it operates
    // on whatever deletion_paths it is given).
    // -----------------------------------------------------------------------

    #[test]
    fn layer_panel_delete_gate_empty_orphans_means_delete_inline() {
        // `lonely` has no referrers -> deleting it from the panel orphans
        // nothing -> the intercept falls through to delete_layer_selection
        // (no dialog). deletion_paths here is the panel selection.
        let doc = doc_with_layer(vec![rect_with_id(Some("lonely"))]);
        let panel_selection = vec![vec![0, 0]];
        let orphaned = orphaned_references(&doc, &panel_selection);
        assert!(
            orphaned.is_empty(),
            "no orphans -> panel delete runs inline, no confirm dialog"
        );
    }

    #[test]
    fn layer_panel_delete_gate_nonempty_orphans_means_confirm_with_count() {
        // a <- r1, r2. Deleting `a` from the panel would orphan both -> the
        // intercept opens delete_layer_orphan_confirm. N (the dialog `count`
        // param) is the orphan count, here 2. Identical to the main delete
        // gate over the same paths, since both use the same predicate.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r1", "a"),
            reference("r2", "a"),
        ]);
        let panel_selection = vec![vec![0, 0]];
        let orphaned = orphaned_references(&doc, &panel_selection);
        assert!(
            !orphaned.is_empty(),
            "orphans exist -> panel delete opens the confirm dialog"
        );
        assert_eq!(
            orphaned.len(),
            2,
            "N passed as the panel-delete dialog count param equals the orphan count"
        );
    }

    #[test]
    fn layer_panel_delete_gate_multi_path_selection() {
        // Panel selections are multi-path (Vec<Vec<usize>>), unlike the single
        // path the other gate tests use. a <- r1; b <- r2. A panel selection of
        // both targets [a, b] would orphan both referrers; neither r1 nor r2 is
        // itself in the selection, so both are counted. N == 2.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            rect_with_id(Some("b")),
            reference("r1", "a"),
            reference("r2", "b"),
        ]);
        let panel_selection = vec![vec![0, 0], vec![0, 1]];
        let orphaned = orphaned_references(&doc, &panel_selection);
        assert_eq!(
            orphaned.len(),
            2,
            "multi-path panel selection orphans both referrers -> N == 2"
        );
    }

    #[test]
    fn canonical_json_has_sorted_keys_and_arrays() {
        // c1<->c2 cycle plus two refs to `a` and a dangling ref.
        let doc = doc_with_layer(vec![
            rect_with_id(Some("a")),
            reference("r2", "a"),
            reference("r1", "a"),
            reference("r3", "ghost"),
            reference("c1", "c2"),
            reference("c2", "c1"),
        ]);
        let idx = dependency_index(&doc);
        let json = dependency_index_to_test_json(&idx);
        // Top-level keys are alphabetical: cycles, dangling, deps, rdeps.
        assert!(json.starts_with("{\"cycles\":[\"c1\",\"c2\"],\"dangling\":[\"r3\"],"));
        // deps object keys sorted; rdeps value list sorted (r1 before r2).
        assert!(json.contains("\"a\":[\"r1\",\"r2\"]"));
        assert!(json.contains("\"r1\":[\"a\"]"));
        // Parse back as generic JSON to confirm well-formedness.
        let _v: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
    }
}
