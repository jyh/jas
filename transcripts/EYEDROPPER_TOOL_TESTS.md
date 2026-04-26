# Eyedropper Tool — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/tools/eyedropper.yaml` and
`workspace/dialogs/eyedropper_tool_options.yaml`. Design doc:
`transcripts/EYEDROPPER_TOOL.md`.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session K parity sweep.

---

## Known broken

_Last reviewed: 2026-04-26_

- **OCaml toolbar icon** — the OCaml toolbar UI button (Cairo-drawn
  slot + click handler) is deferred. The Eyedropper variant is
  registered with `tool_factory.ml`, but it cannot be selected
  from the OCaml toolbar; pressing `I` is the only entry point.
  Same deferral pattern as Magic Wand. See
  `project_eyedropper_spec.md`.
- **Flask** — tool not implemented. The Eyedropper requires
  document hit-testing, a selection model, and a per-document
  cache, none of which the Flask app has today.
- **Character / Paragraph extraction** — stubbed in all four
  native apps. Tests EYE-138 through EYE-159 (and the
  corresponding parity entries) are `[placeholder]` until the
  follow-up that touches Text element internals lands.
- **Gradient / pattern fills** — Phase 1 samples solid fills only.
  A non-solid source fill caches as `None`; tests EYE-076 and
  EYE-077 cover the no-op behavior.

---

## Automation coverage

_Last synced: 2026-04-26_

