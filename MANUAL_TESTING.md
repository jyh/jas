# Manual Test Suite — Per-Component Procedure

Guide for designing a manual test suite for any UI component (panel, dialog,
menubar, layout system, theming, shortcuts). Manual tests cover what auto-tests
can't: widget rendering, typeahead, focus/tab order, menu interaction,
dock/float, appearance theming, visual correctness of canvas output,
cross-panel regressions, and keyboard-only paths.

## Core approach

- One file per component: `<NAME>_TESTS.md` in the transcripts/ directory.
- Test surface derived from the component's yaml spec (`workspace/**/<name>.yaml`)
  plus a small non-yaml section for lifecycle, cross-component, and theming.
- Stable IDs, `[placeholder]` / `[wired]` status tag, priority tier
  (`P0` / `P1` / `P2`), two-line `Do` / `Expect` description, persistent
  pass/fail via checkbox + last-passed date.
- Tests chunked into 10–15 min sessions by feature area; smoke gates all.
- Cross-app parity as a separate short section (~5–8 load-bearing tests run
  across all 5 apps: Rust, Swift, OCaml, Python, Flask).
- Known-broken summary at top; inactive tests (won't fix, duplicate, retired)
  graveyarded at bottom.
- Prose expectations; no per-test screenshot baselines.

## File structure

```
1. Known broken           — summary: IDs + since-date for fix-later items
2. Automation coverage    — class-level summary of auto-tests this suite
                            complements. Includes "last synced" date.
3. Default setup          — shared preamble (app, fixture, selection) for
                            all sessions
4. Tier definitions       — P0/P1/P2 meanings (identical across components)
5. Session ToC            — session name + est. time + ID range
6. Sessions               — tests grouped by tier within each session
7. Cross-app parity       — per-platform checkbox blocks
8. Graveyard              — won't fix / duplicate / retired, grouped
9. Enhancements           — non-blocking follow-ups raised during testing
                            (feature requests, UX gaps, cross-cutting polish)
```

## Step-by-step procedure

### 1. Drive the suite from the yaml

Walk every node in the component's yaml that has an `id` or `action`. Each
becomes one or more tests. The yaml's `description` fields are the expected-
behavior source. Tests group naturally by yaml row / section structure.

Add a small non-yaml section at the end covering what the yaml doesn't:
component open/close, dock/float, cross-component regressions, appearance
theming, keyboard navigation.

Mark each test:

- `[placeholder]` — widget binds to component-local state only; doesn't yet
  act on document/selection.
- `[wired]` — acts on the selected element (or applicable target).

Flip the tag when plumbing lands. The test keeps the same ID across the
transition; Expect text tightens.

### 2. Enumerate existing automation

Open the file with a summary of auto-test coverage, **class-level not
test-level** (100 test names is noise). For each language:

- Name the test file path.
- Bullet the classes / feature areas covered in one line each.
- Explicitly note languages without coverage (e.g. "Rust: no Character
  auto-tests").

Include `last synced: YYYY-MM-DD`. When auto-tests change, resync.

The manual suite below then covers the complement: what the auto-tests can't
reach (UI, focus, theming, lifecycle, menu UX).

### 3. Test format — three lines per test

```
- [ ] **<PREFIX>-NNN** [placeholder|wired][known-broken: ref]? One-line description
      Do: Atomic action to exercise the feature.
      Expect: Observable outcome, stated concretely.
      — last: YYYY-MM-DD or — · regression: free text (if failing)
```

Rules:

- Add a `Setup:` line only when the test needs more than the session default.
- Add a `Pass if:` line only when `Expect` is ambiguous.
- `Expect` must be observable — what the tester sees — not internal state.
- Keep `Do` atomic. One action, one observation. Two clicks before one
  observation is probably two tests.

### 4. Session chunking

Sessions are 5–15 min, grouped by feature area. Ordering:

- Session A = smoke + lifecycle. Always first. Gates the rest — if it fails,
  stop.
- Subsequent sessions by feature area (dropdowns, numeric inputs, toggles,
  menu, theming, etc.).
- Cross-app parity is the optional last session.

Within each session: tier subheader (`**P0**`, `**P1**`, `**P2**`),
insight-first within tier. Drop the tier subheader when a session has ≤4
tests total.

### 5. Priority tiers

State once at top of the file:

- **P0 — existential:** If this fails, the component is broken. Crash, layout
  collapse, complete non-function. 5-minute smoke confidence.
- **P1 — core:** Control does its primary job (click / drag / enter / select
  / toggle).
- **P2 — edge & polish:** Bounds, keyboard-only paths, focus / tab order,
  appearance variants, mutual-exclusion display, icon states.

Default to the lower tier when ambiguous. Promote under evidence (a bug
demonstrates the test matters).

Flipping `[placeholder]` → `[wired]` often promotes tier (P2 → P1 or P1 → P0)
because wired tests affect user output.

### 6. Stable IDs

- Prefix per component, uppercase (CHR, CLR, LYR, SWP, MENU, DLG-COLOR, …).
- Three-digit zero-padded suffix: `CHR-010`, not `CHR-10`.
- Session ranges allocate capacity, densely used within:
  ```
  A smoke        001–009
  B ...          010–029
  C ...          030–069
  ...
  I parity       200–249
  ```
  Reserve generous headroom. Jump ranges with a note if a session overflows.
- IDs never renumber, never reuse. Deleted tests' IDs stay dead.
- Doc order = insight-within-tier, not ID order. ID is a handle, not a
  position.

### 7. Fixtures

Default: inline setup in `Do` lines. Create a fixture file
(`test_fixtures/<component>/`) only when the setup repeats ≥3 times or takes
more than a few clicks.

- Fixtures use the app's native document format.
- Committed to repo.
- `README.md` in the component fixture dir lists each fixture and its purpose.

### 8. Cross-app parity

~5–8 load-bearing tests for behaviors where cross-language drift produces
user-visible bugs. Always `[wired]`. Format:

```
- **<PREFIX>-200** [wired] Behavior description
      Do: ...
      Expect: ...
      - [ ] Rust       last: —
      - [ ] Swift      last: —
      - [ ] OCaml      last: —
      - [ ] Python     last: —
      - [ ] Flask      last: —
```

No tier subheaders in parity section (all effectively P1). Batch by app when
running — one full pass per app, not one pass per test.

Not every component has 5 apps. Omit Flask if generic-only (Flask is generic);
include only apps that expose the component.

### 9. Known-broken and graveyard

`[known-broken: <ref>]` tag on the test in place, plus a summary at the top
of the file listing known-broken IDs with `since: <date>`. Top-of-file summary
carries `last reviewed: <date>` to pressure periodic sweep.

Entry criteria for known-broken:

- Reproducible across two runs.
- Triaged — has a ticket, or at minimum a one-sentence justification.
- Not in current push scope.

Fresh regressions stay regular-failing (unchecked + `regression:` note) until
triaged.

Graveyard at bottom of the file — inactive tests no longer run. Categories:

- `[wontfix: <reason>]` — deliberate non-fix.
- `[duplicate: <canonical-ID>]` — superseded.
- `[retired: <reason>]` — spec changed; test no longer applicable.

Tests move location (session → graveyard) but keep their ID. Never delete —
external references (commits, issues) must not dangle.

### 10. Visual checks

Prose `Expect`s. Cite the component's design doc / the yaml `description` /
CSS theme tokens when precision is needed.

Do **not** reference `examples/*.png` or any checked-in image as a baseline —
those images are scratch captures, not durable reference material. If visual
regression becomes a real concern, add automated tooling (Playwright/Percy-
style) rather than building a manual photo album.

### 11. Enhancements / follow-ups

Manual testing surfaces non-blocking ideas — feature requests, UX gaps, cross-
cutting polish — that aren't test failures but shouldn't be lost. Append them
to an **Enhancements** section at the end of the same `<NAME>_TESTS.md` file.

- Use the `ENH-NNN` prefix, three-digit dense numbering per component.
- Each entry: one paragraph describing the idea; italicized trailer with
  `_Raised during <test-id> on <date>._`
- When an enhancement ships, delete the entry (or move under a "Done"
  subheader if useful).
- Cross-cutting enhancements (affect more than this component) still live
  here, noted first in the file that surfaced them. Don't duplicate across
  test files.

This keeps the finding with the test that surfaced it and avoids sprawl
across an external tracker or memory system.

## Checklist — creating a new `<NAME>_TESTS.md`

1. Read the component yaml end to end.
2. Grep existing auto-tests across Python / Swift / OCaml / Rust / Flask.
   Draft the automation summary (class-level).
3. List every yaml node with `id` or `action`; draft one or more tests per node.
4. Draft the non-yaml section: lifecycle, dock, cross-component, theming,
   keyboard navigation.
5. Organize into sessions by feature area. Session A = smoke.
6. Assign tiers within each session; default to the lower tier when unsure.
7. Order tests insight-first within each tier.
8. Assign IDs in dense blocks per session with headroom for growth.
9. Write `Do` / `Expect` for each test. `Setup:` only where session default
   doesn't suffice.
10. Draft cross-app parity section (~5–8 load-bearing `[wired]` tests).
11. Add the standard scaffolding: tier definitions, default setup, known-broken
    block (empty), graveyard (empty), enhancements section (empty).

## Maintenance rituals

- **When the yaml changes:** diff yaml IDs against test IDs; add missing tests
  or graveyard retired ones.
- **When auto-tests change:** update the automation summary and its
  `last synced:` date.
- **When a test passes:** tick + update `last:` date.
- **When a test fails:** untick + add `regression:` note. If triaged, add the
  `[known-broken]` tag and summary entry.
- **When a test is superseded:** move to graveyard with appropriate category
  tag; keep the ID.
- **When testing surfaces an enhancement idea:** append an `ENH-NNN` entry
  to the Enhancements section with the test ID and date it was raised.
- **Periodic (every 30–60 days):** scan known-broken summary, sweep stale
  `last:` dates, re-examine the graveyard for anything ready to rehabilitate,
  review Enhancements for anything ripe to ship or reclassify.

## Applying to non-panel components

The procedure is identical; yaml paths and natural feature-area groupings
differ:

- **Panels:** `workspace/panels/<name>.yaml`. Groupings: yaml rows / sections.
- **Dialogs:** `workspace/dialogs/<name>.yaml`. Groupings: open path,
  field-by-field, confirm/cancel paths, keyboard dismissal.
- **Menubar:** `workspace/menubar.yaml`. Groupings: top-level menu by top-level
  menu. Smoke covers all menus opening at all.
- **Layout / docking:** `workspace/layout.yaml`, `default_layouts.yaml`.
  Groupings: pane drag, split, collapse, layout save/load, appearance per
  layout. Heavy on lifecycle; yaml-driven part is small.
- **Shortcuts:** `workspace/shortcuts.yaml`. Groupings: by context
  (global, panel-local, canvas). Mostly `[wired]` by nature.
- **Theming:** `workspace/theme.yaml`, `appearances/*`. Groupings: color
  tokens, per-appearance rendering, transitions. Almost entirely visual —
  prose Expects do heavy lifting.

For components without a yaml spec, skip the yaml-driven section and rely on
the non-yaml section expanded to cover the full surface; everything else is
identical.
