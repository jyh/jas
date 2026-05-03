# Print

Vector illustration projects ship for one of two destinations: digital
distribution (PDF, web) and physical printing (consumer printer, commercial
press). The application has neither path today. This document specifies the
print pipeline as a series of phases, of which **Phase 1 (Document Setup
dialog + Print dialog scaffold + PDF export)** is the scope of the first
commit chain.

The physical-printing model is also a prerequisite for several already-
specified features that are deferred until it exists:

- The Layer Options "Print" toggle (LAYERS.md `LAYER_PRINT`) — currently a
  stored field that no renderer honors. Wired in Phase 1B's General tab.
- The `Trap` boolean operator (BOOLEAN.md §Trap) — explicitly waits on a
  physical printing model.
- CMYK color separations.
- Crop / registration / page-info marks.

## Architecture

PDF-first. Each app uses a platform PDF library to render the document; the OS
print panel (or browser print) is a thin shell over the PDF output. This
unifies "Print" and "Export to PDF" into one render pipeline and unblocks the
deferred items above.

Per-language PDF library candidates:

| App | Candidate library |
| --- | --- |
| Rust (jas_dioxus) | `printpdf` or `pdf-writer` |
| Swift (JasSwift) | `PDFKit` (built into macOS) |
| OCaml (jas_ocaml) | `cairo-pdf` (already linked for canvas rendering) |
| Python (jas) | `reportlab` or `fpdf2` |
| Flask | client-side `jsPDF`, or hand back the Python PDF |

Per-app PDF emitters stay aligned via cross-language fixture tests, the same
pattern used today for SVG.

## Three dialogs, three scopes

The print path involves three dialogs that have distinct scopes and must not
be conflated:

- **Document Setup** — *per-document* settings that persist with the file:
  bleed, display toggles, transparency / overprint defaults. Independent of
  any specific print operation. Editing a Bleed value in Document Setup
  changes what every future print job uses by default.
- **Page Setup** — the *OS-level* paper-driver dialog (which paper tray, paper
  size as the printer driver sees it). Invoked via the platform's standard
  print stack, not implemented at the application level. Available as a
  shortcut button at the bottom of the Print dialog.
- **Print** — the *application-level* print operation, modal, six tabs:
  General / Marks and Bleed / Output / Graphics / Color Management /
  Advanced. Per-document `PrintPreferences` remember the last-used settings
  so reopening Print restores the prior choices. A workspace-level
  `PrintPreset` registry stores named saved configurations
  (Phase 1 ships only the built-in `[Default]` preset).

## Phase 1A — Document Setup dialog

Adds a small per-document settings record and a dialog to edit it. Bleed
renders on canvas as a guide so users see immediate effect.

### DocumentSetup record

Lives on `Document` as a peer of `ArtboardOptions`.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `bleed_top` | f64 (points) | 0 | |
| `bleed_right` | f64 (points) | 0 | |
| `bleed_bottom` | f64 (points) | 0 | |
| `bleed_left` | f64 (points) | 0 | |
| `bleed_uniform` | bool | true | Chain-link state. When true, edits to any one side propagate to all four. |
| `show_images_outline` | bool | false | Canvas display: render image placeholders rather than rasterized content. |
| `highlight_substituted_glyphs` | bool | false | Canvas display: tint glyphs that were rendered with a substituted font. |

Defaults give zero-bleed documents (the no-bleed case is by far the most
common).

**Deferred to Phase 6:** Units (per-doc override of a workspace pref —
deferred until global units exists), transparency grid (size/colors/simulate
colored paper), transparency-flattener preset, "Discard White Overprint in
Output". These belong with the rest of the flattener / overprint work in the
Advanced tab phase.

### Bleed canvas display

When any bleed value is non-zero, draw a 1-pixel screen-space red dashed
rectangle inscribed at `(artboard.x - bleed_left, artboard.y - bleed_top)`
with size `(artboard.width + bleed_left + bleed_right,
artboard.height + bleed_top + bleed_bottom)` for every artboard. The bleed
guide sits in the same Z-band as artboard borders (above element content,
below selection handles).

### Document Setup dialog

`workspace/dialogs/document_setup.yaml`. Modal, batched commit. Single undo
entry on OK.

Layout:

```
Document Setup
─────────────────────────────────────────
Bleed
  Top    [0 pt]      Bottom [0 pt]
  Left   [0 pt]      Right  [0 pt]   [chain-link]

[ ] Show Images In Outline Mode
[ ] Highlight Substituted Glyphs

                      [ Cancel ]  [ OK ]
```