**Extract / apply (`algorithms/eyedropper`)** — 7–8 unit tests
per language on the helpers: extract from Rect with fill +
stroke, extract from Line (no fill), JSON / dict round-trip,
master-OFF skips a group, stroke sub-toggle preserves target's
existing fields, opacity-alpha-only apply leaves blend mode,
source-eligibility filters Hidden + Group / Layer (locked is OK),
target-eligibility filters Locked + Group / Layer (hidden is OK).
Files: `jas_dioxus/src/algorithms/eyedropper.rs` (#[cfg(test)]),
`JasSwift/Tests/Algorithms/EyedropperTests.swift`,
`jas_ocaml/test/algorithms/eyedropper_test.ml`,
`jas/algorithms/eyedropper_test.py`.

**Effects (`doc.eyedropper.sample`, `doc.eyedropper.apply_loaded`)**
— Rust carries 7 integration tests: sample writes to cache,
sample applies to non-empty selection, apply_loaded reads cache
and writes to clicked target, apply_loaded falls through to
sample when cache is null, locked source is rejected, locked
target is silently skipped, container target recurses into
leaves. Files: `jas_dioxus/src/interpreter/effects.rs`
(#[cfg(test)]). Swift / OCaml / Python rely on the algorithm
unit tests above; effect-level integration tests are the next
add.

**Cursor color chip overlay** — currently exercised only by the
algorithm-level Appearance round-trip (which validates cache
shape) plus manual smoke tests below. No dedicated rendering
auto-tests today.

---

## Preconditions (assumed for every session)

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default empty document.
3. Appearance: **Dark**.
4. Eyedropper tool active (toolbar slot 5,1 or press `I`).
5. Default toggles: every `state.eyedropper_*` key on (true).
   `state.eyedropper_cache` starts `null`.
6. Selection empty.

---

## Tier definitions

- **P0 — existential.** Tool doesn't activate, plain click
  doesn't populate the cache, or Alt+click doesn't write to a
  target.
- **P1 — core.** Master toggles gate entire groups, sub-toggles
  gate individual fields, eligibility filter excludes locked
  targets and hidden sources, cache survives tool switch and
  save/load, Esc clears cache.
- **P2 — edge & polish.** Color / stroke edge cases (None vs
  Solid, gradient, profile), Reset menu item, cursor color chip
  overlay rendering, dialog open / Cancel / OK behaviors.

---

## Session table of contents

| Session | Topic                                            | Est.  | IDs        |
|---------|--------------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                                | ~4m   | 001–009    |
| B       | Plain click sample                               | ~6m   | 010–029    |
| C       | Alt+click apply                                  | ~5m   | 030–049    |
| D       | Cache lifecycle (Esc, save/load, switch)         | ~5m   | 050–069    |
| E       | Master-toggle group gating                       | ~6m   | 070–099    |
| F       | Stroke sub-toggles                               | ~8m   | 100–129    |
| G       | Opacity / Character / Paragraph sub-toggles      | ~6m   | 130–159    |
| H       | Eligibility (source + target asymmetry)          | ~6m   | 160–189    |
| I       | Tool Options dialog                              | ~6m   | 190–219    |
| J       | Cursor color chip overlay                        | ~3m   | 220–239    |
| K       | Cross-app parity                                 | ~10m  | 300–329    |

Full pass: ~65 min.

---

## Session A — Smoke & lifecycle (~4 min)

- [ ] **EYE-001** [wired] **P0.** Eyedropper activates from the
      toolbar.
      Do: Click the eyedropper button at toolbar slot (5, 1).
      (Or press `I`.)
      Expect: Eyedropper tool active; the slot icon is highlighted;
      the canvas cursor is the eyedropper glyph with hot spot at
      the tip.
      — last: —

- [ ] **EYE-002** [wired] Eyedropper icon is visibly distinct.
      Do: Compare the EYEDROPPER icon to its toolbar neighbours
      (Hand at 5,0; Artboard at 5,2 if shown).
      Expect: Eyedropper shows squeeze cap upper-right + thin
      diagonal glass tube descending to a sharp tip at lower-left.
      No arrow or hand glyph.
      — last: —

- [ ] **EYE-003** [wired] **P0.** Pressing `I` activates the tool
      from any other tool.
      Do: Activate Selection (V), then press `I`.
      Expect: Eyedropper becomes active; toolbar reflects the
      change.
      — last: —

- [ ] **EYE-004** [wired] No drag, no marquee.
      Do: With Eyedropper active, press-and-drag across empty
      canvas.
      Expect: No marquee overlay drawn. On release, no selection
      change, no error.
      — last: —

- [ ] **EYE-005** [wired] Switching away from Eyedropper preserves
      cache.
      Do: Plain-click a styled element to populate the cache,
      then switch to Selection (V), then back to Eyedropper (I).
      Expect: Cache still non-null (cursor chip still visible
      when re-hovered); toggles unchanged.
      — last: —

---

## Session B — Plain click sample (~6 min)

- [ ] **EYE-010** [wired] **P0.** Plain click on an eligible
      element populates `state.eyedropper_cache`.
      Do: Place a red-fill / blue-stroke rect. Plain-click it.
      Expect: `state.eyedropper_cache` becomes a non-null object
      describing the fill / stroke / opacity / blend_mode of the
      clicked rect. The cursor color chip overlay appears.
      — last: —

- [ ] **EYE-011** [wired] **P0.** Plain click with empty selection
      does not mutate any element.
      Do: Selection empty. Plain-click a red rect.
      Expect: Cache populated; the red rect is unchanged
      (sampling is read-only when selection is empty).
      — last: —

- [ ] **EYE-012** [wired] **P0.** Plain click with a non-empty
      selection writes the sampled appearance onto every eligible
      target in the selection.
      Do: Place a red-fill rect A and a blue-fill rect B.
      Marquee-select B with Selection (V), switch to Eyedropper.
      Plain-click A.
      Expect: Cache = A's appearance; B's fill becomes red. A's
      fill is unchanged.
      — last: —

- [ ] **EYE-013** [wired] **P1.** Plain click on empty document
      space is a no-op.
      Do: With cache populated and selection containing one
      element, plain-click empty canvas.
      Expect: No change to cache, no change to the selected
      element. (Distinct from EYE-016 below — Esc is the only
      cache-clear gesture.)
      — last: —

- [ ] **EYE-014** [wired] Plain click on a Group resolves to the
      innermost element.
      Do: Place a red rect inside a Group. Plain-click on the
      visible red area through the group.
      Expect: Cache = red rect's appearance, not the group's.
      Selection (if any) gets the rect's appearance applied.
      — last: —

- [ ] **EYE-015** [wired] Plain click on a Layer resolves to the
      innermost element under cursor.
      Do: Click on a leaf inside the active Layer.
      Expect: Same as EYE-014 — the leaf is the source, not the
      Layer.
      — last: —

- [ ] **EYE-016** [wired] Re-sampling overwrites the cache.
      Do: Plain-click red rect (cache = red). Plain-click blue
      rect (cache = blue).
      Expect: Cache now reflects blue. Cursor chip updates to
      blue.
      — last: —

- [ ] **EYE-017** [wired] **P1.** Sampling onto a multi-element
      selection writes to every member.
      Do: Selection = three rects (red, green, yellow). Plain-click
      a blue rect.
      Expect: Cache = blue. All three previously selected rects
      now have blue fill.
      — last: —

---

## Session C — Alt+click apply (~5 min)

- [ ] **EYE-030** [wired] **P0.** Alt+click on an eligible target
      writes the cached appearance to that target.
      Do: Sample a red rect to populate the cache. Place a blue
      rect. Alt+click the blue rect.
      Expect: Blue rect's fill becomes red (and other cached
      attrs apply). Selection unchanged.
      — last: —

- [ ] **EYE-031** [wired] **P0.** Alt+click does not modify the
      selection.
      Do: Selection = {green rect}. Sample red. Alt+click the
      blue rect.
      Expect: Selection still {green}; blue is updated; green is
      not modified by the Alt+click (only by the prior sample if
      green was selected at sample time).
      — last: —

- [ ] **EYE-032** [wired] **P1.** Alt+click with a null cache
      falls through to plain-sample.
      Do: Press Esc to clear cache. Alt+click a red rect.
      Expect: Cache becomes red rect's appearance. (No prior
      cache → behaves like a plain click without selection
      apply.)
      — last: —

