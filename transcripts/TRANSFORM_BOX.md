# THE TRANSFORM BOX — a design brief
**Raised by JYH at council, 2026-07-29. NOT SPECCED, NOT BUILT.**
This brief states the shape, records what already exists, and leaves the open
questions OPEN. It is a thing to come back to, not a plan to execute.

> JYH: *"one option is to have a bounding box with control points that allows
> resize + rotation, not only for groups, but for any selection. This would be a
> menu toggle because it can also interfere. This has not been specced, and we
> should have a specific design."*

---

## 1. WHY IT CAME UP — a spec "contradiction" that is really a conflation

An adversarial review of the element-dispatch ledger cited DOCUMENT.md's
control-point table against this seat:

| Element | CP count | Positions |
|---------|----------|-----------|
| Line | 2 | Start, end |
| Path | N | One per anchor point |
| **Text** | **4** | **Bounding box corners** |
| **Group** | **4** | **Bounding box corners** |

`control_point_count(Group)` really does return 4, and `control_points(Group)`
really does return the bbox corners. Meanwhile `selection_handle_rects` returns
`[]` for containers in BOTH ports, so nothing ever draws them.

**The table holds two different kinds of row.** `Line | 2 | Start, end` is
GEOMETRY — intrinsic to the element, and dragging one reshapes the thing.
`Group | 4 | Bounding box corners` is not geometry at all; a group's bbox
corners are not *in* the group, they are a frame drawn *around* it.

So neither the code nor the spec is wrong. The spec put a **transform
affordance** in the **control-point** column, and this feature is what separates
them. Recorded because the next enumeration will find the same contradiction and
be right again for the same reason.

---

## 2. IT ALREADY EXISTS, ONCE, PRIVATELY — for Text

`moveControlPoints`' `.text` arm, and its Rust twin:

> *"Text resize/move via corner handles. When the whole element is selected
> translate by (dx, dy). When a single corner is selected, scale the text
> proportionally about the opposite corner — diagonal distance ratio drives both
> font-size and origin so the fixed corner stays put."*

That is a transform box, minus rotation, implemented for exactly one element
kind. **Generalising it ABSORBS a special case rather than adding a subsystem**,
and it gives an implementation path: lift Text's behaviour to the selection
level and delete the one-off.

---

## 3. WHERE THE TRANSFORM GOES — measured, not designed

JYH asked the sharp question: *a selection of several elements with no explicit
container — where does the transform go?*

**The codebase already answers it.** `op_apply::compose_matrix_over_paths`:

> *"Compose `matrix` against every element at `paths`, PRE-MULTIPLYING the
> element's existing transform."*

One document-space matrix, composed into **each selected element's own
`transform` field**. No container is minted, no geometry is baked. The op
(`scale_transform`) already carries a resolved reference point `rx, ry` and the
`scale_strokes` / `scale_corners` options.

**This is the right answer and it needs no container.** A scale about a common
origin is ONE affine matrix in document space; every selected element composes
the same matrix. Minting an implicit container instead would change document
structure as a side effect of a transform — and under the cardinality law an
N→1 wrap mints a fresh identity, which the artist never asked for.

### 3.1 …but it is only correct when the ancestors agree. MEASURED.
An element's `transform` is relative to its PARENT. The compose writes the same
document-space matrix into each element's LOCAL frame with **no ancestor
correction**: `matrix.multiply(&current)`.

Driven 2026-07-29 — two groups, one translated 100 right, one at the origin, one
child selected in each, scaled 2× about the document origin:

```
[0,0,0]  (inside the translated group)  doc-space origin -> (100, 0)   WRONG, should be (200, 0)
[0,1,0]  (inside the identity group)    doc-space origin -> (0, 0)     right
```

Both children received the identical local matrix `scale(2,2)`. The one inside
the translated group **did not move at all**, because in its own frame it sits at
the origin — while its neighbour scaled correctly. **The selection shears apart.**

