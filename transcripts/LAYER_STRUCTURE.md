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

## 9. RULINGS TAKEN AFTER RATIFICATION (the defects this phase surfaced)

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

## 10. STILL OPEN — not ruled, and NOT to be inferred

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