- [ ] **EYE-033** [wired] Alt+click on empty space is a no-op.
      Do: With non-null cache, Alt+click empty canvas.
      Expect: Cache unchanged. No element modified.
      — last: —

- [ ] **EYE-034** [wired] Alt+click on a Group writes to every
      eligible leaf descendant.
      Do: Sample red. Group two blue rects. Alt+click on the
      group.
      Expect: Both blue rects become red. The group itself has
      no fill change (containers don't carry painted attrs).
      — last: —

- [ ] **EYE-035** [wired] Alt+click on a Layer container also
      recurses.
      Do: Same as EYE-034 but with a Layer instead of a Group.
      Expect: Same — every eligible leaf in the layer receives
      the apply.
      — last: —

---

## Session D — Cache lifecycle (Esc, save/load, switch) (~5 min)

- [ ] **EYE-050** [wired] **P1.** Esc clears
      `state.eyedropper_cache`.
      Do: Sample any element. Press Esc.
      Expect: Cache becomes null. Cursor color chip overlay
      disappears.
      — last: —

- [ ] **EYE-051** [wired] **P1.** Cache survives tool switches.
      Do: Sample red. Switch to Selection (V), back to
      Eyedropper (I).
      Expect: Cache still red. Cursor chip reappears once the
      cursor moves over the canvas.
      — last: —

- [ ] **EYE-052** [wired] **P1.** Cache serializes with the
      document (save/load round-trip).
      Do: Sample red. Save the document. Reload it.
      Expect: Cache restored to red. Active tool may be the
      saved tool or default — switching to Eyedropper shows the
      red chip.
      — last: —

- [ ] **EYE-053** [wired] A fresh sample replaces (not merges
      with) the cache.
      Do: Sample a red rect with stroke=`#000`. Sample a blue
      rect with no stroke.
      Expect: Cache after second sample has stroke=null
      (replaced, not merged).
      — last: —

- [ ] **EYE-054** [wired] Esc with already-null cache is a no-op.
      Do: Press Esc twice in a row.
      Expect: First press clears (or was already null); second
      press changes nothing. No error.
      — last: —

---

## Session E — Master-toggle group gating (~6 min)

- [ ] **EYE-070** [wired] **P0.** With every master toggle on
      (default), all five groups copy on apply.
      Do: Sample a fully-styled rect (fill, stroke, opacity 0.5,
      blend Multiply). Selection = a plain rect. Plain-click
      source. (Selection apply path.)
      Expect: Plain rect now has the source's fill, stroke,
      opacity, and blend mode.
      — last: —

- [ ] **EYE-071** [wired] **P1.** `state.eyedropper_fill = false`
      → fill is not copied.
      Do: Toggle off Fill in the Tool Options dialog (or set the
      state directly). Sample a red-fill rect. Apply to a target.
      Expect: Target's fill remains its prior value; stroke /
      opacity / blend mode still copied.
      — last: —

- [ ] **EYE-072** [wired] **P1.** `state.eyedropper_stroke =
      false` → stroke group skipped (color, weight, dash, etc.).
      Do: Toggle Stroke off. Sample a black-stroke 4 pt rect.
      Apply to a target with a different stroke.
      Expect: Target's stroke unchanged. Fill / opacity / blend
      still apply.
      — last: —

- [ ] **EYE-073** [wired] **P1.** `state.eyedropper_opacity =
      false` → opacity group skipped (alpha + blend).
      Do: Toggle Opacity off. Sample a 0.4-opacity Multiply rect.
      Apply.
      Expect: Target's opacity stays at its prior value; blend
      mode unchanged. Fill / stroke still apply.
      — last: —

- [ ] **EYE-074** [wired] **P1.** All masters off → apply is a
      no-op.
      Do: Toggle all five masters off. Sample any rect. Apply.
      Expect: Target unchanged. Cache still populated (sample
      writes the cache regardless of toggles).
      — last: —

- [ ] **EYE-075** [wired] Master OFF still ignores its sub-
      toggles.
      Do: Toggle Stroke master off; leave all stroke sub-toggles
      on. Sample / apply.
      Expect: Stroke still skipped. Master gates regardless of
      sub state.
      — last: —

- [ ] **EYE-076** [placeholder] **P2.** Sampling a gradient fill
      caches as None for fill (Phase 1 deferral).
      Do: Sample a rect with a linear-gradient fill.
      Expect: Cache.fill is null (or sampled-as-None). Apply
      writes "no fill" to a target with the Fill master on.
      — last: —

- [ ] **EYE-077** [placeholder] **P2.** Sampling a pattern fill
      caches as None for fill.
      Do: (Once pattern fills exist.) Sample a rect with a
      pattern fill.
      Expect: Same as EYE-076 — cache.fill is null.
      — last: —

---

## Session F — Stroke sub-toggles (~8 min)

For each sub-toggle, set up a target with a distinguishable
existing stroke, sample a source whose stroke differs in only
that one field, then apply.

- [ ] **EYE-100** [wired] **P0.** `stroke_color` sub-toggle copies
      color only.
      Do: Target stroke = grey, 2 pt, butt cap. Source stroke =
      blue, 4 pt, round cap. Sub-toggles: only `stroke_color` on.
      Sample + apply.
      Expect: Target stroke = blue, 2 pt, butt cap. Color copied;
      width / cap preserved.
      — last: —

- [ ] **EYE-101** [wired] **P0.** `stroke_weight` sub-toggle
      copies width only.
      Do: Same as EYE-100 but only `stroke_weight` on.
      Expect: Target stroke = grey, 4 pt, butt cap.
      — last: —

- [ ] **EYE-102** [wired] **P1.** `stroke_cap_join` copies cap +
      join + miter limit.
      Do: Target = miter join, butt cap. Source = round cap,
      round join. Only `stroke_cap_join` on. Apply.
      Expect: Target gets round cap + round join; weight / color
      preserved.
      — last: —

- [ ] **EYE-103** [wired] **P1.** `stroke_align` copies center /
      inside / outside only.
      Do: Target = center align. Source = inside align. Only
      `stroke_align` on. Apply.
      Expect: Target now inside-aligned; other stroke fields
      unchanged.
      — last: —

- [ ] **EYE-104** [wired] **P1.** `stroke_dash` copies dash flag
      + the six dash/gap values.
      Do: Target = solid (no dash). Source = dashed
      (3,2,3,2,3,2 pattern). Only `stroke_dash` on. Apply.
      Expect: Target now dashed with the source's pattern.
      — last: —

- [ ] **EYE-105** [wired] **P1.** `stroke_arrowheads` copies
      start/end shape, scales, arrow-align.
      Do: Target = arrow-none. Source = simple arrow at end with
      scale 200. Only `stroke_arrowheads` on. Apply.
      Expect: Target now has source's arrowhead config.
      — last: —

- [ ] **EYE-106** [wired] **P2.** `stroke_profile` copies width
      points on Path / Line.
      Do: Target Path with uniform stroke. Source Path with a
      taper-end profile. Only `stroke_profile` on. Apply.
      Expect: Target now has the source's width-point list (a
      taper).
      — last: —

