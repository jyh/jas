# Release notes

Changes that alter **what a saved document renders**, newest first.

This file exists because rendering changes are the ones a user cannot
discover from a diff: the file opens, nothing errors, and the picture is
different. Refactors, new tests, and internal moves do not belong here —
only entries a person looking at their own artwork would want.

Each entry names what changed, what it replaced, and where the behaviour is
pinned by an executing test, so a reader can check the claim rather than
take it.

---

## 2026-08-30 — two of the three opacity-mask laws did nothing at all (browser)

**Affects:** every document using an **inverted** opacity mask (`invert: true`)
or a **reveal-outside-bbox** mask (`clip: false, invert: false`), rendered in the
browser. The ordinary clipping mask (`clip: true, invert: false`) was correct
and is unchanged.

**What changed.** Both of those laws apply the mask by compositing the mask
artwork onto the element with a `destination-out` / `destination-in` operation.
The renderer set that operation and then drew the artwork through the normal
element path — which sets the compositing operation from the element's own blend
mode as one of its first acts. **The operation was overwritten before anything
was drawn**, so the artwork painted itself normally instead of masking, and the
mask had no effect whatsoever. Both laws now render the artwork on its own
surface first, then apply it in one step the artwork cannot disturb.

**In numbers**, measured in Chrome — `#` is ink, `.` is transparent:

| | before | after (and the spec) |
|---|---|---|
| inverted mask over the left half of a shape | `########..` | `....####..` |
| reveal-outside-bbox, artwork with a gap | `########..` | `##....##..` |

**Why it went unnoticed:** for mask artwork that *covers* what it masks — which
is what every existing example used — an inert mask and a working one leave the
same picture. It takes artwork covering only part of the element to see any
difference at all.

**Pinned by:** `canvas::render::ph4_conversion_tests::an_inverted_mask_erases_where_the_artwork_is`
and `…::reveal_outside_bbox_punches_the_gap_in_its_artwork`.

## 2026-08-30 — masked elements composite as an isolated layer (browser)

**Affects:** documents containing an element with an active opacity mask,
rendered in the browser (`jas_dioxus`). Only where the masked element's body
**overlaps itself** — a masked *group* of overlapping shapes, or a masked
path that crosses itself. A masked element whose body is a single
non-overlapping shape renders exactly as before.

**What changed.** The element's own opacity is now applied **once**, to the
finished composite, and the ancestor group product multiplies into **each**
body primitive:

```
effective alpha = own_opacity · compositeOf( body primitives, each at ∏ ancestor alphas )
```

Previously the browser renderer had these two factors the other way round:
the element's own opacity multiplied into every body primitive — so
overlapping parts of the element compounded — and the ancestor product was
applied once at the end.

**In numbers.** A half-opacity masked group of two overlapping opaque
shapes, measured in Chrome:

| | overlap | elsewhere |
|---|---|---|
| before | `0.75` | `0.50` |
| after | `0.50` | `0.50` |

…and the same total alpha carried by an *ancestor* group instead moves the
other way, `0.50` → `0.75`. The change is which factor is isolated, not a
uniform darkening.

**Why.** This is the law the Painter contract specifies (amendment A6 §6.2,
ratified 2026-08-27): group alpha is non-isolated and compounds
per-primitive, while a masked element is an isolated layer carrying its own
opacity. The Swift port's masked composite already applied the element's own
opacity once at a transparency layer; this brings the browser renderer onto
the specified law.

⛔ **This is not the `own²` bug.** That was a separate defect — the
element's own opacity applied twice while the ancestor groups were discarded
entirely — fixed on 2026-08-24. It was already gone before this change.

**Pinned by:** `canvas::render::ph4_conversion_tests` (both paths, both
directions, in a real browser) and `transcripts/OPACITY.md` §Rendering.

## 2026-08-30 — masked elements no longer render in the wrong place when panned or zoomed

**Affects:** every document containing an element with an active opacity
mask, rendered in the browser, at any view transform other than the
identity — that is, essentially every real view.

**What changed.** The mask composite copied the canvas's world transform
onto its offscreen buffer by reading `currentTransform`. **Chrome does not
implement that property**, so the read silently returned nothing, the buffer
stayed at the identity, and the masked element was drawn at the wrong
position and scale — measured: an element at document `x = 0..4` under a
`+8` pan landed at device `x = 2` instead of `x = 10`. The renderer now asks
`getTransform()` first and keeps `currentTransform` as the fallback.

**Pinned by:**
`canvas::render::ctx_transform_tests::a_masked_element_composites_under_the_view_transform`.