The chain-link toggle, when active, mirrors any single-side edit to all four
fields.

### File menu

A new "Document Setup..." item under File opens the dialog.

### Persistence

DocumentSetup is part of the serialized Document in the binary format. SVG
persistence lands in Phase 2 (alongside the PrintPreferences SVG block) via a
namespaced `<jas:document-setup>` element under `<sodipodi:namedview>`.

## Phase 1B — Print dialog scaffold + General tab + PDF export

Ships an actually-functional Print path. The full 6-tab Print dialog is
laid out, but only the General tab is populated; the other five tabs show
"available in Phase N" placeholders. Render-to-PDF works for Composite RGB
output of all artboards.

### PrintPreferences record

Per-document last-used Print dialog state. Lives on `Document` alongside
`DocumentSetup`. Phase 1B fields cover the General tab only; later phases
extend with sub-records for marks, output, graphics, color management,
advanced.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `preset_name` | String | `"[Default]"` | Currently-selected workspace `PrintPreset`. Phase 1 ships only `[Default]`. |
| `printer_name` | Option\<String\> | None | Last-selected printer. None = let the OS dialog pick. |
| `copies` | u32 | 1 | |
| `collate` | bool | false | |
| `reverse_order` | bool | false | |
| `artboard_range_mode` | enum: All / Range | All | |
| `artboard_range` | String | `""` | "1-3, 5" syntax when range_mode = Range. |
| `ignore_artboards` | bool | false | When true, prints document bounds as one page rather than one page per artboard. |
| `skip_blank_artboards` | bool | false | |
| `media_size` | enum: DefinedByDriver / Letter / Legal / Tabloid / A3 / A4 / A5 / Custom | DefinedByDriver | |
| `media_width` | f64 (points) | 612 | Used when media_size = Custom. |
| `media_height` | f64 (points) | 792 | Same. |
| `orientation` | enum: Portrait / Landscape | Portrait | |
| `auto_rotate` | bool | true | When set, individual pages rotate to best-fit the paper. |
| `transverse` | bool | false | Imagesetters: rotate 90° for press grain direction. |
| `print_layers` | enum: VisiblePrintable / Visible / All | VisiblePrintable | "Visible & Printable Layers" honors both Layer.visibility != Invisible AND Layer.print = true (LYR-091 `LAYER_PRINT`). |
| `placement_x` | f64 (points) | 0 | Origin offset on the printed page. |
| `placement_y` | f64 (points) | 0 | |
| `scaling_mode` | enum: DoNotScale / FitToPage / Custom | DoNotScale | |
| `custom_scale` | f64 (percent) | 100.0 | |
| `tile_overlap_h` | f64 (points) | 0 | Reserved for Phase 7 tiling. Stored now so PrintPreferences shape is stable. |
| `tile_overlap_v` | f64 (points) | 0 | |
| `tile_range` | String | `""` | Same. |

**Defaults rationale:** DefinedByDriver paper means "trust the OS print panel
unless the user overrides." DoNotScale matches "what you see is what prints"
which is the safest default for a vector illustration tool. VisiblePrintable
honors the existing Layer Options Print toggle.

### PrintPreset record (workspace-level)

A named saved configuration of all PrintPreferences fields. Lives in workspace
configuration, not in the document. Phase 1 ships exactly one built-in:
`[Default]` with the field defaults above. The Print dialog's preset
dropdown shows it; saving a new preset is deferred to a later phase.

### Print dialog

`workspace/dialogs/print.yaml`. Modal, with a left-rail tab list and a
content area on the right. Clicking a tab swaps the content. The bottom
strip carries: Page Setup..., Setup..., Done, Cancel, Print.

Tabs (Phase 1B status in parentheses):

1. **General** — *populated*
2. **Marks and Bleed** — *placeholder ("Phase 2")*
3. **Output** — *placeholder ("Phase 3")*
4. **Graphics** — *placeholder ("Phase 4")*
5. **Color Management** — *placeholder ("Phase 5")*
6. **Advanced** — *placeholder ("Phase 6")*

(A "Summary" tab as in some reference UIs is omitted; the tabs themselves
serve as the navigation.)

The General tab is the rich panel: see the PrintPreferences table above for
the 1:1 field-to-widget mapping.

The left side of the dialog also carries a small live preview of the page
rect with artboard rectangles inside it (Phase 1 stub: just draws the page
border and artboard outlines; full preview deferred).

### File menu

- **Print...** — opens the Print dialog.
- **Export to PDF...** — opens an OS file-save sheet, then writes the same
  PDF that Print would produce, bypassing the print panel.

### PDF rendering