- [ ] **EYE-107** [wired] **P2.** `stroke_profile` is a no-op on
      element types without width_points.
      Do: Apply a sampled Path's profile to a Rect target.
      Expect: Rect target unchanged (Rect has no
      `width_points`).
      — last: —

- [ ] **EYE-108** [wired] **P1.** `stroke_brush` copies
      `jas:stroke-brush` on Path elements.
      Do: Target Path with no brush. Source Path with brush
      "calligraphic_default". Only `stroke_brush` on. Apply.
      Expect: Target Path now has brush "calligraphic_default".
      — last: —

- [ ] **EYE-109** [wired] All stroke sub-toggles off (master on)
      leaves stroke alone.
      Do: Master on; turn every stroke sub-toggle off. Sample /
      apply.
      Expect: Target stroke unchanged.
      — last: —

- [ ] **EYE-110** [wired] **P2.** Sub-toggle independence —
      enabling two sub-toggles copies exactly those two fields.
      Do: Only `stroke_color` and `stroke_weight` on. Sample
      source with distinct color + width + cap. Apply to target.
      Expect: Color + width copied; cap preserved.
      — last: —

- [ ] **EYE-111** [wired] **P2.** Source has no stroke (`None`),
      master on → target's stroke becomes None.
      Do: Source rect has `stroke = none`. Target has black
      stroke. Stroke master on. Apply.
      Expect: Target stroke = none.
      — last: —

