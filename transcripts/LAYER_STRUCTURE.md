# LAYER STRUCTURE UNDER GROUP AND PASTE — a phase brief

**Opened 2026-07-28 at council, from JYH's question: "when we group elements
into an object, does it also flatten the layers?"** The answer turned out to be
no — it refuses — and pulling the thread found three defects of one family.

**Status: JYH's position stated below and recorded as the intended rulings; not
yet ratified.** Nothing here is implemented. What ratifies it is JYH saying so,
after which the rulings move into `workspace/actions.yaml` and this file becomes
the reasoning record.

---

## 1. THE THREE DEFECTS, all measured

| # | operation | behaviour | kind |
|---|---|---|---|
| D1 | paste a multi-layer fragment | flattened into one layer, **both ports** | shared defect |
| D2 | group a selection spanning parents | silent no-op, **both ports** | shared gap |
| D3 | group a selection inside a Group | Swift escapes a level and strands debris | **live divergence** |

### D1 — paste flattens, in both ports
`jas_dioxus/src/workspace/clipboard.rs:141` `clipboard_read_and_paste` walks
every layer of the pasted document and pushes each child into
`doc.layers[selected_layer]`. `JasSwift/Sources/Clipboard/EditClipboard.swift`
`pasteClipboard` does the same, except that a pasted layer whose NAME matches an
existing layer is appended there instead, falling back to the selected layer.

**Neither port ever creates a layer.** `newLayers` starts as `doc.layers` and is
only ever mutated at existing indices. So pasting a three-layer illustration into
a document that shares none of those layer names flattens it to one layer in BOTH
ports — they agree, and the artist's structure is destroyed silently.

The much-discussed Rust/Swift divergence here is the narrow case: it fires only
when a pasted layer name matches an existing one, and then only for that layer.
In-app copy/paste builds an unnamed clipboard layer, so Swift's name branch
cannot match and the ports agree; the divergence is reachable almost exclusively
through externally-sourced SVG, where it fires almost always.

### D2 — grouping across parents is a silent no-op, in both ports
Both ports carry the same guard. Rust,
`jas_dioxus/src/document/controller.rs:1251` `group_selection`:

```rust
let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
if !paths.iter().all(|p| p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]) {
    return;
}
```

Swift, `JasSwift/Sources/Document/Controller.swift:1020` `groupSelection`:

```swift
let parent = Array(paths[0].dropLast())
guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
```

Select two elements in different layers, press Cmd+G: **nothing happens, and
nothing says why.**

**The guard is about PARENTS, not layers.** A selection spanning two different
Groups fails identically. Any ruling must be written in terms of parents or it
fixes a third of the problem.

### D3 — Swift's group loses path depth (live divergence, Rust correct)
Rust's `Document::insert_element_at` recurses —
`insert_at_in_children(&mut doc.layers[path[0]], &path[1..], new_elem)` — so the
new Group lands at the selection's true depth. Swift's `groupSelection` instead
reads only `insertPath[1]` and inserts directly into `layers[layerIdx].children`,
discarding every deeper component.

**Measured, not inferred.** Twin probes: layer holds `[rect, Group(line, line)]`,
select the two lines at `[0,1,0]` and `[0,1,1]`, group them.

* Rust `grouping_inside_a_group_stays_inside_that_group` — **passes**.
* Swift `NestedGroupProbeTests` — **fails**: `layerCount → 3` (expected 2) and
  the element at `[0,1]` holds 2 children (expected 1).

Reading the failure: the lines are correctly deleted at depth (Swift's
`deleteElement` DOES recurse, via `removeFromGroup`), then the new Group is
inserted at layer level, displacing the original Group to index 2 where it
survives **empty**. So the operation produces a wrong-level group AND leaves an
orphan container behind. The delete/insert asymmetry inside one function is the
bug's whole signature.

---

## 2. THE ANALYSIS — why group and paste deserve different answers

**For grouping, preservation is not merely hard, it is impossible.** A Group is
an element and its children are its children; there is no representation in which
one Group's children live in two different layers. So unlike paste there is no
structure-preserving option to choose between — grouping across parents
necessarily relocates elements.

This is exactly the Preservation Law's clause: *what it cannot preserve, it must
not guess.* But T3 permits a **documented default**, and that is what grouping
needs. Refusing is the worst of the available options: it is a no-op with no
feedback, which reads as broken software rather than as a considered refusal.

**For paste, preservation IS possible**, because paste creates new content and
could create new layers. So preservation is a coherent wish and can be offered.

The asymmetry that justifies different defaults: **with paste the artist is
importing FOREIGN structure**, so preserving it is a meaningful request; **with
group the artist is creating a new container** and the layer question is
incidental to their intent. Evidence that the asymmetry is real: "Group,
preserving layers" has no coherent meaning, while "Paste, preserving layers"
plainly does.

**A note on Swift's name-matching.** It is not a bad behaviour; it is the right
feature attached to the wrong trigger. As a DEFAULT it is indefensible — an
invisible property of the clipboard silently relocates artwork, and renaming a
layer changes where paste lands. Behind an EXPLICIT command the objection
evaporates, because the artist asked for that exact semantic. So the resolution
keeps both ports' work: Rust's flatten becomes plain Paste, Swift's merge-by-name
becomes Paste Preserving Layers.