A new module `geometry::pdf` (per-app) walks the Document and emits PDF using
the per-language library. Phase 1B scope:

- Artboards-as-pages (one page per artboard, in `document.artboards` order),
  unless `ignore_artboards = true` (then a single page covering document
  bounds).
- Per-page render rect = artboard rect, clipped.
- Element types: paths (fill + stroke), rect, line, circle, ellipse,
  polyline, polygon, text (basic single-tspan), groups, layers (transforms
  only).
- Layer.print toggle honored according to `print_layers`.
- Solid fills (no gradients), solid strokes (no dash arrays beyond the basic
  pattern).
- Composite RGB color only (CMYK conversion deferred to Phase 3).
- `placement_x` / `placement_y` apply as the page origin.
- `scaling_mode` applies a uniform scale on the page.
- `auto_rotate`, `transverse`, `tile_*` deferred to later phases — fields
  are stored but unobserved.

**Deferred from Phase 1B PDF scope:**

- Gradients
- Dash arrays beyond a basic on/off
- Masks
- Blend modes other than Normal
- Multi-tspan text (full character / paragraph attribute mapping)
- Image elements (no Image element type yet)
- Live elements (rendered as their evaluated geometry)

### Persistence

PrintPreferences ships with the document in the binary format. SVG
persistence lands in Phase 2 alongside the DocumentSetup SVG block.

### Cross-language tests

A fixture document with a non-trivial PrintPreferences exercises the binary
roundtrip and verifies all four apps emit identical canonical Test JSON. A
separate fixture pair (small SVG + expected PDF object structure) verifies
each app's PDF emitter produces the same page count, page geometry, and
content-stream object counts (not byte-for-byte; PDFs are not canonical at
the byte level, but the structure is).

## Phase 2 — Marks and Bleed tab

Adds a `MarksAndBleed` sub-record to PrintPreferences:

| Field | Type | Default |
| --- | --- | --- |
| `all_printer_marks` | bool | false |
| `trim_marks` | bool | false |
| `registration_marks` | bool | false |
| `color_bars` | bool | false |
| `page_information` | bool | false |
| `printer_mark_type` | enum: Roman / Japanese | Roman |
| `trim_mark_weight` | f64 (points) | 0.25 |
| `mark_offset` | f64 (points) | 6 |
| `use_document_bleed` | bool | true |
| `bleed_top/right/bottom/left` | f64 | 0 | Per-print override; only consulted when `use_document_bleed = false`. |

The Marks tab populates with controls 1:1. The PDF renderer extends each
page by the active bleed and overlays mark geometry around the trim rect.

DocumentSetup and PrintPreferences both gain SVG persistence in this phase
(via `<jas:document-setup>` and `<jas:print-preferences>` under
`<sodipodi:namedview>`).

## Phase 3 — Output tab (separations)

Adds `Output` sub-record: `mode` (Composite / Separations), `emulsion`,
`image_polarity`, `printer_resolution`, `convert_spot_to_process`,
`overprint_black`, per-ink overrides table (frequency, angle, dot shape).
Separations mode emits one PDF page per ink channel.

## Phase 4 — Graphics tab

`Graphics` sub-record: `flatness` (Quality↔Speed), `font_download`,
`postscript_level`, `data_format`, `compatible_gradient_printing`,
`raster_effects_resolution`. PDF renderer applies path-flattening tolerance
and font-subsetting accordingly.

## Phase 5 — Color Management tab

`ColorManagement` sub-record: `document_profile`, `color_handling`,
`printer_profile`, `rendering_intent`, `preserve_rgb_numbers`. Output PDF
gets ICC profile metadata and proper rendering-intent application.

## Phase 6 — Advanced tab + Document Setup transparency/overprint

The Advanced tab covers `print_as_bitmap` and the overprint flattener
preset. Document Setup grows to include the deferred Phase 1A items: grid
size / colors, simulate colored paper, transparency flattener preset, units
(if global units exists by then), discard white overprint.

## Phase 7+ (deferred)

- **Trapping** — `Trap` operator (BOOLEAN.md §Trap) now has its data-model
  home and can be implemented.
- **Tiling** — print to multiple sheets when content exceeds paper. Phase 1B
  reserved the PrintPreferences fields (`tile_overlap_*`, `tile_range`) so
  the data shape is stable.
- **Halftone screens, line frequency** — pro-print only.
- **ICC color management beyond Phase 5** — soft-proofing, simulate
  separations, etc.
- **Workspace-level PrintPreset registry** — save / load / delete named
  presets. Phase 1 ships only the built-in `[Default]`.