- [ ] **EYE-112** [wired] **P2.** Source has no stroke, master
      on, but only sub-toggles off → target's stroke unchanged.
      Do: Source = no stroke. Target = black stroke. Master on,
      every stroke sub-toggle off. Apply.
      Expect: Target stroke unchanged. (No-op short-circuit when
      sub-toggles are all off.)
      — last: —

---

## Session G — Opacity / Character / Paragraph sub-toggles (~6 min)

### Opacity (2 sub-toggles)

- [ ] **EYE-130** [wired] **P1.** `opacity_alpha` copies element
      alpha only.
      Do: Source opacity 0.4, blend Normal. Target opacity 1.0,
      blend Multiply. Master Opacity on, only `opacity_alpha`
      on. Apply.
      Expect: Target opacity = 0.4; blend mode still Multiply.
      — last: —

- [ ] **EYE-131** [wired] **P1.** `opacity_blend` copies blend
      mode only.
      Do: Source blend Multiply. Target opacity 1.0, blend
      Normal. Only `opacity_blend` on. Apply.
      Expect: Target blend mode = Multiply; opacity unchanged.
      — last: —

- [ ] **EYE-132** [wired] Opacity master on, both sub-toggles
      off → opacity group is a no-op.
      Do: Sample / apply with opacity master on, both sub-
      toggles off.
      Expect: Target opacity + blend unchanged.
      — last: —

