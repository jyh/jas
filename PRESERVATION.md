# PRESERVATION — the document-level invariant gate

The enforcement machinery for the preservation law
(`transcripts/EDIT_SEMANTICS_FREEZE.md`, ratified 2026-07-27):

> **An edit changes what it speaks to and preserves the rest; what it cannot
> preserve, it must not guess.**

The freeze's §4 makes the DOCUMENT-LEVEL INVARIANT GATE the primary
enforcement tier, and says plainly why: the gravest violation in either port is
an *inline container rebuild*, which is not a copy API, so no per-copy-API
battery would ever have been written for it. This family inspects no copy site.
It serializes the **whole document** before and after an edit and asserts
invariants over the canonical cross-language test JSON.

JYH's ratification condition: *the law is not reported ENFORCED until the
corpus can see it.* This file describes what the corpus can see today, and
says where it still cannot.

---

## 1. The pieces

| Piece | Path |
|---|---|
| Vectors | `test_fixtures/preservation/preservation_invariants.json` |
| Setup document | `test_fixtures/svg/preservation_nested_attrs.svg` |
| Rust gate | `jas_dioxus/src/cross_language_test.rs` — `preservation_invariants` |
| Swift gate | `JasSwift/Tests/CrossLanguageTests.swift` — `preservationInvariants` |
| Data/anti-vacuity gate | `scripts/check_preservation_corpus.py` (CI: workspace-json-fresh lane) |
| Family registration | `scripts/corpus_manifest.json` → `test_fixtures/preservation` |

Both port gates run the vectors through the production `op_apply` dispatcher —
the same path the operations corpus uses — so nothing here is a test-only
mutation route.

## 2. The six invariants

Evaluated per vector, over the parsed canonical document JSON. Element
attributes are compared with the `children` key stripped, so a container that
legitimately gained or lost a child still has **its own** fields diffed.

| Name | Says | Clause |
|---|---|---|
| `id_uniqueness` | no id appears twice after the edit | REFERENCE_GRAPH.md §2.5 |
| `id_survival` | every id present before, and not consumed, is present after | §3.1 + T4 |
| `consumed_ids_die` | no consumed id rides out on the result | §3.3 (over-preservation is a violation) |
| `fresh_ids` | the edit minted exactly the declared number of new ids | T2.1 / §3.2 / §3.3 |
| `bystanders_unchanged` | every id-bearing non-subject element, **containers included**, is byte-identical | T4 |
| `subject_fields_only` | only the `speaks_to` keys of a subject may differ | T1 / §3.1 |

## 3. Pinning a known violation

A vector may pin a violation per port under `expected_violations`. A pinned
invariant is asserted to **FAIL**. Fixing the site turns the gate red with

```
[<vector>] <invariant> is PINNED as a known violation (<row>) but now HOLDS
           — remove the pin from the vector
```

so a pin can never rot into a silent suppression. Every pin must name a known
invariant and state both its site (`row`) and why (`note`) — enforced by
`check_preservation_corpus.py` (V5).

## 4. Anti-vacuity

The campaign's standing finding is that a family can be registered, green, and
gating nothing (`scripts/corpus_manifest.json`'s own `_coverage_gaps_doc` makes
the same point about `known_gaps` sitting at `[]` while eight real gaps went
unrecorded). Guards, split between the data gate and the runtime gates:

- **V1** every id a vector names exists in the setup SVG (data)
- **V2** at least one **container** bystander exists, or T4 is unwatchable (data)
- **V3** the ops include a non-selection verb, so the document actually changes (data)
- **V4** a one-to-one subject declares a non-empty `speaks_to` (data)
- **V5** every pin names a known invariant and states site + reason (data)
- runtime: the edit must change the document byte-wise; every named id must
  exist in the **loaded** document; at least one bystander must remain

## 5. What the gate sees today — measured

Green means the gate holds the clause in that port; **PINNED** means the gate
reproduces a real violation and holds it pinned.

| §3.5 row | Rust | Swift |
|---|---|---|
| `apply_destructive_boolean` UNION arm carries the frontmost's id | **PINNED** (`consumed_ids_die`) | n/a — Swift carries no id at all |
| UNION mints no fresh id (§3.6 UNION row) | **PINNED** (`fresh_ids`) | **PINNED** (`fresh_ids`) |
| Swift `Document` private `withChildren` | green | **PINNED** (`id_survival`, 4 vectors) |
| Swift inline `Layer(`/`Group(` literals | green | **PINNED** — one site: `applyDestructiveBoolean`'s insert-site `Layer(name:children:opacity:transform:)` |

Two findings this gate produced that no golden in the corpus could:

1. **Every edit in the Swift port destroys the containing layer's identity.**
   All five vectors fail `id_survival` on `lyr_main`; nested ones also lose
   `grp_inner`. The identical Rust gate is green on all five.
2. **A live cross-port divergence on the same N→1 union**: Rust carries the
   frontmost operand's id, Swift carries none. Both boolean fixtures in the
   operations corpus (`boolean_ops.json` → `overlapping_rects.svg`,
   `boolean_collapse_default.json` → `boolean_collinear_union.svg`) run on
   setups whose elements carry no `id` at all, so the two ports produce
   byte-identical goldens and "agree" there. (Counted on this commit: 9 of the
   18 setup SVGs the operations corpus uses DO carry element ids — the gap is
   specific to the boolean fixtures, not general.)

Why the containers had to be new: of the 47 SVGs in `test_fixtures/svg/`,
exactly one other carries a `<g>` with an `id` (`live_compound_id.svg`, a
compound-shape live element). No pre-existing setup gave a Layer or Group an
identity, which is why the `withChildren` class had never been seen.

The Swift boolean's two causes were separated by *isolating mutation*, not by
reading: with `withChildren` temporarily made field-preserving, four of the
five `id_survival` pins go stale but the boolean vector still loses `lyr_main`
— so its inline `Layer(` literal is an independent second site.

**A consequence worth stating plainly:** `bystanders_unchanged` matches
bystanders by id, so while a Swift container's id is being destroyed, that
container is invisible to the bystander predicate. The clause is **masked for
Swift containers** until the `withChildren` row is fixed. The pins say so.

## 6. What the gate does NOT see

Recorded as machine-checked rows in `scripts/corpus_manifest.json`
(`coverage_gaps`), printed on every run of the manifest gate:

- **`preservation-op-vocabulary-only`** — the gate reaches only what `op_apply`
  can express. There is exactly one boolean verb (`boolean_union`) and no verb
  for mask, width points, compound-shape make, or a partial (control-point)
  selection, so §3.5's `withMask`, `withWidthPoints`, `move_control_points`
  Rect→Polygon, `make_compound_shape_with_op`, the boolean survivor arms, and
  both blob-brush `fillRule` arms are unreachable from here.
- **`preservation-minted-element-fields`** — every invariant is keyed on an id
  that existed *before* the edit, so a freshly minted element has no
  before-image and nothing constrains its fields. The single-ring `Polygon`
  demotion and the boolean result's dropped non-paint fields are invisible.

Each row states its own re-runnable evidence and its unblock.
