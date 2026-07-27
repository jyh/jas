# EDIT SEMANTICS FREEZE — what survives an edit?

**Status: PROPOSED, awaiting refuter gauntlet and JYH ratification.**
Drafted 2026-07-27 (Starbuck, design seat) per the fleet-council ruling of the
same date: the fill-rule-on-edit question, element-field preservation, and
referential integrity are ONE question and get one law. This document sits
beside — and does not reopen — THE CARDINALITY LAW (JYH, ratified 2026-07-26):

> *Identity survives a one-to-one edit. It does not survive a change in
> cardinality.*

All code citations are to this branch at commit `ff3e62aa` ("Merge
arc2-prototypes: the cardinality law, and the corpus that can see"). Line
numbers are avoided where they would rot; functions and files are named
instead. Every count in this document states the method that produced it.

---

## 1. The law

> ### THE PRESERVATION LAW
> **An edit changes what it speaks to and preserves the rest; what it cannot
> preserve, it must not guess.**

One sentence, two clauses, and the second is not decoration: the first clause
alone would compel impossible preservations (one id onto N fragments, N
disagreeing opacities into one slot, one reference across two halves), and
"do your best" at an impossible preservation is exactly the mechanical
guessing JYH rejected twice ("the largest fragment keeps the id" — refused in
both directions, because it puts a float comparison in charge of identity).
The two clauses are one law because each is the other's boundary: preserve
everything you can, and the moment preservation stops being well-defined,
stop — do not manufacture an answer from geometry.

### 1.1 Defined terms

**"Speaks to."** The fields the gesture's ratified specification names as its
subject — never inferred from what the implementation happens to touch. A
path edit speaks to `d` (transcripts/PATH_ERASER_TOOL.md §What the fragments
inherit). Attaching a mask speaks to `mask`. Setting a width profile speaks
to `widthPoints`. A boolean operation speaks to geometry *and* to the four
paint properties its spec assigns ("fill, stroke, opacity, blend mode" —
transcripts/BOOLEAN.md §Operand and paint rules), because the artist who
invokes UNION asked for that documented behaviour. The default reading is
narrow: a gesture speaks to the minimum its name states, and widening any
edit's subject is a design ruling requiring ratification, not a code change.

**"Cannot preserve."** Preservation has no single well-defined value in
exactly three shapes:
1. **Identity across a cardinality change** — one id cannot become two, two
   cannot become one (REFERENCE_GRAPH.md §2.5 uniqueness invariant). This is
   the cardinality law's territory; this law incorporates it unchanged. The
   cardinality law is the identity-projection of this law: identity is
   preservable exactly when the edit is one-to-one.
2. **A value across disagreeing sources** — N elements merging into one,
   where the sources differ on a field the edit does not speak to.
3. **A reference across a severed target** — which fragment is "the ship" is
   a statement about PURPOSE, not geometry; the information is not in the
   shape, so no rule that reads only the shape can hold it.

**"Must not guess."** In each shape respectively: the identity dies (fresh
id, minted through the shared loop); the field takes the fresh element's
documented default; the reference breaks — *loudly* (§3.6). The application
never elects a winner by size, z-order, area, or any other geometric proxy.
The forgone choice is recorded where a later chooser — the artist, or an
assistant citing the artist — can find it (§3.7).

### 1.2 The corollary the second clause earns

Unanimity is not a guess. When every source of an N→1 merge agrees on a
field, carrying that value IS preservation — well-defined, no winner elected.
So the second clause forbids exactly the disagreement case and *mandates* the
agreement case. This is the already-ratified UNANIMITY CARRY (JYH,
2026-07-26, `merge_two_blobs` region of `jas_dioxus/src/interpreter/
effects.rs` and its Swift twin in `YamlToolEffects.swift`), now derived
rather than free-standing.

---

## 2. The three questions, decided

**(a) Fill-rule-on-edit — the law AGREES with the ruling.** Dragging an
anchor speaks to `d` and nothing else; `fillRule` is preserved. The ruled
answer (JYH, 2026-07-26: preserve) is the first clause applied to one field.
No tension found. Had the law been unable to reproduce this datum it would be
the wrong law; it reproduces it as a one-line corollary.

**(b) Element-field preservation — the class is this law's first clause plus
an enforcement doctrine (§4).** "Preserve the rest" stated as a law, not a
field list, is precisely what closed the Rust path-edit sites
(`PathElem { d: new_cmds, ..pe.clone() }`) and Swift's `pathWithCommands`
(all 18 properties forwarded, Mirror-battery-pinned). The still-open sites
are decided in §3.4/§5.

**(c) Referential integrity on destructive edits — the reference breaks, and
breaks loudly.** JYH's steer ("breaking the reference probably makes more
sense, because deciding in a mechanical way will generate surprises") is the
second clause verbatim: a remap is a guess about purpose. What the steer left
open — the *silence* — this law closes: the same warn-then-orphan seam that
already guards delete (`orphaned_references` in
`jas_dioxus/src/document/dependency_index.rs`, consulted by the delete flows
in `renderer.rs`, `keyboard.rs`, `menu_bar.rs`) must guard every edit that
kills a referenced identity. §3.6.

---

## 3. The clauses

Each clause states the rule, what conformance looks like in both active
ports, and how a fixture sees a violation.

### 3.1 One-to-one edits (the Theseus clause)

**Rule.** A 1→1 edit preserves every field it does not speak to — including
`id`, `name`, `transform`, `toolOrigin`, both gradients, both brush fields,
`mask`, `visibility`, `blendMode`, `locked`, `fillRule` — stated as a law so
it cannot rot as fields are added.

**Conformance, Rust:** struct-update syntax or clone-then-mutate at every
copy site (`PathElem { d: new, ..pe.clone() }`; `elem.clone()` +
`common_mut()`). A field-enumerating struct literal at a *copy* site is a
review flag: Rust's compiler forces the enumeration to compile, and a human
answering it by hand is how five sites shipped `FillRule::NonZero` while an
audit reported the class closed.

**Conformance, Swift:** one copy helper per element kind with no defaulted
parameter for any preserved field on the *edit* path (the `pathWithCommands`
+ `PathEditIdentity` pattern in `YamlToolEffects.swift` — the identity
argument deliberately has no default, so the compiler enumerates call sites).

**Fixture:** the Mirror-driven battery
(`Tests/Tools/PathEditTheseusTests.swift`,
`Tests/Document/MovePathHandleFieldsTests.swift`) — compare every reflected
property except the spoken-to one, so a field added later is checked without
editing the test. Rust twin: whole-struct equality after grafting the
source's geometry. **Mandatory pairing (banked 2026-07-26):** every such
battery includes at least one assertion on the geometry's actual VALUE —
field-list-free tests are structurally blind to where the geometry landed,
which is how a transform-preservation round shipped over a transform-blind
merge.

### 3.2 Splits (1→N)

**Rule.** Identity dies (cardinality law). Everything else — appearance,
`transform`, AND `name` — copies to every fragment; each fragment wears a
fresh id from the shared mint loop, minted in the effect where the document
is in hand, all-or-nothing (a failed mint aborts the edit, never a
half-identified split).

**Status:** LANDED in both ports (commits `d14a9fdd` FRESHIDS, `100faf86`;
read directly in `path_erase_at_rect` and `pathEraseAtRect`).

**Fixture:** exists (the FRESHIDS gates). The extension this freeze adds:
assert `name` equality on every fragment and id *freshness* (result id ∉
pre-edit id set) — freshness, not merely presence, is the pinned property.

### 3.3 Merges (N→1)

**Rule.** Identity dies; fresh id. Every field the edit does not speak to
follows unanimity: all sources agree → the value carries; any disagreement →
the fresh element's documented default. No winner, ever.

Three decisions this clause makes beyond the landed code:

- **`name` joins the unanimity carry.** The ratified five-field list
  (`opacity`, blend mode, `visibility`, `locked`, `mask` — read in both
  ports) explains its exclusions for `transform` (S-3 containment),
  `tool_origin` (the tool speaks to it), and `id` (minted fresh) — but
  `name` is absent with no stated reason. The law closes the hole: `name` is
  not identity (JYH's 1→N ruling already copies it to fragments, so it is
  appearance-like), and two elements named "leaf" merging into "leaf" is
  preservation, not a guess. AMENDMENT for ratification, since it extends a
  ratified list.
- **`transform` joins the unanimity carry — CONDITIONAL on S-3 landing.**
  Its current exclusion is bug containment, not law: the merge pipeline
  matches raw `d` against a document-space sweep, and carrying a unanimous
  transform today would relocate the merged artwork. Once the pipeline is
  transform-correct, `transform` is an ordinary attribute and the exclusion
  becomes an unprincipled hole. The conforming order is: S-3 lands, its
  fixtures prove the pipeline transform-aware, then the carry list gains
  `transform` in both ports in one commit with a unanimous-transform fixture.
- **Unanimity ranges over every non-spoken-to field**, not the five that can
  differ in today's blob population. The implementation may exploit
  invariants (blob sources are fill-only by construction), but the fixture
  battery must probe the general rule, because tomorrow's merge sources may
  not honour today's invariants.

**Fixture:** exists for the five (`blob_merge_carries_unanimous_attributes`
+ Swift twin); extend per the amendments, plus the disagreement direction
(sources differ → default stands) and id freshness.

### 3.4 The named open field-family sites, decided

Current state, verified by reading the functions at `ff3e62aa`:

| Site | State at HEAD | Verdict under the law |
|---|---|---|
| Swift `pathWithCommands` family | CLOSED — forwards all 18 properties, identity enum, Mirror-pinned | conforming; the model for §3.1 |
| Rust `path_erase_at_rect` `CommonProps::default()` | **ALREADY FIXED** — now `..path_elem.clone()` + fresh ids on severing | conforming; brief was stale (§6) |
| Blob commit, 1-match arm, both ports | FIXED — `..src` / `pathWithCommands(src, …, .sameElement)` | conforming; BOOLEAN.md's banked note is stale (§6) |
| Swift `withMask`, `.path` arm | drops 7: `fillGradient`, `strokeGradient`, `strokeBrush`, `strokeBrushOverrides`, `toolOrigin`, `name`, `id` (enumerated against the `Path` struct's stored properties) | **VIOLATION of §3.1.** Attaching a mask speaks to `mask` alone. Fix: forward everything; Rust's twins (`make_mask_on_selection` etc., clone + `common_mut().mask`) already conform, so this is a live one-sided divergence |
| Swift `withMask`, non-path arms | only the Layer arm passes `name:`/`id:` (grep `name:\|id:` over the function body: 2 hits, both in the Layer arm); every other arm forwards neither | **VIOLATION of §3.1** for every kind carrying them |
| Swift `withWidthPoints`, `.path` arm | drops 9: the 7 above plus `blendMode`, `mask` | **VIOLATION of §3.1.** Rust's `with_width_points` is `..e.clone()` — conforms. Call sites affected: `Controller.swift:1792` (panel), `Eyedropper.swift:202` |
| Eyedropper apply | speaks to the sampled appearance family by spec — rewriting those fields is the edit's subject | conforming *in intent*; its Swift path inherits the `withWidthPoints` violation above |
| Rust `apply_destructive_boolean`, UNION/INTERSECTION/EXCLUDE arm | carries `front.common().clone()` — the frontmost operand's **id** through an N→1 op | **VIOLATION of §3.3 / the cardinality law** — this is "the frontmost source keeps the id", the rejected rule wearing `..clone()` as the hat. Over-preservation is also a violation: preserving what cannot be preserved is a guess |
| Swift boolean rebuild, non-paint fields | per transcripts/BOOLEAN.md §banked: `locked` written `false`, `name`/`id`/`toolOrigin`/`mask` dropped (transcript claim; re-verify at fix time) | **VIOLATION of §3.1** for the 1→1 arms (survivors), **of §3.3** for the N→1 arms |

### 3.5 The boolean panel, per op

The transcript banked this as "needs a decision per op". The law decides all
nine without per-op ceremony, because cardinality + speaks-to classify them:

| Op | Cardinality | id | Non-paint fields | Paint |
|---|---|---|---|---|
| UNION / INTERSECTION / EXCLUDE | N→1 | fresh mint | unanimity (§3.3) | frontmost's four, per ratified spec (the op speaks to paint) |
| SUBTRACT_FRONT / SUBTRACT_BACK survivor, CROP survivor, TRIM operand | 1→1 each | survives | full Theseus preservation (§3.1) | its own |
| consumed cutter / mask operand | 1→0 | ends (a deletion; §3.6 applies if referenced) | — | — |
| DIVIDE | each output region is a fragment of its designated frontmost-covering operand: 1→N per operand | fresh mint | copies from the designated operand, `name` included (§3.2) | designated operand's, per spec |
| MERGE | per merged group — exactly the blob brush's arms | singleton group: survives; multi: fresh mint | singleton: §3.1; multi: §3.3 unanimity | frontmost contributor's, per spec |

One flagged extension, not silently legislated: the ratified paint list is
four properties, and both ports currently drop the frontmost's
`fillGradient`/`strokeGradient` at the rebuild. A gradient is the value of a
fill; the law reads "paint" as including it. AMENDMENT for ratification,
since it widens a ratified list.

One observation for the S-3 round, stated no wider than verified:
`element_to_polygon_set_with` (`jas_dioxus/src/geometry/live.rs`) contains
zero occurrences of `transform` (grep over the function), i.e. the boolean
flattening walk reads raw geometry in every arm — while Rust's UNION output
carries the frontmost's `common` (transform included). If S-3's diagnosis
holds here too, the boolean panel is in the same transform-blind class and
the §3.3 conditional applies to it identically.

### 3.6 References: break loudly

**Rule.** When an edit kills an identity that something references
(instances, future recorded recipes), the reference BREAKS. It is never
remapped to a fragment or a merge product — that would be a purpose-guess —
and it never breaks *silently*. Concretely:

1. **The dangling doctrine stands:** a dangling reference evaluates to empty
   geometry, never a panic (REFERENCE_GRAPH.md §3; pinned in `live.rs`).
2. **The warn seam extends from delete to every identity-death edit.** Today
   `orphaned_references(doc, deletion_paths)` guards only the delete flows
   (verified: its non-test call sites are in `renderer.rs`, `keyboard.rs`,
   `menu_bar.rs`; neither `path_erase_at_rect` nor the blob merge consults
   it). Conformance: any edit whose arm is about to kill a referenced id
   runs the same predicate over the affected paths and routes through the
   same confirm dialog — one seam, not a second mechanism.
3. **No auto-repair, no reference-editing side effects.** The instances
   survive, dangling, so the artist (or the Arc-3 assistant, citing intent)
   can re-point them — "this part goes into the ship, the other part is put
   back into the scrap heap" is a decision this law reserves for someone who
   can hold a purpose.

**Fixture:** create a reference to an id, sever the target, assert (a) the
reference survives serialization and evaluates empty (pattern exists:
`create_reference_dangling`), (b) the confirm seam fires (GUI-harness check,
same recipe as the delete-warn check), (c) no element's `target` field was
rewritten by the edit.

### 3.7 Provenance: what the ledger cites when identity dies

Arc 3's critique mechanism is citation, and citation needs the thing the
artist talked about to remain *findable* after editing. Where this law
forces identity to die, the ledger still needs something to say. Decision:
**provide lineage, and provide it in the journal, not the document.**

**Rule.** Every identity-death edit (split, merge, boolean N→1 / 1→N),
wherever it journals ops, must record **predecessors → successors**: the
pre-mutation ids of the consumed elements (the existing `targets:[common.id]`
shape, OP_LOG.md Fork 4) and the minted ids of the products. Lineage is then
a derivable DAG over the journal — transitive across repeated splits and
merges — and the ledger can say *"the shape you called the hull was severed;
these two carry its planks"* without any mechanical claim about which piece
is the hull.

**Why the journal and not the model.** Identity is a fact about the document
(references bind to it); provenance is a fact about history (citations bind
to it). A successor pointer stored on elements would make geometry carry
purpose it cannot hold, would dangle when successors are themselves edited
away, and would put lineage inside the byte-gated document state where every
port must replicate it forever. The journal already carries `targets` as
additive metadata the byte-gate ignores — the exact right tier.

**Honest gap, named:** today this substrate does not exist for these verbs.
Production transactions journal named ops for three verbs only (OP_LOG.md
§3b-B), and split/merge ids are minted in-effect, not value-in-op, so replay
would re-mint. The clause binds forward: when the op-log increments reach the
identity-death verbs, predecessor/successor recording is REQUIRED from their
first version — and until then the ledger simply cannot cite across an
identity death, which is a truthful limitation, not a silent one.

### 3.8 Geometry-relative attributes: preserved, then refit

A small class of preserved attributes is *parameterized by* the geometry the
edit changed: a linear gradient resolves its ramp against the element's own
bbox (S-2's subject), and a width profile is positioned along the path. The
law's answer: the ATTRIBUTE is preserved unconditionally (§3.1 — dropping it
is never the fix); its REFIT onto the new geometry is a separate, named,
per-family ruling (S-2 for linear gradient stops — in flight; radial
recentring accepted; width-profile refit unruled and hereby named as the
same class). Preservation now, refinement as scheduled work — never
open-ended deferral (the corner-case doctrine), and never "drop it because
the refit is hard".

---

## 4. Enforcement doctrine (the one-sidedness trap, codified)

The compiler-enforced pattern is available in both ports and is REQUIRED —
and it is *insufficient alone*, in a direction proven twice:

- **Rust** struct literals already force enumeration, and a human answered
  five of them with the wrong constant while an audit reported the class
  closed. **Swift's** required-parameter trick enumerates Swift only, and "a
  required parameter satisfied with the WRONG value is the same bug wearing a
  hat."
- Therefore the GATE is never the compiler and never a hand scan. It is the
  battery: per copy API, a reflection/whole-struct comparison of every
  property except the spoken-to one (patterns exist and are named in §3.1),
  **paired with one geometry-value assertion**, in BOTH ports, plus a
  cross-language operations fixture pinning the serialized document (with the
  deterministic mint override so minted ids compare).
- When closing any omission site, enumerate BOTH ports before reporting the
  class closed — a one-sided audit left the fill-rule divergence intact and
  inverted.

---

## 5. What this law deliberately does NOT cover

1. **Creation-time identity (0→1).** No creation tool mints an element id
   today, by doctrine ("when creation-time ids land, they land for every
   tool at once" — blob-merge region comment). This law governs *edits* of
   existing elements; changing creation is a separate ruling.
2. **Sub-element identity** — anchors, tspans, per-output identity of
   multi-output live elements (LIVE_ELEMENTS.md §L6 names it the frontier).
   The law's terms are element-granular; legislating finer grain now would
   be claiming territory nobody has surveyed.
3. **Undo/redo.** History traversal restores snapshots; it is not an edit
   and preserves everything trivially.
4. **Clipboard and cross-document copies.** Copies are born id-less by the
   `clear_ids` doctrine (REFERENCE_GRAPH.md §2.5) — a copy is a creation,
   not an edit of the source.
5. **Collaboration/merge-conflict semantics.** `targets` is additive
   metadata; multi-author identity is deferred with Fork 4's collaboration
   work.
6. **Which fragment is "the ship."** Deliberately and permanently outside
   any mechanical rule — §3.6/§3.7 exist to hand that question, intact, to
   the artist or an assistant citing the artist.
7. **What the Arc-3 assistant may DO with lineage** (proposal contracts,
   citation etiquette). That is Starbuck's Arc-3 contracts block; this law
   only guarantees the substrate those contracts will need.
8. **The frozen ports and the flask renderer** (POLICY.md §1). Conformance
   is defined over `jas_dioxus`, `JasSwift`, and the corpus; frozen ports
   honour the tag.
9. **Tool gating questions** adjacent to but distinct from preservation —
   e.g. whether a LOCKED blob should be a merge candidate at all (the match
   loop does not check `locked`; unanimity would carry `locked: true`
   onward). Flagged for the tool's own spec; this law governs what carries,
   not what matches.

---

## 6. Corrections to the brief (where it was stale or imprecise)

1. **`path_erase_at_rect`'s `CommonProps::default()` is gone.** The FRESHIDS
   commits (`d14a9fdd`, `100faf86`) landed after the brief's snapshot: both
   ports now branch on fragment count, preserve everything on 1→1 (id
   included), and mint fresh ids on severing via one shared loop. The brief's
   "neither port is uniformly the generous one" was true when written; at
   HEAD the verified *dropping* sites are Swift-side (`withMask`,
   `withWidthPoints`), and Rust's live violation runs the other way — the
   boolean UNION *over*-preserves an id into an identity-death (§3.4). The
   law cuts both directions, which is a point in its favour.
2. **The N→1 attribute question is more settled than briefed.** The
   UNANIMITY CARRY is ratified and landed in both ports (commit `4024216b`);
   what remains open is exactly `name` (an unexplained hole, §3.3), the
   conditional `transform` rejoin, and the boolean panel's arms.
3. **"The op log drops id-less elements from journaled ops" is imprecise.**
   Element payloads round-trip value-in-op. What cannot name an id-less
   element is the `targets:[common.id]` metadata — and `targets` seeds
   `capture_recipe`, so id-less elements are invisible to recorded recipes
   and to any future journal-derived lineage (OP_LOG.md: "empty targets ⇒
   empty recipe — targets is load-bearing"). The consequence for Arc 3 is as
   the brief feared, but the mechanism is metadata, not op-dropping.
4. **Two transcripts lag the landed code** and should be updated by whoever
   next touches those panels: transcripts/BLOB_BRUSH_TOOL.md step 6 still
   says the merge result "carries no id" and marks unanimity UNRULED;
   transcripts/BOOLEAN.md's banked note still calls the blob 1-match arm an
   open Theseus site. Both are fixed in code at HEAD.
5. **Swift's `pathWithCommands` family is closed**, including the
   `PathEditIdentity` enum (no default — compiler-enumerated) that the brief
   listed as open. The open members of the family are exactly `withMask` and
   `withWidthPoints` in `Element.swift` (§3.4).

---

## 7. Anticipated refutations

**R1 — "the law admits cases the artist would not mean."** Strongest known
candidates: (i) unanimity carrying `locked: true` into a merge the artist
performed *into* locked artwork — conceded as adjacent, and routed to the
tool-gating question (§5.9) where it belongs: the surprise is that locked
artwork *matched*, not that lockedness was preserved; (ii) preserving a
translucent/CMYK source fill under a lossy match gate — already adjudicated
the law's way when the 1→1 arm landed (the source keeps its own paint; the
gate decides whether to merge, not whether values are equal); (iii)
preserving a gradient/width-profile that no longer fits the geometry — §3.8:
preservation with a named refit beats both dropping and guessing.

**R2 — "cases it fails to cover."** The out-of-scope list (§5) is the
answer's shape: creation ids, sub-element identity, undo, clipboard,
collaboration are excluded *by name with reasons*, not forgotten. The most
likely genuine gap: an edit whose spec does not say what it speaks to. The
law's default (narrow reading; widening requires ratification) makes the gap
fail safe — an underspecified edit preserves too much rather than too
little, and over-preservation of identity is the one direction the fixtures
pin hard (id-freshness assertions).

**R3 — implementability and cross-port enforceability.** The pattern is
landed and proven at the hardest site (`pathWithCommands` + Theseus
batteries + FRESHIDS' shared mint with deterministic override). §4 codifies
why neither compiler alone is the gate. Cost: one Mirror battery per Swift
copy API and one whole-struct fixture per Rust twin — bounded, mechanical,
and already the house style. The known residue: Swift's `withMask` spans
every element kind, so its battery must iterate kinds; the Mirror pattern
does this without per-field edits.

**R4 — the Arc-3 ledger.** The objection I expect and accept: journal-derived
lineage does not exist yet for these verbs (§3.7 names the gap). I chose the
journal anyway, because the alternative — successor pointers in the document
model — buys citability today at the price of purpose-claims in geometry and
byte-gate weight in every port forever. Until the op-log increments arrive,
the ledger's honest sentence is "I can no longer identify that shape; it was
edited destructively" — which is itself a citation-shaped statement, and
strictly better than a confident wrong pointer. A refuter who shows the
first apostles session *needs* transitive lineage on day one has found a
scheduling argument (accelerate 3b-B's successor), not a design flaw.

---

*Trailer for the ratification record: this freeze restates and depends on
rulings of 2026-07-26/27 (cardinality, fill-rule preserve, unanimity carry,
adjudication hierarchy) and proposes two amendments (unanimous `name`;
gradients-as-paint) plus one conditional (`transform` rejoin after S-3). It
changes no code.*
