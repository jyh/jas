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

> **IMPLEMENTED 2026-07-28 — see §9.** Both ports, with the `paste` op verb and a
> 12-case cross-language family §5 said had to be built first. Swift went **10 of
> 12 RED** before the change.

### R3 — "Paste, preserving layers" is a separate, explicit command
Creates a layer when the fragment names one that does not exist; **appends into
the existing layer when the name matches** (JYH, 2026-07-28 — this settles the
open question the brief raised).

*Deliberately NOT a persistent preference.* A hidden mode that changes what Cmd+V
does is the same defect R2 rejects: invisible state deciding where artwork goes.

> **IMPLEMENTED 2026-07-28 — see §9.** Menu-only, no chord, reason recorded in
> `shortcuts.yaml`. **Its honest limit, from §8.0:** an in-app copy emits an
> UNNAMED layer in both ports, so over an in-app copy this command behaves
> exactly like plain Paste. It bites on FOREIGN fragments, which is the case §2
> argued it was for.

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

---

## 9. R2 AND R3, IMPLEMENTED — and the gate that had to be built first

**Lands the two paste rulings of §3.** R1 (group) is NOT in this pass.

### 9.0 The headline

R2 and R3 are implemented in both active ports, and — the part that matters —
they are **watched**. §5 recorded that `op_apply` had no `paste` verb in either
port, so *no fixture could reach any paste behaviour* and both rulings would have
landed completely unwatched. That is fixed first and the rulings ride on it.

**Swift's name-matching was not deleted, it was MOVED.** Plain Paste is Rust's
flatten in both ports; the name-matching is what "Paste, Preserving Layers" now
does, plus the layer creation it always lacked. Each port had implemented half
the answer, and both halves survive.

### 9.1 The machinery, built first

| piece | Rust | Swift |
|---|---|---|
| pure body | `op_apply::paste_fragment_into` | `pasteFragmentInto` (`OpApply.swift`) |
| `Model` wrapper | `op_apply::apply_paste` | `applyPaste` |
| op verb | `"paste"` arm in `op_apply` | `case "paste"` in `opApply` |
| production caller | `clipboard_read_and_paste` (now thin) | `EditClipboard.pasteClipboard` (now thin) |
| R3 command | `"paste_preserving_layers"` menu arm | `EditClipboard.pasteClipboardPreservingLayers` |

**The op verb routes through the PRODUCTION body.** A verb that re-implemented
the paste would be a decoy that never goes red; mutation M6 below severs the
routing and the family reds immediately, which is the evidence that it does not.

`paste` is **VALUE-IN-OP** — the fragment markup travels in the op as `svg`.
It has to: the clipboard is EXTERNAL state, so a journaled paste that re-read the
clipboard on replay would not be a function of the journal. Every case therefore
also passes the `checkpoint_equivalence` gate, which replays the op from its own
params.

**§8.4's NAMED GAP IS CLOSED.** That section recorded Rust's paste sink as
unreachable from `cargo test --lib` — `spawn_local` over an `Rc<RefCell<AppState>>`
and a Dioxus `Signal` — so the twenty lines deciding where pasted artwork lands
were asserted on a *reading*. Those lines no longer live there. What remains in
the closure is the clipboard read plus one call.

