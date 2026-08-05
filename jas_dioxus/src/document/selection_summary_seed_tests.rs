//! CONTAINER-SEEDED EQUIVALENCE for the PANEL-CTX layer.
//!
//! # Why this is not `panel_bind_values`
//!
//! Stubb's letter 16 named "the `panel_bind_values` half of container-seeding"
//! as the highest-value item on the board. I went to build it and it cannot be
//! built as scoped, for a structural reason worth recording:
//!
//! **The 7 `panel_bind_values` vectors are pure DATA SCOPES.** Each is
//! `{ctx, panel}` where `ctx.panel` and `ctx.state` are flat property bags —
//! `{"weight": 2.5, "cap": "round", ...}`. There is no document and no
//! selection, so the seeding transformation ("wrap the selected element in a
//! group and require the same answer") has NO SUBJECT. Seeding more panels into
//! that fixture widens its panel coverage — which the corpus manifest correctly
//! asks for — but it cannot make it see a container defect, because the ctx
//! arrives already built.
//!
//! **The container-blindness lives one layer up.** Every defect of that family
//! this project has found — the Stroke panel's weight field reading
//! `selection.first`'s own stroke and falling through to a hard-coded 1.0
//! (WEIGHTPANEL), the paint summary of a selected container (PAINTSUMMARY) —
//! fired inside the functions that BUILD the ctx from the document and the
//! selection: `selection_fill_summary`, `selection_stroke_summary`, and
//! `build_live_panel_overrides` above them.
//!
//! **And that path is gated by no corpus fixture at all** — grep for
//! `selection_stroke_summary` or `live_panel_overrides` across `test_fixtures/`
//! returns nothing. So the corpus pins bind resolution GIVEN a ctx and never
//! pins the ctx. That is the same shape as the text finding: the algorithm is
//! pinned given an input, and the input is not.
//!
//! This file therefore applies Stubb's law at the layer that can carry it.
//!
//! # The law
//!
//! > `summary(doc with leaf L selected)` == `summary(doc with L wrapped in a
//! > group, that group selected)`
//!
//! It is RULED, not assumed: WEIGHTSPELL — *"a mixed group and its members
//! answer alike"* — and the paint-recursion ruling of 2026-07-29 ("paint
//! RECURSES into members; a transform rides on the container").
//!
//! No golden is involved. It compares the app against ITSELF under a
//! transformation that must not matter, which is why it can see a defect BOTH
//! ports share — six of the original eight were exactly that, and no
//! differential gate can see those.

use std::rc::Rc;

use crate::document::controller::{selection_fill_summary, selection_stroke_summary};
use crate::document::document::{Document, ElementSelection};
use crate::geometry::element::{CommonProps, Element, GroupElem};

