# smoke/ — scenes for the judgment smokes

Four checks that no instrument in this house can stand in for, each needing a
human at the canvas. **The scenes are prepared so the hour is all judgment and
no setup** — open the file, look, decide.

Ratified at the 2026-08-05 sitting: smokes run AFTER council, never during.

Every scene here was ROUND-TRIPPED THROUGH THE REAL CODEC before being
committed (`cargo run --bin svg_roundtrip -- roundtrip smoke/<file>`), because a
scene that silently fails to carry what it claims wastes exactly the hour it was
built to save. The first draft of `01` did precisely that: it said
`jas:start-arrow="triangle"`, which is not a valid name, so it parsed to
`Arrowhead::None` without complaint and the scene had no arrowheads at all.

---

## 1 — `01-arrowtrim.svg` — the ARROWTRIM re-smoke

**JYH's original screenshot case (2026-07-24), rebuilt:** a curved path,
arrowheads on BOTH ends, arrowhead scale 200.

| look at | PASS |
|---|---|
| both heads on the black curve | they point along the path's true end tangent — not flipped, not rotated wrong |
| where the curve meets each head | the sweep does not poke through or past the head |
| the red fat-stroke path | **banked question 1:** the stroke is wider than the head, so its butt-cut shoulders show at the sides. Length trim cannot fix a width problem — acceptable, or should the head scale to the stroke? |
| the red path's FREE (left) end | **banked question 2:** it is declared round-capped and will render BUTT, because one canvas stroke carries one cap. Per-end caps need stroke splitting. Ratify the simplification or schedule the work. |

## 2 — `02-brushsave.svg` — the BRUSHSAVE round trip

Landed 2026-08-05; gated in both ports but never seen by an artist.

1. Open the file. The blue path carries a brush; the green one a variable-width
   profile (thin, fat at the middle, thin).
2. **File > Save.**
3. **Reopen the saved file.**

**PASS: both are still there.** Before this fix, every save silently discarded
the brush and the width profile — the file reopened as two plain strokes.

## 3 — TABTRUTH, one click (no scene; it is the startup state)

Launch with a default workspace. Open **Window**. `Layers` should be **unticked**
— it is a background tab of the `[artboards, layers, symbols]` group, and the
dock draws one panel per group.

**Click it ONCE.** PASS: the Layers panel is on screen. Before TABTRUTH the first
click *deleted* it and a second click was needed to summon it back.

Judgment half, which the gate cannot give: does one click feel right, or does a
ticked-but-invisible panel still read as wrong? The dock renders no tab strip at
all — that is an open council question and this is the moment to form a view.

## 4 — Painter PH2 shapes (banked since 2026-07-24)

No scene file: draw one of each of the six multi-paint kinds and confirm they
render as they did before the painter conversion. Blocks nothing; simply has
never been eyeballed.

---

## Recording the result

Append to `transcripts/SMOKE_TESTS.md` with the date and the build. **A smoke
that is not written down did not happen** — three separate firings have re-asked
whether ARROWTRIM was ever re-smoked.
