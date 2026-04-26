# Properties Panel — Manual Test Suite

Follows the procedure in `MANUAL_TESTING.md`. Spec source:
`workspace/panels/properties.yaml`. No standalone design doc — the
panel is a `type: placeholder` stub today; the yaml's `description`
is the only spec text.

Primary platform for manual runs: **Rust (jas_dioxus)**. Other
platforms covered in Session C parity sweep.

---

## Known broken

_Last reviewed: 2026-04-26_

- **Panel is a placeholder.** `properties.yaml` declares
  `type: placeholder` with summary "Object properties". The yaml's
  `description` lists the intended surface — position (X, Y), size
  (W, H), constrain-proportions lock, rotation, shear, opacity
  slider, blend mode dropdown, mixed-value handling — but no widget
  rows are wired and no dialog/state hooks exist. Every PROP-NNN
  test below that targets a field is `[placeholder]` until the real
  implementation lands.
- **Cross-app drift.** Rust / Swift / OCaml / Python all render
  the placeholder via their respective `render_placeholder` (or
  equivalent) path. Visual output differs slightly across apps
  because each app's placeholder renderer is hand-rolled; cross-app
  parity tests therefore exercise only "panel exists + Window menu
  toggle works", not visual equivalence.
- **Flask** — placeholder panels render via the generic
  `<placeholder>` path. Field-level tests do not apply.

---

## Automation coverage

_Last synced: 2026-04-26_