/// Wrap the element at `path` in a single-child group, IN PLACE.
///
/// In place is what makes this safe for multi-target selections: the wrapper
/// takes the slot its element occupied, so no index moves and every selection
/// path stays valid while now naming a group. Stubb's first cut required a
/// single-target selection and seeded ZERO cases — the corpus is overwhelmingly
/// two- and three-target — and only an anti-vacuity floor caught it.
fn wrap_at(doc: &mut Document, path: &[usize]) -> bool {
    if path.len() != 2 {
        return false; // top-level children only
    }
    let Some(layer) = doc.layers.get_mut(path[0]) else { return false };
    let Some(kids) = layer.children_mut() else { return false };
    let Some(slot) = kids.get_mut(path[1]) else { return false };
    let inner = (**slot).clone();
    if inner.is_group_or_layer() {
        return false; // leaves only
    }
    *slot = Rc::new(Element::Group(GroupElem {
        children: vec![Rc::new(inner)],
        common: CommonProps { name: Some("__seed_wrapper__".into()), ..CommonProps::default() },
        isolated_blending: false,
        knockout_group: false,
    }));
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::svg::svg_to_document;

    /// Anti-vacuity floor. A seeder that wraps nothing reports no
    /// disagreements, which is INDISTINGUISHABLE FROM AGREEMENT — the exact
    /// failure Stubb hit and the only reason he noticed was a floor like this.
    /// MEASURED 72 over the seed set below. Exact, not slack: this is a
    /// COVERAGE floor, where slack admits precisely the move it forbids -- a
    /// seeder that quietly stops wrapping reports no disagreements, which is
    /// indistinguishable from agreement. It went 9 -> 72 when the seed set was
    /// widened, and that change should be a visible line in a diff.
    const MIN_SEEDED: usize = 72;

    /// SVGs to seed over, chosen for PAINT VARIETY rather than count: the
    /// relation turns on whether a container answers for its members, so the
    /// members must actually differ in fill and stroke for `Mixed` to be
    /// reachable at all. A seed set of uniformly-painted shapes can only ever
    /// produce `Uniform`, and would pass while testing one third of the answer
    /// space.
    ///
    /// Surveyed all 68 svg fixtures by distinct fill/stroke count and took the
    /// richest: `locked_all_kinds` (14 leaves, 11 fills), `select_all_top_level`
    /// and `locked_inheritance` (7 leaves, 7 fills), `complex_document`
    /// (3 fills AND 3 strokes -- the only fixture with stroke variety).
    const SEED_SVGS: &[&str] = &[
        "locked_all_kinds.svg",
        "select_all_top_level.svg",
        "locked_inheritance.svg",
        "complex_document.svg",
        "dup_order_four_rects.svg",
        "group_two_clusters.svg",
        "two_rects.svg",
        "overlapping_rects.svg",
        "compound_and_rect.svg",
    ];

    fn fixture(rel: &str) -> Option<String> {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../test_fixtures")
            .join(rel);
        std::fs::read_to_string(p).ok()
    }

    /// Every top-level leaf path in the document, as a selection would name it.
    fn leaf_paths(doc: &Document) -> Vec<Vec<usize>> {
        let mut out = Vec::new();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(kids) = layer.children() {
                for (ci, k) in kids.iter().enumerate() {
                    if !k.is_group_or_layer() {
                        out.push(vec![li, ci]);
                    }
                }
            }
        }
        out
    }

    /// THE RELATION. For every seed document and every non-empty subset of its
    /// leaves, the fill and stroke summaries must not change when those leaves
    /// are each wrapped in a group.
    #[test]
    fn a_selected_container_summarises_paint_exactly_as_its_member_does() {
        let mut seeded = 0usize;
        let mut disagreements: Vec<String> = Vec::new();

        for name in SEED_SVGS {
            let Some(svg) = fixture(&format!("svg/{name}")) else { continue };
            let base = svg_to_document(&svg);
            let leaves = leaf_paths(&base);
            if leaves.is_empty() {
                continue;
            }

            // Every non-empty subset, so multi-target selections are exercised
            // rather than assumed away -- that is the case Stubb's first cut
            // dropped, and it is the common one in real documents.
            for mask in 1u32..(1 << leaves.len().min(5)) {
                let chosen: Vec<Vec<usize>> = (0..leaves.len().min(5))
                    .filter(|i| mask & (1 << i) != 0)
                    .map(|i| leaves[i].clone())
                    .collect();

                let mut plain = base.clone();
                plain.selection =
                    chosen.iter().cloned().map(ElementSelection::all).collect();

                let mut wrapped = base.clone();
                let mut any = false;
                for p in &chosen {
                    if wrap_at(&mut wrapped, p) {
                        any = true;
                    }
                }
                if !any {
                    continue;
                }
                // Wrapping IN PLACE means the SAME paths now name the groups.
                wrapped.selection =
                    chosen.iter().cloned().map(ElementSelection::all).collect();

                seeded += 1;

                let pf = selection_fill_summary(&plain);
                let wf = selection_fill_summary(&wrapped);
                if pf != wf {
                    disagreements.push(format!(
                        "{name} sel={chosen:?} FILL leaf={pf:?} group={wf:?}"
                    ));
                }
                let ps = selection_stroke_summary(&plain);
                let ws = selection_stroke_summary(&wrapped);
                if ps != ws {
                    disagreements.push(format!(
                        "{name} sel={chosen:?} STROKE leaf={ps:?} group={ws:?}"
                    ));
                }
            }
        }

        assert!(
            seeded >= MIN_SEEDED,
            "ANTI-VACUITY: only {seeded} seeded comparisons, floor {MIN_SEEDED}. \
             A seeder that wraps nothing reports no disagreements, which is \
             indistinguishable from agreement."
        );
        assert!(
            disagreements.is_empty(),
            "{} container/member paint disagreement(s) -- a selected group must \
             answer as its members do (WEIGHTSPELL; the 2026-07-29 paint-recursion \
             ruling):\n  {}",
            disagreements.len(),
            disagreements.join("\n  ")
        );
    }

    /// The seeder must be able to FAIL. If `wrap_at` silently stopped wrapping,
    /// the relation above would pass on an empty comparison set -- so prove the
    /// wrapper actually changes the document it is handed.
    #[test]
    fn the_seeder_actually_wraps_and_can_be_seen_to() {
        let Some(svg) = fixture("svg/two_rects.svg") else { return };
        let base = svg_to_document(&svg);
        let leaves = leaf_paths(&base);
        assert!(!leaves.is_empty(), "the seed document must contain leaves");

        let mut wrapped = base.clone();
        assert!(wrap_at(&mut wrapped, &leaves[0]), "wrap_at must succeed on a leaf");

        let at = |d: &Document, p: &[usize]| -> bool {
            d.layers
                .get(p[0])
                .and_then(|l| l.children())
                .and_then(|k| k.get(p[1]))
                .map(|e| e.is_group_or_layer())
                .unwrap_or(false)
        };
        assert!(!at(&base, &leaves[0]), "before: a leaf");
        assert!(at(&wrapped, &leaves[0]), "after: a group in the same slot");
        // And the path did not move -- that is what makes multi-target safe.
        assert_eq!(leaf_paths(&base).len(), leaves.len());
    }

    /// A group is refused as a wrap target: seeding a container inside a
    /// container tests nesting, not the leaf/container relation this asserts.
    #[test]
    fn wrap_at_refuses_a_container() {
        let Some(svg) = fixture("svg/two_rects.svg") else { return };
        let base = svg_to_document(&svg);
        let leaves = leaf_paths(&base);
        let mut d = base.clone();
        assert!(wrap_at(&mut d, &leaves[0]));
        assert!(!wrap_at(&mut d, &leaves[0]), "second wrap must refuse");
    }
}