- [ ] **EYE-133** [wired] **P2.** Opacity copy never touches the
      mask field.
      Do: Target has an opacity mask attached. Sample any source
      and apply with full opacity master + sub-toggles.
      Expect: Mask still attached after apply (alpha + blend
      copy doesn't remove the mask).
      — last: —

### Character (master + 6 sub-toggles)

- [ ] **EYE-138** [placeholder] **P1.** `character_font` copies
      font family + style.
      Do: Source Text element using "Inter Bold". Target Text
      with "Helvetica Regular". Only Character master + sub
      `character_font`. Apply.
      Expect (Phase 2+): Target shows Inter Bold; size etc.
      preserved. (Phase 1 stub: no change.)
      — last: —

- [ ] **EYE-139** [placeholder] `character_size` copies size.
      Do: Source 24 pt. Target 12 pt. Only `character_size`.
      Apply.
      Expect (Phase 2+): Target now 24 pt. (Phase 1: stub.)
      — last: —

- [ ] **EYE-140** [placeholder] `character_leading` copies
      leading.
      Expect (Phase 2+): Target leading replaced. (Phase 1: stub.)
      — last: —

- [ ] **EYE-141** [placeholder] `character_kerning` copies
      kerning. (Phase 1 stub.)
      — last: —

- [ ] **EYE-142** [placeholder] `character_tracking` copies
      tracking. (Phase 1 stub.)
      — last: —

- [ ] **EYE-143** [placeholder] `character_color` copies
      character fill color independently from element fill.
      (Phase 1 stub — will require text-element internals.)
      — last: —

- [ ] **EYE-144** [placeholder] **P2.** Character apply is a
      no-op when target is not a Text / TextPath element.
      Do: Sample a Text element. Apply to a Rect.
      Expect: Rect's painted attrs (fill / stroke etc.) update;
      character sub-toggles silently ignored.
      — last: —

### Paragraph (master + 4 sub-toggles)

- [ ] **EYE-150** [placeholder] `paragraph_align` copies
      paragraph alignment. (Phase 1 stub.)
      — last: —

- [ ] **EYE-151** [placeholder] `paragraph_indent` copies left /
      right / first-line indents. (Phase 1 stub.)
      — last: —

- [ ] **EYE-152** [placeholder] `paragraph_space` copies space
      before / after. (Phase 1 stub.)
      — last: —

- [ ] **EYE-153** [placeholder] `paragraph_hyphenate` copies the
      hyphenate flag. (Phase 1 stub.)
      — last: —

- [ ] **EYE-154** [placeholder] **P2.** Paragraph apply is a
      no-op when target is not a Text / TextPath element.
      Same shape as EYE-144.
      — last: —

---

## Session H — Eligibility (source + target asymmetry) (~6 min)

- [ ] **EYE-160** [wired] **P1.** Locked source IS eligible
      (read-only sampling).
      Do: Lock a red rect. Plain-click it.
      Expect: Cache populated with red rect's appearance.
      — last: —

- [ ] **EYE-161** [wired] **P1.** Hidden source is NOT eligible
      (no hit-test).
      Do: Hide a red rect. Plain-click where it would have been.
      Expect: Click resolves to whatever is behind it (or no-op
      if nothing else is there). Cache does not capture hidden
      rect's appearance.
      — last: —

- [ ] **EYE-162** [wired] **P1.** Outline-mode source IS eligible
      and samples model attrs.
      Do: Set a red rect to Outline visibility. Plain-click it.
      Expect: Cache.fill = red (the model fill, not the rendered
      outline color).
      — last: —

- [ ] **EYE-163** [wired] Group / Layer cannot be sampled
      directly — click resolves to leaves.
      Do: Group with one rect inside. Plain-click the rect's
      visible area through the group.
      Expect: Cache = leaf rect's appearance. The group itself
      is never the source.
      — last: —

- [ ] **EYE-164** [wired] **P1.** Locked target is NOT eligible
      (silent skip).
      Do: Sample a styled source. Lock a target rect. Add it to
      selection. Plain-click source (selection apply path).
      Expect: Locked rect is unchanged; non-locked targets in
      the selection receive the apply. No error.
      — last: —

- [ ] **EYE-165** [wired] **P1.** Hidden target IS eligible
      (writes persist).
      Do: Sample a red source. Hide a target. Apply (Alt+click
      or via selection).
      Expect: Hidden target's appearance updated; once unhidden,
      the new fill / stroke shows.
      — last: —

- [ ] **EYE-166** [wired] **P1.** Group / Layer in selection
      recurses into leaves.
      Do: Sample red. Selection = a group containing two blue
      rects. Plain-click source.
      Expect: Both blue rects are now red. The group's
      identity / nesting unchanged.
      — last: —

- [ ] **EYE-167** [wired] **P2.** Mask-subtree element is not
      eligible as a source.
      Do: Plain-click an element that lives inside an opacity
      mask subtree.
      Expect: Cache unchanged. (Mask shape is not painted
      output.)
      — last: —

- [ ] **EYE-168** [wired] **P2.** Mask-subtree element is not
      eligible as a target.
      Do: Sample a styled source. Add a mask-subtree element to
      the selection. Plain-click source.
      Expect: Mask-subtree element unchanged.
      — last: —

- [ ] **EYE-169** [wired] CompoundShape (live) is eligible as
      both source and target.
      Do: Sample red. Apply to a CompoundShape via Alt+click.
      Expect: CompoundShape's own fill becomes red.
      — last: —

---

## Session I — Tool Options dialog (~6 min)

- [ ] **EYE-190** [wired] **P0.** Double-click the Eyedropper
      icon opens the Eyedropper Tool Options dialog.
      Do: Double-click the eyedropper button in the toolbar.
      Expect: Dialog appears with title "Eyedropper Tool
      Options". Five master rows (Fill, Stroke, Opacity,
      Character, Paragraph) plus Reset / Cancel / OK at the
      bottom.
      — last: —

