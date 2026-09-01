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

## 2026-08-31 — two of the three opacity-mask laws did nothing at all (macOS app)

**Affects:** every document using a **clipping** opacity mask
(`clip: true, invert: false`) or an **inverted** one (`invert: true`), opened in
the macOS app. The reveal-outside-bbox law was repaired earlier the same day and
is unchanged here; the browser had the same defect and was repaired on 08/30.

**What changed.** Both of those laws apply the mask by compositing the mask
artwork onto the element with a `destination-in` / `destination-out` operation.
The renderer set that operation and then drew the artwork through the normal
element path — which sets the blend mode from the element's own blend mode as
one of its first acts. **The operation was overwritten before anything was
drawn**, so the artwork painted itself normally instead of masking, and the mask
had no effect whatsoever. Both laws now render the artwork on its own
transparency layer and apply it in one step the artwork cannot disturb — the
same carrier the reveal law already uses.

**In numbers**, measured on a black shape under white artwork covering only its
left half — `#` is ink, `.` is transparent:

| | before | after (and the spec) |
|---|---|---|
| clipping mask (`clip: true`) | `########........` | `####............` |
| inverted mask (`invert: true`) | `########........` | `....####........` |

**Why it went unnoticed:** for mask artwork that *covers* what it masks — which
is what every existing example used — an inert mask and a working one leave the
same picture. It takes artwork covering only part of the element to see any
difference at all.

**One thing this did NOT fix.** A clipping mask's law is a *luminance* soft mask:
a black-opaque mask should read as fully transparent, a white one as fully
opaque, a gray one as partial. The macOS app composites the artwork's **raw
alpha** instead, so a mask painted in anything but white still differs from the
browser, which promotes to luminance. This entry moves the arm from doing
nothing to doing the browser's own fallback; the luminance difference is
recorded and not yet closed.

**Pinned by:** `MaskCompositeIsolationTests.aClipInMaskErasesWhereTheArtworkIsAbsent`
and `…anInvertedMaskErasesWhereTheArtworkIs`.

## 2026-08-31 — a transformed reveal mask clips the box of what it draws (browser)

**Affects:** documents using a **reveal-outside-bbox** opacity mask
(`clip: false, invert: false`) whose mask carries a transform — a linked mask
on a transformed element, or an unlinked mask's captured transform. Untransformed
reveal masks and the other two mask laws are unchanged.

**What changed.** The reveal law limits the mask to the subtree's bounding box
and leaves the element untouched outside it. The renderer used to set that box
*while the mask's transform was on the context*, so the clip region was the
transformed rectangle — under a rotation, a rotated rectangle. For mask artwork
that fills its own bounds (a plain rect), clip region and artwork coincided and
**the mask did nothing at all**. The ruled contract (2026-08-31) is that the box
is the axis-aligned bounds **of the transformed subtree**, computed before the
clip is set; the corners of that box the rotated artwork does not reach are now
inside the box with zero mask alpha, and are masked out.

**In numbers**, measured in Chrome — a 45°-rotated rect reveal mask over a
full-width shape, one row: before `################`, after `##...######...##`
(kept outside the box, masked to the diamond inside it). A translated reveal
mask renders as before. Pinned by
`ph4_conversion_tests::a_rotated_reveal_mask_clips_the_box_of_what_it_draws`
and `…::a_translated_reveal_mask_converts_and_agrees_with_legacy`; the same
change lets these masks take the A6 element bracket, where the box crosses the
seam precomputed.

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
opacity. The Swift port's masked composite already spends the element's own
opacity once, at a transparency layer, so this brings the browser renderer into
agreement with it **on that half**. Only that half: how each port applies the
*ancestor* product is a separate question, and this note does not claim it.

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
