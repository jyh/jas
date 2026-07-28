# EDIT SEMANTICS FREEZE — what survives an edit?

> **RATIFIED BY JYH, 2026-07-27.** The law, its six defined terms, the §3.5
> violation table as the repair queue, the §4 enforcement doctrine, and the
> ratification condition (*the law is not reported ENFORCED until the corpus can
> see it*) are adopted as the edit-semantics constitution beside the cardinality
> law. **All three §8 questions ruled on the recommendation:**
> **(1)** `name` at a merge — **ASSERTING-SOURCES** (a source that asserts a name
> carries it; silent sources do not veto).
> **(2)** Lossy UNWRAP — **WARNED** (Ungroup proceeds, the artist is told what
> cannot compose exactly; never silent, never refused).
> **(3)** Rect→Polygon `rx`/`ry` — **FLATTEN the rounding into the emitted
> points** (WYSIWYG at promotion).

**Status: RATIFICATION-READY. The refuter gauntlet has run and is folded in.**
Drafted 2026-07-27 (Starbuck, design seat) per the fleet-council ruling of the
same date; revised the same day after four adversarial refuters returned
**4 CONFIRMED_FATAL findings, 23 repairable findings, and 21 attacks that
failed to land**. The verdict up front, because JYH should not have to dig
for it: **the refuters did not find the law unsound. Every fatal was a
missing defined term, not a wrong clause. The one-sentence law survives
unchanged; its defined-terms layer grew from three terms to six.** Section 7
is the full gauntlet record — what was tried, what landed, what held.

This document sits beside — and does not reopen — THE CARDINALITY LAW
(JYH, ratified 2026-07-26):

> *Identity survives a one-to-one edit. It does not survive a change in
> cardinality.*

All code citations are to this branch at commit `ff3e62aa` ("Merge
arc2-prototypes: the cardinality law, and the corpus that can see").
Evidence marked **[driven]** was produced by a refuter executing the code
(probes against the built libraries, replayed gestures); evidence marked
**[read]** was verified by reading the named function at HEAD — every
fatal's anchor site was re-read independently during this revision. Counts
carry the method that produced them; sentences from the first draft that a
refuter falsified as wider-than-verified are corrected in §6 by name.

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

Six terms. The first three were in the original draft; the last three were
forced by the gauntlet's fatal findings, and each is the answer to one
(§7.1 maps them).

**T1 — "Speaks to."** The fields the gesture's ratified specification names
as its subject — never inferred from what the implementation happens to
touch. A path edit speaks to `d` (transcripts/PATH_ERASER_TOOL.md). Attaching
a mask speaks to `mask`. A boolean operation speaks to geometry *and* the
four paint properties its spec assigns (transcripts/BOOLEAN.md §Operand and
paint rules). The default reading is narrow: a gesture speaks to the minimum
its name states, and widening any edit's subject is a design ruling requiring
ratification, not a code change. Three closures, each closing a hole a
refuter drove:

- **Closed under SHADOWING FAMILIES.** If an edit speaks to any member of a
  set of fields that override one another at render time, it speaks to the
  whole set. The renderer defines the families mechanically: any group
  resolved in a single precedence chain — `apply_fill`
  (`jas_dioxus/src/canvas/render.rs`) resolves `{fill, fillGradient}` with
  the gradient branch returning early **[read]**, so an edit that writes
  `fill` speaks to `fillGradient` too (it goes to the fresh default, not
  carried). Likewise `{stroke, strokeGradient, strokeBrush,
  strokeBrushOverrides, widthPoints}` on the stroke chain. Without this
  closure, §3.3's unanimity would carry a unanimous gradient over the very
  fill colour the artist just chose — preservation as a mask for a guess.
  This closure also re-derives the gradients-as-paint amendment (§3.6) as a
  corollary rather than special pleading.
- **May include the element's REPRESENTATION when the spec says so.** Three
  ratified edits change element kind: brush apply promotes Line/Polyline to
  Path (`promote_to_path_for_brush`, the "upgrade naturally" convention,
  JYH 2026-07-25), the Rect corner drag promotes to Polygon
  (`move_control_points`), Object > Simplify promotes Polygon to Path. Under
  a representation change: every field with a counterpart is preserved;
  target-only fields take the documented default from the element-kind spec
  (T2 shape 4); source-only fields must be dispositioned BY THE SPEC, never
  silently discarded (the Rect→Polygon drag currently discards `rx`/`ry`
  with no ruling — flagged in §8). A kind change is lawful only in a
  ratified direction, and an implementation may never demote to a kind that
  cannot hold the source's fields when a holding kind is available (§3.6
  names the boolean flatten's Path→Polygon arm as a violation of exactly
  this).
- **A RING-REGENERATING edit speaks to `fillRule`.** *The fill rule belongs
  to whoever made the rings.* An edit that re-derives an element's ring
  structure through the polygon-set layer (every boolean-result emitter,
  both blob-brush arms) stamps the generated-geometry constant
  (`RESULT_FILL_RULE` / `boolResultFillRule` — EvenOdd, and
  `jas_dioxus/src/algorithms/boolean.rs` documents why in its own words: a
  non-zero declaration over machine-wound rings silently fills holes
  **[read]**). An edit that rewrites `d` while preserving ring structure —
  anchor move, smooth, eraser split — preserves the rule. This boundary
  reproduces the ruled fill-rule datum unchanged AND stops §3.1 from
  reintroducing the multi-ring corruption a prior ratified ruling exists to
  prevent (gauntlet fatal F4, §7.1).

T1 must also acquire a **machine-readable home**: today the subject sets
exist only as English in transcripts and code comments (gauntlet-verified:
grep of `workspace/` and `schema/` for a subject registry — zero hits), so
clause 1 is enforceable only by human review. §4.3 requires a
`workspace/effects.yaml` registry so both ports' batteries derive their
exempt sets from one shared artifact instead of hand-typed per-port lists
that drift.

**T2 — "Cannot preserve."** Preservation has no single well-defined value in
exactly FOUR shapes (the fourth added by the gauntlet):

1. **Identity across a cardinality change** — one id cannot become two, two
   cannot become one (REFERENCE_GRAPH.md §2.5 uniqueness invariant). The
   cardinality law is the identity-projection of this law: identity is
   preservable exactly when the edit is one-to-one.
2. **A value across disagreeing sources** — N elements merging into one,
   where the sources differ on a field the edit does not speak to.
3. **A reference across a severed target** — which fragment is "the ship" is
   a statement about PURPOSE, not geometry; the information is not in the
   shape, so no rule that reads only the shape can hold it.
4. **A field with no counterpart in the edit's output representation** — a
   ratified kind change lands on a kind with fields the source never
   carried; there is no value to preserve and no disagreement to
   adjudicate.

**T3 — "Must not guess."** In each shape respectively: the identity dies
(fresh id, minted through the shared loop); the field takes the fresh
element's documented default; the reference breaks — *loudly* (§3.7); the
field takes the documented default from the element-kind spec, recorded
there, never invented at the call site. The application never elects a
winner by size, z-order, area, or any other geometric proxy. The forgone
choice is recorded where a later chooser — the artist, or an assistant
citing the artist — can find it (§3.8).

**T4 — "The rest" includes the bystanders (the BYSTANDER CLAUSE).** *An
edit preserves, unchanged, every element it does not name — including the
containers it rebuilds to reach its target.* This was implicit in the
sentence, and the gauntlet proved implicit is not enough: Swift's
structural mutators (`Document.replaceElement` / `deleteElement` /
`insertElementAfter`) route every nested edit through a private
`withChildren` that rebuilds Layer/Group from four fields, destroying the
container's `id`, `mask`, `blendMode`, `visibility`, `isolatedBlending`,
`knockoutGroup`, and a Group's `name` on EVERY element edit in the port
**[read at `JasSwift/Sources/Document/Document.swift`, private
`withChildren`; driven by the gauntlet's probe against the built JasLib —
the identical Rust probe shows `Document::replace_element` preserving all
of it]**. No element-local clause reaches this, which is why it is now a
clause of the law and why §4's primary gate is a document-level invariant,
not a per-copy-API battery.

