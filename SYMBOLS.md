# Symbols — reusable masters with live instances

**Status:** design proposed (2026-06-16) · **Branch:** `symbols` · **Lead app:** jas_dioxus (Rust) · **Propagation:** Rust → Swift → OCaml → Python

Symbols are the Phase-3 capstone of the reference graph (see `REFERENCE_GRAPH.md`
§8). The product requirement (REQUIREMENTS.md:97) is one sentence:

> **Symbols:** Reusable design elements. Dynamic Symbols allow editing a master
> symbol to update all instances or adjusting individual instances independently.

Two faculties: (a) a **master** whose edits propagate to every **instance**, and
(b) per-instance independent **overrides** ("Dynamic Symbols").

## 1. The big idea: Symbols are (almost) already built

A Symbol **instance is a `ReferenceElem`** that targets a master by stable id.
Nearly all of Symbols therefore falls out of the merged reference graph for free:

| Symbol faculty | provided by | status |
|---|---|---|
| instance "is an instance of" a master | `ReferenceElem { target: ElementRef }` | done |
| edit master → **all** instances update | instances hold no copy; they re-resolve the live master each paint (rebuild resolver) | done |
| "which instances use this master?" | dependency index `rdeps` | done |
| delete-a-master warns | `orphaned_references` / reference-aware delete | done |
| per-instance **paint** override | Fork F3 (unset fill/stroke inherits the master's; set overrides) | done |
| per-instance **transform** override | Fork F2 `ReferenceElem.transform` (serialized, currently dead) | **wire (P4)** |
| cycle / dangling safety | eval-time visited-set break → empty | done |

**The only genuinely new thing is a place for masters to live** — a definition
that is *resolvable but not painted in document order*. Today every reference
target is an ordinary element in the layer tree, drawn at its own location. A
master must be shared and **off-canvas**.

## 2. Where masters live (Fork S1 — locked: a `Document.symbols` store)

Add `symbols: Vec<Element>` to `Document`, a store of master elements keyed by
their `common.id`. Each master is a plain `Element` (group/shape/…) carrying a
`common.id` (its key) and a `common.name` (its panel label).

- **Off-canvas by construction.** `symbols` is not in `layers`, so render and
  hit-test never touch it — no "skip this layer" special-casing, and no
  path-shift fragility (the rejected alternative, a hidden defs *layer* inside
  `layers`, would shift every other layer's path index and leak into per-app
  layer-count assumptions — contrary to [[project_element_identity_paths]]).
- **Resolvable.** The render resolver (`register_ref_index`/`RebuildResolver`)
  and the dependency index's targetable walk are extended to **also** index
  `doc.symbols`, so a `ReferenceElem` can target a master. A master id is in the
  same flat id-space as document elements (the uniqueness invariant, §6, still
  holds across `layers` + `symbols`).
- **Deterministic order.** `symbols` is iterated in **sorted-by-id** order at
  every order-dependent site (codecs, index), never hash order — the §6.1
  equivalence rule from the reference graph applies verbatim.

A master is reached only through a reference; an orphaned master (no instances)
is harmless (it simply isn't drawn). Masters are not themselves selectable on
the canvas (they have no canvas presence) — they are managed via the Symbols
panel (P3).

## 3. Resolution & propagation

Unchanged from the reference graph. An instance evaluates by `resolve(target)` →
recurse, with the threaded visited-set breaking cycles to empty and a dangling
target (missing master) → empty `PolygonSet`, never a panic. Because the
resolver is rebuilt per paint from the live document, **editing a master is
immediately reflected in every instance** with zero propagation code (Fork S2 —
locked: *re-resolve-live*, no explicit "update instances" step). A
"redefine symbol" operation (P2) simply replaces the master element in
`doc.symbols`; the next paint re-resolves.

## 4. Per-instance overrides ("Dynamic Symbols")

An instance adjusts independently of its master via the `ReferenceElem`'s own
fields, composed onto the resolved master geometry:

- **Paint** (done, Fork F3): unset `fill`/`stroke` inherit the master's; setting
  them overrides for that instance only.
- **Transform** (P4, Fork F2 — to be wired): the per-instance affine. Final
  geometry composes **`common.transform ∘ instance.transform ∘ (master local
  geometry)`** (REFERENCE_GRAPH.md §4). `common.transform` is the element-level
  placement the move tool already mutates (and that Make Instance's offset rides
  on); `instance.transform` is the *parametric* override (mirror/scale a single
  instance while the master stays put). Wiring it is a cross-language
  divergence-risk task (eval is currently transform-free for all kinds) and is
  deferred to P4 with its own fixtures.
- **Deeper overrides** (per-child property overrides) are out of scope for now;
  paint + transform satisfy the requirement's "adjusting individual instances
  independently."

## 5. Codecs (Fork S3 — locked: `<defs>` for SVG)

`doc.symbols` round-trips through all three codecs, masters emitted only when the
store is non-empty (mirroring `print_preferences`):

- **test_json:** a `symbols` key (sorted-by-id array of element JSON), emitted
  only when non-empty so existing fixtures stay byte-identical.
- **SVG:** masters serialize inside a single `<defs>` block (each with its `id`);
  instances are the native `<use href="#id">` already shipped. This is the
  standard SVG mechanism for non-rendered reusable definitions and composes with
  the existing F-svg-use decision (import any `<use>` as a live reference). On
  import, `<defs>` children become `doc.symbols`.
- **binary:** `doc.symbols` is added to the positional document array (after the
  existing fields), emitted as a (possibly empty) element array.

All three are cross-language **fixture-pinned** (a doc with a master + an
instance round-trips byte-identically in all four apps; Python is the binary
oracle as before).

## 6. Identity & the dependency index

Master ids obey the same **unique-within-document invariant** (Fork F-dup-id):
the id space spans `layers` + `symbols`; import normalization (first-pre-order-
wins) treats `symbols` as part of the pre-order walk. The dependency index's
**targetable set** gains the master ids; `rdeps[master]` is the master's instance
list (the Symbols-panel usage count and the safe-delete signal). Operands stay
opaque (Fork F-operand-opaque) — a master may be a group but, for now, not a
bare compound operand (the compound-as-master case waits on §9).

## 7. Operations (value-in-op id minting, as always)

All ids are minted by the initiator and carried verbatim in the op payload
(never inside a Controller), via `generate_element_id`. P2:

- **Make Symbol** (promote): move the selected element into `doc.symbols` as a
  master (minting/keeping its id), and replace it in place with a
  `ReferenceElem` instance targeting it. The dual of Detach.
- **Place Instance:** insert a `ReferenceElem` targeting an existing master
  (offset like Make Instance). The Symbols panel's drag/click-to-place.
- **Detach** (break link / expand): replace an instance with an independent copy
  of the resolved master geometry (id-less, per `clear_ids`), applying the
  instance's overrides; the master and other instances are untouched.
- **Redefine:** replace a master's element in `doc.symbols` with the current
  selection; all instances re-resolve next paint.

Reference-aware delete of a master reuses the existing warn-then-orphan flow
(`orphaned_references` already sees masters once they're in the targetable set):
deleting a master warns "N live instance(s) …", and on confirm the instances
dangle (render empty), recoverable via undo.

## 8. The Symbols panel (P3, sketch)

A new `workspace/panels/symbols.yaml` rendered generically: a library grid of
master thumbnails with name + usage count (`rdeps`), and actions New Symbol
(promote selection), Place Instance, Redefine, Duplicate, Delete (warn via
`rdeps`). Masters need user-visible **names** → this resolves the deferred
live-element-naming decision (a master that is a group already has
`common.name`; if a master can be a compound, the compound-name gap (memory)
must be closed first).

## 9. Fork decisions

| # | fork | decision |
|---|---|---|
| S1 | where masters live | `Document.symbols: Vec<Element>` (off-canvas, sorted-by-id), not a hidden defs layer |
| S2 | propagation | re-resolve-live every paint (no explicit update step); Redefine just swaps the master |
| S3 | SVG form | masters → `<defs>`, instances → `<use href>` |
| S4 | instance type | reuse `ReferenceElem` (no new element kind/variant) |
| S5 | override scope | paint (done) + transform (P4); deeper per-child overrides deferred |
| S6 | master creation | promote-from-selection ("Make Symbol"); Detach is its inverse |
| S7 | delete-a-master | reuse reference-aware delete (warn-then-orphan via `rdeps`) |
| S8 | compound master | deferred — waits on operand-targetability + compound-name decisions |

## 10. Phased plan

Each phase ships fixtures green in all four apps before advancing.

- **P1 — foundation (this increment).** `Document.symbols` store + Default;
  resolver + dependency-index targetable walk extended to `doc.symbols`; all
  three codecs round-trip `symbols` (test_json `symbols` key, SVG `<defs>`,
  binary array); render verified to never paint masters. An instance
  (`ReferenceElem`) targeting a master resolves to the master's geometry.
  *Gate:* a shared `symbols_basic` fixture (a master + an instance) round-trips
  byte-identically through all three codecs in all four apps, and a resolve test
  shows the instance evaluates to the master geometry. **No UX.**
- **P2 — operations.** Make Symbol (promote), Place Instance, Detach, Redefine,
  as cross-language operation fixtures; delete-a-master warns (reuse
  `orphaned_references`).
- **P3 — Symbols panel.** `workspace/panels/symbols.yaml` + the library UX
  (thumbnails, usage via `rdeps`, the P2 ops wired to buttons).
- **P4 — instance transform overrides.** Wire the Fork-F2 `instance.transform`
  at the single eval/render seam (composition `common ∘ instance ∘ target`),
  fixture-pinned; enables mirror/scale of an individual instance.

## 11. Cross-language equivalence plan & risks

No new harness type: P1 rides the codec round-trip harnesses + the resolver
tests; P2 rides the operation-fixture harness. Risks: (1) **store iteration
order** — `symbols` must be sorted-by-id at every codec/index site (the §6.1
rule); (2) **codec round-trip** of the new field — guarded by "emit only when
non-empty" so existing fixtures stay byte-identical, plus a new `symbols_basic`
fixture; (3) **render must never paint masters** — automatic with the
off-canvas store (B), but assert it; (4) **P4 transform composition order** must
be pinned by fixture before propagating (eval is transform-free today for every
kind, so this is an additive, divergence-sensitive change).
