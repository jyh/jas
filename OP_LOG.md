# Operation Log — the transaction spine

**Status:** design locked (2026-06-17), unbuilt · **Implements:** `VISION.md` §10
critical-path item 2 ("the operation/transaction log formalized as the atomic,
reversible, summarizable unit") · **Relationship to other docs:** it is the `VISION.md`
§5 item 5 "operation log is the spine" foundation; it generalizes today's boolean+simplify undo
grouping; it is the generator language for the **recorded** provenance in
`LIVE_ELEMENTS.md`; and it carries the §6.9 versioning / collaboration substrate.

A naming note (as everywhere): this is a **vector illustration application**; we never
name a commercial product.

---

## 1. Why one structure

A single structure must serve **four** consumers — which is what makes it a spine, not
just better undo:

1. **undo/redo** — what exists today.
2. **capture/replay test fixtures** — record the seam once; replay across all apps;
   delete manual testing (`VISION.md` §9 regime 2).
3. **the AI action surface** — every change is a *named operation in the artist's
   vocabulary*, legible and summarizable, committed through the same gate as a human
   (`VISION.md` §6.1/§6.10): the AI has no privileged mutation path.
4. **versioning + future collaboration** — a version is a labeled point in the op
   stream; collaboration is merging op streams (`VISION.md` §6.9).

Get the record shape right once and all four fall out. Get it wrong and we pay a format
break across five apps and the whole fixture corpus.

---

## 2. The locked decisions

These five forks were decided (2026-06-17); the rest of this doc elaborates them.

| # | Fork | Decision |
|---|---|---|
| 1 | Source of truth | **Co-equal:** keep snapshot-undo as the O(1) *mechanism*; layer a typed Transaction **journal** on top; keep them honest with a **mandatory** per-fixture `replay == snapshot` gate. Not event-sourcing; not a passive sidecar. |
| 2 | Undo-law fixture migration | **Explicit reshape** of the snapshot/undo/redo-bearing fixtures into transaction-boundary form, landed in all four native harnesses **together** (auto-wrap is impossible — see §9). |
| 3 | Consolidation timing (`VISION.md` §11 "consolidate to one mutation path") | **Consolidate first, then journal.** Funnel *all* mutation through one enforced chokepoint *before* any recording, so the journal is complete by construction (no "this path isn't journaled yet" asterisk in canonical history). NOTE: the surface is ~148 `set_document` call sites across 13 files, not just the two effect runners (§9). |
| 4 | Op addressing | **Id-address operands + record `targets:[common.id]` from v1**; selection-relative ops keep working **and stay in the transaction verbatim** (selection is serialized Document state, so the byte-gate requires reproducing it — `targets` is additive metadata, not an op rewrite); defer only the full "ops take ids as primary args" rewrite. Recorded recipes (`LIVE_ELEMENTS.md`) break under input edits if ops are path-keyed, so this is load-bearing, not a merge nicety. |
| 5 | Scope: Flask + the third vocabulary | Flask pins **forward-replay + serialization only** — its client-side JS engine (`jas_flask/static/js/engine/`) has a `Model` with undo/generation but no native interactive editor driving transactions, and its `doc.snapshot` effect is a placeholder no-op (`effects.mjs`). The layout-op vocabulary (`apply_workspace_op`) folds under **one `Op` trait eventually** (tracked, not now), so a third op model does not entrench against `VISION.md` §5 item 1. Increments 1–3 journal **document** ops only; layout ops stay on `apply_workspace_op`. |

---

## 3. Where we are today (grounded)

- **Undo is whole-Document snapshots, not ops.** Each native Model owns
  `undo_stack`/`redo_stack` of full `Document` values (Rust/Swift/OCaml pair each with
  its `IdIndex`), capped at `MAX_UNDO = 100`. `snapshot()` clones the current document,
  trims, and clears redo; `undo`/`redo` swap whole states. There is **no recorded op or
  delta** anywhere in the runtime. Clones are cheap only because subtrees are `Rc`/CoW
  shared.
- **"Grouping" is a convention, not a bracket.** The boolean+simplify single-undo that
  `VISION.md` §10 names is achieved by calling the second mutation with
  `take_snapshot = false` so it does not push a second snapshot. No transaction object,
  no nesting, no group id.
- **An embryonic op-log already exists** — as the cross-language equivalence harness.
  `test_fixtures/operations/*.json` are JSON op-streams (`{"op":"move_selection",
  "dx":..,"dy":..}`) replayed by a per-app `apply_op` dispatcher (**~20 verbs** in the
  Rust document dispatcher — `snapshot`/`undo`/`redo` are themselves ops there) and
  byte-compared via `document_to_test_json`. (The layout `apply_workspace_op` and the
  algorithm hit-test dispatch are *separate* dispatchers, consistent with Fork 5 — not
  counted here.) **This is the format the spine becomes — we promote it, not replace
  it.**
- **The mutation surface is wide, and Rust has two effect *interpreters*** (the
  consolidation problem): `renderer.rs` operates the YAML effect vocabulary on
  `AppState`, `effects.rs` on `StateStore`/`Model`. But beyond those, **~148
  `set_document` call sites span 13 files** (also `menu_bar`, `keyboard`, `clipboard`,
  the type tools, `yaml_tool`, and inside `controller.rs`); `snapshot()` itself is
  issued from many native sites (e.g. ~16 direct `tab.model.snapshot()` calls in
  `renderer.rs`), while `actions.yaml` declares only a couple of `doc.snapshot`
  effects. So "one mutation path" (Fork 3 / increment 1) means funneling all of these
  through one enforced chokepoint — substantially more than merging the two
  interpreters.
- **Dialog Preview is an out-of-band channel.** `preview_doc_snapshot` (capture / restore
  / clear) deliberately bypasses undo — the precedent for "mutations excluded from the
  journal," and the template for the AI propose-then-commit gate (§8).

---

## 4. The design

Keep the whole-Document snapshot stacks **exactly as they are** as the O(1) undo/redo
mechanism. Layer a typed **Transaction journal** on top as the legible / replayable /
mergeable artifact. Keep the two honest with a **mandatory gate**: for every fixture,
replaying the journal from the checkpoint must serialize byte-identical to the
snapshot-path document.

- Not **event-sourcing** (journal-as-truth): that pays the full tax (the log is
  untrustworthy until every path brackets) and keeps two reversibility models
  convergent, for coverage the gate already buys.
- Not a **passive sidecar** (snapshot-as-truth, journal advisory): an incomplete op
  would pass every undo fixture undetected. The gate makes faithfulness a
  compile/test-time guarantee, which is the antidote to this project's signature
  "dead-but-green CI" failure mode (`VISION.md` §4).

The op vocabulary does **double duty**: it is the edit surface for every mutation
**and** (for `LIVE_ELEMENTS.md`'s recorded provenance) a generator language — though a
recorded generator draws only from a **replay-safe subset** of it (side-effect-free,
input-addressed, no op that mutates another Live element's generator;
`LIVE_ELEMENTS.md` §4 / fork L5), not the full vocabulary. Build it once here; reuse
the subset there. Promoting `apply_op` from `#[cfg(test)]` into a runtime `op_apply`
module makes live-edit, replay, and the future AI **one code path**.

---

## 5. The record shape

Plain JSON (same portability discipline that made `common.id` portable), canonicalized
with the `document_to_test_json` sorted-key / fixed-float rules so the journal file is
itself byte-pinnable.

**Primitive op** — a superset of today's fixture op (existing keys unchanged, so the
existing operations fixtures keep replaying):

```
{
  "op": "<verb>",            // the existing apply_op verb inventory, verbatim
  ...flat params...,         // literal payload as fixtures use today (dx/dy, path:[..],
                             //   transform:{a..f}, id, char_start/char_end/...)
  "targets": ["<common.id>", ...]   // Fork 4: resolved ids of elements read/written,
                             //   captured from v1 (recipe-safe + merge conflict detection)
}
```

**Transaction** — the atomic / reversible / summarizable unit (`VISION.md` §10 item 2);
*replaces* snapshot-boundary grouping. `snapshot`/`undo`/`redo` are **reclassified as
history navigation** and removed from the op vocabulary.

```
{
  "txn": "<8-char base36 id>",   // minted via the seeded-rng seam at the chokepoint,
                                 //   NEVER inside a Controller (§7)
  "name": "<actions.yaml verb>", // artist/AI-legible op name → the semantic-summary surface
  "ops": [ PrimitiveOp, ... ],   // ordered; boolean_union = {name, ops:[boolean_op, simplify]}
  "summary": "<human text>",     // optional; else derived from name + targets + actions.yaml
  "actor": "artist|ai|peer:<id>",// reserved now (cheap; expensive to retrofit)
  "parent": "<txn|null>",        // causal edge → widens to a parent-set for a merge DAG
  "lamport": <int>,              // logical clock → widens to a {actor:int} vector clock
  "label": null | "<version>"    // non-null = a labeled point in the stream (versioning)
}
```

**The journal cursor.** The journal is `op_journal: Vec<Transaction>` plus a
`journal_head` index — a **cursor**, not a high-water mark: `commit_txn` truncates the
journal at `journal_head` and appends (so a new edit after undo drops the redo tail),
`undo` decrements it, `redo` increments it. `saved_journal_head` is captured at save.
The unified `is_modified` is exactly `journal_head != saved_journal_head` — which makes
"undo back to the saved point ⇒ not modified" true (see §9 for the per-app churn this
implies). The journal, `journal_head`, and `saved_journal_head` are **per-document**
(per tab), like the undo stacks today; cross-document merge therefore needs a document
identifier, which `targets:[common.id]` does not yet carry (deferred with collaboration).

**Session fixture** — strict superset of today's `{name, setup_svg, ops, expected_json}`;
the capture/replay + version artifact:

```
{ "name":..., "setup_svg":..., "txns":[ Transaction, ... ], "expected_json":"golden.json" }
```

A bare legacy `"ops":[...]` reads as one implicit anonymous transaction during
migration — **except** where the ops embed `snapshot`/`undo`/`redo`, which must be
explicitly reshaped (§9), not auto-wrapped. **Scope:** a fixture is **single-document**
in v1; a real interactive *session* also spans tabs, clipboard, tool state, and layout —
capturing that multi-document envelope is deferred (only the document journal is in v1).

There is **no `transient` field**: preview / out-of-band mutations bypass `begin_txn`
entirely and produce no Transaction — that bypass *is* the enforced out-of-band channel
(§8). An empty transaction (zero ops, or one whose net document change is byte-identical)
is **not journaled** — see the `commit_txn` no-op rule in §9.

---

## 6. The mandatory gate (`checkpoint_equivalence`)

The load-bearing honesty mechanism. In **every** operations fixture, from the increment
that introduces the journal: replay the journal from `setup_svg`, serialize, and assert
**byte-identical** to the snapshot-path `document_to_test_json`. It must never be
skippable — if it is ever made optional, the co-equal design's guarantee evaporates and
we are back to "dead-but-green."

This is the same *spirit* as the reference graph's `index == rebuild` and
`cached == fresh` debug-asserts — a per-run proof carried by the whole suite rather than
spot-checked — though stronger: those check a one-directional derived cache against its
source, whereas this reconciles two **co-equal** representations (snapshot and journal).

---

## 7. Determinism & id rules

Replay must be a pure, deterministic function of inputs (`VISION.md` §8):

- **`txn_id` minting** happens at the chokepoint, **never inside a Controller**
  (Controllers take ids as params — the rule already exists because the codebase was
  bitten by entropy-during-replay). Cross-language byte-pinning is the subtlety:
  `REFERENCE_GRAPH.md` §4 locks element-id rng minting as *per-app, not shared-fixture*,
  so a journal carrying live-minted `txn_id`s would **not** byte-compare across apps.
  Fixtures must therefore mint `txn_id` from a **deterministic counter under replay**
  (e.g. `txn-0`, `txn-1`, … — exactly how `element_ids.json` pins element ids as
  `rect-0`/`group-0`, not random base36), so the journal file is byte-shareable; live
  runs draw entropy. (Open: counter vs excluding `txn_id` from the byte compare — §12.)
- **Recorded-recipe output ids are *derived*, not minted** (from `LIVE_ELEMENTS.md`):
  because minting is per-app non-deterministic, a recorded generator derives its output
  ids deterministically from `(the live element's own id + position-in-trace counter)`,
  so replay keeps stable output identity and downstream liveness survives.
- **Ordering**: sorted-id order for any *set-valued* recompute (the §8 trap — never
  hashmap order); a transaction's `ops` are intrinsically ordered and replayed verbatim.
- **No hidden state, but do NOT normalize selection away.** Selection-relative ops
  (`select_rect` then `move_selection`) keep their inputs reproducible, but selection is
  itself serialized `Document` state (and `undo_redo_laws.json` exercises the
  select+move pair), so dropping the `select_rect` op and rewriting to `move([ids])`
  would make the replayed document's selection differ from the snapshot path and **fail
  the byte-gate**. So the transaction keeps the selection op verbatim; `targets:[id]`
  (Fork 4) is additive metadata recorded *alongside*, for recipe-rebind and merge
  conflict-detection — never an op rewrite.

---

## 8. Keep-ready — design in now, build later

Cheap now, expensive to retrofit across five apps + the fixture corpus, so they ship in
the **first** pinned format even though collaboration/versioning land much later:

1. **Causal metadata on every Transaction** — `txn_id`, `parent` (single edge now →
   parent-set later), `lamport` (scalar now → vector clock later), `actor`. ~4 fields.
2. **`targets:[common.id]` on every primitive op** (Fork 4) — gives merge conflict
   *detection* and semantic summaries now; the path→id-*primary* flip is deferred but the
   field that enables it ships now.
3. **`label` on Transaction** — non-null marks a version point (`VISION.md` §6.9); free
   later.
4. **The out-of-band channel + the AI accept path** — the preview-snapshot bypass is the
   *one* sanctioned non-journaled path and the template for the AI propose-then-commit
   gate. Concretely: the AI proposes into the preview snapshot (no Transaction); on
   **accept**, the proposed edits are replayed through `begin_txn`/`commit_txn` into a
   single Transaction with `actor: "ai"` (legible + summarizable like any other); on
   **reject**, `restore_preview_snapshot` discards them. In a later increment, make
   `set_document` assert "inside an open transaction OR the preview flag," so that bypass
   is the only unguarded path — primacy enforced by construction.
5. **Retention/compaction decoupled from `MAX_UNDO`** — the undo *checkpoint* stack stays
   capped at 100, but journal retention (for versioning) is a separate policy; design the
   truncation (drop old ops, keep a coalesced baseline) identically in all apps from the
   start, or replay-from-origin diverges where the gate isn't looking.
6. **Persistence** — undo stacks are **not** persisted to disk today (session-only).
   Keep the journal **session-only in increments 1–3**; journal-to-disk arrives with
   versioning, so the on-disk format is settled deliberately, not by accident now.

---

## 9. The increment plan

Each increment is independently CI-green; write tests first (CLAUDE.md).

- **Increment 1 — mutation-path consolidation (Rust; zero behavior change; no journal
  yet).** Bigger than "merge two runners": make `set_document` (+ `snapshot`) the single
  **enforced** chokepoint and route **all ~148 `set_document` sites across 13 files**
  through it — the two effect interpreters (`renderer.rs`/`effects.rs`) plus the native
  callers (`menu_bar`, `keyboard`, `clipboard`, the type tools, `yaml_tool`, and the
  in-`controller.rs` `snapshot` at the boolean+simplify site). Verify the other three
  native apps are already single-path. Pinned by the existing suite + the 32 operations
  fixtures. **Trap:** when `snapshot` moves under the chokepoint, relocate
  `redo_stack.clear()` with it — today `set_document` does *not* clear redo, only
  `snapshot()` does, so missing this silently breaks "redo clears on a new edit."
  (This increment is the larger half of the work; it is the price of the consolidate-
  first decision and is what makes the journal complete-by-construction in increment 2.)
- **Increment 2 — journal + transactions + gate, through the one chokepoint.** Promote
  `apply_op` → runtime `op_apply`; add `op_journal: Vec<Transaction>` + `journal_head`;
  `begin_txn`/`commit_txn` wrapping `snapshot`; every op records `targets` (Fork 4) +
  reserve the merge metadata (§8); convert boolean+simplify to one transaction and
  **delete `take_snapshot`**; reshape the undo-law fixtures across all four harnesses
  (Fork 2); wire the mandatory `checkpoint_equivalence` gate (§6). Because of increment
  1, the journal is complete from the moment it exists.
  - **Trap:** `boolean_union`/`simplify` are **not** in `apply_op` today (only in
    `actions.yaml`) — they must be added to `op_apply` before boolean can be journaled.
    Unifying the ~20-verb `apply_op` with the ~230-action `actions.yaml` is a real
    ongoing project, not a free byproduct of "same vocabulary."
  - **`is_modified` unifies** to `journal_head != saved_journal_head`, under which "undo
    back to the saved point ⇒ not modified." This is an **observable** change, and the
    churn is the *opposite* of first intuition: today **Swift** alone uses value-equality
    (`document != savedDocument`), which already matches the cursor semantics; **Rust,
    OCaml, Python, and Flask** all use generation/identity (and `set_document` bumps the
    generation even on undo), so they report *modified* after undo-to-saved and **all
    four must flip** to the cursor. So it is a 4-way change (the four generation/identity
    apps), with Swift the one that already conforms.
- **Increment 3+ — the dependents.** Capture/replay sessions → versioning labels →
  **recorded live elements** (`LIVE_ELEMENTS.md`) → the deferred id-primary flip +
  collaboration → fold the layout-op vocabulary under one `Op` trait.

---

## 10. Cross-language equivalence plan

Reuse the existing harness wholesale; add nothing structural. The journal file **is** a
cross-language fixture, compared via `document_to_test_json` byte-equality, loaded by the
four `apply_op` dispatchers. Pins, write-tests-first, in order:

1. **Reshape the undo-law fixtures** (`undo_redo_laws.json`, `undo_move`,
   `undo_redo_equals_op`, `double_undo_equals_op1`) into transaction-boundary form, in
   all four native harnesses **together** (the op-vocabulary change is simultaneous). Add
   new laws: `journal_head` tracks the undo cursor; redo clears after a new committed
   transaction; an empty/no-net-change transaction is not journaled (the `commit_txn`
   no-op rule — note there is no `abort_txn` today and `snapshot` has no rollback, so
   either define `abort_txn` or specify "commit elides a zero-effect transaction").
2. **The `checkpoint_equivalence` gate** (§6) in every operations fixture.
3. **`boolean_union_simplify_grouping`** — one undo entry == one transaction with two
   child ops == today's exact `expected_json`.
4. **`txn_metadata`** — `txn_id`/`lamport`/`parent`/`actor` serialize byte-identically
   when `txn_id` is a deterministic counter under replay (the way `element_ids.json` pins
   element ids as fixed counters `rect-0`/`group-0` — a codec golden — **not** random
   base36; live minting is per-app per `REFERENCE_GRAPH.md` §4).
5. **`is_modified` unification** — canonical = `journal_head != saved_journal_head`;
   re-pin the **four** generation/identity apps that change (Rust, OCaml, Python, Flask);
   Swift already conforms (§9).
6. **Flask** = forward-replay + serialization round-trip only (its JS engine has a Model
   with undo/generation but no native interactive editor driving transactions, and its
   `doc.snapshot` effect is a placeholder no-op); its generation-based `is_modified`
   joins the four that flip to the cursor target.

---

## 11. Risks

- **"All fixtures pass unchanged" is false** for the undo-law fixtures: they embed
  `snapshot`/`undo`/`redo` as flat ops we are removing. Budget the reshape as explicit
  work, all four harnesses together — do not let the "additive" framing hide it.
- **The redo-clear relocation** (§9 increment 1) silently breaks a reversibility law if
  missed. Add a fixture for it.
- **`boolean_union`/`simplify` aren't in `apply_op` yet** — the "same vocabulary" claim
  hides the `apply_op`↔`actions.yaml` unification work.
- **Two sources of truth can silently diverge** — the mandatory gate is the *only* guard
  and adds memory + a retention story that must be identical across apps. If the gate is
  ever optional, the design's guarantee is gone.
- **Merge-readiness here is metadata + conflict-detection, not reorderable streams.**
  Path-keyed and selection-relative ops are non-commutative; increments 1–3 produce a
  *recorded*-merge-ready stream (versioning + AI legibility are real), **not** a
  *mergeable* one. State this loudly so no one expects collaboration before the deferred
  id-primary / op-inversion work.
- **`is_modified` unification is an observable behavior change** in **four** apps (Rust,
  OCaml, Python, Flask — all flip to the journal-head cursor; Swift already conforms) —
  re-pin or equivalence silently breaks.
- **Consolidation is the larger half.** Increment 1 routes ~148 `set_document` sites
  across 13 files through one enforced chokepoint (not "merge two runners"); this is the
  price of the consolidate-first decision and lands before any op-log payoff.

---

## 12. Open questions

- **Recorded-element `release` semantics** (carried from `LIVE_ELEMENTS.md`): what
  `release` means for a transaction-defined element is undefined. (Note: that
  `expand`/`release` *operations themselves* are journaled is **not** an open question —
  it is a Fork-3 consequence: `expand_compound_shape`/`release_compound_shape` mutate the
  document and so flow through the chokepoint into transactions like any other op.)
- **`txn_id` cross-language pinning** — deterministic counter under replay (§10 item 4)
  vs. excluding `txn_id` from the byte compare. Leaning counter, to keep the journal file
  fully byte-shareable.
- **Undo of a transaction with side effects on shared inputs** — the snapshot mechanism
  handles it (whole-document restore), but the *journal*'s inverse story for collaboration
  is the deferred op-inversion project.
- **Granularity of `targets`** — do read-only reads count as targets (for conflict
  detection) or only writes? Leaning writes + explicit reads where a recipe depends on
  them.
- **Layout-op unification** (Fork 5) — the shared `Op` trait spanning document ops and
  `apply_workspace_op` is committed-in-principle but unscheduled; keep it tracked so a
  third vocabulary does not entrench.