---

## 3. THE RULINGS AS JYH STATED THEM (2026-07-28, pending ratification)

> *"1) grouping always flattens (to the topmost layer), 2) normal paste flattens,
> 'paste, preserving layers' creates layers if they do not exist, and appends if
> they do exist."*

### R1 — Group always flattens, to the topmost selected element's parent
No refusal, no silent no-op. The new Group is placed at the **topmost selected
element's parent, at that element's z-position**, and every selected element
becomes its child regardless of where it came from.

*Why topmost rather than the active layer:* it minimises visual change. The group
renders roughly where the topmost element already rendered, so the artwork does
not jump in stacking order. Placing it in the active layer could hurl the
selection forward or backward past unrelated content.

*On electing from geometry:* the Preservation Law forbids electing an IDENTITY
winner from geometry, z-order included. This is not that. Identity here is a
FRESH group (a 0→1 creation under the cardinality law), and z-order is being used
for PLACEMENT, which is inherently an ordering concern. The distinction should be
stated wherever this is written into the spec, because the surface resemblance
will otherwise be read as a contradiction.

*On visibility:* the loss is not silent — the Layers panel visibly loses
children, and it is one undo step.

### R2 — Plain Paste flattens into the active layer
Rust's current behaviour becomes canonical. Swift's name-matching is REMOVED from
the default path. Where artwork lands must not depend on an invisible property of
where it came from.

### R3 — "Paste, preserving layers" is a separate, explicit command
Creates a layer when the fragment names one that does not exist; **appends into
the existing layer when the name matches** (JYH, 2026-07-28 — this settles the
open question the brief raised).

*Deliberately NOT a persistent preference.* A hidden mode that changes what Cmd+V
does is the same defect R2 rejects: invisible state deciding where artwork goes.

---

## 4. WHAT EACH RULING REQUIRES

| ruling | Rust | Swift | spec |
|---|---|---|---|
| R1 | drop the sibling guard; place at topmost parent | same, plus fix D3's depth-losing insert | `actions.yaml` §group description |
| R2 | unchanged | delete the name-match branch from the default path | `actions.yaml` §paste |
| R3 | new command | reuse the existing name-match code, plus layer creation | `actions.yaml` new action, `menubar.yaml` Edit menu, `shortcuts.yaml` |

**D3 is separable and should land first.** Swift discarding path depth is a plain
bug with Rust unambiguously correct — a work order under existing rulings, not
part of this phase. Swift already has a depth-aware `insertElementAtPath` in
`OpApply.swift`; `groupSelection` simply never used it. Fixing D3 before R1 keeps
the phase's diff about semantics rather than about a latent bug.

---

## 5. THE MACHINERY GAP — none of this is watchable today

* **No corpus vector pastes anything.** `op_apply` has no `paste` verb, so no
  fixture can reach any paste behaviour in either port. D1 and the R2/R3
  distinction are unreachable by every gate.
* **No fixture groups across parents**, so D2 is likewise invisible.
* D3 was found only by a hand-written twin probe, and those probes are the only
  thing watching it.
* The same missing `paste` verb blocks a separate banked question: **paste copies
  element ids verbatim in both ports**, so a pasted element can duplicate a live
  identity. Under the cardinality law a paste is 0→N and should mint fresh ids.
  Whatever machinery this phase builds should unblock that too.

**So the phase must build its own gate**, as the zoom package had to. A ruling
that lands without one is a ruling nothing enforces.

---

## 6. OPEN QUESTIONS, not settled by the above

1. **R3 naming when creating.** If the fragment names "Layer 1" and the document
   has no "Layer 1", we create it — but do we take the fragment's name verbatim,
   or disambiguate? Verbatim is what "preserving" implies; the risk is two
   documents' "Layer 1" meaning different things being fused on a later paste.
2. **R3 and locked or hidden layers.** If the matching layer is locked, does
   append succeed, fail, or unlock? Unaddressed everywhere in the spec.
3. **R1 and mixed depths.** The current guard also requires equal path LENGTH.
   Selecting an element and something nested deeper inside a group is a shape
   nobody has ruled on; R1 as stated does not obviously cover it.
4. **Cross-artboard selections** — the same question one axis over, and not
   examined here at all.

---

## 7. BLIND SPOTS OF THIS BRIEF

* **No GUI was driven.** Every claim is from source reading plus two unit probes.
  Nobody has watched a paste or a cross-layer group happen on screen in either
  port.
* **The frozen ports were not examined.** `jas_ocaml` and `jas` are pinned at
  `five-port-parity` and may implement any of this differently; that is out of
  scope by the freeze, but it means "both ports" throughout means the two ACTIVE
  ports.
* **`jas_flask` was not examined at all.**
* **Only the SVG paste path was read.** Both ports also have an internal-clipboard
  fallback path, and this brief does not establish that it behaves the same way.
  That is a real gap — the internal path is what in-app copy/paste uses most.