The fragment is normalized to `(optional layer name, elements)` per entry, so the
**SVG path and the internal-clipboard path run the same body** and cannot
diverge. A bare element (Rust's `TabState.clipboard` payload) has no name, so
preserve mode degenerates to R2 for it — correctly, since there is nothing to
preserve.

### 9.2 The corpus family

`test_fixtures/operations/paste_layers.json` — 12 cases, both ports, goldens
shared. Setup is `multi_layer.svg` (layers "Background" and "Foreground",
Background active).

It **pins the R2/R3 difference over one input rather than describing it**:
`paste_one_name_match_still_flattens_into_active` and
`paste_preserving_one_name_match_appends_and_creates` carry a **byte-identical**
`svg` — a fragment whose first layer is named "Foreground", a name the document
HAS, and whose second is "Sky", which it does not — and differ only in
`preserve_layers`. The first requires both children in the ACTIVE layer (R2); the
second requires the append into "Foreground" AND the creation of "Sky" (R3).

`paste_preserving_unnamed_fragment_layer_falls_back_to_active` and
`paste_single_unnamed_layer_flattens_into_active` point at the **same golden
file**, so "preserve degenerates to R2 for an unnamed layer" is pinned by file
identity rather than by two goldens that could drift apart.

### 9.3 RED FIRST — measured, in Swift

The family and its goldens were authored and generated from Rust, then run
against Swift **before any Swift change**:

> **10 of 12 cases FAILED.** The two that passed are the two no-op cases
> (`paste_family_setup_...` and `paste_empty_fragment_is_a_benign_noop`), which
> pass because Swift's unknown-verb path leaves the document unchanged — so the
> family DISCRIMINATES rather than being uniformly red.

After R2/R3 landed in Swift: **12 of 12 green.**

Rust's implementation preceded its family, so Rust's evidence is mutation proof,
not red-first. That difference is stated rather than smoothed over.

### 9.4 Mutation proof — every cause reverted INDIVIDUALLY

Production restored and verified byte-clean (`git diff --stat` purely additive)
after every one.

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | R3 preserve branch neutered | 3 failed — locked probe `left: [(5.0, 5.0)]  right: [(5.0, 5.0), (25.0, 26.0)]` |
| M2 | Rust | match but never CREATE | 1 failed — layers `['Background','Foreground','Sky','Ground']` → `['Background','Foreground']`, counts `[1,1,1,1]` → `[3,1]` |
| M3 | Rust | name-match on the DEFAULT path (undo R2) | 2 failed — `plain Paste must land in the ACTIVE layer, name match or not`, `left: [(0.0, 0.0)]  right: [(0.0, 0.0), (25.0, 26.0)]` |
| M4 | Rust | offset forced to 0 | 4 failed — **and the three zero-offset probes correctly stayed GREEN** |
| M5 | Rust | match the ORIGINAL doc, not the working one | 1 failed — `[('Sky', 2)]` → `[('Sky', 1), ('Sky', 1)]`, two layers of one name |
| M6 | Rust | verb no longer routes through `apply_paste` | 1 failed immediately — **the verb is not a decoy** |
| M7 | Swift | R3 preserve branch neutered | 3 probes + 3 corpus preserve cases failed |
| M8 | Swift | the OLD field-list `Layer` rebuild restored | 3 probes failed — `id → nil` (want `"lyr-sky"`), `visibility → .preview` (want `.invisible`), and the locked assertion. **The corpus family stayed GREEN.** |
| M9 | Swift | match but never CREATE | 4 corpus cases failed; the probes, which all match, stayed GREEN |

**M4 and M9 are the useful splits**: they show the offset's two halves, and R3's
match-half and create-half, are separable, so a repair cannot satisfy one by
breaking the other.

**M8 is the most important row in this table**, for two reasons, below.

### 9.5 A defect found while implementing, and repaired: Swift's paste dropped layer fields

Swift's old paste rebuilt the target layer as
`Layer(name:children:opacity:transform:)` — a hand-written four-field list
against a struct with twelve. So **pasting into a layer silently discarded its
`locked`, `visibility`, `blendMode`, `mask`, `isolatedBlending`, `knockoutGroup`
and `id`.** Pasting into a locked layer UNLOCKED it; pasting into a hidden layer
REVEALED it; pasting into an identified layer DESTROYED its identity. This is the
Swift copy-site omission class (EDIT_SEMANTICS_FREEZE.md §3.1), landing at a
paste, and it shipped on main. It is a Preservation Law violation on its face: an
edit must preserve what it does not speak to, and a paste does not speak to
whether the target layer is locked.

The repair is the shape that cannot drift again: the new body **mutates the layer
value in place**, so there is no field list to fall behind. Measured by M8, which
restores the old rebuild verbatim and reds exactly those assertions.

Rust never had this defect (`children_mut()` mutates in place).

### 9.6 The blind spot M8 exposes, stated plainly

**Under M8 the shared cross-language corpus family stayed GREEN while three
in-port probes went RED.** That is not a footnote, it is the honest strength of
this pass's gating: every corpus case is seeded from a `setup_svg`, and **the SVG
codec does not persist `locked` at all**, so a layer parsed from SVG is always
unlocked, visible and id-less. The corpus is *structurally blind* to the entire
locked / hidden / layer-id question.

What watches it is per-port probes only — Rust
`op_apply::paste_layer_structure_tests`, Swift `PasteLayerStructureTests` — which
is a weaker watch than a shared golden, because the two ports can fail
differently without any single file moving. **The class is OPEN to that extent.**
Closing it needs `locked` in the SVG codec (or another seeding route), which is
its own work order.

The same probes carry the bare-element fragment shape, for the same reason: the
op verb feeds `svg_to_document(...).layers`, which is always layers.

### 9.7 What R3 cannot do, and it follows from §8.0

§8.0 found that **the flattening is settled at COPY, not at paste**. That result
constrains this one, and the constraint is real rather than theoretical:

> **"Paste, Preserving Layers" over an IN-APP copy behaves exactly like plain
> Paste, in both ports.** Rust's copy payload is a `Vec<Element>` with nowhere to
> record a layer; Swift's `copySelection` emits ONE UNNAMED layer. Either way
> there is no name to preserve, so R3 has nothing to work with.

R3 bites on **foreign** fragments — externally-sourced SVG that names its layers
— which is exactly the case §2 argued it was for ("with paste the artist is
importing FOREIGN structure"). So the ruling is delivered as ruled. But anyone
expecting Cmd+C / "Paste preserving layers" inside one document to round-trip
layer structure will not get it, and **no paste-side change can give it to
them**. That needs a ruling on whether an in-app COPY should carry layer
identity, which touches Rust's five copy sites and Swift's one.

### 9.8 The spec

* `workspace/actions.yaml` §paste — was silent on layer targeting (§8.4 noted the
  vacuum). It now states that everything lands in the ACTIVE layer, that a
  fragment's layer names are ignored, why, and where to go instead. It also
  states the locked/hidden and id behaviours.
* `workspace/actions.yaml` §paste_preserving_layers — NEW, comprehensive.
* `workspace/actions.yaml` §paste_in_place — gained one sentence: its layer
  targeting is plain Paste's.
* `workspace/menubar.yaml` — Edit menu gains "Paste, Preserving &Layers".
* `workspace/shortcuts.yaml` — **no binding**, with the reason recorded in the
  file: Ctrl+V and Ctrl+Shift+V are taken, every remaining V combination is
  either unreachable mid-gesture or a platform-collision risk, and the case for a
  chord is weakest exactly where the command is meant to be chosen consciously.

**One sentence was deliberately NOT touched.** §paste still says *"Repeated
pastes stack with cumulative offsets."* §8.3's D7 measured that no port
implements it (second paste lands at x=24, not 48). Removing the sentence would
decide a question that is BANKED for JYH (§8.6 item 3), so it stays.

`workspace/workspace.json` regenerated.

**A gate caught the menu change, which is worth recording as a good sign:**
`algorithm_menu_state_vectors` went red on the new Edit-menu item.
`test_fixtures/algorithms/menu_state.json` was regenerated **from the reference
interpreter** (`workspace_interpreter/menu_state.py`), not from either port — a
golden regenerated from a port it gates would agree with itself. The delta was
then verified mechanically to be exactly one new row per vector plus
`select_all` shifting `[1,8]` → `[1,9]`, with `enabled` correctly following
`state.tab_count > 0` (False in `no_document`, True in the other three).

### 9.9 BANKED — no ruling invented

1. **IDS. The verb DOES expose it.** `paste_duplicates_the_source_id_verbatim` is
   a cross-language golden in which **two live elements carry the id `rect-1`** —
   the source and its paste. Under the cardinality law a paste is 0→N and should
   mint fresh; it does not, in either port. Deliberately unchanged: a separate
   ruling. The golden is what will move the day it lands. The paste op's
   `targets` list is left EMPTY on purpose, so duplicated identities are not
   baked into the recipe layer as though legitimate.
2. **OPEN QUESTION 1 — a created layer's name.** Taken VERBATIM, no
   disambiguation, and placed at the END of the layer list. Verbatim is what
   "preserving" means, and a disambiguated name would make the second paste of
   one fragment create a THIRD layer rather than append. The risk §6 named — two
   documents' "Layer 1" being fused — is real and unaddressed. Conservative,
   commented at both bodies, pinned by
   `paste_preserving_multi_layer_no_name_match_creates_both_layers`.
3. **OPEN QUESTION 2 — locked and hidden targets.** Append SUCCEEDS; the layer is
   neither unlocked nor revealed nor refused. This pins what the ports did rather
   than inventing an answer. Note the user-facing consequence, which is why it
   wants a ruling: **a paste into a hidden layer is invisible, so the command
   looks like it did nothing.**
4. **D4/D5 from §8.6 remain unsettled and R2 has now landed on top of them.**
   §8.6 recommended settling them BEFORE R2 because R2 rewrites the same
   function. It was not settled, and R2 was implemented anyway per the work
   order. The rewrite is **behaviour-preserving** for both: Rust still falls back
   to `tab.clipboard` on non-SVG text and on an unreadable clipboard, and Swift
   still builds a Text element / no-ops. So nothing was foreclosed — but the
   divergence is still live and still unwatched by any gate.

### 9.10 What was NOT done

* **R1 (group) is untouched.** This pass is the two paste rulings only.
* **No GUI was driven.** The menu item and both ports' call sites are wired and
  compile; nobody has watched a paste happen on screen. §7's first blind spot
  stands.
* **`jas_flask` and the frozen ports were not examined**, per the freeze.
* **The reference interpreter has no clipboard code at all**, so it could not
  arbitrate R2/R3 — it arbitrated only the menu golden. The corpus family is
  Rust-vs-Swift.
* **`paste_in_place` has no preserving twin.** The corpus pins
  `paste_in_place_preserving_layers_applies_no_offset` through the op verb, so
  the combination is gated, but no menu command reaches it.

### 9.11 Gates

| gate | before this pass | after |
|---|---|---|
| `cargo test --lib` | 2741 passed / 0 failed / 18 ignored | **2748** passed / 0 failed / 18 ignored |
| `swift test` | 2778 tests / 21 suites | **2786** tests / 22 suites |
| `pytest workspace_interpreter/` | 1268 passed | 1268 passed |
| `cross_language_algorithms.py` | 1086 (465+396+225) | 1086 (465+396+225) |
| `check_corpus_manifest.py` | 26 families / 457 files / 31 gaps | 26 / **468** / 31 |
| `check_naming_rule.py` | OK | OK (+ `--self-test` OK, 22 cases) |
| `check_workspace_json.sh` | up to date | up to date |

Three coverage-gap rows updated in `scripts/corpus_manifest.json`:
`paste-flow-layer-targeting-divergence` (RESOLVED),
`paste-offset-compound-divergence` (its remaining OPEN half closes — that row's
`unblock` predicted this fix's shape exactly), and
`identity-law-duplication-verbs-id-less` (its paste half is now watched, though
still unfixed).

---

## 10. RULINGS TAKEN AFTER RATIFICATION (the defects this phase surfaced)

### D6 — Swift's `Selection` becomes an ordered array. RULED 2026-07-28.
> JYH: *"agreed to use vec for swift, with a thought that once we have AI
> assistance, we may be large selections, but let's deal with it at that point."*

**QUEUED, not yet implemented.**

Swift's `Selection` is a `Set` (`Document.swift:175`); Rust's is a `Vec`
(`document.rs:207`). Measured: copy emits in per-process hash order — 5 elements,
10 processes, **10 different orders, document order never once**. This is on the
SHARED SVG path, not just the internal clipboard.

**Ruled on determinism, not performance.** The z-order of a copied fragment is
part of the artwork: paste the same selection twice and the stacking can differ.
Performance does not decide it — membership queries dominate (18 Swift sites, 38
Rust), but the worst nested scan (`renderer.rs:9488`) is in a **Cmd-click
handler**, bounded by user interaction rather than frame rate, and Rust already
builds a local `HashSet` beside it where the cost showed. For realistic selection
sizes a linear scan over a small array likely beats hashing anyway.

**Deliberately NOT an ordered-set type.** An array-plus-index would keep dedup and
O(1) lookups, but Swift has no stdlib `OrderedSet`, so it means a dependency or
~40 lines of our own — and it would diverge from Rust's representation. Identical
representation in both ports is worth more than the convenience.

**THE MIGRATION HAZARD, named up front:** `Set` gives free deduplication. Rust
pays for order with manual guards (`if !doc.selection.iter().any(...)` before
every push). Every Swift insertion site needs the same guard or duplicate
selections appear. That is the **Swift copy-site omission class**, which has bitten
this project three times — so the sites must be enumerated BY THE COMPILER, not by
a human reading. Removing a defaulted initializer parameter is the ratified trick.

**Deferred by JYH, consciously:** large selections under AI assistance may change
the performance calculus. Revisit then, with data — not before.

### D7 — cumulative paste offsets. RULED 2026-07-28: follow the spec.
> JYH: *"D7: yes, follow the spec."*

`workspace/actions.yaml:186` already specifies *"Repeated pastes stack with
cumulative offsets."* **Neither port implements it** — measured, the second paste
lands exactly on the first (x=24, not 48); `paste_count`/`pasteCount` have zero
hits in either port. Both ports are wrong TOGETHER, so this is a tier-1 spec
violation rather than a divergence, and no adjudication was needed: the written
requirement stands and the code must meet it.

Implement the stacking; do NOT amend the sentence. (A previous lane started to
delete that sentence and correctly put it back — deleting a requirement is
deciding a ruling.)

### Open question 1 — layer naming on create. RULED 2026-07-28: verbatim.
> JYH: *"R3: verbatim."*

When R3's preserving paste creates a layer the document lacks, it takes the
fragment's layer name **exactly as given**, not a disambiguated variant.
"Preserving layers" means preserving them, names included; a user who reached for
that command wants their names back. The known cost is accepted: two documents'
"Layer 1" can fuse on a later paste, which is the same command doing what it says.

### Open question 3 — mixed depths under R1. RULED 2026-07-28: frontmost wins.
> JYH: *"R1: preference for frontmost."*

When a selection spans different DEPTHS — an element alongside something nested
deeper inside a group — the **frontmost path wins, even when it is the deeper
one**, so a shallower element is pulled INTO the group. This confirms the
conservative reading the R1 lane took to compile and pinned in a fixture; it is
now ruled rather than provisional.

Consistent with R1 itself: frontmost governs placement in both cases, so there is
one rule to remember rather than two.

---

## 11. STILL OPEN — not ruled, and NOT to be inferred

These were put to JYH in the same sitting and were not answered. They are
recorded as open rather than resolved, because assuming a ruling is exactly the
failure this document exists to prevent.

1. **Paste and element ids.** Both ports copy ids VERBATIM, so a pasted element
   can duplicate a live identity. The cardinality law says a paste is 0 -> N and
   should mint fresh, so this looks ratified-by-implication — **but it touches
   IDENTITY, and identity rulings in this project have twice been got wrong by
   inference.** It needs JYH's explicit word. The `paste` verb landed with R2/R3
   is what finally makes it gateable.
2. **R3 into a LOCKED or hidden layer.** Unaddressed everywhere in the spec. The
   proposal on the table was: append succeeds and the layer STAYS locked --
   locking guards against accidental edits and an explicit paste is not
   accidental, while silently unlocking discards a state the artist set and
   failing would be the silent no-op that R1 just abolished. Not ruled.
3. **Cross-artboard selections.** Nobody has looked. It may already work, or be a
   fourth instance of this family. **Measure before ruling.**

### Paste and element ids — RULED 2026-07-28: MINT FRESH.
> JYH: *"Paste ids, it seems we have to mint fresh, we should not duplicate."*

A paste is 0 -> N under the cardinality law, so pasted elements take FRESH ids.
Both ports currently copy ids verbatim.

**The shipped spec contradicts this ruling and must be corrected**:
`workspace/actions.yaml` says *"Pasted objects keep the ids they were copied
with"* in BOTH paste descriptions, and that text is on public `main`. It was the
lane's provisional reading, written before the ruling existed. Code and spec both
change.

### Locked layers — the question was reframed by measurement, then RULED.
> JYH: *"the artist will assume locked means locked, no changes, but if we
> silently drop that is also a problem... paste into a new similarly-named layer
> when the target layer is locked."*
> Then, after the measurement below: *"yes, lock should protect contents."*

**WHAT THE MEASUREMENT FOUND.** Both ports have `effective_visibility` /
`effectiveVisibility` which INHERIT visibility down the tree — `select_all`
computes `min(layer_vis, child.visibility())`. But for locking the same code
checks `child.locked()`, the child's OWN flag, and **there is no
`effective_locked` anywhere in either port.**

So **locking a layer does not protect its contents today.** Its children stay
individually selectable, clickable and editable; the lock only stops you
selecting the layer object itself. The question "what should paste do with a
locked layer" could not be answered honestly until that was known, because the
premise — that lock protects anything — was false.

**RULED: lock must protect its contents.** An artist locks a layer in order to
work around it. Scoping is under way (`seat/fleet/SCOPE-effective-locked.md`);
it is a change well beyond paste, touching selection, hit-testing and every
operation that walks children, and the SVG codec may not persist `locked` at all
— which would make persistence a prerequisite rather than a detail.

**The paste behaviour follows from it, and is JYH's proposal:** once lock really
protects, pasting into a locked layer would create content the artist cannot
touch, so R3 diverts to a NEW similarly-named layer — neither violating the lock,
nor silently dropping artwork, nor stranding it. It is also *visible*: a new
layer appears in the panel. Generalised, R3's rule becomes **"append into the
matching layer if it can accept content; otherwise create."**

Two costs on the record: this is the one place R3's ratified VERBATIM naming does
not hold, so it needs a stated exception and a naming convention; and whether the
divert follows automatically or needs its own ruling is listed as an open
question in the scope.

**The currently shipped text is the opposite** — *"A matching layer that is locked
or hidden is appended to unchanged: the paste neither refuses nor unlocks nor
reveals it"* — published, provisional, and now superseded pending the scope.
## 12. D4 AND D5 — TEXT ON THE CLIPBOARD PASTES AS TEXT

**Closes §8.6 item 1 and §9.9 item 4.** JYH ruled at council 2026-07-28:
**Swift is canon; Rust drops the internal-clipboard fallback.** D5 was ruled in
the same breath and in the same direction, and nothing was found that makes the
empty case differ from the text case, so nothing was banked in its place.

### 10.0 The headline

**The internal clipboard is deleted, not merely bypassed.** `TabState.clipboard`
had exactly **one reader** — the fallback in `clipboard_read_and_paste` — and
**five writers**. Removing the reader left the field write-only, so the field
went with it, and all five copy sites now write the system clipboard and nothing
else, which is exactly what Swift's single `copySelection` does. That is the
enumeration the work order asked for, done mechanically:

| site | what it did | what it does |
|---|---|---|
| `keyboard.rs` Cmd+C | SVG + `tab.clipboard` | SVG |
| `keyboard.rs` Cmd+X | SVG + `tab.clipboard` + delete | SVG + delete |
| `menu_bar.rs` Cut | SVG + `tab.clipboard` + delete | SVG + delete |
| `menu_bar.rs` Copy | SVG + `tab.clipboard` | SVG |
| `renderer.rs` `doc.copy_selection_to_clipboard` | SVG + `tab.clipboard` | SVG |

The verifying grep is `grep -rn "\.clipboard" jas_dioxus/src/`: before, five
writes and one read; after, none.

### 10.1 The machinery, and why it is not a parallel path

The work order said to use the `paste` verb R2/R3 landed, not to build beside
it. That verb's `svg` param carries **fragment markup**, which presupposes the
SVG branch was already chosen — so it could not express the D4/D5 question at
all. It gained a **`text`** param carrying the **raw clipboard payload**, before
any branch is chosen, and that is the only new surface.

| piece | Rust | Swift |
|---|---|---|
| predicate | `op_apply::clipboard_text_is_svg` | `clipboardTextIsSvg` |
| text branch | `paste_text_element_into` | `pasteTextElementInto` |
| the dispatch | `paste_clipboard_text_into` | `pasteClipboardTextInto` |
| `Model` wrapper | `apply_paste_clipboard_text` | `applyPasteClipboardText` |
| production caller | `clipboard_read_and_paste` (now one call) | `EditClipboard.pasteClipboard` (now one call) |

`text` routes an SVG payload into the **same** `paste_fragment_into` body the
`svg` param reaches, and that is pinned **by file identity, not by assertion**:
`paste_clipboard_svg_payload_through_text_equals_the_svg_param` and
`paste_single_unnamed_layer_flattens_into_active` point at ONE golden file, so a
second copy of the paste body behind `text` could not stay agreeing with it.

`null` in `text` means **the clipboard read failed**; `""` means **readable and
empty**. They are kept as distinct inputs rather than collapsed at the call
site, so the corpus pins each and a future ruling that wants them to differ has
a seam to move. Both no-op today.

### 10.2 RED FIRST, in BOTH ports at once — and how that was possible

`test_fixtures/operations/paste_clipboard_text.json` (11 cases) was authored
**and its goldens HAND-AUTHORED from the canonical test-JSON encoding**
(`jas_dioxus/src/geometry/test_json.rs`, the `Element::Text` arm plus
`tspan_json` and `common_fields`) rather than generated from a port. That is
what made a simultaneous two-port red possible: a golden generated from a port
can only ever red the other one.

> **Rust**: `op 'paste' unexpectedly errored: MissingParam(svg)` — the first case
> aborts the family.
> **Swift**: **18 recorded issues across 10 of the 11 cases.** The eleventh is
> the setup case, which has no `txns` and therefore cannot fail — so the family
> DISCRIMINATES rather than being uniformly red.

Rust was then implemented and the family went green **without a golden being
regenerated**: the hand-authored bytes and the implementation's bytes matched
exactly, first run, all 11 cases. That is a stronger result than a green, and it
is the only evidence in this brief that the spec and the code were derived
independently.

### 10.3 A second defect, found and repaired red-first in the same seam

**Swift's plain-text branch dropped the target layer's fields.** It rebuilt the
layer as `Layer(name:children:opacity:transform:)` — a hand-written four-field
list against a twelve-field struct — so **pasting text into a locked layer
UNLOCKED it, into a hidden layer REVEALED it, and into an identified layer
DESTROYED its identity.** The Swift copy-site omission class
(EDIT_SEMANTICS_FREEZE.md §3.1) at a paste, and it shipped on main. §9.5
repaired exactly this shape on the SVG path and left it standing here.

> **Measured before the repair**, by
> `pasteOfPlainTextPreservesTheTargetLayersOwnFields`:
> `locked -> false` (want `true`), `visibility -> .preview` (want `.invisible`),
> `id -> nil` (want `"lyr-sky"`). Three issues.

This had to be repaired rather than banked: Rust's new text branch uses
`children_mut()` and is field-preserving by construction, so leaving Swift's
rebuild in place would have **created** a fresh divergence out of the fix for
this one. The repair is the shape that cannot drift again — the branch mutates
the layer value in place, so there is no field list to fall behind.

### 10.4 Mutation proof — every cause reverted INDIVIDUALLY

Production restored and verified after every one; the family was re-run green
between each.

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | D4 text branch removed | 3 failed — corpus `paste_clipboard_plain_text_becomes_a_text_element`, plus both text probes |
| M2 | Rust | the `""` guard removed | **1 failed — `paste_clipboard_empty_text_is_a_noop` ONLY**; the unreadable case correctly stayed green |
| M3 | Rust | the `<?xml` arm of the predicate deleted | **1 failed — `paste_clipboard_xml_declaration_payload_takes_the_svg_branch` ONLY** |
| M4 | Rust | baseline drop removed (`y = offset`) | 3 failed — `left: (24.0, 24.0)  right: (24.0, 40.0)`; `left: (0.0, 0.0)  right: (0.0, 16.0)` |
| M5 | Rust | the verb no longer routes through `apply_paste_clipboard_text` | 1 failed immediately — **the `text` param is not a decoy** |
| M6 | Rust | the text branch appends but does not select | 3 failed — selection `left: 0  right: 1` |
| M12 | Rust | the unreadable (`text?`) arm removed | **1 failed — `paste_clipboard_unreadable_is_a_noop` ONLY** |
| M7 | Swift | D4 text branch removed | 11 issues across 5 tests, 5 of them corpus cases |
| M8 | Swift | the `!isEmpty` half of the guard removed | **2 issues — the empty-STRING probe and one corpus case**; the unreadable probe stayed green |
| M13 | Swift | the `nil` half of the guard removed | **3 issues — the unreadable probe, the empty-pasteboard probe, one corpus case**; the empty-STRING probe stayed green |
| M9 | Swift | the OLD field-list `Layer` rebuild restored | 3 issues, exactly the three field assertions — **and the corpus stayed GREEN** |
| M10 | Swift | `EditClipboard.pasteClipboard` no longer calls the dispatch | **11 issues across 9 tests in 2 suites**, including every pre-existing paste probe — the production wire is real |
| M11 | Swift | the verb no longer routes through `applyPasteClipboardText` | 8 corpus cases failed |

**M2 / M12 and M8 / M13 are the useful splits**: they show the empty case and
the unreadable case are separately watched, so neither is riding on the other.
Without them the two no-op cases would be indistinguishable from vacuous.

**M9 is the most important row**, for the same reason M8 was in §9.4: **under it
the shared cross-language corpus stayed GREEN while three in-port assertions went
RED.** §9.6's blind spot, restated with a live example — every corpus case is
seeded from a `setup_svg` and the SVG codec does not persist `locked` at all, so
the corpus is structurally blind to the locked / hidden / layer-id question on
the text branch exactly as it is on the SVG branch. That class remains OPEN and
is watched by per-port probes only.

### 10.5 What this gate reaches, and what it does NOT

**Reached, in both ports, over shared goldens:** everything from the payload
string down. Text becomes a Text element at `(offset, offset + 16)` in the
active layer and becomes the selection; markup that is not SVG stays text;
whitespace-only text is still text; an empty string and an unreadable clipboard
each no-op; and all three SVG payload shapes (`<svg`, `<?xml`, leading
whitespace) route into the shared R2/R3 body.

**Reached in Swift only:** the WIRE. `EditClipboard.pasteClipboard` takes an
injectable `NSPasteboard`, so `ClipboardTextPasteTests` drives read -> dispatch
-> document edit end to end (M10 is what proves that is not decorative).

**NOT reached in Rust, and this is the named obstacle the work order
anticipated:** the clipboard READ. `clipboard_read_and_paste` still reads inside
a `spawn_local` closure over an `Rc<RefCell<AppState>>` and a Dioxus `Signal`,
neither constructible outside a Dioxus runtime. The dispatch was lifted OUT of
that closure — which is what makes everything above reachable — but the read
itself, the text-editing-session hand-off above it and the `begin_txn`/`commit`
bracket below it are still asserted on a **reading**. So the two ports are
watched to different depths and only the shallower depth is common. Recorded as
the coverage-gap row `rust-clipboard-read-unreachable-from-cargo-test`, with the
unblock (an injectable reader parameter) stated there.

**Also NOT done:** no GUI was driven in either port; `jas_flask` and the frozen
ports were not examined; the reference interpreter still has no clipboard code
at all, so it could not arbitrate — this family, like `paste_layers.json`, is
Rust-vs-Swift.

### 10.6 §8.5's mutation-proof gap, closed on the way past

§8.5 recorded that `internal_copy_payload_order_is_deterministic_selection_order`
**reproduced** the copy expression rather than calling it, so a change at any of
the five copy sites would not have been caught. There is no expression left to
reproduce: the module is renamed `copy_payload_tests` and both probes now drive
the production `selection_to_svg` through a real `AppState`, round-tripping the
payload back through `svg_to_document`. The two D4/D5 characterization probes at
the end of `InternalClipboardConfirmTests` are deleted — they pinned a
divergence that no longer exists, and what replaces them makes the ports AGREE
rather than recording that they do not.

### 10.7 The spec

`workspace/actions.yaml` §paste gains the clipboard-content rule in three
ordered paragraphs (a drawing, any other text, nothing at all), plus one
sentence stating that a paste leaves the target layer's own lock, visibility,
name and identity alone — the sentence §10.3's defect violated.
§paste_preserving_layers and §paste_in_place each gain the same rule by
reference. `workspace/workspace.json` regenerated.

**The sentence still NOT touched**: §paste's *"Repeated pastes stack with
cumulative offsets."* D7 remains banked (§8.6 item 3) and no port implements it.

### 10.8 Gates

| gate | before this pass | after |
|---|---|---|
| `cargo test --lib` | 2756 passed / 0 failed / 18 ignored | **2760** passed / 0 failed / 18 ignored |
| `swift test` | 2794 tests / 23 suites | **2802** tests / 24 suites |
| `pytest workspace_interpreter/` | 1268 passed | 1268 passed |
| `cross_language_algorithms.py` | 1086 (465 + 396 + 225) | 1086 (465 + 396 + 225) |
| `cross_language_commutativity.py` | 28 + 28 oracle | 28 + 28 oracle |
| `check_corpus_manifest.py` | 26 families / 478 files / 31 gaps | 26 / **483** / **32** |
| `check_naming_rule.py` | OK, 1392 tracked text files | OK, 1392 (+ `--self-test` OK, 22 cases) |
| everything else in house law 8 | OK | OK |

The full set was run, not the subset expected to matter: `check_menu_structure`,
`check_intent_map` (237 actions), `check_toolbar_structure`, `check_action_refs`
(257 references), `check_panel_goldens`, `check_path_b_exclusions`,
`genericity_check`, `check_preservation_corpus` (12 vectors),
`check_corpus_manifest --self-test`, `lane_report --self-test`,
`check_workspace_json`. **No golden outside the new family moved** — the
`paste` verb's `svg` arm is untouched, so `paste_layers.json`'s twelve cases and
`menu_state.json` are byte-identical.

### 10.9 Banked — no ruling invented

1. **The canon Text element carries `fill: null`.** Swift's
   `Text(x:y:content:)` defaults `fill` to nil, so a pasted text object has no
   explicit fill and relies on SVG's implicit black. Rust now matches it exactly,
   because matching Swift is the ruling. Whether a pasted text object should take
   the current fill (as the Type tool's would) is a real question and this pass
   did not answer it — the golden is what will move.
2. **Whitespace-only text is a paste.** The guard tests byte-emptiness, not
   trimmed-emptiness, so three spaces produce a Text element holding three
   spaces. Swift's behaviour, pinned rather than invented, with its own corpus
   case so a ruling moves a visible byte.
3. **D6 (nondeterministic Swift paste z-order) and D7 (no cumulative paste
   stacking) are untouched** and remain exactly as §8.6 banked them.

---

## 13. LOCK IS INHERITED, NOT MATERIALIZED. RULED 2026-07-28.

> JYH: *"yes, let's choose inheritance: a locked layer locks everything inside,
> and those elements cannot be unlocked."*

This settles the fork the scope uncovered. Full costing:
`seat/fleet/SCOPE-effective-locked.md`.

### What the scope found, and why this was a fork at all
**The shipped spec already contained a lock-propagation design, and it was the
opposite one.** `workspace/panels/layers.yaml:81-85` and
`workspace/actions.yaml:1505-1512` specify **MATERIALIZATION**: locking a
container WRITES `locked=true` onto each direct child, saving their prior states
in transient app state for restore on unlock, one level deep. Meanwhile the Rust
comments at `controller.rs:2800` and `doc_primitives.rs:79` assert the exact
opposite — *"the lock is NOT materialized onto children."* **The spec and the
implementation contradicted each other in writing, and neither actually protected
contents.**

Both designs satisfy the ruling that lock protects contents. They differ in what
they can EXPRESS:

| | materialization | inheritance (RULED) |
|---|---|---|
| child unlocked inside a locked parent | expressible | **not expressible** |
| depth | one level | whole subtree |
| restore state | transient, app-lived | none needed |
| survives save/reload | no (restore table is not in the document) | yes |

### The ruling
**Inheritance.** `effective_locked(path)` ORs down the path, mirroring
`effective_visibility`. A locked layer locks everything inside it, at every
depth, and **those elements cannot be individually unlocked** — JYH ruled the
expressiveness loss explicitly, not by omission.

Consistent with the visibility precedent: nothing anywhere lets a child be
visible inside an invisible parent, and lock now behaves the same way. One rule
to learn instead of two.

### What follows automatically
* **Materialization is REPEALED** — the two YAML specs are rewritten, and the
  `layers_saved_lock_states` / `savedLockStates` machinery is deleted. Keeping
  both would double-apply: lock a layer, children get written locked, unlock it,
  restore fires against a state inheritance already made meaningless.
* **R3's locked-layer divert** (JYH's earlier proposal: paste into a new
  similarly-named layer) now has a real premise, because a locked layer will
  genuinely refuse content. It remains listed as an open question in the scope —
  whether it follows automatically or needs its own ruling.
* Scope stone 3's deleted restore-on-unlock behaviour is observable only through
  the Layers panel, and panel interaction has no shared corpus, so its removal is
  watched by the widget-tree snapshot rather than by a behavioural gate. Stated,
  not smoothed over.

### The prerequisite, and it is not optional
**`locked` does not survive an SVG round trip in either active port** — Rust
writes one hardcoded `locked: false` at `svg.rs:1350`, Swift writes nothing. Every
conformance fixture is SVG-seeded, so **the shared corpus is structurally blind to
lock** and cannot gate this ruling at all until the codec carries it. That is also
why the corpus stayed green through the unlock-on-paste bug. Persistence is scope
stone 1, before enforcement.

### Do first, ruling or not — five live divergences
The scope found five, all source-confirmed, inside the code this ruling touches.
Two are worse than the ruling and unrelated to it: **`ungroup_all` in Swift drops
`symbols`, `artboards`, `artboardOptions`, `documentSetup` and `printPreferences`
from the Document plus seven fields from every rebuilt Group** (the copy-site
omission class again), and **Rust iterates layers in the wrong z-order in
hit-testing**, where Swift, the Python reference and Rust's own inner loops all
agree against it. Also measured: **Align's documented lock rule is unimplemented**
— `align.rs` mentions `locked` on two lines and both are comments.

### 13.1 STONE 1 LANDED — `jas:locked`, the prerequisite (2026-07-28)

The prerequisite above is closed. `common.locked` now survives an SVG round trip
in **both** active ports, so the shared conformance corpus can finally start a
case from a locked document and the ruling becomes gateable.

**The spelling, and the reasoning that picked it.** ` jas:locked="true"`, in the
`urn:jas:1` namespace, written immediately after the element's `id`.

The scope left this open (its Q5) between `sodipodi:insensitive` and
`data-locked`. Both were rejected:

* The precedent is the **sibling `CommonProps` field**. `tool_origin` is written
  `jas:tool-origin` by both ports and read by both, in the same namespace,
  emitted only when set (`svg.rs` `tool_origin_attr` / `parse_common`;
  `Svg.swift` the `<path>` arm and `parseElement`). The five arrowhead
  attributes (`jas:start-arrow` and friends) are the same shape. `locked` is a
  `CommonProps` field, so it belongs where its siblings live.
* `sodipodi:insensitive` carries a **measured hazard**, not merely a different
  taste. JasSwift decides whether to declare `xmlns:jas` by matching the
  ` jas:` PREFIX in its emitted body — a guard written *after* an undeclared
  prefix made Foundation reject a WHOLE document and the artwork came back
  empty. A `jas:`-namespaced attribute inherits that guard for free. A
  `sodipodi:`-namespaced one would need `needsSodipodi` widened (it is
  currently `needsNamedview` alone), and forgetting that re-opens exactly the
  hole the guard was built to close.
* `data-locked` is already shipped in **jas_flask** (`svg_io.mjs:96,225`) but
  only for leaf shapes — `:144` and `:156` hard-code `locked: false` for `<g>`,
  so it cannot express a locked layer at all. Adopting it would import a
  spelling that does not cover the case the ruling is about.

**Written only when true, so golden churn is zero** — measured, not assumed: 0
of the elements across the 60 SVG fixtures carry `locked = true`, and no shipped
golden moved. Same conditional-key convention as `fill-rule="evenodd"`. Only the
exact string `"true"` locks on read; a foreign or malformed value must not
silently protect artwork the artist never protected.

**The copy-site omission class, handled by making the COMPILER enumerate.** Both
ports hand-inline their attribute lists per element kind (16 arms in Rust, 15 in
Swift). Every arm in both ports already called `id_attr` / `idAttr`, so that
helper took a REQUIRED `locked` argument and became `id_lock_attrs` /
`idLockAttrs`; the compilers then listed the sites — 10 in Rust, 15 in Swift —
and neither would build until every one was answered. On the read side Rust
already funnels every kind through one `parse_common`; Swift's reader builds
fourteen different structs, so it applies `Element.withLocked` once at
`parseElement`, whose own switch the compiler checks for exhaustiveness over all
twelve cases.

**A second defect, found by the census fixture and repaired.** JasSwift promotes
a top-level bare `<g>` to a Layer by rebuilding it field by field, where Rust
carries `common: g.common.clone()` and loses nothing. `locked` is threaded now.
The fields still dropped there — `visibility`, `blendMode`, `mask`,
`isolatedBlending`, `knockoutGroup` — are a REAL divergence from Rust that no
SVG gate can see, because none of them survives an SVG round trip in either port
either. Named in a comment at the site; `isolatedBlending` / `knockoutGroup` were then
the standing coverage gap `container-blend-fields-survive-no-codec`.

**That gap CLOSED on 2026-07-28** (CONTAINERFLAGS), which retires half of the
sentence above: `isolatedBlending` and `knockoutGroup` now survive **all three**
codecs in both ports — the canonical test JSON emits them conditionally on true,
the binary codec carries two container-private trailing slots, and SVG carries
` jas:isolated-blending` / ` jas:knockout-group` in the same `urn:jas:1`
namespace `jas:locked` uses. All four cells are asserted in
`test_fixtures/expected/codec_field_survival.json`, whose `fields` list gained
`group.*` and `layer.*` rows so the two container kinds are measured separately.
`visibility`, `blendMode` and `mask` are unchanged by that wave and remain
SVG-invisible.

**THE REFERENCE CANNOT ADJUDICATE THIS, and that is a standing fact about lock
persistence, not a gap this stone left.** `workspace_interpreter/` has **no SVG
codec at all** — measured: `svg` appears in four files and every occurrence is
prose in a comment. It *does* model lock (`common.locked` on its document dicts,
read by `doc_primitives._child_is_locked` and reachable from expressions as
`element_at(path(0)).common.locked`), so it can adjudicate lock SEMANTICS and
already prunes locked subtrees in `hit_test`. It cannot adjudicate lock
PERSISTENCE, in this or any codec. For Stone 4 that is fine: enforcement is
semantics. It is recorded here so no later wave mistakes the reference's silence
for agreement.

**What is gated.** `common.locked` is now a watched row of
`test_fixtures/expected/codec_field_survival.json` in all three codec columns
(it was absent, which is why the drop was structurally invisible even though the
saturated Path the gate round-trips has carried `locked: true` since the file was
written). Two new SVG fixtures — `locked_layer_and_element.svg` (the semantic
vector: a locked LAYER whose children carry no flag of their own, plus a locked
ELEMENT inside an unlocked layer) and `locked_all_kinds.svg` (the writer-arm
census) — are registered in four lanes per port plus the cross-language
commutativity driver, whose OFF-DIAGONAL cells are what prove the two ports
agree on the spelling rather than each agreeing with itself.

**BANKED, not decided** — each needs JYH, and none blocks Stone 4:

1. **Interop read.** Should the readers ALSO accept `sodipodi:insensitive`, so a
   layer locked in Inkscape opens locked here? There is precedent for a
   dual-spelling read (`name` accepts `inkscape:label` OR a `<title>` child),
   and it is one line per port — but it is a second decision that Q5 owns, and
   both ports must move together.
2. **jas_flask.** It still writes and reads `data-locked` on leaf shapes only,
   so a locked rect saved by the flask renderer still loses its lock in the
   active ports and vice versa. Flask is the non-gating reference renderer, so
   this is a divergence by policy rather than a defect — but it is a divergence.
3. **The frozen ports.** `jas_ocaml/lib/geometry/svg.ml:1038` and the Python Qt
   app still parse `locked = false` unconditionally. Correct per the freeze; the
   consequence is that a file saved by an active port and reopened in a frozen
   one silently unlocks. Stated, not fixed.

### 13.2 STONE 2 LANDED — `Object > Lock` stops materializing (2026-07-28, LOCKMAT)

**§13's repeal was half-landed and the half that shipped had teeth.** The
Layers-panel path was repaired; `Object > Lock` — the menu item, Ctrl+2, and the
`lock_selection` op verb — kept a SECOND, recursive implementation that stamped
`locked = true` onto every descendant of a Group. Two doors to the same artist
action wrote different documents, on public `main`.

Both are now one shape. `Controller::lock_selection` is clone-then-mutate
through `get_element_mut`; `Controller.lockSelection` calls
`Element.withLocked(true)`, the very helper `togglingElementLock` uses. Rust's
`lock_element` is deleted. The spec says the rule too: `workspace/actions.yaml`
§lock and §unlock_all.

**MEASURED, and it narrows the scope's framing: the residue was GROUP-ONLY, in
both ports.** Rust recursed under `new.is_group()`, which is
`matches!(self, Element::Group(_))` and excludes `Element::Layer`; Swift recursed
in its `case .group` arm alone. Locking a LAYER never stamped in either port. The
layer vector in the new family is therefore a control, kept so the repair cannot
be read as "stop writing the flag" — and it is not vacuous: mutations M3/M6,
which materialize onto a layer's children, red it and nothing else.

**RED FIRST, IN BOTH PORTS AT ONCE.**
`test_fixtures/operations/lock_selection_no_materialization.json`, 7 cases:
**3 of 7 failed in Rust and 3 in Swift, on exactly the same case names**, before
either port moved. The family discriminates — the setup, both controls and the
leaf case were green throughout. That simultaneity was possible because **not one
golden was generated from the behaviour it pins** (§15.5's device):

* the group and leaf headlines point at the PANEL family's own goldens BY FILE
  IDENTITY, which pins `Object > Lock` as an **equation** — it must produce
  exactly what the lock button produces on the same element, which is the thing
  that had stopped being true;
* `unlocking_a_group_frees_its_children` shares one golden with
  `control_clicking_a_child_of_an_untouched_group`, so the lock/unlock round trip
  is pinned against a document nothing touched;
* the three new goldens were DERIVED from `lock_toggle_group_locked_expected.json`
  by flipping named flags.

**A preservation vector had pinned the PRE-RULING answer, and was turned rather
than deleted.** `lock_a_group_keeps_the_group_itself` named `r_back` and
`r_front` as SUBJECTS with `must_change: ["locked"]` — it asserted the
materialization in as many words, and it went red on the fix. They are
BYSTANDERS now, a strictly stronger claim.

**Mutation proof — 6 causes, each reverted INDIVIDUALLY, whole suite each time:**

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | Group recursion restored | 2 failed — the new family AND `preservation_invariants` |
| M2 | Rust | the wholesale selection clear dropped | 3 failed — new family + `action_corpus` + `controller::tests::lock_selection` |
| M3 | Rust | materialize onto a LAYER's children | **1 failed — ONLY the new family**, so the depth control earns its place |
| M4 | Swift | Group recursion restored | 4 issues / 2 tests — twin of M1 |
| M5 | Swift | the selection clear dropped | 6 issues / 3 tests — twin of M2 |
| M6 | Swift | materialize onto a LAYER's children | **1 issue — ONLY the new family**, twin of M3 |

No guard was found redundant: every part of the repair is load-bearing, and the
two ports red on matching causes.

#### The rest of the class, enumerated mechanically — and it is empty now

Method: grep every write of `locked` in both ports' non-test sources, then
classify each site. Rust: `renderer.rs` `common.locked` doc.set arm (target-only,
already documented), `effects.rs` and `controller.rs` boolean/group unanimity
carries (mint a new element, not a cascade), `document.rs`
`toggling_element_lock` (target-only), `unlock_element` (recursive BY DESIGN, see
below). Swift: the `doc.set` twin, `Controller.swift:90` unanimity,
`Document.swift` `togglingElementLock`, `LayersPanel.swift:271`
`withLocked(newLocked)` on one top-level layer, `unlockChildren`. `Object > Lock`
was the only remaining materializer in either port.

Three findings that came out of that sweep and are NOT fixed here, each with its
reason:

1. **`unlock_all` keeps its recursion deliberately** — it is the sole
   artist-reachable revocation (EDIT_SEMANTICS_FREEZE **T6(i)**), and it is the
   only thing in either port that can clear flags a document ALREADY carries.
   Comment added at both sites saying so. Note that `toggle_all_layers_lock`'s
   "Unlock All Layers" branch is NOT a substitute: it writes only the top-level
   layer paths.
2. **`unlock_all`'s post-state selection still DIVERGES** (SCOPE §4 D-C): Rust
   clears the selection, Swift re-selects every formerly-locked path, and Swift's
   `collectLocked` starts at depth 2 so a layer's own lock is never collected.
   Real, shared-corpus-gateable, and left alone so this wave stays a gate on
   materialization alone.
3. **`JasSwift/Sources/Interpreter/YamlPanelBodyView.swift:4337`** holds a
   SECOND lock toggle that writes the flag without pruning the selection. It sits
   in `treeRows_OLD`, reached only from `treeRows_DEPRECATED`, and grep finds no
   caller of either — dead code, so it is reported rather than repaired.

#### BANKED FOR JYH — do saved documents need repair? (facts, not a decision)

**Can a stamped child be distinguished from one the artist locked deliberately?
NO, and this is the hard part of the answer.** All three codecs carry a bare
boolean with no provenance: `jas:locked="true"`, one binary slot, one JSON key.
The one asymmetry available is a pattern, and it is necessary but not sufficient
— the old `lock_element` stamped the ENTIRE subtree, so a locked group with any
UNLOCKED descendant cannot have come from `Object > Lock`; but a fully-locked
subtree is exactly what an artist also gets by locking a small group's children
by hand. A migration keyed on the pattern would silently unlock deliberate work,
most often on the small groups where it is likeliest.

**The exposure is much wider than the SVG window, and this is the fact that
should drive the ruling.** `jas:locked` landed on 2026-07-28 (LOCKSVG), hours
before this repair, so almost no SVG file can carry stamped flags. But **both
active ports auto-persist whole documents in the JAS BINARY format for session
restore** — jas_dioxus to `localStorage` every 30 seconds and on `beforeunload`
(`workspace/session.rs`), JasSwift to
`~/Library/Application Support/Jas/session/tabN.jasbin` (`Canvas/Session.swift`)
— and `binary.rs` / `Binary.swift` have packed `locked` on the Group and Layer
arms since well before 2026-06-16. **Stamped flags have therefore been surviving
restart in both ports for as long as the materialization existed.**

The choice, stated without taking it:
* **(a) leave them.** The artist meets a lock they cannot remove except with
  `Unlock All`, which also clears every lock they placed on purpose.
* **(b) clear every descendant flag under a locked container on load.** Lossy in
  exactly one scenario: lock a child, then lock its parent, then later unlock the
  parent and expect the child to still be locked. Under inheritance that child's
  flag is unobservable while the parent is locked, so the loss is narrow — but it
  is silent.
* **(c) neither; make the revocation reachable** — a per-subtree unlock, which
  the ruling's "cannot be individually unlocked" does not forbid at the container
  level.

**Blind spot of the above:** the codec history was established by reading the
packers and `git log -S`, not by opening a real localStorage blob or a `.jasbin`
from any machine. Nobody has measured how many documents actually carry stamped
flags, and no GUI was driven in either port during this wave.

## 14. REPEATED PASTES STACK WITH CUMULATIVE OFFSETS. RULED 2026-07-28.

> JYH: *"follow the spec."*

`workspace/actions.yaml` §paste has carried the sentence **"Repeated pastes
stack with cumulative offsets"** since it was written. Neither active port
implemented it: the second paste landed exactly on the first — invisible, the
one outcome the offset exists to prevent, arrived at by pasting twice instead of
once. Both ports were wrong TOGETHER, so this was never a divergence needing
adjudication. The written requirement governs: implement the stacking, do not
amend the sentence.

### 14.1 The four decisions the sentence leaves open

The spec says "cumulative" and stops. Four things had to be chosen, and all four
are now artist-facing prose in `actions.yaml` (§paste, §paste_preserving_layers,
§paste_in_place) as well as code:

1. **RESET IS KEYED TO WHAT IS PASTED, not to a copy hook.** A paste whose
   payload differs from the one the run is counting starts a new run. This is
   what makes an EXTERNAL copy — from another application — reset the offset,
   which no in-app copy hook could ever see. Re-copying the SAME artwork does
   NOT reset: the first slot already holds the previous paste. A
   SELECTION-keyed reset was considered and rejected with a proof, not a
   preference: paste SETS the selection, so a selection-keyed reset would fire
   after every paste and the run could never reach step two.
2. **`paste_in_place` DOES NOT PARTICIPATE.** It lands on the source, which is
   not a run slot, so it neither advances the run nor restarts it: 24, 0, 48.
3. **"Paste, Preserving Layers" SHARES THE ONE RUN.** The two commands differ in
   WHICH LAYER artwork lands in, never in the offset — §9's ruling, applied.
4. **A PASTE THAT LANDS NOTHING DOES NOT ADVANCE THE RUN.**

### 14.2 The run is keyed to the RAW CLIPBOARD PAYLOAD

`Model.paste_run` / `Model.pasteRunState` holds `(payload, count)` where
`payload` is the raw string — the text a port read off the system clipboard, or
the `svg` fragment markup the corpus supplies. It is offset-independent, it is
what both op params already carry, it costs a string compare rather than a deep
element compare, and "the same clipboard content" is exactly what the spec
sentence is about.

TWO CONSEQUENCES, BANKED AND PROBED, NOT RULED:

- Markup differing only in whitespace is a DIFFERENT payload and restarts the
  run. Conservative: the artist's clipboard did change.
- The run is a SINGLE SLOT. Copying B between two pastes of A loses A's count,
  so the next A lands back on the first. A fragment-keyed run would have the
  same limitation. Pinned by `an_intervening_payload_loses_the_first_runs_count`
  in both ports, so the day a multi-slot run is ruled, a byte moves.

### 14.3 Where it lives, and the lifetime argument

Per-document, session-lived, never serialized, undoable — on the `Model`.

- **NOT `Document`.** It is a value type that many Swift sites rebuild field by
  field, so a new field there is dropped silently at every one of them (the
  copy-site omission class, found five times). It would also survive a save, and
  a paste offset remembered from a previous session is a lie: the clipboard it
  counted is gone.
- **NOT app state.** §13's lock save-state table was ruled a design flaw the
  same day for living somewhere whose lifetime does not match what it describes.
  A counter that outlives the artwork it counts is the same defect: undo the
  second paste and the third would skip to 72, leaving 48 empty — a slot the
  artist can see and cannot fill.

Undoability is bought EXPLICITLY. The `(Document, IdIndex)` undo/redo tuple
became a NAMED `Checkpoint` struct carrying the run, so the COMPILER enumerated
all 13 sites in Rust and all 11 in Swift rather than letting a two-element
destructure silently drop a third field. `begin_txn` captures the PRE-paste run,
so undo-then-paste is exactly redo; abort rolls it back too.

### 14.4 One place the run moves

`paste_run_apply` / `pasteRunApply`. Both model-level entry points route through
it: `apply_paste` (the corpus-only `svg` param) and `apply_paste_clipboard_text`
(the `text` param, which is what BOTH ports' production paste reads after §12).
Measured: a run implemented on `svg` alone leaves ONE corpus vector red and
every per-port probe green, which is precisely the decoy shape.

Rust's production path was REROUTED as part of this: `clipboard_read_and_paste`
called the pure `paste_clipboard_text_into` and bracketed by hand, which would
have left the run unreachable from the artist. Swift's `EditClipboard.pasteClipboard`
already routed through the model-level function and needed no change.

### 14.5 What is watched, and what is not

WATCHED: `test_fixtures/operations/paste_stacking.json`, 9 vectors over shared
goldens in both ports, plus twin per-port probes for undo, redo, abort and the
per-document lifetime — which the operations runner structurally cannot reach,
because it applies `history` AFTER every transaction and an undo op embedded in
a transaction would desync the `checkpoint_equivalence` gate.

NOT WATCHED, and MEASURED rather than asserted: **Rust's production wire.**
Replacing the clipboard payload in `clipboard_read_and_paste` with `None` — so
production pastes nothing at all — leaves all 2784 `cargo test --lib` tests
GREEN. The same mutation in Swift (`EditClipboard.pasteClipboard` reading `nil`)
reddens 19 issues across 14 tests, including both stacking wire probes. This is
the pre-existing `rust-clipboard-read-unreachable-from-cargo-test` gap in
`scripts/corpus_manifest.json`, unchanged by this wave and now covering the
paste run as well: the read still sits in a `spawn_local` closure over an
`Rc<RefCell<AppState>>` and a Dioxus `Signal`. The two ports are watched to
DIFFERENT depths here and only the shallower depth is common.

ALSO NOT WATCHED: no GUI was driven in either port. Nobody has seen a second
paste land at 48 on screen.
### 13.2 STONES 3 AND 4 LANDED — the repeal and `effective_locked` (2026-07-28)

Both stones are ONE semantic change and landed together. Keeping
materialization while adding inheritance would DOUBLE-APPLY: lock a layer,
children get written locked, unlock it, and the restore fires against a state
inheritance had already made meaningless.

**STONE 4 — `effective_locked` / `effectiveLocked.`** ORs `locked` down the
path, mirroring `effective_visibility` / `effectiveVisibility` line for line
(`document.rs`, `Document.swift`). Because the fold is an OR there is
deliberately no escape hatch: a child cannot be unlocked inside a locked
parent, which is the expressiveness loss ruled explicitly above. An empty or
unresolvable path is NOT locked — nothing is protected by an address that names
no artwork.

Wired at three seams per port, and each one had a different defect:

* **`select_element` / `selectElement`** — the smoking gun the scope named. The
  element's OWN `locked` was read ONE LINE ABOVE an ancestor-aware
  `effective_visibility` read, so a click on a child of a locked layer selected
  it, in both ports.
* **`select_all`** (Rust only; Swift delegates to `selectFlat`) — the
  hand-rolled layer→child loop tested `child.locked()` and NEVER the layer's,
  so Select All swept up a locked layer's whole contents. Swift already skipped
  it. **A live prime-directive divergence, not merely a gap** — and one no gate
  could see until `jas:locked` let a fixture start from a locked document.
* **`select_flat` / `selectFlat`** — the layer and child guards became ancestor
  reads, and the GRANDCHILD acquired a guard it never had: a locked member of
  an open group no longer TRIGGERS the group selection nor JOINS it. A rubber
  band that touched only a locked element used to drag the group and its
  unlocked siblings in with it.

Left alone on purpose: `hit_test` / `hit_test_deep` already prune locked
subtrees correctly in Rust, Swift AND the Python reference, and
`select_recursive` / `selectRecursive` already cascade. Nothing there moved.

**STONE 3 — materialization repealed.** `workspace/panels/layers.yaml` and
`workspace/actions.yaml` §`toggle_element_lock` now state inheritance;
`§select_all` says whose flag "locked" means; `§ungroup_all` says the same (see
Q7 below). `AppState.layers_saved_lock_states` (declaration + five construction
sites) and `YamlPanelBodyView.savedLockStates` are DELETED, and with them the
`saved_to_restore` / `savedToRestore` parameter. `workspace.json`,
`intent_map.json` and `INTENT_MAP.md` regenerated.

**THE MACHINERY THAT MADE STONE 3 GATEABLE AT ALL.** The scope listed the
restore-deletion among the things "that CANNOT be watched by a shared
cross-language gate", because the lock button's document work lived only behind
a Dioxus click handler and a SwiftUI closure — no op verb, no action, no
gesture reached it. That is precisely how a spec which WRITES `locked=true`
onto every direct child shipped while the Rust comments eight lines away
asserted the opposite. Two op verbs were added, each routing through the
PRODUCTION mutator rather than a copy of it:

* `select_element` — the path-addressed click seam
  (`Controller::select_element` / `Controller.selectElement`), selection-only
  and non-undoable exactly like `select_rect`.
* `toggle_element_lock` — the panel lock button's document work, now
  `Document::toggling_element_lock` / `Document.togglingElementLock`.

Rust's half of that function MOVED out of the web-gated
`interpreter::renderer` and onto `Document`: it is document logic with no UI in
it, `op_apply` must reach it in a `--no-default-features` build (the
cross-language algorithm driver builds that way, and it went red), and Swift's
twin was already a `Document` method — so the move is toward parity. **BANKED:
its VISIBILITY twin `cycle_element_visibility_at` is still in `renderer.rs`
while Swift's `cyclingElementVisibility` is on `Document`. The same move is
owed, and was not made here because nothing in this wave forced it.**

**RED FIRST, MEASURED, IN BOTH PORTS.** Per-case counts were taken by
generating each case into a unique throwaway golden, because the Rust runner
panics at the first mismatch and would otherwise report "1 failure" for any
number of them.

`test_fixtures/operations/lock_inheritance.json` — **6 of 15 RED in EACH port,
and the same 6:**

| case | before | ruled |
|---|---|---|
| click a child of a locked layer | `[0,0]` | `[]` |
| click a grandchild of a locked layer | `[0,1]`,`[0,1,0]` | `[]` |
| click an unlocked group inside a locked layer | `[0,1]` | `[]` |
| click a child of a locked group | `[1,1]`,`[1,1,0]` | `[]` |
| marquee over the whole document | 4 entries | 3 |
| marquee over only a locked member of an open group | 3 entries | `[]` |

`test_fixtures/actions/lock_inheritance_actions.json` — `select_all` RED in
jas_dioxus, **GREEN in JasSwift**. That asymmetry IS the finding.

`test_fixtures/operations/lock_toggle_no_materialization.json` — **4 of 7 RED
in each port**: locking a layer, locking a group, the lock→unlock round trip,
and the selection prune. The round trip is the one that shows the shipped
design was LOSSY through this seam: the lock wrote flags onto both children and
the unlock, with no restore table to consult, left them locked while the
container itself opened.

Final: `cargo test --lib` 2782 (was 2777) · `swift test` 2828 in 26 suites (was
2823) · pytest 1270 · cross-language 1086 (ORACLE 465 + COMPARISON 396 +
RELATIONAL 225) · commutativity 32+32 · workspace 8+4 · manifest 26 families /
504 files / 34 gaps · preservation 13 vectors.

**Q7 ANSWERED BY DIRECT APPLICATION, NOT BY A NEW RULING.** `ungroup_all`
already READ lock ("except locked ones"); §13 changed what the word MEANS, so
the read follows: a Group inside a locked layer or a locked group is left
alone, structure included. No new guard was added anywhere — this is NOT the
unruled Q3 (whether an operation should refuse to act on a SELECTED locked
element). A sibling lane had pinned the old behaviour deliberately, with the
note *"if lock becomes INHERITED, this assertion is what has to move, and it is
written so the move is visible instead of silent."* It moved, in both ports'
tests, exactly as that lane intended.

**BANKED — each needs JYH, and none blocked these stones:**

1. **Does a container selection sweep up a locked member?** Clicking the free
   member of a mixed group still selects the group AND every child, including
   the locked one. §13 rules on what may be selected by POINTING AT IT, not on
   what a container selection collects. Pinned by
   `click_a_free_member_of_a_mixed_group_selects_the_whole_group`, so the day
   of a ruling is a visible byte change rather than a silent drift.
2. **The Layers panel's own SELECT_SQUARE ignores lock entirely.** Rust's
   `on_select_click` (`renderer.rs`) writes `doc.selection` directly with no
   lock check of any kind — not the element's own, not an ancestor's. Selection
   from the PANEL is therefore still not gated, in a wave whose whole subject
   was the selection gate. Not fixed here because it is GUI-only code no corpus
   drives; it wants a GUI-harness check.
3. **Q3 remains open and is now the visible next gap.** Move, delete,
   transform and align still ignore lock — for a DIRECTLY locked element, not
   just an inherited one — and `align.rs` still mentions `locked` on two
   comment lines and reads it nowhere.
4. **`Q4` — the panel icon.** A child of a locked layer now renders
   `lock_unlocked` (its stored flag) while being unselectable.
   `runtime_contexts.yaml:243` surfaces the stored value, so the icon and the
   enforcement disagree. Unchanged by this wave and stated rather than
   smoothed over.

**WHAT THIS WAVE DID NOT DO.** No GUI was driven in either port: the Layers
panel lock button, the Dioxus handler and the SwiftUI closure are compile-and-
corpus findings only. The deleted restore-on-unlock BEHAVIOUR is not directly
observable by any shared gate — the corpus can prove that unlocking leaves the
children untouched, which is the same fact from the outside, but the tables'
disappearance is watched by the compiler alone. And the frozen ports keep the
materialization design at their tag, correctly.

---

## 15. LOCK IS IMMUTABLE, AND WHAT PASTE DOES ABOUT IT. RULED 2026-07-28.

> JYH, on Q3: *"yes, locked is locked and immutable."*
> On Q6: *"numeric suffixes; hidden is not locked so it can be appended to; I
> think plain Paste should just refuse, it is more intuitive."*

### 15.1 Q3 — a locked element refuses OPERATIONS, not only selection
Selection-level enforcement (§13, Stone 4) was deliberately scoped narrow because
Q3 was unruled. It is ruled now: **locked means immutable.** An operation must
not mutate a locked element even if it somehow reaches one.

The measured surface, from `seat/fleet/SCOPE-effective-locked.md` — every one of
these ignores lock TODAY even for a **directly** locked element:
delete · move / drag / nudge · group / ungroup · boolean ops ·
fill / stroke / brush apply · anchor drag (Rust's direct-Path arm) ·
**Align, whose own module doc states the rule while `align.rs` contains `locked`
on exactly two lines, both comments.**

**STILL OPEN — where the guard lives.** Two shapes, and this was NOT ruled:
* **Per-operation guards** — one check in each of ~8 places. Simple, and it rots
  the way this class always rots: the ninth operation arrives without one.
* **At the write chokepoint** — every mutation already funnels through
  `setDocumentUnbracketed(_:intent:)` (Arc 1, S1). One guard there is inherited
  by every future operation for free. But it must diff a write to know what it
  touched, and some writes legitimately touch locked elements — unlocking, for
  one. **Measure whether the chokepoint can see enough before committing.**

### 15.2 Q6 — the principle: WHO CHOSE THE TARGET
JYH's split between plain and preserving paste is not arbitrary and generalises:

> **Refuse when the ARTIST chose the target. Divert when the FRAGMENT chose it.**

* **Plain Paste (R2) targets the ACTIVE layer — the artist's explicit choice.**
  Landing artwork somewhere else would silently override that choice, which is
  worse than declining. **It refuses.**
* **Preserving Paste (R3) targets a layer named by the incoming fragment.** The
  artist asked for STRUCTURE, not for that layer. Diverting serves their actual
  intent, so **it creates a sibling** rather than refusing.

### 15.3 The three sub-rulings
1. **Numeric suffixes.** A diverted layer takes the fragment's name plus a
   numeric suffix — "Sky" locked ⇒ "Sky 2". This is the ONE place R3's ratified
   VERBATIM naming cannot hold, and it is a stated exception rather than a
   silent one. Precedent in-house: `advance_next_untitled_past` /
   `advanceNextUntitledPast` already suffix Untitled-N numerically.
2. **Hidden is NOT locked.** Hidden is a visibility state, not a protection, so a
   hidden target is **appended to normally** and the artist unhides to see the
   result. Diverting there would manufacture layers to avoid a condition that
   protects nothing. The asymmetry is deliberate.
3. **Plain Paste refuses** into a locked active layer.

### 15.4 A REFUSAL MUST NOT BE A SILENT NO-OP
This is the defect §13 abolished for grouping: select across layers, press Cmd+G,
nothing happens and nothing says why — which reads as broken software.

**Recommended implementation, using machinery that already exists rather than a
new notification system:** declare `enabled_when` on `paste` so the Edit menu
item GREYS OUT while the active layer is locked. The artist then sees the
refusal before attempting it, and Cmd+V doing nothing is explained rather than
mysterious.

Measured: `paste` currently declares **no** `enabled_when`; the expression
language CAN already read `.common.locked` (`actions.yaml:1534,1851`); but there
is **no `active_document.active_layer_locked`** primitive to hang it on. Adding
one is small and well-precedented — `active_document.*` already exposes
`has_selection`, `can_undo`, `current_artboard` and a dozen more.

**Not ruled, flagged:** whether a refusal ALSO wants an active message (status
bar or transient) on top of the disabled item, for the artist who presses Cmd+V
without looking at the menu.

### 15.5 Q6 IMPLEMENTED — both ports, red first, 2026-07-28 (PASTELOCK)

**The headline.** Both halves of §15.2/§15.3 are in both active ports and are
watched by a shared corpus: `paste` refuses into a locked active layer, "Paste,
Preserving Layers" diverts to `"Sky 2"`, hidden is appended into unchanged, and
the Edit menu greys the two refusing commands out while the lock stands.

**§15.1 IS NOT IN THIS WAVE.** Q3's general question — where the operation guard
lives, per-operation or at the write chokepoint — is untouched, and the other
seven or eight operations the scope named still ignore lock. This is paste only.

#### RED FIRST, in BOTH PORTS at once

`test_fixtures/operations/paste_locked_layers.json`, 18 cases, three SVG-seeded
setup documents.

> **8 of 18 RED in Rust and 8 in Swift, on exactly the same case names**, before
> either port moved. The 10 green are the setups, the controls, the anti-blanket
> vector and all three hidden vectors — so the family DISCRIMINATES rather than
> being uniformly red. After: 18 of 18 in both.

That simultaneity was possible because **not one golden was generated from the
behaviour it pins.** Two devices, and the second is the reusable one:

* every REFUSAL points at its own family's SETUP golden **by file identity**, so
  "the document is unchanged" is asserted against the document itself;
* every DIVERT points at a **CONTROL** case that pastes a fragment layer
  literally named `"Sky 2"` into the same setup — behaviour this ruling does not
  touch. **The divert is therefore pinned as an EQUATION** (diverting from a
  locked `"Sky"` must produce exactly what naming the sibling outright produces)
  rather than as a snapshot of the code that implements it. The ten golden files
  were generated from a REDUCED family holding only the unchanged cases, so
  today's wrong answers could not be baked in.

This is the family §9.2 said could not exist. `paste_layers.json`'s `_doc` read
"no `setup_svg` can produce a locked layer" until this wave; `jas:locked`
(§13.1) landed the same day and retired it. Both that sentence and the corpus
manifest's `paste-flow-layer-targeting-divergence` row are updated.

#### The three decisions the ruling left open, and how each was taken

1. **The suffix is a WALK, not a mint.** `name`, `name 2`, `name 3`, … — take
   the first that either does not exist (create it verbatim) or exists and is
   not locked (append into it). Stopping at an EXISTING open `"Sky 2"` instead
   of minting `"Sky 3"` is what keeps a repeated paste from manufacturing one
   layer per repetition, which is the same proliferation argument R3's verbatim
   naming already rests on. Shape from `advance_next_untitled_past`, as §15.3
   asked. Terminates by pigeonhole.
2. **The refusal is WHOLESALE.** A preserving paste carrying both a divertible
   named layer and a loose element bound for the locked active layer lands
   NOTHING. §15 speaks about a paste, not half of one, and a partial paste that
   silently drops content is the failure mode the ruling is written against.
   **Banked below** — it is a decision, not a ruling.
3. **`paste_in_place` refuses too.** `actions.yaml` already says "Layer
   targeting is plain Paste's", so it inherits plain Paste's answer. Not doing
   this would leave Cmd+Shift+V walking straight past the greyed menu item.
   Derived, not ruled; **banked below**.

#### Where the guards live — one per port, per concern

| concern | Rust | Swift |
|---|---|---|
| is the artist's layer locked | `Document::active_layer_locked` | `Document.activeLayerLocked` |
| R2 refusal | `op_apply::active_paste_target` | `activePasteTarget` |
| R3 divert | `op_apply::preserving_layer_target` | `preservingLayerTarget` |

`active_paste_target` is **the one place the R2 refusal lives**, read by both
bodies that target the active layer — the artwork paste and the plain-text
paste. A guard on one would have left the other open, and production reaches
both.

`active_layer_locked` is **one definition with two consumers**: the enforcement
above, and the `active_document.active_layer_locked` menu predicate. A menu that
greyed on one rule while the code refused on another would be worse than either
alone; there is no second rule to drift to.

**One deliberate spelling difference, stated because it is a divergence risk
even at zero divergence today.** Rust's divert reads
`effective_locked(&vec![i])` on a Document; Swift's reads `layers[i].locked` on
the working layer array, because that port's paste body builds a local `[Layer]`
rather than a working Document. For a TOP-LEVEL layer the two are identical — an
OR folded down a path of length one — and a paste target is always top-level.

#### Mutation proof — 13 causes, each reverted INDIVIDUALLY

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | R2 refusal deleted | 2 failed — corpus `plain_paste_into_a_locked_active_layer_refuses_and_changes_nothing` + the inherited-lock text probe |
| M2 | Rust | R3 divert deleted | 4 failed — corpus divert case + all three divert probes |
| M3 | Rust | the walk always MINTS | 2 failed — `…_appends_into_the_existing_numeric_sibling` |
| M4 | Rust | refusal made PARTIAL | **1 failed — ONLY the wholesale case.** The split that proves atomicity is separable from the refusal |
| M5 | Rust | HIDDEN treated as locked | 2 failed — the hidden corpus case + the hidden probe |
| M6–M10 | Swift | the same five | 8 / 11 / 5 / 1 / 3 issues, same case names |
| M11 | YAML | the `enabled_when` term reverted | RED in the SHARED `menu_state` corpus in BOTH ports, plus both live-ctx tests |
| M12 | Rust | ctx builder stops emitting the key | **RED in ONLY the Rust live-ctx test — the shared corpus stayed GREEN** |
| M13 | Swift | ctx builder stops emitting the key | **RED in ONLY the Swift live-ctx test, same proof** |

**M5/M10 are why "hidden is not locked" is a floor and not a sentence.**
**M12/M13 are the load-bearing pair**: they measure that the shared `menu_state`
corpus, which SEEDS its context, is structurally blind to a port that forgets to
BUILD the predicate — and a missing key is null, `!null` is true, and paste
stays enabled, which is silently the pre-ruling behaviour. The per-port live-ctx
tests are therefore not redundant with the corpus, and that was measured rather
than argued.

#### Two measurements in §15.4 above that are WRONG, corrected

1. **"`paste` currently declares no `enabled_when`" is false.** It has declared
   `enabled_when: "state.tab_count > 0"` since 2026-04-12 (`git blame` →
   `07af52e13`). The lock term is CONJOINED onto it. Written as §15.4 describes,
   the new predicate would have silently dropped the no-document guard.
2. **The predicate that greys a menu item lives in `workspace/menubar.yaml`,**
   not in the action's own `enabled_when` in `workspace/actions.yaml`. The
   action-level one is real but is not what the menubar compiles from — the
   first attempt edited only `actions.yaml` and moved zero corpus bytes, which
   is how this was found. Both are updated now.

#### Probes that pinned the PRE-RULING answer, turned rather than deleted

`preserve_appends_into_a_locked_matching_layer_and_leaves_it_locked` (and its
Swift twin) said in as many words that a ruling to refuse or unlock would turn
it red. It did. Three probes lost their `locked: true` target, in both ports,
because a locked active layer now refuses outright — which preserves strictly
more than an append that keeps the flag. Each keeps an inverted lock assertion
as a live discriminator against a copy site that starts INVENTING a lock.

#### A defect in the Swift test suite, found BY the mutation proof

M7's first run did not report failures — it **TRAPPED** with "Index out of
range" and aborted the whole `swift test` process, so the summary line never
printed and any later failure would have been invisible. Cause: `#expect`
records and CONTINUES where Rust's `assert_eq!` panics, so a probe that indexes
a layer the mutant never created runs off the end. Fixed here for the three
probes involved (bounds-safe helper plus hard count guards). **This is a
property of the whole Swift suite, not of these three probes** — any
`#expect`-then-index probe has it. Banked.

#### BANKED for JYH — decisions taken here that a council may want to revisit

1. **Wholesale vs partial refusal** (decision 2 above). The alternative is to
   land the divertible named layers and drop the loose elements, which was
   rejected as silently losing content.
2. **`paste_in_place` refuses** (decision 3 above). Derived from an existing
   sentence in `actions.yaml` rather than ruled.
3. **The ACTIVE MESSAGE was NOT built and nothing was invented for it.** What it
   would need, MEASURED here rather than assumed — method: case-insensitive grep
   over each port's non-test sources for `status_bar` / `statusbar` /
   `status_message` / `toast` / `snackbar` / `notification` / `banner`, and for
   Swift additionally `NSAlert` / `showMessage`:
   * **Rust: zero.** The single hit is a doc comment about `state_store` change
     notifications, which is the reactive-signal sense of the word. There is no
     status bar, no toast, no transient anything.
   * **Swift: zero transient surfaces, but SIXTEEN `NSAlert` sites** (chiefly
     `JasCommands.swift`, plus `LayersPanel.swift` and `ContentView.swift`).
     A modal alert is the WRONG SHAPE for this: it demands a click for a message
     that should evaporate, and it is AppKit, which the iOS-readiness doctrine
     keeps behind thin adapters. It is also Swift-only, so using it would make
     the two ports diverge on a user-visible behaviour.

   So the honest position is that the message is a **UI SUBSYSTEM** — in Rust it
   would be built from nothing — not a detail this wave could have added. Three
   things want settling before any code: the surface and its lifetime; whether a
   refusal is the ONLY client (a one-client notification system is a liability);
   and whether it is per-document or per-window.

   **Blind spot of that measurement:** it is a name-based grep. A message
   surface built under an unguessed name, or one living in a `.rsx`/SwiftUI
   view without any of those words, would not have been found. No GUI was run.
4. **The suffix separator is a SPACE** (`"Sky 2"`, matching §15.3's own
   spelling). A document whose layers are already `"Sky"` and `"Sky 2"` by the
   artist's own hand will therefore see a paste append into their `"Sky 2"`.
   That is the walk working as designed, and it is also the one place where a
   diverted paste lands in a layer the artist made for another purpose.

---

## 16. SELECT ALL SELECTS TOP-LEVEL OBJECTS. RULED 2026-07-28 (D2).

> JYH: *"keep the Rust shape."*

### 16.1 What the two ports actually did
**Rust** `select_all` walks layers then direct children and pushes ONE entry per
child. A group contributes a single entry `[li, ci]`.

**Swift** `selectAll` delegates to `selectFlat`, whose group branch inserts
**both** the group and every unlocked grandchild:

```swift
if anyHit {
    selection.insert(ElementSelection.all([li, ci]))         // the group
    for gi in 0..<g.children.count {
        selection.insert(ElementSelection.all([li, ci, gi])) // AND each child
    }
}
```

A group of three therefore yielded **four** entries. That is the measured
2-entry cardinality difference on a 6-element document.

### 16.2 Why this was a DEFECT, not a competing design
The Swift selection contained an element **and its own descendants at the same
time**, and no operation has a coherent reading of that set: translate it and the
group moves by 24 while each child — already carried by its parent — moves 24
again; delete it and the group goes, then its children are deleted from a parent
that no longer exists.

**The cause is one function serving two callers.** `selectFlat`'s group branch
was written for the MARQUEE, where "did anything inside the band match?" is the
right question and its own comment says so. `selectAll` calls it with
`predicate: { _ in true }`, so every group always hits and a rubber-band rule
fired universally in a context it was never written for. Rust never had the bug
because `select_all` is its own hand-rolled loop rather than a marquee call.

### 16.3 The ruling
**Select All selects top-level objects; a group counts as ONE.** That is what
grouping means — the group IS the object, and entering it is how you reach the
members. Swift changes; Rust is canonical.

`workspace/actions.yaml` §select_all was rewritten today for inherited lock and
is **silent on group expansion**, which is how this stayed unadjudicated. The
ruling goes there, or the next reader re-derives the argument.

### 16.4 STILL OPEN — the invariant underneath
Should the selection MODEL permit an ancestor and its own descendant to be
selected simultaneously at all? If not, that is an assertable invariant, and it
would have caught this without anyone noticing the divergence. **Not ruled.**
Raised because a rule that makes a defect impossible is worth more than a fix
that makes one instance go away.

---

## 17. HOW §15 GETS BUILT: FOUR LAYERS, THREE OF THEM NOW. RULED 2026-07-28.

> JYH: *"defer layer 4. I believe we need to add LockedTarget."*

Full costing: `seat/fleet/SCOPE-lock-immutable.md`.

### 17.1 The ruling was priced as one thing; it is four
Scoping separated what §15 actually requires, and only the last is expensive:

| | layer | cost |
|---|---|---|
| 1 | **Enforcement** — the code path refuses | the ruling itself |
| 2 | **Signal** — a machine-readable refusal | one new error class |
| 3 | **Affordance** — the menu item greys out | small, existing machinery |
| 4 | **Notification** — an active message | **a UI subsystem** |

**Layers 1–3 land now. Layer 4 is DEFERRED, deliberately and on the record.**

### 17.2 Why layer 4 is deferred, and it is not about cost
**Zero message surface exists in either active port** — measured, eight patterns
across four trees, no hits. What exists is 26 modal dialogs (a modal for "that is
locked" is more disruptive than the operation it refuses) and a Swift-only
`NSAlert` with no Rust equivalent, so not even the modal escape hatch is at
parity.

The argument for deferring is not the price. It is that **a channel built to
serve lock would be shaped by lock.** jas needs a transient message channel for
save failures, import warnings, tool constraints and — before long — AI
suggestions. Designing it as "the thing that says you cannot do that", under
schedule pressure from a feature that is not about notification, is how a project
acquires a bad toast system it then lives with for years. **Scope it separately,
when something other than lock is also asking for it.**

**The half-measure objection does not apply here.** Partial closure genuinely
rots in this codebase — the Swift copy-site omission class has five sightings,
each one somebody closing the instances and leaving the category. But that risk
attaches to ENFORCEMENT, not to notification. Deferring layer 4 weakens layer 1
not at all; the two risks live on different layers, which is why they were
decided separately.

**The residual, stated rather than glossed:** an artist who presses the keyboard
shortcut without looking at the menu gets silence. This is NOT the grouping
defect §13 abolished — grouping's no-op had an explanation nowhere, this one has
one in the menu. On macOS a disabled item's key equivalent does not fire at all;
in Dioxus the key router is ours and must be made to honour `enabled_when`, which
it should do regardless.

### 17.3 LockedTarget — RULED, and it widens a FROZEN taxonomy
There is already a cross-language fault taxonomy with a fixture contract: Rust
`OpError` and Swift `OpApplyError`, five classes each (`MalformedEnvelope`,
`UnknownVerb`, `MissingParam`, `BadParamType`, `MissingTarget`), asserted through
`expected_error` in 11 files under `test_fixtures/operations/`.

**A sixth class, `LockedTarget`, is added.** It gives the refusal a
**corpus-gated, cross-language signal today**, independently of any UI channel —
which is precisely what makes deferring layer 4 safe rather than lossy. The
refusal becomes provable in both ports the moment it is implemented.

**Both ports declare the taxonomy FROZEN in comments, so this is a ratified
widening, not an implementation detail.** It is recorded here as such. Note the
honest limit: `workspace_interpreter/` does not implement the channel at all
(zero hits for `expected_error`/`OpError`), so "cross-language" here means **two
ports, not three**, and the live reference cannot adjudicate a lock refusal.

### 17.4 What is NOT part of this decision
Two items in the scope are bugs today no matter how §15 had been ruled, and
must not be counted as its price:

* **S0 — `Object > Lock` still MATERIALISES** in both ports
  (`controller.rs:2797`, `Controller.swift:892`), stamping `locked = true` onto
  every descendant. §13 repealed that and only the Layers-panel path was fixed.
  **This is worse because of our own work:** §13.1 landed `jas:locked`
  persistence, so the stamped flags now survive save/reload and, under
  inheritance, are individually unremovable — unlock the parent and the children
  stay locked, which is exactly the outcome §13 ruled against. Unpushed, so
  nothing is published. **Fix first.**
* **D-A — Swift destructively converts a LOCKED path.** `hitTestPathCurve`
  (`CanvasSubwindow.swift:3201`) has no lock check anywhere, so the Type-on-Path
  tool converts a locked Path where Rust refuses (`type_on_path_tool.rs:107`).
  Live data loss.
## 18. D2 AND D6, IMPLEMENTED — and the gate that had to be un-blinded first

**Lands §16 (D2) and §10 (D6) together.** They were separable as rulings and
not as code: both live in JasSwift's selection subsystem, and the D2 repair
rewrites a function whose type D6 changes.

### 17.0 The headline

Both are implemented in both active ports and both are **watched** — but only
after a third thing was fixed, which was not in either ruling and is the most
useful finding of the pass:

> **The shared corpus was structurally blind to selection ORDER, in BOTH
> ports.** `test_json::selection_json` / `TestJson.selectionJson` SORTED the
> selection by path before emitting it. Every golden therefore agreed no matter
> what order either port produced. That is why D6 — ten different orders over
> ten processes, measured in §8.3 — never moved a shared byte.

The sort is gone. Rust stayed **green with zero golden churn**, which is the
half worth stating: Rust's runtime selection order already IS document order in
every corpus case, so making the property visible cost nothing. JasSwift went
**RED with 23 issues across 5 tests** (`actionCorpus`,
`operationControllerOps`, `operationLockInheritance`, `operationPasteLayers`,
`operationSelectAndMove`) — the D6 defect, finally on a shared gate, before one
line of the fix was written.

### 17.1 A defect in the CANONICAL port, found on the way

`Controller::toggle_selection` (Rust) built two `HashMap`s and iterated **them**,
so with two or more surviving entries the shift-marquee's selection order was
Rust's per-process `RandomState` order. **That is D6's own defect, in the port
that is supposed to be canonical**, and the `selection_json` sort is what hid
it. JasSwift's `toggleSelection` had the identical shape over `Dictionary`. Both
are repaired the same way: the maps are lookup-only and emission walks `current`
then `new` in their own order.

No existing golden moved, because no existing case reached `toggle_selection`
with a multi-entry map — so the repair would have been a fix no mutation could
turn red. A case was added for exactly that reason
(`extend_marquee_deselects_one_and_keeps_the_other_eight_in_order`), and M5/M6
below are it going red.

### 17.2 D6 — the migration, and the number that proves the audit was mechanical

`Selection` is `[ElementSelection]`, identical to Rust's `Vec<ElementSelection>`.

**The sites were enumerated BY THE COMPILER.** Changing the typealias makes
`Set.insert(_:)` a type error at every insertion site (`Array.insert` requires
an `at:` index), so the build lists them:

| pass | unique `file:line` errors | files |
|---|---|---|
| production | **28** | 5 — `Controller.swift`, `OpApply.swift`, `Binary.swift`, `TestJson.swift`, `YamlToolEffects.swift` |
| test targets | **23** | 15 |

The second pass exists because Swift stops at the first failing module; the
production number is the one that matters.

**A note for accuracy, correcting what JYH was told at council.**
`swift-collections` IS already a dependency (`JasSwift/Package.swift:12`;
`TreeDictionary` is live in `Document.swift` and `Model.swift`), so `OrderedSet`
would have been free. The ruling stands on the other reason it gave —
identical representation across the active ports beats the convenience.

### 17.3 The dedup guards: 24 of 25 were redundant, and are gone

The first cut of D6 put a `contains(where:)` guard at every enumerated site,
which is what "every Swift insertion site needs the same guard" reads like.
**Measured**: replacing all of them with a plain `append` left the whole Swift
suite GREEN. Under house law a guard no mutation can turn red is deleted, so 24
were deleted and the `appendUnique` extension with them.

That is also the correct answer on parity grounds, which is the stronger
argument: **jas_dioxus pushes plainly at every selection site but two**, because
a path enumerated from `layers[li].children[ci]` cannot repeat. The two Rust
guards are now the two Swift guards, written out at each site rather than hidden
behind a helper:

* `Controller::add_to_selection` / `Controller.addToSelection` — its whole
  contract is idempotence. JasSwift had **no such Controller method at all**;
  the guard was inlined in the `doc.add_to_selection` YAML effect, where nothing
  shared could reach it. It now lives where Rust's lives.
* the magic wand's `"add"` mode — a new match may already be selected.

Two sites take a plain `append` for a stated reason rather than an audited one:
`Binary.unpackSelection` and `TestJson.parseSelection`, because **a codec reads
back what was written** — a duplicate in a file must survive the round trip and
be visible, not be silently repaired by the decoder. Both mirror Rust.

**One behaviour changed as a deliberate parity choice, and is flagged rather
than smuggled:** `doc.set_selection` no longer deduplicates, because jas_dioxus
does not. Under `Set` this port silently deduped a spec naming one path twice.
Nothing in either port's corpus reaches a repeated path there, so this is parity
rather than measurement. **Noticed while reading it:** Rust's `doc.set_selection`
also EXPANDS containers to every descendant and JasSwift's does not — a real,
pre-existing divergence, unrelated to this pass, unwatched by any gate, and
recorded here because nobody had written it down.

### 17.4 D2 — the repair respects the caller it was written for

`selectFlat` is **untouched**, and `selectRect` / `selectPolygon` keep it. Only
`selectAll` changes, into its own loop mirroring Rust's `select_all` line for
line — including its single `effectiveLocked([li, ci])` read, since that read
already folds in the layer's flag and a layer-level short-circuit above it would
be another guard no mutation could red.

The corpus pins the distinction rather than describing it:
`marquee_over_everything_still_expands_groups_unlike_select_all` requires **nine**
entries over the same document that Select All must answer with **four**. A
repair made by deleting `selectFlat`'s group branch reds that case immediately.

### 17.5 The machinery, and the two new verbs

| piece | Rust | Swift |
|---|---|---|
| Select All verb | `"select_all"` arm | `case "select_all"` |
| additive verb | `"add_to_selection"` arm | `case "add_to_selection"` |
| selection-only set | `is_selection_only_verb` | `isSelectionOnlyVerb` |

Both verbs route through the PRODUCTION `Controller` mutator. The growing `&&`
chain that listed the journal-neutral verbs became one named predicate per port,
so a new selection verb has one place to register.

### 17.6 The corpus family

`test_fixtures/operations/select_all_top_level.json` — 8 cases, both ports,
goldens generated from Rust. Setup `select_all_top_level.svg` is new: two
layers, a three-child group beside a solo rect, a two-child group beside a solo
rect. Four top-level objects, nine elements.

Plus one ACTION-seam case,
`select_all_action_counts_a_group_as_one_object` in
`test_fixtures/actions/lock_inheritance_actions.json`, because the Edit menu
dispatches the ACTION and not the op verb; it is evidence that the seam the
artist touches reaches the ruled body. That file's `_doc` said Select All's
group expansion was UNRULED and that a group would red for the wrong reason —
true when written, stale now, and corrected in place.

### 17.7 RED FIRST — measured

| gate | red, before the change | after |
|---|---|---|
| `swift test`, sort removed (D6) | **23 issues in 5 tests** | 2839 / 27 suites GREEN |
| `operationSelectAllTopLevel` (D2) | **2 of 7 cases**: 9 entries where 4 are required, 3 where 2 are | 8 of 8 GREEN |
| `actionCorpus` (D2) | 1 case | GREEN |

The D2 family DISCRIMINATES rather than being uniformly red: five of its seven
cases passed before the fix, including the marquee case and both order cases.

### 17.8 Mutation proof — every cause reverted INDIVIDUALLY

Production restored and the suite re-verified green after each.

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Swift | `selectAll` delegates to `selectFlat` again | 3 issues — `operationSelectAllTopLevel` (2), `actionCorpus` (1) |
| M2 | Swift | restore the path sort in `selectionJson` | 2 issues — exactly the two ORDER cases |
| M3 | Swift | drop `Controller.addToSelection`'s guard | 2 issues — the corpus dedup case + `docAddToSelectionIsIdempotent` |
| M4 | Rust | drop `Controller::add_to_selection`'s guard | 2 failed — the diff shows the literal duplicate, `"selection":[{path:[0,1]},{path:[0,1]}]` |
| M5 | Rust | `toggle_selection` emits survivors in the other order | 1 failed — the extend-marquee case |
| M6 | Swift | `toggleSelection` the same | 1 issue — the same case |
| M7 | Swift | `selectFlat`'s group branch appends the group twice | 2 issues — `operationSelectAllTopLevel` + `operationLockInheritance` |

M2 is the row that matters most: it is the proof that the ORDER is gated and not
merely the membership. M4 is the dedup half, and it is the only place in the
pass where a golden shows a duplicated selection entry.

### 17.9 Gates

| gate | before | after |
|---|---|---|
| `cargo test --lib` | 2790 passed / 0 failed / 18 ignored | **2792** passed / 0 failed / 18 ignored |
| `swift test` | 2838 tests / 27 suites | **2839** tests / 27 suites |
| `pytest workspace_interpreter/` | 1270 passed | 1270 passed |
| `cross_language_algorithms.py` | 1086 (465+396+225) | 1086 (465+396+225) |
| `cross_language_commutativity.py` | 32 comparisons | 32 comparisons |
| `cross_language_workspace.py` | 4 comparisons | 4 comparisons |
| `check_corpus_manifest.py` | 26 families / 512 files / 35 gaps | 26 / **523** / 35 |
| `check_preservation_corpus.py` | 14 vectors, floor 14 | 14 vectors, floor 14 |
| `check_naming_rule.py` | OK, 1437 files | OK, **1448** files |
| `check_encoding_hygiene.py` | 0 violations | 0 violations |
| `check_swift_copy_sites.py` | OK | OK, 25 sites / 21 ledger rows |
| structural gates (menu, toolbar, action refs, panel goldens, path-B, intent map, workspace.json) | OK | OK |
| `jas_flask` | — | 325 passed |

### 17.10 What was NOT done, and why

* **No GUI was driven.** §7's first blind spot stands. Nobody has watched a
  Select All happen on screen in either port; the evidence is the corpus, the
  in-port probes and the mutation table.
* **The reference interpreter could not arbitrate.** `workspace_interpreter/`
  has no selection model of the kind these rulings are about — it is not a
  consumer of `test_fixtures/operations` at all (the manifest lists `rust` and
  `swift`). So this family, like the paste family before it, is Rust-vs-Swift.
  It DID arbitrate one thing: nothing in `menu_state.json` moved.
* **The frozen ports were not examined**, per the freeze. Recorded because it is
  measurable and someone will ask: `cd jas && pytest` fails 6 tests on this
  branch **with and without this pass's changes** — verified by stashing the
  working tree and re-running. Pre-existing, not caused here, not fixed here.
* **§16.4 is still open** — whether the selection MODEL should forbid an
  ancestor and its own descendant at the same time. This pass fixes the one
  instance; it does not make the class impossible. Note that the marquee
  deliberately PRODUCES such a selection, so the invariant cannot simply be
  asserted — it would have to be scoped, and that is the ruling §16.4 wants.
* **`copy_selection` still leaves the selection in DESCENDING path order** in
  both ports, which the new golden now pins. Whether that is the intended
  post-copy selection order or an artifact of iterating backwards to keep
  insertion indices stable is not ruled; it is pinned so the day it is ruled
  moves a visible byte.

### 17.11 BANKED — needs JYH, not decided here

1. **Is the post-`copy_selection` selection order part of the contract?** Both
   ports emit the copies' paths descending, because both iterate the selection
   backwards so insertions do not shift earlier paths. Now golden-pinned. The
   artist-visible consequence is small (it is a selection, not a z-order) but it
   is the one place the corpus asserts a non-document order, so it should be
   ruled rather than inherited from an implementation detail.
2. **`doc.set_selection` diverges twice over, and only one half was touched.**
   Rust EXPANDS a selected container to every descendant; JasSwift selects only
   the named paths. That is a live divergence at a real production seam,
   unwatched by any gate, found by reading during this pass and NOT repaired —
   it is not what either ruling is about, and choosing a winner is a ruling. The
   dedup half was aligned to Rust here.

---

## 19. THE SELECTION AFTER A DUPLICATE IS IN DOCUMENT ORDER. RULED 2026-07-28.

> JYH: *"yes document order."*

`Controller::copy_selection` (the Alt-drag duplicate, not the clipboard) sorts
the source selection **descending** — `sort_by(|a, b| b.path.cmp(&a.path))` — and
must: inserting after `[0,1]` shifts `[0,3]`, so the walk has to run
back-to-front. **That part is load-bearing and stays.**

But the NEW selection was then built in that same descending order, purely as a
byproduct of the loop. Duplicating `[0,1]` and `[0,3]` yielded `[[0,4],[0,2]]`.
Both ports did it; a shared convention nobody ever chose.

**Not cosmetic, because of §10 (D6).** Selection order is part of the document
precisely because a copied fragment's z-order is part of the artwork. So:
Alt-drag-duplicate, then Copy, and the clipboard SVG lists the elements in
REVERSE document order — pasting them stacks them backwards. The defect surfaces
one step from where it is created, which is why it went unseen.

**RULED: the selection a duplicate leaves behind is in document order.** Sort the
result; leave the descending iteration alone. Every other selection-producing
operation already yields document order, so this was the odd one out, and leaving
one operation's order as an artifact would undercut the ruling that made order
semantic in the first place.

*Gate:* duplicate two elements, copy, assert the clipboard's element order
matches document order — the assertion has to reach the CLIPBOARD, because that
is where the byproduct becomes artist-visible.

---

## 19A. §19, IMPLEMENTED — and the byproduct was worse than an order

### 19A.0 The headline

Implemented in both active ports, gated at three levels, and mutation-proven
six ways. **But the ruling's premise was wrong in the artist's favour: the
byproduct paths were not merely mis-ORDERED, they were STALE, and one of them
named a SOURCE element.**

Duplicating `[0,1]` and `[0,3]`, the descending walk copies d first and records
`[0,4]`; it then copies b, and *that* insertion pushes everything above `[0,1]`
up one slot. The recorded `[0,4]` therefore stops naming d's copy (now at
`[0,5]`) and starts naming **d itself**. So the shipped behaviour was not "the
clipboard lists the copies backwards" — it was **"the clipboard contains one
copy and one original"**, and dragging after an Alt-drag duplicate moved one
copy and one source. Measured on the clipboard, in both ports: payload
`[30, 16]` where the copies are at x=16 and x=36.

**The same fact that makes the descending walk load-bearing invalidates the
paths that walk records.** They are one defect seen from two ends, which is why
the repair is one function: `shift_path_for_insertion` /
`shiftedPath(_:forInsertionAt:)` rewrites every already-recorded copy path for
each new insertion, and the §19 sort is then a sort of the RIGHT paths rather
than a tidy list of the wrong ones.

**Why a sort alone would have passed a weaker gate.** Sorting stale paths gives
`[[0,2],[0,4]]` — ascending, document order by inspection, and still naming a
source. Every assertion added here pins ORDER **and** IDENTITY, by path and by
geometry, for exactly that reason.

### 19A.1 RED FIRST — measured, on the commit before the fix

| gate | red |
|---|---|
| Rust `copy_selection_of_two_elements_selects_both_copies_in_document_order` | selection `[[0,4],[0,2]]`, required `[[0,2],[0,5]]` |
| Rust `a_duplicate_then_copy_emits_the_copies_in_document_order` | **clipboard payload `[30.0, 15.999975]`**, required `[16, 36]` |
| Swift `copySelectionOfTwoElementsSelectsBothCopiesInDocumentOrder` | selection `[[0,4],[0,2]]`, selected xs `[30.0, 16.0]` |
| Swift `DuplicateCopyOrderTests.aDuplicateThenCopyEmitsTheCopiesInDocumentOrder` | **clipboard payload `[30, 16]`** |
| `operation_select_all_top_level` / `operationSelectAllTopLevel` | 2 cases, **both ports, byte-identical actuals** |

### 19A.2 What the gate reaches, and what it does not

**The clipboard half is IN-PORT in each port, not cross-language, and that is a
limit of the corpus rather than a choice.** `copy_selection` is a shared op
verb, so the SELECTION is gated cross-language; there is **no copy-to-clipboard
op verb in either port**, and the corpus's canonical JSON serializes a document,
not a pasteboard. So:

* Rust `workspace::clipboard::copy_payload_tests` drives the production
  `selection_to_svg` through a real `AppState`.
* Swift `JasSwift/Tests/Clipboard/DuplicateCopyOrderTests.swift` drives the
  production `EditClipboard.copySelection` onto a real (private) `NSPasteboard`.

Both run the production mutator first, so each is the artist's gesture pair end
to end within its port; what is asserted twice rather than once is that the two
payloads agree, and the shared selection golden is what holds that together.

### 19A.3 The corpus, and the case that earns its bytes

Two new cases in `test_fixtures/operations/select_all_top_level.json`:

1. `duplicating_a_noncontiguous_pair_selects_both_copies_not_a_source` — new
   setup `dup_order_four_rects.svg` (four distinctly coloured rects, so identity
   is legible in the golden rather than inferable from indices). Two elements
   admit only two orders, so the pre-existing contiguous case cannot tell a SORT
   from a REVERSAL; this one can.
2. `duplicating_across_parents_and_depths_rewrites_only_the_paths_that_moved` —
   duplicates `[0,0]`, `[0,1,2]` and `[1,1]` of this family's own setup. **Four
   separate mutations red this single case**, which is why it exists: it is the
   only thing that watches the path-rewrite RULE rather than its outcome on one
   flat layer.

The pre-existing `copy_of_a_two_element_selection_emits_a_deterministic_order`
golden moved from `[[0,2],[0,1]]` to `[[0,1],[0,3]]`, and its `_doc` — which
described the old order as deliberate — is corrected in place rather than left
to rot.

### 19A.4 Mutation proof — every cause reverted INDIVIDUALLY

Production restored and the suite re-verified green after each.

| # | port | mutation | RED observed |
|---|---|---|---|
| M1 | Rust | drop `copy_paths.sort()` | 3 failed — both in-port gates + the corpus family |
| M2 | Rust | drop the `shift_path_for_insertion` loop | 3 failed — the same three |
| M2b | Rust | drop the helper's parent-prefix check | 1 failed — the across-parents case |
| M2c | Rust | weaken the helper's `>=` to `>` | 1 failed — the across-parents case |
| M3 | Swift | drop `copyPaths.sort` | 7 issues in 3 tests |
| M4 | Swift | drop the `shiftedPath` map | 6 issues in 3 tests |
| M4b | Swift | drop the parent-prefix check | 1 issue — the across-parents case |
| M4c | Swift | weaken `>=` to `>` | 1 issue — the across-parents case |

**M2b and M2c were GREEN on the first attempt** — measured, before the
across-parents case existed. Under house law a guard no mutation can red is
deleted; these two are load-bearing for correctness across parents and across
depths, so the case was written to red them instead. That is the same choice
§18.1 made and it is recorded here so the reasoning is not re-litigated: the
rule is *delete the guard or gate it*, never *leave it unwatched*.

### 19A.5 THE PREMISE IS FALSE — a second operation, measured, NOT fixed

§19 states *"Every other selection-producing operation already yields document
order, so this was the odd one out."* **Surveyed by measurement, not by reading,
and that is not true.**

> **R3 "Paste, preserving layers" leaves a non-document-order selection, for
> exactly the §19 byproduct reason.** `paste_fragment_into` appends into each
> fragment layer's target and records `[idx, at]` as it goes, so the result is in
> FRAGMENT order. Measured: `multi_layer.svg` (layers Background, Foreground) with
> a fragment whose layers are `[Foreground, Background]` yields selection
> **`[[1,1],[0,1]]`**. No existing golden moves, because every shipped preserving
> case happens to list its fragment layers in ascending document order.

**Deliberately NOT fixed here, and this is a ruling, not an oversight.** §19
names the duplicate; extending a ruling to an operation it did not name is
itself a ruling, and this seat has been wrong twice in one day by inference.
The principle plainly reaches it — a Copy after a paste emits that order, which
is §19's own artist-visible consequence — but the fix touches `op_apply` and the
`paste_layers` goldens, which were concurrently in another lane's hands. **Cost
if ruled: one sort per port plus one corpus case with a reversed fragment.**

Everything else surveyed yields document order: `ungroup_selection` (one layer),
`show_all`, `group_selection`, `select_all`, and the marquee/toggle paths §18
repaired. `ungroup_all` and Rust's `unlock_all` clear the selection entirely.

### 19A.6 BANKED — found by the survey, out of scope, needs JYH

1. **`ungroup_selection` across TWO LAYERS is broken in BOTH ports, and broken
   DIFFERENTLY.** Its `offset` accumulator advances across every ungrouped
   group regardless of which layer the group lives in, so the second layer's
   released children are computed at the wrong indices. Measured on two layers
   holding one two-child group each (four released children):
   * Rust → `[[0,0],[0,1],[1,1]]` — **three** entries; `[1,0]` is never
     selected and `[1,2]` is dropped by the `get_element(...).is_some()` guard
     at `controller.rs:1517`.
   * Swift → `[[0,0],[0,1],[1,1],[1,2]]` — **four** entries, and `[1,2]` does
     not exist; `Controller.swift:1298` has no such guard.

   `ungroup` is a shared op verb, so this is corpus-reachable and currently
   **ungated**. Not order, so not §19; a live divergence at a real seam.
2. **The same `offset` shape appears in `release_compound_shape`
   (`controller.rs:1696`) and `expand_compound_shape` (`controller.rs:1852`)**
   — by INSPECTION, not measured. Three call sites of one wrong idea argue for
   one shared helper rather than three separate repairs.

---

## 20. `doc.set_selection` SELECTS ONLY THE NAMED PATHS. RULED 2026-07-28.

> JYH: *"accept recommendation, swift."*

### 20.1 What Rust did, and the reason it gave
`jas_dioxus/src/interpreter/effects.rs:718` expands every named container to
include all its descendants. The comment states why:

> *"Expand containers to include all descendants — matches the Layers panel
> selection-square click behavior. Without this, a Selection-tool click on a
> group would put only the group in selection, and the Layers panel would
> highlight only the group row (not its children)."*

Swift does not expand: it filters to valid paths and stops.

### 20.2 Why Swift is right
**This is a presentation problem solved by corrupting the model.** The panel
highlights a row by asking `selection_contains(path)`, an EXACT-path test
(`doc_primitives.rs:185`), so to light up a group's children Rust writes every
descendant into `doc.selection`. The document's selection was made to carry a
fact about how a panel draws.

**And it contradicts §16 (D2), ruled the same day.** Swift's `selectAll` was
called a defect precisely because it produced a selection containing an element
AND its own descendants — a set no operation reads coherently: translate it and
the group moves by 24 while each child, already carried by its parent, moves 24
again. Rust's `doc.set_selection` produces exactly that set, on **every
Selection-tool click on a group**. So D2 was half-fixed: the function that made
those sets in one place was repaired, and the one that makes them on every click
was left.

### 20.3 The ruling, and what it unlocks
**Select only the named paths. The highlight moves to where it belongs** — the
panel asks *"is this row AT OR UNDER a selected path?"* instead of requiring the
selection to enumerate every descendant.

**This also answers §16.4.** That invariant — may the selection hold an ancestor
and its own descendant? — could not be asserted while Rust deliberately violated
it to drive a highlight. Once the expansion is gone it becomes assertable, and it
would have caught D2 without anyone noticing a divergence.

### 20.4 Two costs, on the record
* The ancestor-aware predicate must exist in BOTH ports **and probably in the
  expression language**, since `workspace/panels/layers.yaml` drives the panel.
  A small YAML-layer addition, not a purely internal change.
* **NOT YET ENUMERATED: every consumer of `doc.selection` that may rely on
  descendants being present.** An operation written against the expanded form
  changes behaviour when it stops being expanded. That enumeration is exactly the
  kind this seat has been wrong about twice in one day — **measure it before
  implementing, do not assert it.**

*A narrower fallback, if the panel work proves larger than it looks:* keep the
expansion as a DERIVED view computed at render time, leaving the stored selection
clean. Same end state for the model, smaller blast radius.

---

## 21. THE MEASUREMENT §20.4 ASKED FOR — and the defect it found. 2026-07-29.

§20.4 recorded that the consumers of `doc.selection` relying on descendants
being present were **NOT enumerated**, and said to measure before implementing.
This is that measurement. It found a load-bearing consumer, and on the way it
found a live defect in both ports that had nothing to do with §20.

### 21.1 A group selected as ONE entry did not move
`move_control_points` (Rust) / `moveControlPoints` (Swift) matched nine leaf
kinds and fell to a catch-all returning the element unchanged. **There was no
`Group` arm, no `Layer` arm, and no arm for the non-reference live kinds.**
`Controller::move_selection` calls it once per selected path, so a container in
the selection contributed nothing.

It reaches the artist by the shortest possible route. The Selection tool sets a
ONE-ENTRY selection on a click — `selection.yaml` runs `doc.set_selection: {
paths: [hit] }` — and `hit_test` returns the **group's** path for a click inside
a group's child (`doc_primitives.rs`,
`hit_test_returns_group_path_when_clicking_child_rect`). So this was every
click-and-drag of a group. §16 then made Select All produce the same shape.

**JasSwift could not drag a group at all. Rust could, by accident:**
`doc.set_selection` expands a container to all descendants, so the CHILDREN were
in the selection and each moved itself — visually indistinguishable from the
group moving.

**That accident is what §20 rules should be deleted.** Implementing §20 as ruled
would have carried the defect into the canonical port. The fix is a prerequisite
for §20, not a sibling of it.

### 21.2 Two corrections to §20's own text
* **§20.2's mechanism is wrong.** It argues the expanded selection is incoherent
  because "translate it and the group moves by 24 while each child, already
  carried by its parent, moves 24 again." **That double-move never happened** —
  the group contributed nothing, so children moved once. The ruling's conclusion
  may stand; the reason given for it does not.
* **§20.3's claim that this unlocks §16.4 is wrong.** The MARQUEE independently
  produces ancestor+descendant selections, deliberately, and the ratified corpus
  says so in prose: *"the MARQUEE keeps the group branch — it legitimately asks
  'did anything inside the band match?' and its answer includes the members."*
  **13 such pairs live in 4 goldens today.** §16.4 is not assertable after §20
  lands; it needs a ruling on the marquee first. **STILL OPEN, and now with a
  measured obstacle rather than an assumed clear path.**

### 21.3 The durable half — an invariant, not a patch
**For an ALL selection, moving IS translating:**
`move_control_points(elem, All, d) == translate_element(elem, d)`, for every
kind. The two functions are two spellings of one idea; they disagreed only where
one had forgotten a kind. Asserted **per kind** in both ports
(`move_all_equals_translate_for_every_kind`, `moveAllEqualsTranslateForEveryKind`).

Writing that test found a **second** kind nobody had reported: **Polyline** had
no arm either, so a polyline did not move, whole or by control point. Fixed in
the same shape. The bug this started from was one of two — which is the argument
for a per-kind invariant over a per-bug fix.

### 21.4 A recorded gap closed, in lockstep
Both ports carried a test asserting Edit > Copy of a live compound shape lands
the copy **exactly on top of** its source, each explaining that
`move_control_points` fell through for a compound shape, each declining to
repair it. Both went red on the same value (x=20, not 0) when the arms landed,
and now assert the copy lands beside its source. Two ports, one number — the
corpus reporting a closure rather than a regression.
