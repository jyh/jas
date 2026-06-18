# Recorded Live Elements — history-based parametric modeling

The novel, artist-direct live-element provenance (`LIVE_ELEMENTS.md` §4): promote a
segment of the operation-log into a Live element whose generator is "replay these
operations against the current inputs." A demonstration becomes a live relationship.

> The eye: the artist selects an eye in a portrait, copies it, reflects the copy, and
> moves it into place. We capture `copy(eye) → reflect → move` as a recorded generator
> with the original eye as its input. Edit the original eye and the reflected copy
> re-derives live.

This is the **whole reason the operation-log spine (`OP_LOG.md`) exists**, and the
keystone of the `VISION.md` liveness-everywhere goal. It builds on: stable element ids
(`VISION.md` §10 item 1 — shipped), the typed journal + cursor (OP_LOG Increment 2 —
shipped), the `LiveElement` trait + dependency graph + cache-equivalence
(`REFERENCE_GRAPH.md` — shipped, two conformers: `CompoundShape`, `Reference`).

---

## 1. Capture is journal-segment selection — not a "recording mode"

A recipe is the op-segment between two journal cursor positions:
`capture_recipe(ancestor_head, descendant_head) → normalized op list`. There is no
special recording mode — there is the journal, and two ways to choose the bounds:

- **"Watch what I do"** (prospective) — mark the ancestor at start, the descendant at stop.
- **"Watch what I did"** (retrospective) — scrub the journal history afterward and pick
  both bounds. This rides the journal's **uncapped retention** (the undo stack caps at
  `MAX_UNDO = 100`; `op_journal` is a separate uncapped artifact, OP_LOG §8 item 5), so
  it can reach segments older than undo can. The 3a version/journal navigation is its
  picker UI.

Both feed the identical `Recorded` mechanism below; the bounds-picker is the only
difference.

---

## 2. The `Recorded` LiveVariant

A third `LiveVariant` (alongside `CompoundShape` and `Reference`), conforming to the
existing `LiveElement` trait so the resolver / dependency graph / cache-equivalence
machinery handles it unchanged. It stores:

- `ops` — the **normalized, input-addressed** op-segment (§4), replayed verbatim in
  intrinsic order.
- `inputs: [common.id]` — the source element id(s) the recipe rebinds against.
- `id` — the recorded element's own `common.id`, used to derive output ids (§5).
- `params` — the bound constants (the trace's literals; §3).

`evaluate_with(precision, resolver, visiting)` resolves the `inputs` (dangling/cycle →
empty result, never a panic — `REFERENCE_GRAPH.md` §3), replays `ops` against them into
a scratch document, and returns the produced geometry/elements. Output is value-equal
across apps (equivalence pinned on OUTPUT, `LIVE_ELEMENTS.md` §2 / `VISION.md` §3).

---

## 3. Trace → function (the hard part) — the deterministic MVP

A recording is concrete ("reflect about x=412.7", "move by (37,−12)"). A reusable
generator must know which op args are **inputs** (rebind by id), which are **bound
constants** (literal), and which are **derived** (recompute relative to the input). The
trace alone cannot say; only intent can.

- **MVP (no AI, `VISION.md` §7 buildable tier):** the artist marks the input(s), or we
  infer "the first element the segment reads." Everything that traces to that input is
  rebound by id; everything else stays a literal constant. Predictable default —
  reflected *geometry* updates live, the *placement* stays put. Ships the eye example.
- **Fitter upgrade (frontier, §5 / `VISION.md` §6.3):** detecting which constants *want*
  to be relative, or extracting named parameters, is the AI-assisted fitter — deferred.

---

## 4. Normalization & the replay-safe subset

Replay must be a pure, deterministic function of inputs (`OP_LOG.md` §7):

- Ops reference inputs by **stable `common.id`**, never by value or tree-path-at-capture
  ("copy element X" means "copy whatever X *is now*").
- **No hidden tool/selection state.** Selection-relative ops (`select_rect` then
  `move_selection`) are normalized at capture to a closed, input-addressed form
  (`move([those ids])`).
- The recorded generator draws from a **replay-safe subset** of the op vocabulary:
  input-addressed, side-effect-free, and with **no op that mutates another Live
  element's generator** (that op is rejected at capture — it is what prevents
  generator-level cycles the dependency-graph cycle-break does not catch). One
  vocabulary at two levels: the edit surface for all Live elements, and a restricted
  generator language for the recorded kind (resolves former fork L5).