**Layout / dock plumbing.** The Properties panel is exercised by
the existing layout tests in every app (`PanelKind::Properties`
appears in default layouts and `PanelKind::ALL`). Tests verify
that the panel is part of the panel set, that the layout
serializer round-trips it, and that Window-menu toggle paths
resolve to the right `PanelKind`. Files:
`jas_dioxus/src/workspace/workspace.rs` (#[cfg(test)]),
`JasSwift/Tests/Workspace/WorkspaceLayoutTests.swift`,
`jas_ocaml/test/workspace/workspace_layout_test.ml`,
`jas/workspace/workspace_layout_test.py`.

**No field / widget auto-tests** — the panel has no fields to
test. The widget tests will land alongside the real
implementation.

The manual suite below complements: open / close / dock / float
lifecycle, placeholder rendering, Window-menu toggle, and
appearance theming. Field tests are pre-allocated `[placeholder]`
slots so IDs stay stable when the real panel ships.

---

## Default setup

Unless a session or test says otherwise:

1. Launch the primary app (`jas_dioxus`).
2. Open a default workspace with no document loaded.
3. Appearance: **Dark**.
4. Properties panel visible (default layout pairs it with Stroke
   in panel group 1; if hidden, open via Window → Properties).

---

## Tier definitions

- **P0 — existential.** Panel doesn't open, crashes the app, or
  collapses the layout when shown.
- **P1 — core.** Window-menu toggle works; panel docks / floats;
  placeholder summary renders.
- **P2 — edge & polish.** Appearance theming, dock-with-Stroke
  group integrity, multi-pane layouts. Field-level tests are all
  `[placeholder]` here pending real implementation.

---

## Session table of contents

| Session | Topic                                       | Est.  | IDs        |
|---------|---------------------------------------------|-------|------------|
| A       | Smoke & lifecycle                           | ~3m   | 001–019    |
| B       | Field-level (deferred to real impl)         | ~0m   | 020–099    |
| C       | Cross-app parity                            | ~5m   | 200–219    |

Full pass: ~8 min today (Session B is mostly placeholder slots).

---

## Session A — Smoke & lifecycle (~3 min)

- [ ] **PROP-001** [wired] **P0.** Properties panel is part of
      the default layout.
      Do: Launch the app with the default workspace.
      Expect: A pane labelled "Properties" exists; either visible
      out of the box (Stroke / Properties group) or available via
      Window → Properties.
      — last: —

- [ ] **PROP-002** [wired] **P0.** Window → Properties toggles
      the panel.
      Do: With Properties visible, choose Window → Properties.
      Then choose it again.
      Expect: First click hides the panel; second click shows it.
      Toggle indicator (checkmark or radio) reflects current
      state.
      — last: —

- [ ] **PROP-003** [wired] **P1.** Panel renders the placeholder
      summary text.
      Do: Make Properties visible.
      Expect: Panel body shows "Object properties" (the
      `summary` field from the yaml). No field widgets, no error
      glyph — just the placeholder text rendered in the
      appearance's secondary text color.
      — last: —

- [ ] **PROP-004** [wired] **P1.** Panel docks alongside Stroke.
      Do: Reset the layout to defaults (Window → Reset Layout, or
      delete `workspace_layout.json` and relaunch). Inspect panel
      group 1.
      Expect: Stroke + Properties share a tab group. Tabs switch
      independently.
      — last: —

- [ ] **PROP-005** [wired] **P2.** Panel survives float / re-dock.
      Do: Drag the Properties title bar out to float, then drag
      it back into the Stroke group.
      Expect: Panel re-docks; placeholder summary still renders.
      No layout corruption.
      — last: —

- [ ] **PROP-006** [wired] **P2.** Panel respects appearance
      theming.
      Do: Switch Appearance → Light Gray, then back to Dark.
      Expect: Placeholder text + panel chrome recolor to match
      the active appearance.
      — last: —

- [ ] **PROP-007** [wired] **P2.** Closing via the panel's title-
      bar close button hides it (does not destroy state).
      Do: Click the title-bar `×`. Reopen via Window →
      Properties.
      Expect: Panel returns to the same dock slot. The Window
      menu's checkmark for Properties stays in sync.
      — last: —

---

## Session B — Field-level (deferred to real implementation) (~0m today)

All tests in this session are `[placeholder]` until the real
Properties panel lands. Yaml `description` defines the surface:
position (X, Y), size (W, H) with constrain-proportions lock,
rotation angle, shear, opacity slider, blend mode dropdown,
mixed-value handling for multi-element selection.

- [ ] **PROP-020** [placeholder] **P1.** X / Y inputs reflect the
      selected element's position. Editing applies immediately.
      — last: —

- [ ] **PROP-021** [placeholder] **P1.** W / H inputs reflect the
      selected element's size. Editing applies immediately.
      — last: —

- [ ] **PROP-022** [placeholder] **P1.** Constrain-proportions
      lock keeps W:H ratio when one dimension is edited.
      — last: —

- [ ] **PROP-023** [placeholder] **P1.** Rotation input reflects
      the selected element's rotation; editing applies.
      — last: —

- [ ] **PROP-024** [placeholder] **P1.** Shear input reflects /
      applies the selected element's shear.
      — last: —

- [ ] **PROP-025** [placeholder] **P1.** Opacity slider reflects /
      applies the selected element's opacity.
      — last: —

- [ ] **PROP-026** [placeholder] **P1.** Blend mode dropdown
      reflects / applies the selected element's blend mode.
      — last: —

- [ ] **PROP-027** [placeholder] **P1.** Multi-element selection
      with shared values shows the shared value in every input.
      — last: —

- [ ] **PROP-028** [placeholder] **P1.** Multi-element selection
      with mixed values shows blank (mixed-state) in inputs whose
      values differ.
      — last: —

- [ ] **PROP-029** [placeholder] **P2.** Empty selection blanks
      every input (or disables them).
      — last: —

- [ ] **PROP-030** [placeholder] **P2.** Edits commit on blur,
      Enter, and tab-out — no need to click an apply button.
      — last: —

- [ ] **PROP-031** [placeholder] **P2.** Edits are undoable as a
      single transaction per field.
      — last: —

---

## Session C — Cross-app parity (~5 min)

Re-run PROP-001, PROP-002, PROP-003, PROP-004, PROP-006 on each
of:

| Platform | Notes                                            |
|----------|--------------------------------------------------|
| Rust     | Reference. Full coverage above.                  |
| Swift    | All Session A tests in scope.                    |
| OCaml    | All Session A tests in scope.                    |
| Python   | All Session A tests in scope.                    |
| Flask    | Placeholder panel renders via the generic stub; PROP-001 / PROP-003 only. |

- [ ] **PROP-200** [wired] Default layout exposes the Properties
      pane. (PROP-001.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- [ ] **PROP-201** [wired] Window → Properties toggles
      visibility. (PROP-002.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: — (Flask: skip if no Window menu)

- [ ] **PROP-202** [wired] Placeholder summary "Object
      properties" renders. (PROP-003.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —

- [ ] **PROP-203** [wired] Properties docks alongside Stroke in
      the default layout. (PROP-004.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

- [ ] **PROP-204** [wired] Appearance theming repaints the panel
      cleanly. (PROP-006.)
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —

---

## Coverage matrix (tier × session)

|              | A | B | C |
|--------------|---|---|---|
| P0           | 2 | — | — |
| P1           | 2 |12 | — |
| P2           | 3 | 3 | — |

(All Session B tests are `[placeholder]`. The B totals reflect
*intended* tier counts once the real panel ships.)

---

## Observed bugs (append only)

_None yet._

---

## Graveyard

_None yet._

---

## Enhancements

_None yet._
