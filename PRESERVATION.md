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
| Vectors | `test_fixtures/preservation/preservation_invariants.json` (an OBJECT: `min_vectors` + `vectors`) |
| Setup documents, SVG | `test_fixtures/svg/preservation_nested_attrs.svg`, `preservation_blob_attrs.svg`, `preservation_compound_operand_ids.svg` |
| Setup document, test JSON | `test_fixtures/expected/preservation_saturated_bystanders.json` |
| Rust gate | `jas_dioxus/src/cross_language_test.rs` — `preservation_invariants`, `preservation_pin_inversion` |
| Swift gate | `JasSwift/Tests/CrossLanguageTests.swift` — `preservationInvariants`, `preservationPinInversion` |
| Data/anti-vacuity gate | `scripts/check_preservation_corpus.py` (+ `--self-test`) (CI: workspace-json-fresh lane) |
| Family registration + FLOOR | `scripts/corpus_manifest.json` → `test_fixtures/preservation`; `VECTOR_FLOOR_FAMILIES` in `scripts/check_corpus_manifest.py` |

Both port gates run the vectors through the production `op_apply` dispatcher —
the same path the operations corpus uses — so nothing here is a test-only
mutation route.

### 1.1 The two setup doors

A vector declares exactly ONE of `setup_svg` or `setup_test_json`.

`setup_test_json` exists because the SVG codec has **no counterpart** for a
mask, a blend mode or a stroke alignment, and neither port writes a `jas:`
extension for the two gradients, the stroke brush or the width profile (the
`svg` column of `test_fixtures/expected/codec_field_survival.json`).
`preservation_nested_attrs.svg` says so in its own header. A corpus whose only
door is SVG therefore **cannot place a mask or a blend mode on a bystander** —
which is exactly the class T4 exists to watch. The canonical test JSON carries
all of them (§7), so it is the door that can express the setup the law needs.
Pairing `setup_test_json` with `events` is refused: the gesture runner takes SVG
text and would silently run against the wrong document.

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

**The inversion has its own self-test, because the corpus exercises it zero
times.** Measured on this commit: all 13 shipped vectors declare
`expected_violations: {"rust": [], "swift": []}`, so the "PINNED … but now
HOLDS" arm never runs on a green build. `preservation_pin_inversion` /
`preservationPinInversion` drive the fold directly over a five-cell truth table
(unpinned+violated, pinned+violated, pinned+holds, unpinned+holds, and a pin on
a *different* invariant not suppressing this one). Mutation-proved: deleting the
inversion arm reds **only** that test — `2756 passed; 1 failed` in Rust, 2 issues
inside one Swift test — everything else, the corpus gate included, stays green.
That number is the finding: before the self-test, deleting the mechanism cost
nothing anywhere in either suite.

## 4. Anti-vacuity

The campaign's standing finding is that a family can be registered, green, and
gating nothing (`scripts/corpus_manifest.json`'s own `_coverage_gaps_doc` makes
the same point about `known_gaps` sitting at `[]` while eight real gaps went
unrecorded). Guards, split between the data gate and the runtime gates:

- **V1** every id a vector names exists in the setup (data)
- **V2** at least one **container** bystander exists, or T4 is unwatchable (data)
- **V3** the ops include a non-selection verb, so the document actually changes (data)
- **V4** a one-to-one subject declares a non-empty `speaks_to` (data)
- **V5** every pin names a known invariant and states site + reason (data)
- **V7** every `bystander_fields_present` row names an id the setup defines and
  the vector does **not** name — a subject is not a bystander (data)
- runtime: the edit must change the document byte-wise; every named id must
  exist in the **loaded** document; at least one bystander must remain
- runtime: every `must_change` key really is rewritten, and every
  `bystander_fields_present` field really is carried by the **loaded** setup

### 4.1 The FLOOR — added 2026-07-28, after the hole was measured

Every guard above is a guard *on a vector*, so a corpus with **no** vectors
satisfied all of them vacuously. Measured on the base commit with the file
rewritten to `[]`:

```
scripts/check_preservation_corpus.py   ->  "OK (0 vectors, 1 file(s))"  rc=0
scripts/check_corpus_manifest.py       ->  rc=0   (the DIRECTORY is non-empty)
cargo test --lib preservation_invariants   ->  ok, 1 passed, 0.00s
swift test --filter preservationInvariants ->  passed, 0.001s
```

Four gates over the law, all green over zero vectors. Deleting the file or the
directory was caught; **emptying it was not.** So the corpus file declares
`min_vectors` in its own header and all four readers refuse a file carrying
fewer. The count is a fact the corpus states about itself rather than a magic
number in four places, and lowering it is a visible edit to the header instead
of an invisible deletion of data. The bare-array form is REFUSED rather than
tolerated — a tolerant reader would accept `[]` again.

Both script gates carry a `--self-test` that pins the floor's red over synthetic
corpora (empty array, below-floor, zero floor, no floor) **and** asserts the
shipped corpus passes, so neither ships a rule the real data violates.

### 4.2 `bystander_fields_present` — anti-vacuity for the setup

`bystanders_unchanged` compares *before* against *after*, so a setup that lost
its mask **on the way in** would compare two identical mask-less snapshots and
pass, green and vacuous — the document-level twin of the failure §3.1 of the
freeze guards against per-battery. Naming a field under
`bystander_fields_present` asserts the BEFORE snapshot really carries it. A
dotted name `a.b` means "top-level key `a` exists and its canonical JSON value
contains the key `b`", which is what reaches the four stroke fields. Both ports
implement the identical rule.

