# LAYER STRUCTURE UNDER GROUP AND PASTE — a phase brief

**Opened 2026-07-28 at council, from JYH's question: "when we group elements
into an object, does it also flatten the layers?"** The answer turned out to be
no — it refuses — and pulling the thread found three defects of one family.

## RATIFIED 2026-07-28 by JYH, at council

> *"Good writeup, my friend, ratified. Yes we will have to confirm the internal
> clipboard."*

**R1, R2 and R3 below are LAW.** They move into `workspace/actions.yaml` and the
active ports implement against them; this file is the reasoning record and the
place a future reader is owed an explanation.

**One condition rode with the ratification.** JYH accepted §7's stated blind
spot: only the SVG paste path was read, and **the internal-clipboard path — the
one in-app copy/paste actually uses most — must be confirmed** before R2 and R3
are considered implemented. If the internal path turns out to carry layer
structure differently from the SVG path, that is a finding against this brief,
and it is to be reported rather than quietly accommodated.

D3 (Swift's depth-losing group insert) was separable and **landed already**, at
commit `GROUPDEPTH`, with twin probes in both ports.

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
* ~~**Only the SVG paste path was read.**~~ **CLOSED 2026-07-28 — see §8, "The
  internal clipboard, confirmed."** The gap is measured and the central claim
  SURVIVES: neither port creates a layer on the internal path either. Two
  sentences of this brief were nonetheless wrong and are corrected in §8 —
  (a) "both ports have an internal-clipboard fallback": **Swift has none**, it is
  a Rust-only construct; (b) "the internal path is what in-app copy/paste uses
  most": **it is not**, in either port. Rust's in-app copy writes SVG to the
  system clipboard as well, and paste tests for SVG FIRST, so an ordinary in-app
  copy/paste takes the SVG branch and never reaches `tab.clipboard`. §8 also
  records four previously-unrecorded defects found while measuring, one of them a
  live divergence that fires on ordinary use.

---

## 8. THE INTERNAL CLIPBOARD, CONFIRMED

**Closes the ratification condition of 2026-07-28** — *"Yes we will have to
confirm the internal clipboard."* Referee pass, no behaviour changed.

### 8.0 The headline, first

**THE BRIEF'S CENTRAL CLAIM SURVIVES.** Neither port creates a layer on the
internal path, and a multi-layer paste is flattened in both. R2 and R3 stand as
ratified; the implementation lanes are not blocked.

But **two sentences of §7 were factually wrong**, and one of them shaped how this
phase was scoped:

1. **Swift has no internal clipboard at all.** `EditClipboard.pasteClipboard`
   has exactly two branches — SVG, and plain-text-becomes-a-Text-element. There
   is no third fallback. The only "rich clipboard" in Swift
   (`TypeTool` / `TextEditSession`) is tspan-scoped for text editing and never
   carries elements. The internal clipboard is a **Rust-only** construct
   (`TabState.clipboard: Vec<Element>`, `jas_dioxus/src/workspace/app_state.rs:68`).
2. **The internal path is not what in-app copy/paste uses most — in either
   port.** Rust's copy writes the selection SVG to the *system* clipboard AND
   snapshots `tab.clipboard`; `clipboard_read_and_paste` then tests for SVG
   **first** (`clipboard.rs:176-210`) and returns from that branch. So an
   ordinary in-app copy -> paste in Rust takes the **SVG** branch. `tab.clipboard`
   is reached only when the system clipboard is unreadable or holds non-SVG text
   (`clipboard.rs:212-213`). That is precisely where the ports diverge, below.

The flattening question turns out to be settled **at copy, not at paste**, in
both ports — which is a stronger result than the brief claimed, and it is why no
paste-side fix alone can deliver R3.

### 8.1 Where the internal clipboard is, and what it stores

| | Rust | Swift |
|---|---|---|
| store | `TabState.clipboard: Vec<Element>` (`app_state.rs:68`) | **none** |
| copy writes | system clipboard (SVG) **and** `tab.clipboard` | system pasteboard (SVG) only |
| copy sites | 5, byte-identical payload | 1 (`EditClipboard.copySelection`) |
| paste reads | SVG first, then `tab.clipboard` | SVG, else plain text |
| carries layer identity? | **no** — `Vec<Element>` has nowhere to put it | **no** — one unnamed `Layer` |

Rust's five copy sites — `keyboard.rs:327` (Cmd+C), `keyboard.rs:376` (Cmd+X),
`menu_bar.rs:129` (menu Cut), `menu_bar.rs:166` (menu Copy),
`renderer.rs:3572` (`doc.copy_selection_to_clipboard`) — all store the identical
expression:

```rust
doc.selection.iter().filter_map(|es| doc.get_element(&es.path).cloned()).collect()
```

`get_element` returns the ELEMENT. The layer it came from is never recorded. So
**Rust's internal clipboard is structurally incapable of carrying layer
identity**, and the flattening is total before the paste sink runs.

Swift's `copySelection` (`EditClipboard.swift:30`) builds
`Document(layers: [Layer(children: elements)])` — **one** layer, and an
**unnamed** one — from a selection that may have spanned many. Same conclusion by
a different route, and it confirms §1's aside: because in-app copy emits an
unnamed layer, Swift's name-match branch **cannot** fire for in-app copy. That
was inferred in the brief; it is now measured (mutation M5 below made the emitted
layer *named*, and the name-match branch immediately fired).

### 8.2 The four questions, answered

| Q | answer | evidence |
|---|---|---|
| Q2 does the internal path flatten? | **yes, in both — at COPY** | Rust `internal_copy_payload_is_flat_elements_carrying_no_layer_identity`; Swift `copyAcrossTwoLayersEmitsOneUnnamedLayerCarryingNoLayerIdentity` + `pasteOfACrossLayerCopyPutsEverythingInTheActiveLayer` |
| Q3 does either create a layer? | **no, neither** | Swift `pasteNeverCreatesALayerForATwoLayerNamedFragment` (2-layer foreign fragment -> 1 layer, both children flattened); Rust by payload type + read of `clipboard.rs:213-234` |
| Q5 ids | **copied verbatim, both** — identity duplicated | Swift `pasteCopiesElementIdsVerbatimSoIdentityIsDuplicated`; Rust `internal_paste_keeps_the_source_id_so_identity_is_duplicated`. Corroborated in-source: `element.rs:2247-2252` already states `clear_ids` is deliberately NOT called by the paste path |
| Q6 offset | **consistent**; `paste_in_place` correctly applies none | Swift `pasteAppliesTheOffsetToACompoundThroughTheWholePath` + `pasteInPlaceAppliesNoOffsetThroughTheWholePath` (end-to-end, not just the helper); Rust `internal_paste_offsets_and_paste_in_place_does_not` |

A cross-layer copy is **not** forbidden by any guard — unlike D2's group guard,
copy accepts a selection spanning parents and silently flattens it.

### 8.3 Q4 — the ports DIVERGE, and it fires on ordinary use

The divergence is not *inside* the internal path; it is at the two points where
Rust consults `tab.clipboard` and Swift does something else entirely.

**D4 — plain, non-SVG text on the clipboard.** Copy a rect in jas, then copy some
text in another application, then paste.

* **Rust**: the text is not SVG, so the SVG branch is skipped and the fallback
  pastes `tab.clipboard` — **the rect again**. The text the user actually copied
  is silently discarded, and stale artwork appears instead.
* **Swift**: creates a Text element holding that text.

Same gesture, two entirely different documents. Pinned by
`plainTextPasteBuildsATextElementWhereRustWouldPasteItsInternalClipboard`.
(Rust routes plain text to a *text-editing session* first, `clipboard.rs:158-171`
— so this fires whenever no text session is active, i.e. normal canvas work.)

**D5 — empty or unreadable clipboard.** Rust pastes `tab.clipboard`; Swift
no-ops (`guard let text ... else { return }`). Pinned by
`emptyPasteboardIsANoOpWhereRustWouldStillPasteItsInternalClipboard`.

**D6 — pasted z-order is nondeterministic in Swift.** Found while measuring Q2.
`Selection` is `Set<ElementSelection>` in Swift (`Document.swift:175`) and
`Vec<ElementSelection>` in Rust (`document.rs:207`). Both copy sides iterate
`doc.selection`, so Rust emits in stored order and Swift emits in **hash** order.
Swift's `Hasher` is seeded per process, so the stacking order of a multi-element
paste can differ between two runs of the same build.

> **Measured**: five selected elements, ten separate `swift test` processes.
> Orders observed: `2,3,1,0,4` · `1,3,2,0,4` · `3,4,1,0,2` · `4,3,1,0,2` ·
> `4,2,3,0,1` · `4,1,0,3,2` · `4,0,3,1,2` · `2,0,1,4,3` · `3,4,2,0,1` ·
> `1,3,2,0,4`. **Ten runs, ten orders; document order never once observed.**
> Rust's twin (`internal_copy_payload_order_is_deterministic_selection_order`)
> is stable over ten iterations.

This is a live prime-directive divergence on the **shared SVG path**, not only
the internal one, so it affects every copy/paste of more than one element. Two
tests in the new suite had to be written order-insensitively because of it; that
concession is documented at each site rather than hidden.

**D7 — repeated pastes do not stack (SHARED defect, not a divergence).**
`workspace/actions.yaml:186` specifies *"Repeated pastes stack with cumulative
offsets."* Neither port implements it: paste never mutates the clipboard, so
every paste applies the same 24pt offset and the second paste lands **exactly on
top of the first**. Pinned by
`repeatedPastesDoNotStackCumulativelyAsTheSpecRequires` (measured: second paste
at x=24, not 48). Rust has the same shape by reading — it re-reads an unmutated
`tab.clipboard`. This is a tier-1 spec sentence that no port meets.

**A transport property, noted not filed.** `documentToSvg` scales points to px
(x4/3) and emits 4 decimals; `svgToDocument` scales back. So `x = 1` returns as
`0.999975` — every clipboard round trip quantizes geometry by ~2.5e-5 pt. Rust's
internal fallback clones `Element` values and is **exact**; Swift, having no
internal clipboard, has no lossless copy/paste path at all. Below any plausible
visual threshold, but it is the reason the new Swift probes assert geometry to
1e-3 rather than 1e-9, and that tolerance is derived, not guessed.

### 8.4 What was driven, and what was only read — the honest split

**Driven (real production code):** all of Swift. `EditClipboard.copySelection`
and `pasteClipboard` take an injectable `NSPasteboard`, so all 10 Swift probes
drive the true paste path end to end.

**NAMED GAP — Rust's paste SINK is unreachable from `cargo test --lib`.**
`clipboard_read_and_paste`'s body (`clipboard.rs:212-234`) sits inside a
`spawn_local` closure — a wasm-only executor — over an `Rc<RefCell<AppState>>`
and a Dioxus `Signal`, neither constructible outside a Dioxus runtime. As the
work order anticipated, it was **read, not driven**. What was driven instead:

* the **payload** the five copy sites store (the expression reproduced verbatim
  in the test), which is where the layer question is actually decided;
* `translate_element`, the one helper the sink calls.

The sink itself — twenty lines that push each payload element into
`doc.layers[doc.selected_layer]` — is asserted on a reading. **The class is OPEN
to that extent**: if the sink is ever changed, no `cargo test --lib` gate will
see it. Closing it needs either the `paste` op verb §5 already calls for, or a
pure helper extracted from the closure. Not done here — this pass changed no
behaviour.

**Also not done, and why:** no GUI was driven (§7's first blind spot stands, now
narrowed to the interactive layer); `jas_flask` and the frozen ports were not
examined; and the reference interpreter has **no** paste or clipboard code at
all, so it could not arbitrate — a grep of `workspace_interpreter/*.py` for
`paste|clipboard` returns nothing, which independently confirms §5's machinery
gap.

**Spec silence, worth stating.** `actions.yaml` §paste / §paste_in_place specify
the offset and the resulting selection and say **nothing about layers**. Both
ports' flattening is therefore an unwritten default, not a spec violation — which
is exactly the vacuum R2/R3 are meant to fill.

### 8.5 Gates

New: 4 Rust probes in `jas_dioxus/src/workspace/clipboard.rs`
(`internal_clipboard_confirm_tests`), 10 Swift probes in
`JasSwift/Tests/Clipboard/InternalClipboardConfirmTests.swift`.

| gate | before | after |
|---|---|---|
| `cargo test --lib` | 2737 passed / 0 failed / 18 ignored | **2741** passed / 0 failed / 18 ignored |
| `swift test` | 2768 tests / 20 suites | **2777** tests / 21 suites |
| `check_naming_rule.py` | OK, 1366 files | OK |

These are CHARACTERIZATION probes: they assert today's behaviour, not R2/R3's.
So their evidence is their **mutation proof**, each cause reverted individually,
production restored after every one:

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | `get_element` returns the containing layer | 2 failed — `payload[0] is a Layer`; order probe `left: [NaN x5]` |
| M2 | Rust | `translate_element` clears the rect id | 1 failed — `left: None, right: Some("keel-1")` |
| M3 | Rust | `translate_element` drops `dy` | 2 failed — `left: (31.0, 11.0), right: (31.0, 35.0)` |
| M4 | Swift | paste creates a layer on name miss | 5 failed — `layers.count -> 3 == 1`; `layer count moved 2 -> 3` |
| M5 | Swift | copy emits one layer per SOURCE layer | 3 failed — `copy emitted 2 layers`; **and layer[1] gained a child, proving the name-match branch fires once the emitted layer is named** |
| M6 | Swift | paste mints (clears) the id | 1 failed — `kids[1].id -> nil == "keel-1"` |
| M7 | Swift | plain-text branch removed | 2 failed — `expected the plain text to append one element, got 1` |
| M8 | Swift | paste offset forced to 0 | 3 failed — `pasted x 0.0 is not source x 0.0 + 24`; `paste_in_place` probe correctly stayed GREEN |

M8's split result is the useful one: it shows the offset's two halves are
separable, so a repair cannot satisfy one by breaking the other.

**Mutation-proof gap, stated:**
`internal_copy_payload_order_is_deterministic_selection_order` reproduces the
copy expression rather than calling it (the production copies are inline in
closures). M1 does reach it through `get_element`, but a change to the copy
expression *itself* at any of the five sites would not be caught. That is the
same unreachability as the sink, one level up.

### 8.6 Banked for a JYH ruling — not decided here

1. **D4/D5: what should paste do with non-SVG text, and with an empty
   clipboard?** The ports disagree today and both answers are defensible. Rust's
   fallback is arguably the R2 defect in miniature — *invisible state deciding
   what gets pasted* — since `tab.clipboard` is not what the system clipboard
   says. Deleting Rust's fallback would make the ports agree and would delete the
   only "internal clipboard" in the codebase. **This decision should be taken
   before R2 lands, because R2 rewrites the same function.**
2. **D6: is pasted z-order part of the contract?** If yes, Swift's `Selection`
   must become ordered (or every consumer must sort), which is a wide change well
   beyond paste. If no, the corpus must never assert paste order. Recommend
   ruling it IS part of the contract — stacking order is artwork — but the fix is
   its own work order.
3. **D7: implement cumulative paste stacking, or amend the spec sentence?**
   Both ports are silent on it today, so nothing regresses either way.
