# Path B — Five-App Box-Model Review (§9 ratification gate)

**Status:** for sign-off, 2026-06-28. This is the `TESTING_STRATEGY.md` §7 item #9
gate: **before any non-Rust render migration, ratify the canonical box-model values**
(`PATH_B_DESIGN.md` §2 / Appendix A), because re-pinning to one box model shifts
already-shipped panels in all five apps. Each decision below is marked **LOCK** (adopt
as-is), **ADJUST** (a value needs your call), or **WATCH** (no seed-panel impact yet;
revisit as the corpus broadens). The per-app "current" columns are the framework rules
documented in the layout survey (code-cited); exact rendered pixels are confirmed by the
visual pass (§5), since each app's current rects are framework-computed at runtime.

Naming note: this is a **vector illustration application**; no commercial product is named.

---

## 1. The concrete anchor — canonical seed-panel rects

`layout_panel` output for the two seed panels at three widths (min dock 150, default
228 = dock 240 − 12 scrollbar, wide 300). `(x, y, w, h)`, panel-relative, integer px.

**symbols** — column root, separator, flow-row footer (width-independent except the root):
```
path        node                  @150            @228            @300
[]          sym_root              0,0,150,33      0,0,228,33      0,0,300,33
[1]         separator             0,0,150,1       0,0,228,1       0,0,300,1
[2]         sym_footer            0,1,150,32      0,1,228,32      0,1,300,32
[2,0..2]    icon_button ×3        6/34/62,5,24,24 (identical at all widths)
```
Footer icons are fixed 24px and never reflow — the row never fills the panel. *Already a
review signal: should the footer stretch / right-align, or is left-packed correct?*

**opacity** — two 12-col grid rows (spans sum to exactly 12), second has a nested column:
```
path        node                  @150            @228            @300
[]          op_content            0,0,150,106     0,0,228,106     0,0,300,106
[0,0]       select op_mode        4,6,47,20       4,6,73,20       4,6,97,20     (fills /12 cell)
[0,1]       text "Opacity:"       51,6,80,20      77,6,80,20      101,6,80,20   (FIXED 80 — overflows)
[0,2]       number_input          87,6,47,20      132,6,73,20     174,6,97,20   (fills /12 cell)
[0,3]       icon_button           134,4,24,24     205,4,24,24     271,4,24,24   (fixed 24)
[1,0]       placeholder           4,48,36,40      4,48,55,40      4,48,73,40    (fills /12 cell)
[1,2]       placeholder           52,48,36,40     77,48,55,40     101,48,73,40
[1,3]       op_buttons_col        88,34,59,68     132,34,92,68    174,34,122,68
[1,3,2]     checkbox "Invert Mask" 88,82,130,20   132,82,130,20   174,82,130,20 (FIXED 130 — overflows)
```

**Two overflow hotspots, exact:**
- `text "Opacity:"` is **80px at every width** (8 chars × `char_width 10`) but its `/12`
  cell is 36 / 55 / 73px — it **overflows the cell at all three widths**.
- `checkbox "Invert Mask"` is **130px** but `op_buttons_col` is 59 / 92 / 122px — it
  **overflows even at 300px** (`174 + 130 = 304 > 300`).

Both are the same root cause: **`char_width = 10` makes the stub text wider than the
columns the grid hands it.** This is the single most consequential value to ratify (§2,
decision 5). It is not an algorithm bug — it is the canonical model faithfully reporting
"this label does not fit this cell," which is exactly the class of bug Path B exists to
make visible as data. The question is whether 10 is the right stub.

---

## 2. Decision ledger (current vs. canonical, per app)

| # | Canonical (PATH_B_DESIGN §2) | Python / Qt | Rust / Dioxus | Swift / SwiftUI | OCaml / GTK | Flask | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | **Columns = Bootstrap /12** | raw Qt **stretch weights** + left-align cell | Bootstrap `col-N` (N/12 %) | `Bootstrap12Layout` ÷12 | GtkGrid `col_homogeneous` ÷12 | Bootstrap `col-N` | **LOCK** (Python moves) |
| 2 | **Overflow wraps (Σspan>12)** | no wrap (Qt single row) | Bootstrap wraps | **no wrap** | no wrap | Bootstrap wraps | **LOCK** (no seed impact) |
| 3 | **Per-kind min-col floor** | none | none | none | `size_request` min | none | **ADJUST/defer** (not in v1) |
| 4 | **`flex:N` weighted (horiz.)** | binary `Expanding` (N ignored) | CSS `flex:N` | `fillsParent` flag | none | CSS `flex:N` | **LOCK** (no seed impact) |
| 5 | **Text = `len × 10` stub** | real Qt font | webview font | SwiftUI font | GTK font | browser font | **ADJUST — your call (see §3)** |
| 6 | **Integer round-half-up** | float | float | float | float | float | **LOCK** (mechanism, not visible) |
| 7 | **gap 0 / pad 0 / inset = root `style.padding`** | container margins 0 ✓ | 0 ✓ | extra panel-wide `.padding(4)` | 0 ✓ | `.app-panel` margin 4/2 | **LOCK** (Swift/Flask drop framework inset) |
| 8 | **content width = dock 240 − 12** | dock 240, −12 ✓ | model width | natural (hint ignored) | natural (hint ignored) | model | **LOCK** (Swift/OCaml must feed width) |

