# Reference-Based Live Dependency Graph

**Status:** design locked (2026-06-15) · **Branch:** `live-reference-graph` · **Lead app:** jas_dioxus (Rust) · **Propagation:** Flask-spec → Rust → Swift → OCaml → Python

This is the keystone of the liveness architecture (VISION §6.2, §7): elements that
reference *other* elements by stable identity, so the document becomes a live
dependency graph rather than a pure tree — enabling cross-tree references,
mirrored/instanced geometry, connectors-follow-blocks, parametric relationships,
and Symbols.

It builds directly on the completed **stable-identity foundation** (additive
`common.id`, round-tripping in test_json / SVG / binary, duplication-clears-id;
merged to main 2026-06-15). See the memory note *Element identity is paths* and
ARCH.md.

---

## 1. The model

A reference is a **stable-id string**, never an embedded pointer. `Element` does
not grow — it already has `Live(LiveVariant)`. `LiveVariant` gains one additive
arm; `CompoundShape` is untouched.

```
ElementRef(String)            # transparent newtype over common.id; Ord (sorted iteration)

ReferenceElem {
    target:    ElementRef     # the single dependency edge
    transform: Option<affine> # optional affine instance transform (serialized from
                              # Phase 1, always None until Phase 3 — see Fork F2)
    fill:      Option<Fill>   # None = inherit the resolved target's paint (Fork F1)
    stroke:    Option<Stroke>
    common:    CommonProps    # the reference element's own id, name, opacity, transform…
}

LiveVariant =
  | CompoundShape(CompoundShape)   # unchanged
  | Reference(ReferenceElem)       # new; kind() = "reference", kind_schema_version = 1
```

**Trait surface — additive `dependencies()`, never break `children()`:**

```
LiveElement::dependencies(&self) -> Vec<ElementRef>   # default: empty
  CompoundShape  -> []            (its operands are owned via children(); zero blast radius)
  ReferenceElem  -> [self.target] (the only edge source the index reads)
```

`ReferenceElem` exposes no children (an always-empty `children()`), so the trait
signature is unchanged.

---

## 2. Identity, the index, and the resolver

### 2.1 The resolver interface (the stable seam)

The geometry layer depends only on a trait, never on `Model`/`Document`:

```
ElementResolver::resolve(&self, id: &ElementRef) -> Option<element>
```

`evaluate` and `element_to_polygon_set` take the resolver **plus an explicitly
threaded visited-set** (cycle safety; must be a parameter, never instance/thread
state — the subtlest cross-language trap):

```
evaluate(precision, resolver, visiting: &mut Set<ElementRef>) -> PolygonSet
```

This interface is identical for every backing strategy, so swapping the index
implementation (§2.3) touches one type per app and **no caller, no fixture**.

### 2.2 The index maps `id → element`, not `id → path` (Fork F-index-key)

Under copy-on-write, an edit at path P rebuilds only the ancestor spine (O(depth)
new nodes); unedited siblings stay pointer-identical. Therefore:

- the set of elements whose **value** changed per edit is O(depth);
- the set whose **path** changed is O(N) (every following sibling + descendants).

So the index keys on the **element** (`id → Rc<Element>`), which is incrementally
maintainable; `id → path` is not. Maintenance must **refresh the spine ancestors'
entries**, not just the edited node (an ancestor group gets a new value when its
children change, so a reference to it must resolve to the new value). That refresh
is O(depth) and free-rides the spine rebuild the mutation already performs.

`resolve()` returns the element (all `evaluate` needs). "Where in the tree is id
X?" is a separate, rare, human-speed **on-demand O(N) tree search** — never a
second `id → path` index (which would drag the O(N)-per-edit problem back).

### 2.3 Derived cache, paired with the snapshot (Fork F-index-home)

The index is a **pure function of the document** and carries no authoritative
state, so:

- **never serialized** (rebuilt on load; `serde(skip)` / absent from every codec);
- **never compared** (excluded from `Document` equality);
- lives **paired with the snapshot, not inside `Document`**: the undo stack holds
  `(Document, IdIndex)` (a thin `IndexedDocument`/`Model`-level companion), so
  `Document` keeps its derived `Clone`/`PartialEq`/codecs unchanged and remains
  the pure canonical spec.

**Trust mechanism:** `debug_assert!(index == rebuild(doc))` after mutations
(debug/test only; O(N)) — the analogue of the boolean `incremental ==
from-scratch` law (VISION §9). It makes incremental maintenance self-checking and
catches a missed ancestor-refresh immediately.