## 5. What the gate sees today — measured

Green means the gate holds the clause in that port; **PINNED** means the gate
reproduces a real violation and holds it pinned.

> **The PINNED cells below describe an earlier state of the corpus.** Counted on
> this commit: 13 vectors, **0** of them carrying a non-empty
> `expected_violations` for either port. The rows are kept as the record of what
> this gate found when those sites were open; the repairs they drove are why the
> pins are gone. §3's self-test is what keeps the mechanism alive now that no
> data exercises it.

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

Why the containers had to be new: when this sentence was first written, of the
47 SVGs then in `test_fixtures/svg/`, exactly one other carried a `<g>` with an
`id` (`live_compound_id.svg`, a compound-shape live element). No pre-existing
setup gave a Layer or Group an identity, which is why the `withChildren` class
had never been seen. **Re-counted on this commit** (comments stripped first, so
only real markup is counted): the directory now holds 53 SVGs and 5 of them
carry a `<g>` with an `id` — the two above plus `nested_containers.svg` (added
after this paragraph by the BYSTANDER round), and the two added by DEDUPEIDS,
`dup_id_compound_operand.svg` and `preservation_compound_operand_ids.svg`. The
original count was correct when written and has since gone stale; the
conclusion it supports is unchanged.

### 5.1 The serialization boundary — `id_uniqueness` before the edit even runs

`compound_operand_dup_id_is_deduped_on_import` is the family's first vector
whose subject is what the **reader** hands the edit, not what the edit does. A
serialization boundary that fails to establish an invariant is the same defect
class as an edit that breaks one: the round trip speaks to nothing, so it must
preserve — and re-establish — everything.

Its setup SVG is ill-formed on purpose: a live compound shape's OPERAND repeats
the id of an earlier tree child. `dedupe_element_ids` / `dedupeElementIds` are
supposed to normalize that away on import, but both walked group/layer children
only, so the duplicate rode through and the loaded document violated
REFERENCE_GRAPH.md §2.5. The vector's edit is a deliberately trivial 1:1 move of
a bystander rect; because `id_uniqueness` is evaluated on the POST-edit
document, an import-time duplicate is carried straight through to it.

Measured, both ports, by reverting the DEDUPEIDS fix one port at a time:

```
[compound_operand_dup_id_is_deduped_on_import] id_uniqueness VIOLATED:
    id(s) appear more than once after the edit: ["r_dup"]
```

Green in both ports with the fix in place. This is a SECOND, independent gate on
that fix — the first is the parse golden `expected/dup_id_compound_operand.json`
— and the two watch different things: the golden pins the exact normalized
document, this one pins the document-wide predicate.

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

## 7. The codec ceiling — what the gate could not see until 2026-07-28

`bystanders_unchanged` and `subject_fields_only` range over exactly the keys the
canonical test JSON emits. Anything the codec drops is invisible to the law **by
construction** — not a gap in the corpus, a gap in the oracle.

Measured, and it is the `test_json` column of
`test_fixtures/expected/codec_field_survival.json`: **twelve** element fields
were DROPPED — `common.mask`, `common.mode`, `common.tool_origin`,
`fill_gradient`, `stroke.align`, `stroke.dash_align_anchors`,
`stroke.dash_pattern`, `stroke.miter_limit`, `stroke_brush`,
`stroke_brush_overrides`, `stroke_gradient`, `width_points`. The reader was the
other half: `parse_stroke` built every `Stroke` with `miter_limit: 10.0`,
`align: Center` and an all-zero dash array, and `parse_common` wrote
`mask: None` and the default blend mode. So an edit that destroyed a
**bystander's** mask, blend mode, dash pattern, stroke brush, width profile or
either gradient produced byte-identical canonical JSON, and this gate stayed
green.

All twelve are now carried, writer and reader, in both ports
(`extended_element_fields` / `extendedElementFields`), emitted conditionally on
being non-default so an element carrying none of them serializes
byte-identically to before. Mutation-proved 24 of 24: each writer emission
reverted individually in each port turned its own matrix cell PRESERVED →
DROPPED with zero collateral cells.

`move_nested_rect_keeps_a_masked_group_and_a_saturated_path` is the vector that
uses the new reach. Two mutation results worth keeping, because they are the
class this gate exists for:

```
# Swift, the historic bug verbatim — the edit-path container rebuild
# (Document.swift) clears the group's mask:
bystanders_unchanged VIOLATED: grp_masked.mask: {"clip":true,"disabled":false,
  "invert":true,"linked":false,"subtree":{…"id":"msk_rect"…},
  "unlink_transform":{…}} -> <absent>

# Either port — a container rebuild that hand-restates a sibling's stroke:
bystanders_unchanged VIOLATED: p_dashed.stroke: {"align":"inside",…,
  "dash_align_anchors":true,"dash_pattern":[3,1.5,6,0.75],…} -> (a bare stroke)
```

Each reds **one** vector: the twelve older ones cannot see either, because their
SVG setups cannot hold the fields.

**Still outside the ceiling, banked and named:** the five arrowhead fields
(`start_arrow`, `end_arrow`, both scales, `arrow_align`) are the same shape of
blindness and are absent from the matrix's own `fields` list, so nothing
measures them in **any** codec. Unblock is one edit: add the five rows to
`codec_field_survival.json`, let the gate measure all three codecs, and close
whichever then read DROPPED.