**Reading the big ones:**

- **#1 columns.** For a row whose `col` spans **sum to 12** (both seed rows do), Qt's
  weight normalization happens to equal `/12`, so Python looks fine on the seed. The
  divergence bites on rows where **spans sum ≠ 12**: Bootstrap/canonical leave the
  remainder empty, Qt stretches children to fill 100%. **Audit done: 3 of 36 grid rows
  across all panels sum ≠ 12** — `character[10]` (sum 9), `magic_wand[5]` (sum 5),
  `paragraph[3]` (sum 6); those three rows will visibly shift in Python on migration (Qt
  fills today; canonical leaves the gap). Everything else sums to 12. Also, Python
  **left-aligns intrinsic-width**
  widgets in their slot, whereas canonical **fills** the cell for fill-kinds (select,
  number_input, placeholder) — so even at sum 12, `op_mode`/`op_opacity` move from Qt's
  natural width to the full 73px cell.
- **#5 text stub.** Affects **all five apps** and drives both overflow hotspots. See §3.
- **#7 inset.** The panel inset is **data-driven** (the root container's own
  `style.padding` — opacity root `padding:4`, symbols root `padding:0`), not a magic
  constant. Swift's extra `.padding(4)` and Flask's `.app-panel` margins are framework
  add-ons that must be removed so the inset comes only from the YAML.

---

## 3. The load-bearing call — `char_width`

`char_width = 10` was chosen to match the existing `text_layout.json` stub (one stub
across both corpora). But 10px/char is **wider than real UI fonts** (~7–8px average at an
11px system font), so canonical text is systematically wider than every app renders today
— producing the two seed overflows and widening every label/button. Trade-off:

| Option | Effect |
|---|---|
| **Keep `char_width = 10`** (recommended for consistency) | one stub shared with `text_layout`; but expect more "label overflows cell" cases — which may be *correct* signal (tells authors to widen cells / shorten labels) |
| **Lower to ~7** | closer to real fonts, less re-pinning shock and fewer overflows; but **diverges from `text_layout.json`'s stub** (two different stubs to reason about) |
| **Per-kind / per-style measure** | most faithful; defeats the determinism that makes the corpus byte-exact — **rejected** |

**This is the one value I can't pick for you.** It sets every text width app-wide.
Recommendation: **keep 10** and treat the overflows as authoring signal, but if you'd
rather minimize visual churn on migration, say so and I'll re-pin to a smaller stub and
regenerate the golden.

---

## 4. Biggest shifts, ranked (what re-pinning actually moves)

1. **Text width (#5)** — all five apps; canonical wider than real fonts. Hotspots above.
2. **Python columns (#1)** — fill-vs-left-align on every grid cell now; plus any
   `col`-sum ≠ 12 row. Python is the most-moved app.
3. **Swift framework add-ons** — `.padding(4)` panel inset (#7), no overflow wrap (#2),
   ad-hoc `.frame` widths vs the size table. Swift re-pins broadly.
4. **Feeding a fixed width (#8)** — OCaml and Swift ignore the width hint today; they must
   consume the canonical content width or rects won't match.
5. **Widget-kind heights (Appendix A.5)** — every widget height becomes canonical
   (text 20, button 24, icon_button 24, slider 12, placeholder 40, …). Mostly matches the
   per-app literals the survey found, but ratify per kind as the corpus broadens.

---

## 5. Visual verification protocol (per app)

The decision ledger is rule-level; the magnitude is confirmed by eye against §1's rects.

- **Rust** — `JAS_PATH_B=1 ./run_dioxus_desktop.sh`, open Opacity + Symbols. This renders
  *from the canonical pass*; compare to a normal run (flag off) side by side.
- **Python / OCaml / Swift / Flask** — open the same two panels in a normal build and
  compare against §1's canonical rects (no flag exists yet in these apps). Note any place
  the current render disagrees with canonical by more than the expected stub-text width.

Confirm specifically: the two overflow hotspots (§1), the footer left-pack (symbols), and
the fill-vs-left-align of `op_mode`/`op_opacity` (opacity row 1).

---

## 6. Ratification checklist (what I need from you)

1. **`char_width`** — keep **10** (consistency), or lower to ~7 (less churn)? *(§3 — the one real fork.)*
2. **Min-col floor (#3)** — adopt a per-kind floor in v2, and at what value? (Not in v1.)
3. **Symbols footer** — left-packed (current canonical) ok, or should the action row
   stretch / right-align?
4. **Decisions 1, 2, 4, 6, 7, 8** — LOCK as recommended? (Each is the majority behavior
   and/or the existing `LAYOUT.md` spec.)

On your answers I'll: regenerate the golden if `char_width` changes, record the locked
values in `PATH_B_DESIGN.md §2`, run the panel `col`-sum ≠ 12 audit, then start the
render migrations in order (Flask → Swift → OCaml → Python).