**Equivalence payoff:** because the index is derived, the five apps **need not use
the same index implementation** — equivalence is pinned on `resolve()` *results*,
not on the cache. Each app picks its own persistent map; one app may even use a
different *strategy* (rebuild vs incremental) and stay equivalent.

### 2.4 Staging: rebuild-first, persistent-incremental as a per-app upgrade (Fork F-staging)

| Phase | index strategy |
|---|---|
| 1–3 (feature build) | **rebuild-on-demand, all apps, presence-gated** — built only when the document contains a live element with `dependencies()`. No persistent-map dependency, no mutation-threading. |
| 4 (scale) | **persistent-incremental** in Rust (`rpds::RedBlackTreeMap` or `im::OrdMap`), Swift (`swift-collections` `TreeDictionary`), OCaml (stdlib `Map`). **Python stays on rebuild as the oracle.** |

Persistent-map complexities (all give O(log n) updates + O(1) snapshot, the
property the undo stack needs):

| app | persistent map | lookup | update | snapshot | ordered? |
|---|---|---|---|---|---|
| Rust | `rpds::RedBlackTreeMap` / `im::OrdMap` | O(log n) | O(log n) | O(1) | sorted |
| OCaml | stdlib `Map` / `lm_map` | O(log n) | O(log n) | O(1) | sorted |
| Swift | `TreeDictionary` (CHAMP) | O(1)~ | O(log n) | O(1) | hash |
| Python | `immutables.Map` / `pyrsistent` / rebuild | O(1)~ | O(log n) | O(1) | hash |

> Swift's plain `Dictionary` is a **trap**: it copies O(N) on the first mutation
> after a snapshot (CoW), defeating persistence during editing. Use a true
> persistent map (`TreeDictionary`). Hash-ordered maps (Swift/Python) require an
> explicit `keys.sorted()` wherever order matters (e.g. Phase-3 recompute order);
> sorted maps (Rust/OCaml) get it free.

**Why this is the right end-state (and safe to defer):** at the 1M-element target,
viewport culling makes paint O(visible) — but the index must cover *all* elements
(a visible reference can target an off-screen one), so a *rebuild* is the one
residual O(N)-per-frame cost culling cannot remove, and during editing
`generation` bumps every frame. The persistent-incremental index turns that into
O(1) per paint. It is deferrable because the presence-gate (no refs → no index),
sparse-ref resolve-on-demand, and small-doc cases keep rebuild cheap until a
document is large *and* reference-dense *and* being edited — exactly the corner
the persistent index is for.

### 2.5 Uniqueness invariant (Fork F-dup-id)

**Element ids are unique within a document — an enforced internal invariant.**
Authoring preserves it (`clear_ids` on copy; `assign_id`/`create_reference` mint
fresh). The only entry point for duplicates is **import of ill-formed input**, so
the SVG/JSON/binary readers enforce uniqueness: during the parse walk, the **first
occurrence in canonical pre-order keeps its id; every later occurrence is cleared
to `None`.** Pre-order is identical across apps, so all five normalize identically.

Consequences: the index never collides → `id→element` stays a plain map (no
multimap, no promote-on-delete) → incremental maintenance is trivial → the
`index == rebuild` invariant holds. A well-formed document round-trips exactly; an
ill-formed dup-id import is normalized (later duplicates come back id-less), pinned
by a dup-id import fixture.

---

## 3. Resolution semantics

- **`evaluate` of a `Reference`:** if `target ∈ visiting` → empty `PolygonSet`
  (cycle break); else insert target, `resolve`, recurse, remove.
- **Dangling** (`resolve` → `None`) → empty `PolygonSet` (matches the existing
  "unsupported → empty set" convention). Never panic.
- **Cycles** → broken at the re-entry edge by the threaded visited-set → empty. A
  depth cap (e.g. 64) is defense-in-depth. (Fork F-cycle: **eval-time break only**;
  write-time cycle rejection is deferred to Phase 3.)
- **Paint inheritance** (Fork F-paint): a `Reference` with `fill == None` /
  `stroke == None` renders with the **resolved target's paint** ("instance of"
  semantics — a mirrored eye looks like the eye); setting fill/stroke repaints the
  instance.
- **`CompoundShape::evaluate`** threads `resolver` + `visiting` unchanged; a
  `Reference` used as an operand composes for free.

---

## 4. Operations (minting & creation)

Identity is **lazy-minted by the initiator and carried verbatim in the op
payload** — never minted inside a Controller (entropy-based minting would desync
the four cross-language operation harnesses). `generate_artboard_id`'s injected-rng
seam generalizes to `generate_element_id`.

- **`assign_id`** (Phase 0): stamp a minted id onto an element that has none.
  Payload `{ path, id }`. Enables identity before any reference exists
  (comments-on-objects, AI tagging, pre-reference identity).