- [ ] **EYE-191** [wired] **P1.** Dialog opens populated with
      current state.
      Do: Toggle off `state.eyedropper_fill` directly (e.g. via
      an earlier dialog session). Reopen the dialog.
      Expect: Fill checkbox is unchecked; the rest reflect
      current state.
      — last: —

- [ ] **EYE-192** [wired] **P1.** Sub-toggles render indented
      under their master.
      Do: Open dialog.
      Expect: Stroke has 8 indented sub-toggles; Opacity has 2;
      Character has 6; Paragraph has 4. Fill has none.
      — last: —

- [ ] **EYE-193** [wired] **P2.** Sub-toggles are visibly
      disabled (greyed) when their master is OFF.
      Do: Uncheck Stroke master. Inspect the eight Stroke sub-
      toggles.
      Expect: Sub-toggles greyed; their checked state preserved
      (they reactivate visually when master is re-checked).
      — last: —

- [ ] **EYE-194** [wired] **P1.** Cancel discards working-copy
      edits.
      Do: Open dialog. Toggle several values. Click Cancel.
      Expect: `state.eyedropper_*` keys unchanged.
      — last: —

- [ ] **EYE-195** [wired] **P1.** OK writes working copy to
      state.
      Do: Open dialog. Uncheck Fill. Click OK.
      Expect: `state.eyedropper_fill = false`.
      — last: —

- [ ] **EYE-196** [wired] **P2.** Reset writes the declared
      defaults (all-true) to the working copy.
      Do: Open dialog. Uncheck several values. Click Reset.
      Expect: All 25 checkboxes return to checked. Nothing
      committed yet (Cancel still discards).
      — last: —

- [ ] **EYE-197** [wired] **P2.** OK after Reset commits the
      defaults.
      Do: After EYE-196, click OK.
      Expect: All 25 `state.eyedropper_*` keys are `true`.
      — last: —

- [ ] **EYE-198** [wired] Dialog never touches
      `state.eyedropper_cache`.
      Do: Sample a red rect (cache populated). Open dialog,
      toggle / Reset / OK.
      Expect: Cache still red after the dialog closes; cursor
      chip still red.
      — last: —

---

## Session J — Cursor color chip overlay (~3 min)

- [ ] **EYE-220** [wired] **P1.** Chip is hidden when the cache
      is null.
      Do: Press Esc. Move cursor over the canvas.
      Expect: No color chip rendered.
      — last: —

- [ ] **EYE-221** [wired] **P1.** Chip appears at offset
      (+12, +12) from the cursor while cache is non-null.
      Do: Sample a red rect. Move the cursor across the canvas.
      Expect: A small swatch follows the cursor at lower-right
      offset (+12, +12).
      — last: —

- [ ] **EYE-222** [wired] **P1.** Chip fill matches the cached
      `cache.fill.color`.
      Do: Sample a `#ff0000` rect. Hover.
      Expect: Chip is filled red.
      — last: —