---

## 5. Derived output ids

`REFERENCE_GRAPH.md` §4 mints element ids non-deterministically (per-app, not by shared
fixture), so a recipe that *minted fresh* output ids each replay could not keep stable
output identity, breaking downstream liveness. Recorded-generator **output ids are
derived deterministically** from `(the recorded element's own id + a position-in-trace
counter)` — e.g. `<id>/0`, `<id>/1`, …. Sorted-id ordering (the §8 trap) governs only
*set-valued recompute*; the trace's own op order is intrinsic and replayed verbatim.

---

## 6. Boundary: element-granularity is v1

Stable ids solve the topological-naming problem at the **element** level (we have them);
they do **not** yet exist for sub-element entities (anchor points, path segments). So
**element-granularity recipes (the eye — a whole element) are safe now; control-point-
granularity recipes are the frontier** and are deferred (`LIVE_ELEMENTS.md` §4).

---

## 7. The op-capture dependency, and the A-then-B plan

A recorded recipe *is* a journal op-segment — but production transactions are currently
**opaque** (whole-document writes; only the `apply_op`/fixture path records real ops).
So capture from a real demonstration (either "do" or "did") needs the journal to carry
real ops, which is the deferred `apply_op`↔`actions.yaml` unification. Chosen sequencing:

- **3b-A — the mechanism (this increment).** Build the `Recorded` LiveVariant, the
  `capture_recipe(ancestor, descendant)` primitive, normalization, the deterministic
  mark-input rule, derived output ids, and `evaluate_with` replay. Prove it on the
  **op-vocabulary path** — the eye demo as a cross-language fixture (ops supplied via the
  existing vocabulary, captured into a journal segment, promoted to a `Recorded`
  element, source edited, output re-derived). Mode-agnostic and load-bearing.
- **3b-B — production op-capture (follow-on).** Make production edits journal real ops
  (at least the replay-safe subset), so "watch what I do" and "watch what I did" become
  real-edit features wired to the live UI. Larger; the shared unblocker for both modes.
  **Concrete v1 scope + deferred follow-ons live in `OP_LOG.md` §9 (Increment 3b-B):**
  promote `apply_op` → a shared runtime `op_apply`, adopt it from production for the
  three replay-safe verbs (`select_rect`/`copy_selection`/`move_selection`) with
  `targets:[common.id]` + `name_txn`; the Layers-panel and artboard "Duplicate" gestures
  and the other ~30 `doc.*` verbs are explicitly postponed there.

---

## 8. Cross-language plan

Reuse the OP_LOG harness wholesale. The `Recorded` element + its replay are pinned by a
fixture whose golden is the **re-derived output document** after editing the source —
byte-compared via `document_to_test_json` across the four native apps (Flask has no live
subsystem, `LIVE_ELEMENTS.md`). The recipe's serialized form (`ops` + `inputs` + id) is
pinnable the same way the journal artifact is. Rust first, then Swift → OCaml → Python
(per CLAUDE.md), each independently re-verified.

---

## 9. Open questions

- **`release` semantics for a recorded element** (carried from `LIVE_ELEMENTS.md` §12 /
  `OP_LOG.md` §12): what "release" means when the source is an op-trace, not a static
  operand set, is undefined. Defer until expand/release is exercised on a recorded kind.
- **Multi-input recipes** beyond the single marked input — the MVP infers/marks one;
  multiple inputs (and which constants are derived from which) is the fitter's job.
- **Whole-segment vs sub-segment capture** when the journal segment includes unrelated
  edits — the MVP captures the contiguous span; pruning to only the ops that touch the
  input is a refinement.