**T5 — What the cardinality arrow COUNTS.** *The arrow counts elements
whose material is at stake — the elements the edit consumes and the
elements it produces from that material. Re-parenting is not consumption.*
A container added or removed around unchanged elements is 0→1 or 1→0 *for
the container* and 1→1 *for each child*. Without this term the law
misreads the commonest structural gestures: Object > Group read over the
selection would be N→1 (killing every child's id); Ungroup read over the
group would be 1→N (minting fresh ids for children that already had
identities, and stamping the group's name on all of them). Both ports
already ship the correct reading (`apply_unpack_group_at`: "children keep
their ids — NO minting" **[read]**); the law now says it instead of
contradicting it. §3.4 gives the container rules in full, including the
verb the first draft's copy/preserve/default vocabulary lacked: COMPOSE.

**T6 — CAPABILITY MARKERS.** A field whose value changes what future
gestures DO — read as a gate by a tool's match/eligibility loop — is a
capability marker, distinct from appearance. Today: `toolOrigin` (the blob
brush's match gate at both ports' commit and erase arms, document-wide by
default — `blob_brush_merge_only_with_selection: false` in
`workspace/state.yaml` **[read]** — and never cleared by any production
write, gauntlet-enumerated); arguably `locked`. A capability marker is
still preserved by default — the Theseus clause is not weakened — but the
law additionally requires: (i) **no capability marker may gate a
document-wide scan until an artist-reachable revocation exists** (an
Object-menu / Layers-panel "detach from tool"); (ii) **widening a marker's
behavioural reach is a ratified ruling, not a code change** — the same
discipline T1 imposes on widening a gesture's subject. *A marker that
changes what tools may do to an element must come with a way to take it
off.* Without this, "preserve `toolOrigin`" quietly legislates that a blob
painted once is a merge candidate forever — the gauntlet's background-wash
gesture, where an hour of refinement on a named, gradient-filled shape is
eaten by one overlapping stroke in a matching colour.

### 1.2 The corollary the second clause earns

Unanimity is not a guess. When every source of an N→1 merge agrees on a
field, carrying that value IS preservation — well-defined, no winner
elected. So the second clause forbids exactly the disagreement case and
*mandates* the agreement case. This is the already-ratified UNANIMITY CARRY
(JYH, 2026-07-26, the blob-merge region of
`jas_dioxus/src/interpreter/effects.rs` and its `YamlToolEffects.swift`
twin), now derived rather than free-standing. Two boundaries the gauntlet
sharpened: unanimity never ranges over a shadowing sibling of a spoken-to
field (T1's closure), and never over `fillRule` on regenerated rings (T1's
ring term) — in both cases "carrying the agreed value" would be a guess
wearing preservation's clothes.

---

## 2. The three questions, decided

**(a) Fill-rule-on-edit — the law AGREES with the ruling, now for the
right stated reason.** Dragging an anchor rewrites `d` without
regenerating ring structure, so it does not speak to `fillRule`; the rule
is preserved. The ruled answer (JYH, 2026-07-26: preserve) falls out of
T1's ring boundary — which ALSO yields the other half the first draft
missed: boolean emitters and both blob arms stamp the generated-rings
constant rather than preserving or unanimity-carrying a source's rule.
Two refuters attacked the datum directly (shadowing siblings; hunting a
reset site at HEAD) and both attacks failed — §7.3. Had the law been
unable to reproduce this datum it would be the wrong law.

**(b) Element-field preservation — the class is this law's first clause
plus an enforcement doctrine (§4).** "Preserve the rest" stated as a law,
not a field list, is what closed the Rust path-edit sites and Swift's
`pathWithCommands` (all 18 properties forwarded, Mirror-battery-pinned).
The gauntlet's central lesson for (b): the class is bigger than element
copy helpers — it includes **bystander containers** (T4) and **cross-kind
copy sites**, where Rust's compiler-forced enumeration is answered by a
human with `None` (the fill-rule failure mode recurring: the Rect→Polygon
arm hard-codes `fill_gradient: None` at HEAD **[read]**). The open sites
are decided in §3.5.

**(c) Referential integrity on destructive edits — the reference breaks,
and breaks loudly.** JYH's steer ("breaking the reference probably makes
more sense, because deciding in a mechanical way will generate surprises")
is the second clause verbatim: a remap is a guess about purpose. What the
steer left open — the *silence* — this law closes, with the gauntlet's
correction folded in: **loudness is the law; the dialog is not** (§3.7
separates the predicate from its delivery, because a modal per mousemove
sample is not a design anyone would ratify).

---

## 3. The clauses

Each clause states the rule, what conformance looks like in both active
ports, and how a fixture sees a violation.

### 3.1 One-to-one edits (the Theseus clause)

**Rule.** A 1→1 edit preserves every field it does not speak to — including
`id`, `name`, `transform`, `toolOrigin`, both gradients, both brush fields,
`mask`, `visibility`, `blendMode`, `locked`, and `fillRule` when rings are
not regenerated (T1) — stated as a law so it cannot rot as fields are
added. A 1→1 edit may change element KIND only per T1's representation
term: ratified direction, counterpart fields preserved, target-only fields
to documented defaults, source-only fields dispositioned by the spec.

**Conformance, Rust:** struct-update syntax or clone-then-mutate at every
same-kind copy site (`PathElem { d: new, ..pe.clone() }`; `elem.clone()` +
`common_mut()`). A field-enumerating struct literal at a *same-kind copy*
site is a review flag. **Cross-kind sites get no compiler protection in
either direction** — the compiler demands the field and a human answers
`None` (gauntlet-driven at the Rect→Polygon arm, §3.5) — so cross-kind
sites are exactly where the §4 batteries are mandatory, not optional.

**Conformance, Swift:** one copy helper per element kind with no defaulted
parameter for any preserved field on the *edit* path (the `pathWithCommands`
+ `PathEditIdentity` pattern — the identity argument deliberately has no
default, so the compiler enumerates call sites). The gauntlet showed the
deeper fix is structural, and §4.4 adopts it: the omission class is
generated by `public let` stored properties forcing open-coded rebuilds
(gauntlet count: 220 `public let` vs 38 `public var` in Element.swift),
while `LiveVariant.withMask` already does the lossless clone-then-mutate
thing because its conformers declare `var`. Grade (a): make element stored
properties `var`/`private(set) var`, so every `with*` helper becomes
clone-then-mutate and omission stops being expressible — closing the class
across all kinds in one edit. Grade (b), closer to Rust: give Swift a
`CommonProps` carrier so a rebuild forwards ONE field, killing at the root
the asymmetry that generated the class. Either grade turns the per-API
batteries into belt-and-braces; the law requires the structure, not the
grade.

**Fixture:** the Mirror-driven battery (`PathEditTheseusTests.swift`,
`MovePathHandleFieldsTests.swift`); Rust twin: whole-struct equality after
grafting the source's geometry. Three requirements the gauntlet added:
(i) **the anti-vacuity guard is mandatory** — every battery asserts its
fixture differs from the default in every non-subject field
(`theseusFixtureDiffersFromDefaultInEveryNonDField` is the pattern),
because a rich fixture that silently decays to defaults passes on nothing;
(ii) the double-Mirror walk is proven viable across element kinds
(gauntlet-probed with swiftc), with two caveats honoured: `.live(...)` is
an enum inside an enum and needs a third reflection level, and every
kind's battery asserts reflected child count > 0 so a non-struct payload
cannot make it silently vacuous; (iii) **`FillRulePreservationTests.swift`
is named as the CONVERSION TARGET, not an existing gate** — it walks all
17 Element-returning copy helpers but asserts ONE field, and passes green
today over `withMask` dropping seven (its own header admits the hand-list
failure mode; `withMask`'s doc comment asserts preservation the arms do
not perform and must be struck when the arms are fixed). **Mandatory
pairing (banked 2026-07-26):** every battery includes at least one
assertion on the geometry's actual VALUE — field-list-free tests are
structurally blind to where the geometry landed.

### 3.2 Splits (1→N)

**Rule.** Identity dies (cardinality law). Everything else — appearance,
`transform`, AND `name` — copies to every fragment; each fragment wears a
fresh id from the shared mint loop, minted in the effect where the document
is in hand, all-or-nothing (a failed mint aborts the edit, never a
half-identified split).

**Status, stated exactly:** field preservation LANDED in both ports
(FRESHIDS commits `d14a9fdd`, `100faf86`; read directly in
`path_erase_at_rect` / `pathEraseAtRect`). **PLACEMENT is NOT verified
under `common.transform`: the eraser is in the S-3 transform-blind class**
— it flattens raw `d` against a document-space rect; zero `transform`
references in the hit-test region, both ports identically
(gauntlet-verified; method: awk over the function's line range, `grep -c
transform` → 0). On a transformed element, WHERE the cut lands — hence the
fragment count, hence whether identity dies at all, hence whether
references break — is computed against geometry the artist is not looking
at. The first draft certified this site conforming; that was a sentence
wider than what was verified, and §6.2 corrects it. The post-S-3 sweep
(§3.3) covers merge, boolean flattening, AND erase as one class.

**Fixture:** the FRESHIDS gates exist per-port. Extensions this freeze
requires (ratification condition, §4): assert `name` equality on every
fragment and id *freshness* (result id ∉ pre-edit id set) — freshness, not
presence, is the pinned property — and a CROSS-LANGUAGE gesture vector
reaching the severing arm, which does not exist today (FRESHIDS' own
commit message says so; gauntlet re-confirmed against all 44 action
goldens and the gestures corpus).

### 3.3 Merges (N→1)

**Rule.** Identity dies; fresh id. Every field the edit does not speak to
(under T1's closures — shadowing siblings and regenerated-ring `fillRule`
are spoken to, hence excluded) follows unanimity: all sources agree → the
value carries; any disagreement → the fresh element's documented default.
No winner, ever. The new sweep/stroke is not a voter — unanimity ranges
over the pre-existing sources only (the landed code already does this;
attacked and held, §7.3).

Decisions this clause makes beyond the landed code:

- **`name` joins the unanimity carry — with a choice for JYH (§8).** The
  ratified five-field list (`opacity`, blend mode, `visibility`, `locked`,
  `mask`) explains all its other exclusions; `name` is absent with no
  stated reason. Two variants, both guess-free; the Captain picks:
  - **STRICT:** all sources agree on `name` → carries; else default. The
    gauntlet showed the cost plainly: no drawing tool sets `name`
    (gauntlet-enumerated: zero production writes to `common.name` in
    effects.rs), so the commonest real case is ONE named source among
    unnamed neighbours — strict unanimity deletes the artist's word
    exactly there, and combined with the fresh id the merge product is
    left with no handle of any kind. Total amnesia at a routine gesture.
  - **ASSERTING-SOURCES (recommended):** for `name` only, unanimity ranges
    over sources that ASSERT a name — absence is not a competing claim.
    "hull"+unnamed → "hull"; "hull"+"keel" → default. This is not the
    rejected rule in disguise: nothing geometric elects the winner, no
    float is compared — the only assertion present survives, which is
    preservation in the second clause's own sense.
  If JYH rules STRICT, the freeze records the consequence: `name` is not a
  lineage channel, and §3.8's death record is the only thing standing
  between the ledger and amnesia at every merge.
- **`transform` joins the unanimity carry — CONDITIONAL on S-3 landing.**
  Its current exclusion is bug containment, not law: the merge pipeline
  matches raw `d` against a document-space sweep, and carrying a unanimous
  transform today would relocate the merged artwork. The conforming order:
  S-3 lands with fixtures proving the pipeline transform-aware, then the
  carry list gains `transform` in both ports in one commit with a
  unanimous-transform fixture. The transform-blind CLASS has three known
  members — the blob merge (S-3), the boolean flattening walk
  (`element_to_polygon_set_with`: zero `transform` occurrences in the
  function body, gauntlet-counted), and the eraser's placement (§3.2) —
  and the post-S-3 sweep covers all three together.
- **Unanimity ranges over every non-spoken-to field**, not the five that
  can differ in today's blob population. The implementation may exploit
  invariants (blob sources are fill-only by construction); the fixture
  battery must probe the general rule, because tomorrow's merge sources
  may not honour today's invariants.

**Fixture:** exists for the five (`blob_merge_carries_unanimous_attributes`
+ Swift twin); extend per the amendments, plus the disagreement direction
(sources differ → default stands), the shadowing-family direction (one
pinned case per family, both ports), and id freshness. Plus a
cross-language vector reaching the N≥2 arm — none exists today (§4).

### 3.4 Containers: wrap, unwrap, compose (new — answers gauntlet fatal F1)

T5 gives the arrow; this clause gives the rules. Container lifecycle is a
category of its own, and the shipped code already implements most of it
correctly — the first draft's silence, not the code, was the defect.

- **WRAP** (Object > Group, Make Compound Shape, wrap-in-layer): 0→1 for
  the container — fresh identity, never a member's; 1→1 for every child —
  ids and all fields survive untouched. `group_selection` conforms
  (`CommonProps::default()` on the new Group, children re-parented
  untouched **[read]**). `make_compound_shape_with_op` VIOLATES it: it
  clones the frontmost operand's whole `common` — id included — onto the
  wrapper while that operand remains a child, leaving TWO live elements
  wearing one id **[read at `controller.rs`: `let common =
  frontmost.common().clone()`; gauntlet-driven: the resulting document's
  id walk yields a duplicate]**. That breaks the uniqueness invariant the
  cardinality law itself leans on, and it is worse than a broken
  reference: a reference to the duplicated id silently REBINDS to
  whichever element the index walk reaches first — the one outcome §3.7
  exists to prevent. The Swift twin diverges instead of matching (no id,
  `opacity: 1.0` and `locked: false` hard-coded, `name`/`mask`/`blendMode`
  dropped). Rule: the wrapper takes the frontmost's PAINT per the ratified
  spec, never its `common`; both ports brought to that rule in one commit.
- **UNWRAP** (Ungroup, Release Compound Shape, layer flatten): the
  container's identity ends — a 1→0 deletion; §3.7 applies if it was
  referenced. Every revealed child is 1→1 and preserves everything, ids
  included. The shipped ungroup conforms on ids ("children keep their ids
  — NO minting" **[read]**).
- **COMPOSE.** A container's own geometry-affecting attributes
  (`transform`, `opacity`, `blendMode`, `mask`, isolation/knockout) are
  neither copied to children nor dropped on unwrap: they are COMPOSED into
  the children — the verb the first draft's copy/preserve/default
  vocabulary lacked. Where composition is exact (transform
  premultiplication; opacity under normal blending onto non-overlapping
  children) it is required. Where it is NOT exact (mask, isolated
  blending, knockout, opacity over overlapping children), the law does not
  guess — **whether the unwrap is refused, warned, or deliberately lossy
  is a genuine Captain's ruling, named in §8.** The shipped ungroup
  currently DISCARDS the group's own `common` wholesale **[read:
  `ungroup_selection` deletes the group and re-inserts the children
  verbatim]** — a live defect the first draft could not even express, now
  on the repair queue behind that ruling.

**Fixture:** the document-level invariant gate (§4.1) catches wrap/unwrap
id violations with zero per-op fixtures; compose gets one fixture per
exact family (transformed group ungrouped → children's rendered geometry
identical before/after).

### 3.5 The named open field-family sites, decided

Verified at `ff3e62aa`; rows added by the gauntlet are marked ▲.

| Site | State at HEAD | Verdict under the law |
|---|---|---|
| Swift `pathWithCommands` family | CLOSED — 18 properties forwarded, no-default identity enum, Mirror-pinned | conforming; the model for §3.1 |
| Rust `path_erase_at_rect`, fields | `..path_elem.clone()` + fresh ids on severing | conforming on FIELDS; placement is in the transform-blind class (§3.2) |
| Blob commit, 1-match arm, both ports, fields | `..src` / `pathWithCommands(src, …, .sameElement)` | conforming on fields — including paint: the hex match gate does not overwrite a translucent/CMYK source (attacked and held, §7.3) |
| ▲ Blob commit, BOTH arms, `fillRule` | 1-match arm carries the source's rule onto union-generated rings; N→1 arm stamps `NonZero` (`effects.rs:5123` **[read]**; Swift twin's own comment: "parity, not preference") | **VIOLATION of T1's ring term and of the ratified generated-rings ruling — a LIVE DIVERGENCE from ratified law (adjudication tier 4: outranks feature work).** Both arms stamp `RESULT_FILL_RULE`/`boolResultFillRule` |
| Swift `withMask`, `.path` arm | drops 7: `fillGradient`, `strokeGradient`, `strokeBrush`, `strokeBrushOverrides`, `toolOrigin`, `name`, `id`; the `.line` arm additionally drops `strokeGradient` (gauntlet understatement-correction); only the Layer arm passes `name:`/`id:` | **VIOLATION of §3.1.** Masking a cited path destroys its identity on a 1→1 edit. Rust's twins (clone + `common_mut().mask`) conform — a live one-sided divergence. **REPAIRED and re-verified 2026-07-27:** every one of the twelve arms is now `case .path(var v): v.mask = mask; return .path(v)` — clone-then-mutate, so omission is no longer expressible; the `.live` arm delegates to `LiveVariant.withMask`, which was already clone-then-mutate **[read at `Element.swift`, this commit]** |
| Swift `withWidthPoints`, `.path` arm | drops 9 (the 7 plus `blendMode`, `mask`); call sites `Controller.swift` (panel) and `Eyedropper.swift` | **VIOLATION of §3.1.** Rust's `with_width_points` is `..e.clone()` on both arms — conforms. **REPAIRED and re-verified 2026-07-27:** both arms are clone-then-mutate **[read at `Element.swift`, this commit]** |
| ▲ Rust `move_control_points`, Rect→Polygon arm | hard-codes `fill_gradient: None, stroke_gradient: None` **[read]**; the Swift twin forwards both — the divergence runs Rust-ward here | **VIOLATION of §3.1** on a 1→1 kind change: a gradient-filled rounded rect, corner-dragged, silently loses both gradients **[driven]**. The only non-spread `fill_gradient: None` in production element.rs (gauntlet brace-matched enumeration; the other is the Line→Path promotion, where a Line genuinely has none) |
| ▲ Swift `Document` private `withChildren` (replace/delete/insertAfter paths) | rebuilds Layer/Group from 4 fields; destroys the container's `id`, `mask`, `blendMode`, `visibility`, `isolatedBlending`, `knockoutGroup`, and Group `name` on EVERY nested edit **[read + driven, both ports probed — Rust preserves all of it]** | **VIOLATION of T4 — the gravest site in either port: every element edit in the Swift port silently orphans container references and erases the ledger's handle.** The fix sits in the same codebase: `Group.withChildren`/`Layer.withChildren` in `Element.swift` preserve every field; delete the private twin, route the three mutators through them |
| ▲ Swift inline `Layer(`/`Group(` literals | gauntlet enumeration (brace-matched regex over Sources, serialization/normalization files excluded): 41 production sites, 39 omitting `id`; exemplar: `pathEraseAtRect`'s layer rebuild hand-forwards TEN fields and omits exactly `id` | **VIOLATION class of T4.** Nine right and the tenth is identity — the hand-audit pathology, found inside the first draft's own proof-of-conformance site. Gated by §4.1's document-level invariant, which no per-site audit can substitute for |
| ▲ Rust `make_compound_shape_with_op` | duplicate id: wrapper wears the frontmost's `common` while the frontmost stays a child **[read + driven]**; Swift twin diverges the other way | **VIOLATION of the uniqueness invariant** (§3.4 WRAP rule; silent-rebinding hazard — strictly worse than a loud break) |
| Rust `apply_destructive_boolean`, UNION/INTERSECTION/EXCLUDE arm | carries `front.common().clone()` — the frontmost operand's id through an N→1 | **VIOLATION of §3.3 / the cardinality law** — "the frontmost source keeps the id", the rejected rule wearing `..clone()` as the hat. Over-preservation is also a violation: preserving what cannot be preserved is a guess |
| Swift boolean rebuild, non-paint fields | `locked` written `false`; `name`/`id`/`toolOrigin`/`mask` dropped (source comment concedes it and banks it for a ruling) | **VIOLATION of §3.1** for the 1→1 survivor arms, **of §3.3** for the N→1 arms |
| ▲ Boolean flatten, single-ring arm, both ports | emits `Polygon` — a kind with NO slot for `widthPoints`, `strokeBrush`, `strokeBrushOverrides`, or `fillRule` **[read: `PolygonElem`'s six fields]**; even the multi-ring Path arm writes them empty | **VIOLATION of §3.1 for the 1→1 survivor arms** — not an amendment; the first draft misfiled the gradient half of this as one. Per T1's representation term: emit the survivor's own kind or Path (the superset), never a lossy demotion |
| Eyedropper apply | speaks to the sampled appearance family by spec | conforming in intent; its Swift path inherits the `withWidthPoints` violation |
| ▲ Swift `withStrokeBrush` / `withStrokeBrushOverrides`, all four arms | four same-kind `Path`→`Path` rebuilds still open in `Element.swift` AFTER the class was declared closed there (`cb7e2a78`; see correction 8). Each restates all 18 `Path` fields by hand; the two `.line`/`.polyline` arms restate the Path that `promoteToPathForBrush` just produced, so the file rebuilds its own output. Two more of the same shape outside the "element-struct" scope of that commit's pass: `Stroke.withWidth`, `Stroke.withLinecap` (14 fields each) **[read; argument labels balanced-paren-parsed and diffed against the stored-property lists]** | field-COMPLETE at HEAD — **no live drop**, so NOT a violation today; an UNGATED SHAPE of the §3.1 class, and the only battery that reached them (`FillRulePreservationTests`) watched 1 field of 18. `BrushHelperTheseusTests.swift` now pins all four Path arms (9 tests, green on arrival, mutation-proved one site at a time). Repair to clone-then-mutate is still owed |

▲▲ **RE-CENSUS of the Swift container-literal row, 2026-07-27 — the class
is OPEN, and here is exactly what remains.** Two waves have repaired 15 of
these sites (8 + 7) and both scoped their enumeration to
`Tools/YamlToolEffects.swift` alone; the second's subject line, "the seven
remaining container literals — CLOSED", reads port-wide and is not. A fresh
census over ALL of `JasSwift/Sources` finds **46** `Layer(`/`Group(`
literals, **none of them in YamlToolEffects.swift any more** (the two waves'
work is real), decomposing as:

- **21 REBUILDS of an existing container that drop `id`** — every one a live
  T4 violation, all in files no wave has owned yet:
  `Clipboard/EditClipboard.swift` 65, 85 (paste-into-layer), 129, 132
  (`translateElement`); `Document/Controller.swift` 162
  (`addElementToLayer`), 476 (a mask-subtree Group; drops only `name`+`id`),
  843 (`lockSelection`), 888, 893, 903 (`unlockSelection`), 954, 961
  (show-all), and the five identical layer rebuilds at 1008
  (`groupSelection`), 1044 (`ungroupSelection`), 1110 (make compound), 1157
  (release compound), 1207 (`expandCompoundShape`);
  `Interpreter/YamlPanelBodyView.swift` 4138 (layer rename);
  `Menu/MenuActions.swift` 57, 69 (flatten); `Panels/LayersPanel.swift` 251.
  Seventeen of the 21 also drop `blendMode`, `mask`, `isolatedBlending` and
  `knockoutGroup`; ten also drop `visibility`. Consequence in plain words:
  **Object > Lock, Object > Unlock, Group, Ungroup, layer rename, and every
  compound-shape lifecycle verb each destroy their layer's or group's
  identity and opacity mask as collateral.** Every one has `withChildren` /
  `Document.replacing` already available to it, exactly as the 15 repaired
  sites did.
- **9 CREATIONS** (0→1), where fresh defaults are the §3.4 WRAP rule rather
  than a defect: `EditClipboard.swift` 25 and `LayersPanel.swift` 548
  (throwaway docs for SVG serialization), `Controller.swift` 1001 (the new
  Group in `groupSelection` — correct: never a member's identity), 1745 (an
  empty Group as a Mask subtree), `Document.swift` 208, 237 (the default
  document layer), `LayersPanel.swift` 423 (`doc.create_layer`), and
  `OpApply.swift` 799, 833 (wrap-in-group / wrap-in-layer — these two pass
  `id:` from the mint, the model the other sites should follow).
- **16 in serialization / normalization** (`Binary.swift`, `Normalize.swift`,
  `Svg.swift`, `TestJson.swift`), the exemption this row already declares.

**METHOD, so it can be re-run and audited:** brace-matched scan of every
`\b(Layer|Group)\(` token over `JasSwift/Sources/**/*.swift` with `//` and
`/* */` comments blanked (string literals preserved), each call's top-level
argument list harvested for `label:` tokens and compared against the struct's
own stored-property set, itself harvested from the struct body. **BLIND
SPOTS, stated:** (i) it checks label PRESENCE, not that the value passed is
the right one — a site forwarding `l.opacity` under `opacity:` and a garbage
constant look alike; (ii) it cannot distinguish a rebuild from a creation, so
that split was made by READING all 30 non-codec sites, not mechanically;
(iii) `bounds` and `displayName` are computed properties that the harvester
initially reported as stored, and were excluded by reading the structs; (iv)
it does not see clone-then-mutate sites at all, which is correct — those
cannot omit a field; (v) it does not scan `Document(` literals, which the
earlier wave did. **None of the 21 is repaired here** — this wave owned
`Geometry/Element.swift` and `Geometry/LiveElement.swift` only, and both are
CLEAN of container literals under the same census.

▲ **Cross-port field vocabulary (gauntlet finding; latent but
structural):** `tool_origin` lives on Rust's `CommonProps` — all eleven
kinds **[read]**; Swift's `toolOrigin` is a stored property of `Path`
alone, so the Line→Path promotion carries it in Rust (`common:
e.common.clone()`) and writes `toolOrigin: nil` in Swift **[read at the
promotion sites]** — not a bug the Swift author could fix, because the
source field does not exist there. Latent today only because `tool_origin`
is blob-brush-only and blobs are Paths. Consequences: §4.2 defines
conformance over the SHARED SERIALIZED FIELD SET, not per-port reflection;
and the vocabulary divergence itself is a scheduled defect (lift
`toolOrigin`/`fillRule` into a Swift common carrier, or demote Rust's to
Path — either, but decided, not drifted). The law should not outlive the
accident that hides this.

### 3.6 The boolean panel and the compound-shape lifecycle, per op

The transcript banked this as "needs a decision per op". The law decides
all of them without per-op ceremony, because cardinality + speaks-to
classify them (the `fillRule` column is T1's ring term — gauntlet fatal F4
— and the compound-shape rows answer the gauntlet's missing-lifecycle
finding):

| Op | Cardinality | id | Non-paint fields | Paint | fillRule |
|---|---|---|---|---|---|
| UNION / INTERSECTION / EXCLUDE | N→1 | fresh mint | unanimity (§3.3) | frontmost's four, per ratified spec | RESULT_FILL_RULE |
| SUBTRACT_FRONT / SUBTRACT_BACK survivor, CROP survivor, TRIM operand | 1→1 each | survives | full Theseus preservation (§3.1); output kind per T1's representation term — no lossy demotion | its own | RESULT_FILL_RULE — the op regenerated the rings; preserving a nonzero survivor's rule over a cutter-inside-survivor result would fill the hole the artist just cut (F4) |
| consumed cutter / mask operand | 1→0 | ends (a deletion; §3.7 applies if referenced) | — | — | — |
| DIVIDE | 1→N per designated operand | fresh mint | copies from the designated operand, `name` included (§3.2) | designated operand's, per spec | RESULT_FILL_RULE |
| MERGE | per merged group — exactly the blob brush's arms | singleton: survives; multi: fresh mint | singleton: §3.1; multi: §3.3 | frontmost contributor's, per spec | RESULT_FILL_RULE, both arms |
| Compound Shape MAKE | wrap: 0→1 container, 1→1 children (§3.4) | fresh for the wrapper — NEVER the frontmost's | children untouched | frontmost's, per spec — paint only, never `common` | n/a (live op; operands keep their own) |
| Compound Shape RELEASE | unwrap (§3.4) | container's id ends; children keep theirs | children 1→1; container attrs COMPOSE | children's own | children's own |
| Compound Shape EXPAND | 1→N per operand | fresh mint; §3.7 loud break for the compound's own referenced id | §3.2 per operand | per spec | RESULT_FILL_RULE |

One flagged amendment, not silently legislated: the ratified paint list is
four properties, and both ports currently drop the frontmost's
`fillGradient`/`strokeGradient` at the rebuild. Under T1's shadowing
closure, "paint" includes the gradient — an op that speaks to `fill`
speaks to its shadowing siblings. AMENDMENT for ratification since it
widens a ratified list, though it is now a corollary of a defined term
rather than a taste call.

### 3.7 References: break loudly

**Rule.** When an edit kills an identity that something references, the
reference BREAKS. It is never remapped to a fragment or a merge product —
that would be a purpose-guess — and it never breaks *silently*. Two
refuters independently broke the first draft's delivery mechanism (a
modal per mousemove sample, with Cancel unanswerable mid-stroke); the rule
itself held. Four parts:

1. **The dangling doctrine stands — demoted to what it is:** a dangling
   reference evaluates to empty geometry, never a panic
   (REFERENCE_GRAPH.md §3) — an EVALUATION-SAFETY invariant, **not the
   artist-facing presentation.** The gauntlet's gesture: erase a nick from
   a path feeding a live/recorded element; two pixels deeper the nick
   severs, and untouched artwork elsewhere on canvas silently vanishes,
   leaving nothing to click or drag — a cliff decided by a hit-test the
   artist cannot see. Evaluate-empty must never double as the
   notification.
2. **LOUDNESS IS THE LAW; THE DIALOG IS NOT.** The binding PREDICATE:
   before an arm kills a referenced id, `orphaned_references` /
   `orphanedReferences` runs over the affected paths and the result is
   never discarded. DELIVERY is by gesture shape: *discrete,
   re-dispatchable commands* (delete, boolean panel ops, symbol delete)
   keep the existing pre-commit modal intercept (five non-test call sites
   per port, gauntlet-audited and symmetric); *continuous gestures* (the
   path eraser — whose effect fires once per mousemove sample by design;
   the blob commit's merge arm) report at the GESTURE BOUNDARY:
   post-commit, non-blocking, one notice per undo step, coalesced on the
   drag coalescer that already exists. The first draft's "routes through
   the same confirm dialog — one seam, not a second mechanism" was
   unimplementable for the verb it named first, and is struck.
3. **The seam PUBLISHES; subscribers are open.** An identity-death arm
   publishes {verb, dying ids, minted ids} to one seam. The document's
   orphan-check consumer (which raises the dialog or the gesture-boundary
   notice) is one subscriber; the Arc-3 ledger is another. Without this,
   the clause closes the silence only for referrers that live inside the
   byte-gated document — and §3.8 argues at length that provenance must
   not live there. Same code motion the clause already required; the
   subscriber set is the only new word.
4. **Orphans must be FINDABLE.** Where an edit orphans a referrer, the
   edit leaves the orphaned referrers selected and badged in the Layers
   panel — the predicate already returns exactly that id list
   (`dependency_index.rs`), so no new machinery. A stronger, still
   guess-free presentation is offered to the panel spec rather than
   mandated: render the orphan's LAST RESOLVED geometry with a broken-link
   decoration — a fact about history, the tier §3.8 already reserves for
   provenance, electing no winner from geometry. **No auto-repair, no
   reference-editing side effects, ever:** re-pointing is reserved for
   someone who can hold a purpose. "This part goes into the ship, the
   other part is put back into the scrap heap."

**Fixture:** create a reference, sever the target; assert (a) the
reference survives serialization and evaluates empty (pattern exists:
`create_reference_dangling`), (b) the publish fires with the right {verb,
dying, minted} triple (unit-testable, no GUI needed), (c) the discrete
path raises the dialog and the continuous path yields exactly one
gesture-boundary notice per undo step (GUI harness), (d) no element's
`target` field was rewritten by the edit.

### 3.8 Provenance: what the ledger cites when identity dies

Arc 3's critique mechanism is citation, and citation needs the thing the
artist talked about to remain *findable* after editing. Decision:
**provide lineage, in the journal, not the document** — attacked directly
by the Arc-3 refuter and HELD (§7.3). Four clauses; the last three are
gauntlet-forced:

1. **The DEATH RECORD (minimum viable, required at every identity-death
   arm):** *no identity leaves the document without a receipt.* The
   published triple of §3.7.3 — {verb, predecessor ids, minted successor
   ids} — IS the record; full transitive lineage in journaled ops arrives
   with the op-log increments (3b-B's successors) and is REQUIRED from
   those verbs' first journaled version. Until the record exists, the
   assistant cannot truthfully say "it was edited destructively" — an
   absent id is equally consistent with delete, undo, sever, merge, the
   eraser's whole-element drop branch, or an outright bug (Swift's
   `withMask` destroys an id on a 1→1 edit today) — so the honest interim
   sentence is weaker than the first draft's: *"the shape you called the
   hull is no longer in the document; I do not know what became of it."*
   The record doubles as an INVARIANT with teeth: "no id may leave the
   document undeclared" is checkable in exactly the shape the codebase
   already uses (`debug_assert!(id_index == rebuild)`, model.rs), and it
   would fire on BOTH live id-destruction classes in §3.5.
2. **The CITATION MINT: naming is minting.** The gauntlet found the circle
   the first draft drew: lineage needs ids; drawn elements have none (the
   only production id-minters are referencing, the six Symbols sites, and
   the identity-death arms — gauntlet-enumerated by grep over production
   regions); and the mint ruling was pushed out of scope. So the ledger
   could never cite the artist's first shape — §3.7 promised a substrate
   the law forbade itself from having. The escape is doctrine that
   already exists: `create_reference` lazily stamps an id on its target
   iff it has none (assign-on-create **[read]**). Generalized: ANY namer
   mints — and the Arc-3 ledger banking a ruling about an element is a
   namer. Under this law that is simply a 1→1 edit whose subject IS `id`;
   §5.1's refusal to mint at creation time survives untouched — the mint
   happens at first NAMING, not at birth. A citation mint is a document
   mutation (journal + undo stack), deliberately. AMENDMENT for
   ratification (§8), since it admits a new class of minter.
3. **Lineage is CURSOR-RELATIVE.** The journal is a rewindable cursor that
   new edits truncate (`journal_head` is "NOT a high-water mark"
   **[read at model.rs]**), while the ledger is the assistant's own memory
   and is not rewound by Cmd-Z. So: lineage is derived at the current
   `journal_head` on demand, never cached in a ledger entry; a ledger
   entry stores the citation (the ruling and the ids it names), never the
   derived lineage. Undo rewinds lineage, and any assistant statement
   derived from it is defeasible by it. Fixture: split → death record
   derivable → undo → record NOT derivable.
4. **Set citation resolves through GROUP identity.** Four of the founding
   document's five moves cite sets ("the women", "the flat tableau"), not
   elements — the commonest citation granularity, which the first draft
   neither served nor excluded. The law already makes a group's identity
   durable: a group is 1→1 under any member edit (`replace_element`
   rewrites the child slot in place; the parent's `common`, id included,
   survives **[read]** — and T4 now makes that survival LAW in both
   ports). So the assistant's move when the artist rules about a set is
   to propose a group — itself one of the five moves. Stated truthfully
   rather than discovered in Arc 3: **an UNGROUPED set has no handle**,
   and an enumerated-member citation decays with every destructive edit.

**Why the journal and not the model** (unchanged, now attack-tested):
identity is a fact about the document — references bind to it; provenance
is a fact about history — citations bind to it. A successor pointer stored
on elements would make geometry carry purpose it cannot hold, would dangle
when successors are themselves edited away, and would put lineage inside
the byte-gated document state that every port replicates forever. The
precedent is REFERENCE_GRAPH.md §2.3's derived id-index: outside
`Document`, never serialized, never compared, paired with the snapshot.

### 3.9 Geometry-indexed attributes: two classes, not one

The first draft had one clause ("preserved, then refit"); the gauntlet
split it with a gesture that renders artwork the artist did not draw:
erase a nick from a taper-both stroke, and BOTH fragments re-normalize the
full profile onto their shorter lengths — each pinching to a point at the
fresh cut, the stroke's rhythm across the drawing changed by an erase.

- **Geometry-RELATIVE** (resolved against the element's bbox): linear
  gradient ramps (S-2's subject, in flight; radial recentring accepted).
  Preserved unconditionally; refit is a separate, named, scheduled ruling.
  Preservation now, refinement as scheduled work — never open-ended
  deferral (the corner-case doctrine), never "drop it because the refit is
  hard".
- **Geometry-PARAMETERIZED** (indexed by a normalized coordinate of the
  very path the edit rewrote): membership derived mechanically — fields of
  `PathElem` keyed by a normalized path parameter — and today that is
  exactly one field, `width_points` (via its `t`; gauntlet-verified
  against `profile_to_width_points`). For this class **preservation and
  refit are ONE ruling, not two**: the attribute is preserved AND its
  refit lands in the same commit, or the edit is a named LIVE DIVERGENCE —
  which outranks feature work under adjudication rule 4. For an attribute
  indexed by the geometry the edit changed, preserve-without-refit is not
  a neutral holding position; the first draft licensed an open-ended
  wrong-pixels state and is corrected.

---

## 4. Enforcement doctrine (rebuilt around the gauntlet)

The first draft's gate was per-copy-API batteries. The gauntlet proved
that gate structurally blind to the gravest violation in either port —
inline container rebuilds are not copy APIs, so no battery would ever have
been written for them, and the class would have been reported closed while
every Swift edit destroyed container identity. The doctrine is now four
tiers; the first is primary.

1. **The DOCUMENT-LEVEL INVARIANT GATE (primary).** For every
   non-identity-death edit in the operations corpus: the multiset of ids
   in the document and the full serialized attribute set of every
   unedited element are byte-identical before and after. For every
   identity-death edit: dying ids + minted ids exactly match the published
   death record, and id uniqueness holds document-wide. One fixture shape
   catches all 39 Swift bystander literals, the compound-shape duplicate
   id, and any future copy site no battery covers — and cannot be defeated
   by a new site appearing where no battery looks.
2. **Conformance is defined over the SHARED SERIALIZED FIELD SET** (the
   cross-language document encoding), not per-port struct reflection: the
   Theseus assertion is "serialize before, serialize after, diff — only
   the spoken-to keys may differ", one predicate both ports can fail
   identically. Necessary, not merely nice: the ports' struct vocabularies
   differ today (§3.5's `toolOrigin` note), so per-port reflection cannot
   even express the shared law. Per-port Mirror/whole-struct batteries
   remain as the inner, faster loop — with §3.1's anti-vacuity guard and
   geometry-value pairing mandatory in every one.
3. **The SUBJECT REGISTRY.** `workspace/effects.yaml` (+
   `schema/effect.schema.json`): one entry per `doc.*` effect carrying
   `speaks_to:`. Both ports' batteries derive their exempt sets from it;
   one corpus family asserts every registered effect has an entry, so a
   new effect cannot ship subject-less. Same YAML-declares/apps-implement
   grain as tools, panels, and the menubar. This converts clause 1 of the
   law from review-enforced to cross-port machine-checked.
4. **The STRUCTURAL Swift fix** (§3.1, grade (a) or (b)) so field omission
   stops being expressible, demoting per-API batteries to belt-and-braces
   and R3's "one battery per copy API forever" from permanent cost to
   one-time. And the standing rules, re-proven this round: neither
   compiler is the gate (Rust's forced enumeration was answered by hand
   with `None` at the Rect→Polygon arm — the fill-rule failure mode
   recurring, uncaught, at a cross-kind site); enumerate BOTH ports before
   reporting any class closed.

**RATIFICATION CONDITION — corpus visibility.** The identity law currently
has ZERO cross-language corpus coverage (gauntlet-verified three ways: no
gesture fixture reaches the severing arm or the N≥2 merge arm — FRESHIDS'
own commit message concedes it; a census of all 44 action goldens finds 5
element-id hits, all creation vectors; all four boolean vectors run on two
bare rects where every field this law legislates sits at its default). The
frontmost-id violation could be fixed, unfixed, or inverted between ports
without one golden moving. The machinery exists — both corpus runners
already install the deterministic mint override. Required before this law
is reported ENFORCED (distinct from ratified): (a) an attribute-rich
boolean setup SVG (ids, names, transform, mask, opacity, blend mode, fill
rule, gradient, width profile, stroke brush, tool origin); (b) gesture
vectors reaching the severing-erase and N≥2 merge arms; (c) id-FRESHNESS
assertions in the goldens.

---

## 5. What this law deliberately does NOT cover

1. **Creation-time identity (0→1).** No creation tool mints an element id
   today, by doctrine ("when creation-time ids land, they land for every
   tool at once"). This law governs *edits*; changing creation is a
   per-all-tools ruling. (The CITATION MINT, §3.8.2, is not an exception:
   it mints at first naming, which is an edit with `id` as its subject.)
2. **Sub-element identity** — anchors, tspans, per-output identity of
   multi-output live elements (LIVE_ELEMENTS.md §L6 names it the
   frontier). Element-granular terms; finer grain is unsurveyed. (SUPER-
   element granularity — set citation — is no longer silent: §3.8.4
   routes it through group identity and names the ungrouped limit.)
3. **Undo/redo — for document fields.** History traversal restores whole
   `(document, id_index)` snapshot pairs; a severing erase undone restores
   the ORIGINAL id — no re-mint is possible (attacked independently by two
   refuters; held both times). **Provenance is IN scope for undo**
   (§3.8.3): the journal cursor rewinds, lineage is cursor-relative, and
   the first draft's blanket exclusion was wrong by exactly that much.
4. **Clipboard and cross-document copies.** Copies are born id-less by the
   `clear_ids` doctrine — a copy is a creation, not an edit of the source.
   (Attack-tested: both ports' clear-id paths are field-preserving —
   in-place mutation in Rust, the preserving `withId(nil)`/`withChildren`
   struct methods in Swift; the exclusion is real, not a hole.)
5. **Collaboration/merge-conflict semantics.** `targets` is additive
   metadata; multi-author identity is deferred with Fork 4.
6. **Which fragment is "the ship."** Deliberately and permanently outside
   any mechanical rule — §3.7/§3.8 exist to hand that question, intact, to
   the artist or an assistant citing the artist.
7. **What the Arc-3 assistant may DO with lineage** (proposal contracts,
   citation etiquette). Starbuck's Arc-3 contracts block; this law only
   guarantees the substrate.
8. **The frozen ports and the flask renderer** (POLICY.md §1). Conformance
   is defined over `jas_dioxus`, `JasSwift`, and the corpus.
9. **Tool gating** adjacent to preservation — e.g. whether a LOCKED blob
   should be a merge candidate at all. Still the tool's own spec — but the
   law no longer pretends the boundary is clean: T6 (capability markers)
   is the piece of that boundary that IS this law's, because "preserve the
   marker" without a revocation quietly legislates tool behaviour forever.
10. **Grouping is NOT on this list any more.** The first draft was silent
    on containers; §3.4 now covers wrap/unwrap/compose. That silence was
    fatal finding F1.

---

## 6. Corrections to the brief and to the first draft

Where either was stale, imprecise, or — twice — wider than verified. The
first draft corrected the brief; the gauntlet corrected the first draft;
both layers are kept honest here.

1. **`path_erase_at_rect`'s `CommonProps::default()` is gone** (FRESHIDS
   `d14a9fdd`, `100faf86`; the brief was stale — this correction stands).
   But the first draft's replacement sentence — "at HEAD the verified
   *dropping* sites are Swift-side, and Rust's live violation runs the
   other way" — was FALSIFIED by the gauntlet: Rust's Rect→Polygon arm
   drops both gradients on a 1→1 edit **[read + driven]**, and Swift's
   `Document.withChildren` out-drops everything either port was known to
   drop. Corrected claim, no wider than the §3.5 table: both ports carry
   live dropping sites, and Rust additionally carries two live
   over-preservation/duplication sites (boolean frontmost-id;
   compound-shape Make). The law cuts both directions; the brief's
   "neither port is uniformly the generous one" was right after all.
2. **The eraser was certified conforming one sentence too widely.** Field
   preservation is landed; PLACEMENT is transform-blind (§3.2), so §3.2's
   and §3.4's first-draft verdicts were true about which fields survive
   and unverified about where the cut lands. The first draft applied its
   own mandatory-pairing lesson to the merge and missed the split. Had
   this shipped uncorrected it would have been the seventh consecutive
   round to ship one over-wide sentence; the gauntlet caught it at six.
3. **The blob brush's fill-rule handling is a LIVE DIVERGENCE from
   ratified law** — both arms, both ports (§3.5) — not a settled site.
   Worse, the first draft's §3.1 would have RATIFIED the 1-match arm's
   carry; T1's ring term now condemns it. Adjudication tier 4 applies:
   this outranks feature work.
4. **The N→1 attribute question is more settled than briefed** (the
   unanimity carry is ratified and landed, `4024216b`); open are exactly
   `name` (§3.3's choice), the `transform` conditional (now a three-member
   class), and the boolean/compound arms.
5. **"The op log drops id-less elements from journaled ops" is
   imprecise.** Element payloads round-trip value-in-op; it is the
   `targets:[common.id]` metadata — which seeds `capture_recipe` — that
   cannot name id-less elements. Mechanism: metadata, not op-dropping.
   The consequence for Arc 3 stood, and §3.8.2 answers it.
6. **Transcripts and comments lagging landed code or asserting falsehoods**
   for whoever next touches them: BLOB_BRUSH_TOOL.md step 6 (merge
   "carries no id"; unanimity UNRULED — both stale); BOOLEAN.md's banked
   note (blob 1-match arm as an open Theseus site — stale, though its
   fill-rule half is re-opened by correction 3); `withMask`'s doc comment
   in Element.swift asserts "all other fields … are preserved" directly
   above arms that drop seven — strike it when the arms are fixed.
7. **Swift's `pathWithCommands` family is closed**; the open copy-helper
   members are exactly `withMask` and `withWidthPoints` — plus, discovered
   this round, the Document-level `withChildren` and the inline
   Layer/Group literal class, which belong to no copy-helper family and
   are gated by §4.1 instead.
8. **A FALSE CLOSURE CLAIM IS IN PERMANENT COMMIT HISTORY.** Commit
   `cb7e2a78` ("PRESERVE: Swift — the last same-kind rebuilds in
   Element.swift go clone-then-mutate") states: *"After this commit pass
   (1) reports ZERO same-kind rebuilds in Element.swift. The only
   open-coded constructor sites left are the three CROSS-KIND
   promotions — Rect→Polygon in moveControlPoints, Line→Path and
   Polyline→Path in promoteToPathForBrush."* Both sentences are false, and
   one enumeration refutes both. Git history cannot be rewritten in place,
   so the correction lives here, and the §3.5 table carries the sites.

   **What was actually still open**, at that commit and at this one: FOUR
   same-kind `Path`→`Path` rebuilds — `withStrokeBrush`'s `.path` arm and
   its `.line`/`.polyline` arm, and `withStrokeBrushOverrides`'s two
   matching arms. That is SEVEN element-struct constructor sites in the
   file, not three. The two promotion arms are the sharpest: each restates
   all eighteen fields of the Path that `promoteToPathForBrush` produced one
   line earlier. Two further sites of the same shape sit outside that
   commit's stated "element-struct" scope but inside its sentence's scope:
   `Stroke.withWidth` and `Stroke.withLinecap`, 14 fields each, same file.

   **The method that found them**, so it can be refuted in turn: declaration
   boundaries by brace matching, then every UpperCamel-identifier-followed-by-`(`
   in the whole file treated as a candidate constructor call — not a
   name-scoped grep, and not scoped to the functions the earlier pass chose
   to look at — then each site read, and each site's argument labels
   balanced-paren-parsed and diffed against the struct's stored-property
   list. Its **blind spots**: scoped to `Element.swift`, because the refuted
   sentence was; classifies by SHAPE, and all seven element-struct sites
   were read but not every `Transform(` / `StrokeWidthPoint(` site; a
   rebuild expressed through `Self(…)`, a type alias or a generic factory
   would not match `Kind(`.

   **The severity, stated no wider than measured:** all six sites are
   field-COMPLETE today, so there is no live field drop and no §3.1
   violation at HEAD — this is the ungated SHAPE, which is what the class
   closure was about. `BrushHelperTheseusTests.swift` pins the four Path
   arms as of `acdacd94` (green on arrival, mutation-proved one site at a
   time, including the no-op over-reach that the `Mirror` walk is blind
   to). The conversion to clone-then-mutate is still owed, and the two
   `Stroke` sites are still unpinned.

   **The pattern, not the instance.** `cb7e2a78` was the fourth
   consecutive round to claim a class closed and be refuted by a later
   lens's own enumeration. Its own header said the method was stated "so it
   can be refuted"; the refutation is that the method's SCOPE was narrower
   than the sentence built on it. A closure claim must state both what the
   pass covered and what it could not see — and this correction's own
   blind-spot paragraph is the shape that costs.

---

## 7. The gauntlet record

Four refuters, four lenses: everyday gestures driven against HEAD;
mechanical enumeration of copy sites with probes compiled against both
built libraries; implementability and enforceability of every clause; the
Arc-3 ledger walked through a concrete apostles session. JYH should weigh
the law knowing what was thrown at it. Their full reports are in the
session record; this section is the disposition of every finding.

### 7.1 The four CONFIRMED_FATAL findings — each answered

**F1 — UNGROUP (enumeration lens).** The law classified Object > Ungroup
as 1→N: children's ids die, fresh mint, group's `name` stamped on every
child. The shipped code — correctly — does the opposite, and nobody would
ratify what the law demanded. **Answer: the law changed.** T5 (the arrow
counts material at stake; re-parenting is not consumption) plus §3.4
(wrap/unwrap/compose). The finding also surfaced a defect the first
draft's vocabulary could not express — ungroup DISCARDS the group's own
transform/opacity/mask instead of composing them — now on the repair queue
behind a named Captain's ruling (§8, question 2).

**F2 — BYSTANDER CONTAINERS (enumeration lens, driven against both built
ports).** Every element edit in the Swift port destroys its enclosing
containers' identity and blending state via the private
`Document.withChildren`; 39 of 41 inline Layer/Group literals omit `id`;
no clause of the element-local law reached any of it, and the per-copy-API
gate never would have — it would have reported the class closed over the
gravest violation in either port. **Answer: the law changed.** T4 (the
bystander clause) and §4.1 (the document-level invariant as the primary
gate). The site is entered in §3.5; the fix is the preserving
`withChildren` twins already sitting in Element.swift.

**F3 — KIND-CHANGING 1→1 EDITS (enumeration lens).** Three ratified
promotions change element kind; the law's narrow reading forbade them
("applying a brush speaks to `strokeBrush` alone — so the kind must be
preserved"), and "preserve the rest" was undefined in both directions
across a representation change. **Answer: the law changed.** T1's
representation term, T2's fourth shape, and the no-lossy-demotion rule —
which also reclassifies the boolean flatten's Polygon arm as a violation
(convergent with the implementability refuter's independent finding of the
same hole from the other side). One residue is genuinely the Captain's:
`rx`/`ry` disposition on the Rect→Polygon drag (§8, question 3).

**F4 — FILLRULE ON REGENERATED RINGS (implementability lens).** §3.1's
"preserve `fillRule`" applied to boolean survivors would re-fill holes the
artist never drew — the exact corruption the ratified generated-rings
ruling exists to prevent ("a hole they never drew" is the sentence that
won that ruling); the law could not distinguish a dragged anchor from a
re-derived ring set. **Answer: the law changed.** T1's ring term ("the
fill rule belongs to whoever made the rings"), the §3.6 fillRule column,
and correction 3 naming both blob arms a live divergence the first draft
would have canonized. The boundary reproduces ruled datum (a) unchanged —
confirmed independently by two other refuters' failed attacks on that
datum.

**None of the four was an argument that a clause was wrong; all four were
holes in the defined terms. The sentence survived all four.**

### 7.2 The 23 repairable findings — disposition ledger

Folded into the law, by destination: shadowing families (→T1); capability
markers (→T6); the predicate/delivery split — found independently by two
refuters, which is the strongest evidence in this section (→§3.7.2);
publish-with-open-subscribers (→§3.7.3); orphan findability (→§3.7.4);
the death record + the undeclared-id invariant (→§3.8.1, §4.1); the
citation mint (→§3.8.2); cursor-relative lineage + the undo-scope
correction (→§3.8.3, §5.3); set citation via group identity (→§3.8.4);
the parameterized/relative split (→§3.9); the eraser's transform-blind
status (→§3.2, §6.2); serialized-field-set conformance + the vocabulary
defect (→§4.2, §3.5); the effects.yaml subject registry (→§4.3); the
structural Swift fix (→§3.1, §4.4); battery anti-vacuity + naming
`FillRulePreservationTests` as the conversion target (→§3.1); corpus
visibility as a ratification condition (→§4); the Rect→Polygon gradient
row and the falsified first-draft sentence (→§3.5, §6.1); the
compound-shape duplicate id (→§3.4, §3.6); the Path→Polygon lossy
demotion (→§3.5, §3.6); the blob fillRule divergence (→§3.5, §6.3); the
arrow's range ambiguity (→T5); the name-unanimity variant (→§3.3, chosen
by JYH in §8); the cardinality-vocabulary term for grouping (→T5, §3.4).

Recorded as narrowed-in-form rather than adopted whole: TWO. The orphan
"last-resolved geometry with broken-link decoration" presentation is
offered to the panel spec, not mandated — selected-and-badged is the law's
minimum (§3.7.4). The Swift structural fix's grade — `var` properties vs a
CommonProps carrier — is left to the implementing session; the law
requires the structure, not the grade (§3.1). Rejected outright: NONE.

### 7.3 The 21 attacks that failed — what the law survived

Reported with the refuters' own verification, because a law that survived
four adversarial passes is stronger evidence than a law nobody attacked:

- **Live compound shapes cannot be blanked by an eraser stroke** —
  operands are OWNED (`CompoundShape { operands: Vec<Rc<Element>> }`, doc
  comment explicit), and the eraser walks only layer children, touching
  only `Element::Path`. The everyday non-destructive-boolean workflow
  never trips the reference clause; the genuine exposure is confined to
  `RecordedElement`'s by-id inputs, which §3.7 covers.
- **The blob merge's fresh sweep is not a unanimity voter** — sources are
  built exclusively from pre-existing matches; the new stroke's defaults
  cannot veto the artwork's customizations.
- **The blob 1-match arm does not flatten a translucent/CMYK source to the
  tool's colour** — the hex gate is a match criterion, not an equality
  guarantee; the source keeps its own paint, and the code comment argues
  the law's line unprompted. §3.1 holds at its hardest paint site.
- **Undo cannot re-mint** — whole-snapshot stacks including the id index,
  debug-asserted against a rebuild; a severing erase undone restores the
  ORIGINAL id. Attacked independently by two refuters; held both times.
- **The fill-rule datum is clean** — no shadowing sibling, no geometry
  parameterization, and no reset site at HEAD (`move_control_points`' Path
  arm and `simplify_selection` both conform). Attacked by two refuters
  from different directions; held. Dragging an anchor on an even-odd
  compound keeps the hole a hole — the clean case.
- **SVG round-trip preserves ids in both ports** (every shape writer plus
  group and layer writers, read in both) — the Arc-3 substrate survives a
  session boundary.
- **Clipboard/duplicate flows are truly creations** — both ports'
  clear-id paths are field-preserving; §5.4 is real, not a hole.
  **NARROWED 2026-07-27, twice, by driven counter-examples.** The sentence
  was true about FIELDS and read as wider than reality about IDENTITY: at
  the time it was written, `clear_ids` and `clearingIds()` both walked
  children only, so a copy of a COMPOUND SHAPE was born id-less at the top
  and id-DUPLICATING underneath — a compound's `operands` are not
  `children` (measured in both ports: `id_uniqueness VIOLATED … ["op_b"]`
  after `copy_selection` over a compound). Both walks now descend
  `operands` and mirror `Document::element_ids` / `Document.elementIds`
  (Rust: "clear_ids missed a compound's operands"; Swift: "Swift
  clearingIds was blind to a compound's operands"). Two things the reader
  should not infer from the repair: the flows are STILL corpus-blind at
  this property (both repairs landed with the preservation gate green —
  the pin needs a cardinality word for a duplicate, which no ruling has
  yet supplied; `scripts/corpus_manifest.json` gap
  `clear-ids-blind-to-compound-operands` carries the state), and PASTE is
  not one of these paths in either port (`clipboard_read_and_paste` /
  `EditClipboard.translateElement` copy the id verbatim) — both ports'
  doc comments used to claim it was, and both have been struck.
- **The `orphaned_references` call-site audit was exact** — five non-test
  sites per port, symmetric; extending the seam is bounded work, not a
  from-scratch build.
- **The boolean walk's transform-blindness was correctly stated and
  correctly not legislated ahead of S-3** — zero `transform` occurrences,
  independently recounted.
- **Every field-level site claim in the first draft's table re-derived
  independently with no overclaim found** — one understatement in the
  law's favour (`withMask`'s `.line` arm also drops `strokeGradient`),
  folded into §3.5.
- **JOURNAL-NOT-MODEL held under direct attack** — model-side successor
  pointers buy nothing the ledger cannot derive from history, at the price
  of purpose-claims in geometry and byte-gate replication in every port
  forever; and they dangle one level up when successors are edited away.
- **"Citation demands identity survive a merge" fails hard** — an id that
  followed the hull into hull-plus-mast would let the assistant cite a
  ruling against artwork it no longer describes, silently and with full
  confidence: unfalsifiable from the artist's side, strictly worse than
  losing the handle. Identity death at N→1 is right; the ledger is owed
  the receipt, not the survival.
- **The 1→1 clause carries the session** — reshape, restyle, transform,
  mask, width, fill-rule edits are the overwhelming majority of a working
  session and all preserve id BY LAW; the law spends identity only where
  the artist genuinely changed the count. The right budget.
- **Name-copy to fragments producing two "hull"s is intent, not defect** —
  ambiguity that hands the artist a choice is what the law reserves; two
  candidates the assistant can ask about beats zero. It is also the one
  lineage channel that survives a split at HEAD — which is exactly why the
  merge-side name question (§3.3) is the sharpest one left to JYH.
- **The Mirror battery pattern is viable across kinds** (probed with
  swiftc; caveats folded into §3.1); the Swift structural precedent exists
  in-tree (`LiveVariant.withMask`); symbol-detach is vacuous today (every
  `detach` in the codebase is panel-layout); and **the twice-rejected
  largest-fragment rule has NOT crept back anywhere** — no float
  comparison sits in any identity path in either port. The two
  over-preservation sites elect by z-order, a different wrong rule and one
  the law already forbids by name.

### 7.4 What is in flight, restated (a census is a photograph)

S-3 (transform-blind blob merge) and the eraser/boolean members of its
class (§3.2, §3.3); S-4 (leading-Z no-op); S-2 (linear gradient stop
remap — §3.9's geometry-relative class). The `transform` rejoin remains
CONDITIONAL on S-3. Nothing in this freeze blocks on them; two clauses
schedule work behind them.

---

## 8. THE RATIFICATION ASK

**The single ruling requested: ratify THE PRESERVATION LAW — the sentence
of §1 with the six defined terms of §1.1 — as the edit-semantics
constitution beside the cardinality law.** Ratifying it carries these
consequences as one package, each a clause's direct application rather
than a separate decision:

- the §3.5 violation table becomes the repair queue, ordered by the
  adjudication hierarchy — the LIVE DIVERGENCES from already-ratified law
  (blob fillRule, both arms both ports; the boolean survivors' multi-ring
  exposure) outrank feature work; the Swift `withChildren` bystander
  destruction and the compound-shape duplicate id are the gravest new
  entries;
- §4's enforcement doctrine: the document-level invariant gate (primary),
  serialized-field-set conformance, the `workspace/effects.yaml` subject
  registry, and the structural Swift fix;
- §4's RATIFICATION CONDITION: the law is not reported ENFORCED until the
  corpus can see it (attribute-rich boolean setup SVG; severing and N≥2
  merge gesture vectors; id-freshness assertions);
- the two amendments now derived from defined terms: gradients-as-paint on
  boolean output (T1's shadowing corollary) and `name` joining the
  unanimity carry (§3.3, variant per question 1 below);
- the conditional: `transform` joins the unanimity carry after S-3 lands,
  one commit with its fixture, the sweep covering all three
  transform-blind members (merge, boolean walk, eraser placement);
- the CITATION MINT (§3.8.2): naming is minting — the ledger joins
  references and symbols as a lawful id-minter, at first naming, never at
  birth; and the DEATH RECORD (§3.8.1): no identity leaves the document
  without a receipt.

**Three questions genuinely the Captain's, not decided here.** Each can be
ruled now or returned to; the law stands either way, with the stated
interim:

1. **`name` at a merge — STRICT unanimity, or ASSERTING-SOURCES?** (§3.3.)
   Starbuck recommends asserting-sources: the only assertion present
   survives; nothing geometric elects it. Interim until ruled: `name`
   stays out of the carry (today's behaviour), and the death record is
   the ledger's only handle across a merge.
2. **Lossy UNWRAP — when a group's mask/isolation/knockout cannot compose
   exactly into its children, is Ungroup refused, warned, or deliberately
   lossy?** (§3.4.) Starbuck recommends warned — §3.7's delivery seam
   already gives the mechanism. Interim until ruled: exact-compose cases
   proceed; inexact cases keep today's discard, which this freeze names a
   live defect awaiting the ruling rather than behaviour anyone chose.
3. **Rect→Polygon `rx`/`ry` — what does the ratified corner-drag promotion
   do with corner rounding?** (T1's source-only-field rule requires the
   spec to say; today it discards silently.) Starbuck recommends:
   rounding is flattened into the emitted points — WYSIWYG at the moment
   of promotion — but this is artwork semantics, and the artist-surprise
   call is the Captain's.

---

*Trailer for the ratification record: this freeze restates and depends on
rulings of 2026-07-26/27 (cardinality, fill-rule preserve, unanimity
carry, generated-rings fill rule, adjudication hierarchy). It was
refuter-gated: four adversarial passes; four fatal findings, all answered
by new defined terms rather than by defending the indefensible;
twenty-three repairs folded (two narrowed in form, none rejected);
twenty-one attacks withstood and recorded. It changes no code.*


---

## RULED 2026-07-27 (JYH): THE BINARY CODEC'S SEVEN DROPPED FIELDS

The binary (msgpack) codec drops `common.mode`, `common.mask`, `common.tool_origin`,
`fill_gradient`, `stroke_gradient`, `stroke_brush` and `stroke_brush_overrides` — in
**both ports**. Save as binary, reload, and they are gone. Under this law that is
unambiguous: **a round trip speaks to nothing, so it must preserve everything.**

**RULED — the format shape:** **per-tag trailing append, tolerant reads, NO VERSION
BUMP.**
- `unpack_common` reads FIXED indices and every variant's payload starts at index 7,
  so the common block cannot be extended once — it must be extended **per element
  tag**, with a per-tag arity table mirrored in both ports.
- **`VERSION` stays at 2.** `MIN_VERSION` is also 2 and readers reject
  `version > VERSION`, so bumping to 3 would make the FROZEN ports unable to read
  anything the active ports write. They are tag-pinned canaries and orphaning them
  costs a real signal. This is the same reasoning that settled the `fill_rule`
  slot-11 decision, verified then to work across all four ports because neither
  frozen reader validates array length.
- **Tolerant reads** (`arr.get(n)` -> documented default when absent): an old blob
  loads correctly, and a new blob loses only the new fields in an old reader —
  honest degradation. The format has grown trailing slots twice before (document
  index 3 for `symbols`, `TAG_LIVE` slot 9 for the instance transform), so the
  mechanism is established, not novel.

### IMPLEMENTED 2026-07-27 — five of the seven, and the gate

**What landed.** A per-tag trailing extension block, exactly as ruled:
`common.mode` (an integer tag 0..15 in `BlendMode`'s declaration order),
`common.mask` (`[subtree, clip, invert, disabled, linked, unlink_transform]`,
where the subtree is a full nested element) and `common.tool_origin` on
**every** element tag, plus `stroke_brush` and `stroke_brush_overrides` on
`TAG_PATH`. `VERSION` is still 2. Every slot is always written, so each tag's
arity is constant and can be asserted. Reads are tolerant: an absent slot, a
nil slot and a wrong-typed slot all read as the documented default, which is
the contract the `fill_rule` slot established. One model asymmetry, documented
rather than papered over: Rust carries `tool_origin` on every element's
`CommonProps`, JasSwift only on `Path`, so JasSwift writes nil in that slot for
the other eleven tags — the same shape as its existing `name: nil` for the live
variants. A value a port cannot hold is a value it cannot lose.

**Verified by measurement, not argument, that the frozen readers survive it.**
The frozen Python reader (`jas/geometry/binary.py`, read-only, never edited)
decodes all four new pinned blobs. The frozen OCaml reader was **read, not
run**: `jas_ocaml/lib/geometry/binary.ml`'s `unpack_element` indexes with
`List.nth` at fixed positions and validates no length, so trailing slots are
ignored — stated at reading-strength, deliberately.

**What did NOT land, and why it is banked rather than guessed.**
`fill_gradient` and `stroke_gradient` are still dropped. The wire mechanism is
not the obstacle; the two ports' models are. `jas_dioxus`'s
`GradientStop.color` is a `Color` (f64 channels, rgb/hsb/cmyk, with alpha);
`JasSwift`'s is a hex `String` — a divergence
`test_fixtures/algorithms/gradient_remap.json` already records. Measured this
wave: encoding the stop colour as the codec's existing colour array is lossless
in Rust but **normalises** the Swift string (`"#ff0000"` returns as
`"ff0000"`), while encoding it as a hex string is lossless in Swift but
**discards** a Rust hsb/cmyk stop colour and its alpha. Byte-identity across
the ports therefore requires a canonical form, and choosing which port
normalises is an artwork call with a real cost either way. Under the
adjudication hierarchy that is a ruling, so it is banked with its evidence in
`test_fixtures/expected/codec_field_survival.json`.

**The gate found a live divergence on its first run — the justification for
building it, not a bonus.** `jas_dioxus`'s `pack_tspan` writes **fifty-one**
slots per tspan; `JasSwift`'s `packTspan` writes **twenty-two**, and its
`unpackTspan` reads only 22. The two ports have never written the same bytes
for any `Text` or `TextPath`, and JasSwift's binary codec drops 29 tspan fields
on a round trip although its own `Tspan` struct holds every one of them. It was
invisible for precisely the reason this gate was ruled: the existing codec
gates compare canonical test-JSON strings, the Python-fixture gate reads
Python-written bytes, and both ports read trailing slots tolerantly, so each
round-trips its own blobs and neither notices the other's. It is **pinned**, not
fixed, as `port_hex.swift` on the `text_default` case; closing it deletes the
entry, so it cannot rot into a silent suppression.

**A third finding, same gate.** JasSwift's `Text(x:y:content:…)` and
`TextPath(d:content:…)` convenience initializers *accepted* `blendMode:` and
`mask:` and forwarded **neither** to the tspans-bearing init, so both were
silently discarded at construction — the Swift copy-site omission class again.
Fixed. A mechanical enumeration of every delegating `public init` in
`Element.swift`, `LiveElement.swift` and `Tspan.swift` found exactly those two
sites and no others; the method's blind spots are non-public inits and
non-delegating rebuild sites, which it does not see.

**Still open in the codec, stated so the next reader does not have to
re-derive it.** The binary codec also drops, outside this ruling's scope:
`isolated_blending` and `knockout_group` on **Group** in both ports (and on
**Layer** in Rust, where JasSwift's `Layer` has no such field at all — a model
divergence, not a shared codec drop); `fill` and `stroke` on a live
CompoundShape (both readers hard-code `None`, both writers omit them); and
eleven `TextElem` / `TextPathElem` fields
(`text_transform`, `font_variant`, `baseline_shift`, `line_height`,
`letter_spacing`, `xml_lang`, `aa_mode`, `rotate`, `horizontal_scale`,
`vertical_scale`, `kerning`). Read from the two writers on this commit, not
driven. They are shared defects, so no equivalence gate can see them; the byte
gate cannot either, because both ports omit the same slots.

**RULED with it — the byte-level gate lands at the same time.** Measured by an
earlier wave: **every codec gate compares canonical test-JSON strings, and the fields
the binary codec drops are a strict SUBSET of the fields that string oracle also
drops.** So no fixture can red-light a binary drop today, and a one-port slot
mismatch in `pack_element` would land SILENTLY. The repair therefore needs a
**byte-level binary comparison**, not the string oracle — otherwise we would be
extending a format whose divergences we cannot see. Coverage gap
`codec-string-oracle-cannot-see-a-dropped-field` is the record of that.