- [ ] **EYE-223** [wired] **P2.** Chip border matches the cached
      `cache.stroke.color`.
      Do: Sample a rect with `fill=#ff0000`, `stroke=#0000ff`.
      Hover.
      Expect: Chip is red with a 1 px blue border.
      — last: —

- [ ] **EYE-224** [wired] **P2.** Chip border falls back to a
      neutral outline when stroke is None.
      Do: Sample a rect with `stroke = none`. Hover.
      Expect: Chip's border is a neutral grey (~#888) so the
      chip stays visible against any backdrop.
      — last: —

- [ ] **EYE-225** [wired] **P2.** Chip renders the none-glyph
      when fill is None / gradient / pattern.
      Do: Sample a rect with `fill = none`.
      Expect: Chip shows a white square with a red diagonal
      slash (none-glyph).
      — last: —

- [ ] **EYE-226** [wired] Chip only renders while Eyedropper is
      the active tool.
      Do: Sample, then switch to Selection (V).
      Expect: Chip disappears. Switch back to Eyedropper —
      reappears.
      — last: —

---

## Session K — Cross-app parity (~10 min)

Re-run a core subset (EYE-001, EYE-010, EYE-012, EYE-030,
EYE-032, EYE-050, EYE-051, EYE-052, EYE-070, EYE-100, EYE-130,
EYE-160, EYE-164, EYE-166, EYE-190, EYE-195, EYE-221) on each
of:

| Platform | Notes                                                        |
|----------|--------------------------------------------------------------|
| Rust     | Reference. Full coverage above.                              |
| Swift    | All sessions in scope.                                       |
| OCaml    | Toolbar icon deferred (see Known broken). Press `I` to enter the tool; rest of suite in scope. |
| Python   | All sessions in scope.                                       |
| Flask    | Tool not implemented; skip entire suite.                     |

- [ ] **EYE-300** [wired] Tool activates from toolbar / shortcut.
      (EYE-001 / EYE-003.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: — (toolbar dblclick / icon deferred — `I` only)
      - [ ] Python     last: —

- [ ] **EYE-301** [wired] Plain click samples to cache.
      (EYE-010.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-302** [wired] Plain click + non-empty selection
      writes to selection. (EYE-012.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-303** [wired] Alt+click applies cache to target.
      (EYE-030.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-304** [wired] Alt+click with null cache falls
      through to sample. (EYE-032.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-305** [wired] Esc clears the cache. (EYE-050.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-306** [wired] Cache survives tool switch + save/load.
      (EYE-051 / EYE-052.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-307** [wired] Master toggles gate entire groups.
      (EYE-070 / EYE-074.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-308** [wired] `stroke_color` sub-toggle preserves
      target's other stroke fields. (EYE-100.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-309** [wired] `opacity_alpha` copies element alpha
      without affecting blend mode. (EYE-130.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-310** [wired] Locked source eligible; locked target
      not. (EYE-160 / EYE-164.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-311** [wired] Group / Layer target recurses to
      leaves. (EYE-166.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **EYE-312** [wired] Tool Options dialog opens via
      double-click on the icon and OK commits to state.
      (EYE-190 / EYE-195.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: — (icon deferred — open via menu if available)
      - [ ] Python     last: —

- [ ] **EYE-313** [wired] Cursor color chip renders at offset
      with cached fill / border. (EYE-221 / EYE-222 / EYE-223.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Coverage matrix (tier × session)

|              | A | B | C | D | E | F | G | H | I | J | K |
|--------------|---|---|---|---|---|---|---|---|---|---|---|
| P0           | 2 | 3 | 1 | — | 1 | 2 | — | — | 1 | — | — |
| P1           | — | 2 | 1 | 3 | 4 | 5 | 3 | 5 | 4 | 3 | — |
| P2           | — | — | — | — | 2 | 3 | 1 | 3 | 4 | 4 | — |

---

## Observed bugs (append only)

_None yet._

---

## Graveyard

_None yet._

---

## Enhancements

_None yet._