- **`create_reference`** (Phase 1): payload `{ target_path, target_id, ref_id }`.
  Assign-on-create stamps `target_id` onto the target **iff** its id is currently
  `None` (the lazy-mint trigger named in the `clear_ids` doc-comment); the target
  stays in the tree (shared, not moved); a new `ReferenceElem` with `common.id =
  ref_id` and `target = <resolved target id>` is inserted.
- **Make Instance** (Phase 3 — the first user-facing trigger). Object-menu command
  "Make Instance", enabled only when **exactly one** whole element (`SelectionKind::All`)
  is selected. It is *not* a new operation — it is native UI glue that composes two
  existing, already-pinned ops under **one** snapshot: `create_reference` (the UI mints
  `target_id`/`ref_id` via `generate_element_id`, value-in-op, with a collision-retry
  loop over existing ids — never minted in a Controller), then a move of the now-selected
  reference by `(PASTE_OFFSET, PASTE_OFFSET)` = `(24, 24)`.
  - **The offset rides on the new reference's `common.transform`, not the instance
    `transform` field.** Decided after an investigation: `common.transform` is already
    applied to a reference at both render seams (the element-level `apply_transform`
    above the per-kind match) — zero new render wiring — and the move tool mutates the
    same field, so "create offset, then drag to reposition" is split-brain-free. Eval
    stays transform-free for *all* element kinds (a transformed rect ignores its
    transform as a boolean operand too), so references remain consistent — no new
    divergence. The instance `transform` field (Fork F2) stays reserved for the genuine
    parametric role (mirror/scale instance overrides); when wired, the two compose
    `common.transform ∘ instance.transform ∘ (target local geometry)`.
  - **Moving a reference** required teaching `move_control_points` and `translate_element`
    a `Reference` arm (whole-element move only) that composes the translate onto
    `common.transform` — references have no geometry of their own. Pinned by the
    `move_reference` operation fixture across all 4 apps. `generate_element_id` mirrors
    `generate_artboard_id` exactly (8-char base36, injected-rng seam, UI-layer only,
    never in a Controller); pinned per-app by determinism tests, not a shared fixture
    (minting is non-deterministic).

---

## 5. Codecs — and closing the Live round-trip gap

Live currently survives **no** document codec (test_json reader panics on
`"live"`; SVG demotes to a plain `<g data-jas-live>` with no reader; binary
*panics* on write). Implementing references forces fixing all three, and a
reference's tiny payload is the easiest first exercise of each new arm — the fix
generalizes to make `CompoundShape` round-trip too (a pre-existing bug fixed as a
byproduct).

- **test_json** (Phase 1, first — the canonical cross-language codec the fixtures
  need): writer emits `{type:"live", kind, operation|target, fill, stroke,
  common}` (adds the currently-missing `operation` for compound, `target` for
  reference); reader gains a `"live"` arm dispatching on `kind` (removes the
  panic).
- **SVG** (Phase 2): a `Reference` round-trips as native `<use href="#id">` (it
  *is* `<use>`); compound keeps `<g data-jas-live="compound_shape">` and gains a
  reader branch.
- **binary** (Phase 2): add `TAG_LIVE` + a `kind`-discriminated payload, replacing
  the write panic.

Because `common.id` already round-trips (pinned by `element_ids`), the target's
identity persists for free; only the reference element itself needs new arms.

---

## 6. Cross-language equivalence plan

No new harness type is needed — every piece maps onto the existing
operation-fixture harness (`apply_op` + `test_fixtures/operations/*.json`) or the
codec round-trip harnesses. Each phase ships its fixtures green in all five apps
before propagating.

| design piece | harness | fixture(s) |
|---|---|---|
| `assign_id` stamps an id | operations | `assign_id_basic` |
| `create_reference` mints target id + builds reference | operations | `create_reference_assigns_id` (on `two_rects.svg`) |
| assign-on-create does not re-mint an existing id | operations | `create_reference_existing_id` (on `rect_with_id.svg`) |
| dangling → empty geometry, reference survives serialize | operations | `create_reference_dangling` |
| cycle → empty, no recursion | operations | `create_reference_cycle` |
| duplicate-id import normalization | codec round-trip | `dup_id_import` |
| reference round-trips | test_json / SVG / binary | `live_reference_roundtrip` |
| compound round-trips (bug fix rides along) | test_json / SVG / binary | `live_compound_roundtrip` |
| `incremental == from-scratch` (Phase 4) | operations (property) | `reference_incremental_equals_fresh` |

**Determinism review gates** (the cross-language traps):

