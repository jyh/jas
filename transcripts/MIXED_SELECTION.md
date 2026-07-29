# `<mixed>` — what a panel shows for a selection that disagrees
**Raised by JYH at council, 2026-07-29. PARTLY BUILT — the model half exists.**

> JYH: *"for a mixed selection, the panel should probably show `<mixed>`. For
> example, when we select a 5pt line and a 1pt line simultaneously, there is no
> numeric stroke weight that reflects reality. However, I realize this is a
> massive change."*

Measured at council. **The model half is already built and correct. The display
throws it away. The widget vocabulary is the part that is genuinely large.**

---

## 1. WHAT ALREADY EXISTS
`selection_fill_summary` / `selection_stroke_summary` (and the Swift twins)
return a three-state answer over the whole selection:

```
NoSelection | Mixed | Uniform(value)
```

JYH's 5pt-and-1pt example **already produces `Mixed` today**. The concept is
named, computed by walking every selected element, and consumed per render by
`build_live_panel_overrides` (`workspace/dock_panel.rs`) — a pull merged into
the panel scope. There is no push-style sync to keep in step; the former one was
dead and was removed.

**So this is not a change to every panel.** It concentrates at the pull.

---

## 2. WHAT IS MISSING — the display discards the answer
`dock_panel.rs`:

```rust
StrokeSummary::Uniform(Some(s)) => Some(s.color),
StrokeSummary::Uniform(None)    => None,
_ => t.model.default_stroke.map(|s| s.color),   // <- Mixed lands here
```

`Mixed` falls through to the **tab default** — a value belonging to nothing in
the selection. So the panel does not merely pick one of the two weights; it
shows a **third number belonging to neither**. That is worse than the lie the
council was discussing, and it is the current behaviour.

---

## 3. THE COST, split three ways
| part | size | why |
|---|---|---|
| **Model** | **done** | the summaries exist and are correct |
| **Display** | small | honour `Mixed` instead of falling through, at a handful of sites per port |
| **Widget vocabulary** | **this is the massive part** | every widget kind needs a mixed rendering |

The third is what touches everything: a `length_input` showing `<mixed>`, a
colour swatch showing *something* (hatched? empty? the panel's own question), a
combo box with an indeterminate state — and the widgets are YAML-driven, so it
is a widget-level concept in **both ports plus the reference interpreter**, with
its own corpus.

**Editing FROM mixed needs no new machinery**: typing a value writes it to the
whole selection, which is what the apply path already does.

---

## 4. A GROUP IS A MIXED SELECTION OF ONE
This is the unification worth keeping. A group holding a 5pt and a 1pt member
poses **exactly** JYH's question — there is no honest common weight — so
whatever answers "what does the panel show for two lines" answers "what does it
show for a group", and the two spellings must agree.

That equivalence is now pinned as a test in both ports
(`theContainerAndNonContainerSpellingsAgree`).

---

## 5. THE CHEAP FIRST STEP — TAKEN 2026-07-29
The summaries read a CONTAINER's own `fill()`/`stroke()`, which is always
`None`. So a selected group gave a **wrong** answer, and the two ports gave
*different* wrong answers:

* **Rust**: `Uniform(None)` — "this has no stroke".
* **Swift**: skipped containers entirely, so `first` stayed true and it returned
  `.noSelection` — "nothing is selected".

Since the paint ruling of the same day (fill, stroke and brushes recurse into
members) an artist meets this directly: **set a group's stroke, and the panel
says it has none.**

**Both summaries now recurse to paintable leaves** — `for_each_paintable` /
`forEachPaintable`, the READ twin of `map_paintable`. A group whose members
agree reads back their common value; one whose members disagree reads `Mixed`.
This repairs the asymmetry with **no widget work at all**, and leaves only
genuinely-mixed selections falling through to the default, which is the
pre-existing behaviour rather than a new one.

An empty container visits no leaf and contributes no value; both ports return
`Uniform(None)` for it, pinned so they cannot drift apart on that edge again.

---

## 6. OPEN — genuinely undecided
1. **What a mixed COLOUR swatch looks like.** A weight has an obvious `<mixed>`
   spelling; a colour does not.
2. **Does `<mixed>` differ from empty?** A selection with no stroke at all and a
   selection whose strokes disagree are different facts and today both render as
   nothing.
3. **Per-field or per-panel.** Two selected rects may share a fill and differ in
   stroke width. Mixedness is per FIELD, and the summaries are currently per
   PANEL-GROUP (whole `Fill` / whole `Stroke` compared by value) — so two
   strokes differing only in cap read as `Mixed` for weight too, which is
   over-broad.
4. **Whether the reference interpreter needs the state**, or whether it can stay
   a display-layer concept in the two active ports.

**Item 3 is the one that decides the size of the work**, and it is not decided.