Correct would be `A⁻¹ · M · A` per element, where `A` is that element's
accumulated ancestor transform.

**Why it has never been noticed:** it is invisible whenever every selected
element shares an ancestor transform, which is the ordinary case (elements under
untransformed layers). Transformed groups arrive mainly through SVG import,
where `<g transform=...>` is common. Post-§16.4 the marquee selects GROUPS
rather than their members, so reaching the bad case now takes direct selection
or the Layers panel.

**This is a prerequisite for the transform box, not an independent bug.** A box
over a mixed-ancestor selection is exactly the gesture that exposes it.

---

## 4. WHERE IT LIVES — the argument that settles it

**A transform box over three selected elements has no element to hang off.**
`control_points(elem)` structurally cannot express it.

So the box is a property of the **SELECTION**, not of an element — which also
means it can never be a row in the control-point table, and Group's bbox corners
are in the wrong place today regardless of whether this is ever built.

---

## 5. GROUPS: THE TRANSFORM RIDES ON THE CONTAINER. RULED.
> JYH: *"I think it makes sense to keep it on the container, not recurse."*

**And note this is the OPPOSITE of the paint ruling taken the same day**, where
fill, stroke and brushes recurse into members. The asymmetry is principled:

* **Paint is a property each member OWNS.** A group has no fill of its own, so
  "fill this group" can only mean "fill its members".
* **A transform is a frame the container IMPOSES.** The container has a real
  `transform` field of its own, so it can hold the answer — and holding it there
  preserves every member's own numbers, keeps the transform reversible, and lets
  an artist un-scale cleanly.

Recursing a scale would rewrite every member's geometry irreversibly.

---

## 6. OPEN — genuinely undecided, do not infer
1. **The rotation origin.** Centre by default; movable? Persisted per selection,
   per document, or not at all?
2. **The toggle.** A mode (like the incumbent's) or a persistent preference?
   Where does it live in the menu, and does it survive a restart?
3. **Handle geometry.** 4 corners, or 8 (corners + edge midpoints)? Rotation
   zones just outside the corners, or a dedicated handle?
4. **Mixed-ancestor selections** — §3.1 must be repaired first, and its repair
   needs a decision about what "the selection's bounding box" means when
   ancestors differ (document space, presumably).
5. **Stroke and corner scaling.** `scale_transform` already carries
   `scale_strokes` and `scale_corners` as explicit options. Does the box expose
   them, inherit the dialog's last values, or take a preference?
6. **Live elements.** A compound shape or a symbol instance under a transform
   box — does the box transform the instance or its master?

---

## 7. WHY IT NEEDS A TOGGLE, stated precisely
Worth writing down because it is the justification, not a vague worry: the box's
handles occupy screen space at the selection's edges, so a click there grabs a
HANDLE instead of the element beneath it. During path editing the corner handles
compete with anchor points for the same pixels.

---

## 8. THE INTERIM, and it is what ships today
**No resize/rotate handles. The selection is recursive, and a selected container
draws a SIMPLE bounding box with no control points.** That is exactly what
landed 2026-07-29 (`GROUPHILITE`), and JYH confirmed it as the right interim:
handles that imply a drag which does nothing would be worse than no handles.

Two consequences to leave alone until this is designed:
* `control_point_count(Group)` stays 4. It is not *used* to draw handles, and
  the move guard reads the element's own count, so it is correct at any value.
  **Do not "fix" it to 0** — that pre-empts this design.
* A selected group therefore shows an outline and no handles, which disagrees
  with the table read literally. §1 is why that is a conflation rather than a
  defect.

---

## 9. A PREREQUISITE ALREADY ON THE BOOKS
`scale_elem_stroke_width` is classified **owed** in the element-dispatch ledger:
scaling a group leaves its members' stroke widths untouched. If the box scales
groups, that stops being an independent defect and becomes a blocker.