1. Order-dependent consumers iterate in **sorted-by-id** order, never native map
   order (BTreeMap/sorted in Rust/OCaml; explicit `sorted()` in Swift/Python).
2. The cycle visited-set is **membership-only** and **parameter-threaded**,
   identical in all five apps.
3. Id minting is **value-in-op**; the replay consuming literal ids enforces it.
4. Duplicate-id normalization is **first-pre-order-wins**, identical across apps.

---

## 7. Fork decisions (locked)

| # | fork | decision | runner-up / why |
|---|---|---|---|
| F1 | reference representation | new `LiveVariant::Reference` arm; `CompoundShape` untouched | reject migrating compound operands to refs *first* (highest blast radius); get it free later since a `Reference` composes as an operand |
| F2 | `transform` field timing | serialized from Phase 1, always `None` until Phase 3 | avoids a later `kind_schema_version` bump + 5-app fixture regen |
| F3 | paint when unset | inherit the resolved target's paint | vs render paintless — "instance of" is the natural default |
| F4 | cycle prevention | eval-time visited-set break (→ empty); write-time guard deferred to Phase 3 | eval-time is load-bearing (handles imported cycles); write-time is an additive nicety |
| F5 | `assign_id` op | exposed in Phase 0 | identity can exist before a reference (comments, AI tags, pre-reference) |
| F-index-key | index key | `id → element` (not `id → path`) | paths shift O(N)/edit; element values don't |
| F-index-home | index home | derived, serde-skipped, paired with snapshot (not in `Document`) | keeps `Document` pure canonical; equivalence on outputs |
| F-staging | index strategy | rebuild-first (Phases 1–3, presence-gated); persistent-incremental per-app in Phase 4; Python = rebuild oracle | start-small + no synchronized retrofit |
| F-dup-id | duplicate ids | unique-id invariant; normalize at import (first-pre-order-wins, later cleared) | keeps the index a plain map; invariant-safe |
| F-svg-use (open) | importing foreign `<use>` | **deferred to Phase 2** | decide then: import foreign `<use>` as live references vs flatten; only jas-authored refs stay live |

---

## 8. Phased plan

Propagation each phase: Flask-spec → Rust → Swift → OCaml → Python, fixtures green
in all five before advancing.

- **Phase 0 — prerequisite.** `generate_artboard_id` → `generate_element_id`
  (keep rng seam). `assign_id` op + `assign_id_basic` fixture. Import dup-id
  normalization + `dup_id_import` fixture. *Gate: `element_ids`, `copy_clears_id`
  stay green.*
- **Phase 1 — FIRST INCREMENT (vertical slice).** `ElementRef`, `ReferenceElem`,
  `LiveVariant::Reference`, `dependencies()`; `ElementResolver` + threaded
  `evaluate`/`element_to_polygon_set`/render/bounds/hit-test; presence-gated
  `RebuildResolver`; `create_reference` + assign-on-create; test_json `"live"`
  reader/writer arm; dangling/cycle → empty. `CompoundShape` touched only to
  thread the resolver params (behavior-identical). Fixtures:
  `create_reference_assigns_id`, `create_reference_existing_id`,
  `create_reference_dangling`.
- **Phase 2 — full codec round-trip.** SVG `<use>` + binary `TAG_LIVE`; reference
  and compound round-trip fixtures. Live survives every codec for the first time.
- **Phase 3 — graph structure + UI.** Promote the `id→element` map into a
  dependency index (`deps`, `rdeps`, `topo_order`, `cycles`, `dangling`); add
  write-time cycle rejection; wire the `transform` field + a "link to selection"
  gesture (VISION §7: mirrored eyes, connectors-follow-blocks); Symbols.
- **Phase 4 — scale.** Persistent-incremental index (per §2.4) + incremental
  recompute cache keyed on `(target_id, Rc::as_ptr)` in sorted-topo order, with
  `reference_incremental_equals_fresh` as the gate. Python remains the rebuild
  oracle.
- **Phase 5 — optional.** Migrate `CompoundShape` operands to references (may need
  no struct change, since a `Reference` already composes as an operand).

---

## 9. Risks

1. **Hash/Btree iteration desync** — mitigated by sorted-by-id at every
   order-dependent site (gate §6.1).
2. **In-Controller minting desyncs harnesses** — hard rule: id is a value in the
   op payload (gate §6.3).
3. **Trait signature churn** — `evaluate`/`element_to_polygon_set`/`bounds` gain
   resolver + visiting params in all five apps; mechanical but must be identical.
4. **Missed ancestor-refresh** in the Phase-4 incremental index — caught by the
   `index == rebuild` invariant and the resolve() fixtures (Python oracle).
