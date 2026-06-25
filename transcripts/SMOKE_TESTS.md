# Smoke tests — post tool-activation fix

Branch: `smoke-tests-post-activation` (off `main` @ `5fc91a61`).
Date: 2026-06-24.
Driver: `jas_gui_harness.py` (Quartz synthetic input + `screencapture`).

## Scope

Sanity-check that all four native/desktop apps launch and the core interactive
path works after merging the tool-activation fix (`5fc91a61`) — with explicit
coverage of the paths that were broken/crashing in the Rust app:

- **S1 Launch** — window appears with a document + artboard.
- **S2 Draw** — select Rectangle (`M`) + mouse drag → a rectangle is created and
  auto-selected.
- **S3 Tool-switch no-crash** — select Scale (`S`) with a shape selected, then Pen
  (`P`). These are the exact triggers that produced the Rust `RefCell already
  borrowed` panic before the fix.
- **S4 File▸New** (Rust only — it was broken there) — creates a new tab/document.

## Harness pattern (carried over from the per-app drag checks)

- Select tools by **keyboard shortcut** (`M`/`S`/`P`/`V`), not the toolbar icon —
  a synthetic icon click can register as hover, not select.
- Draw with the **button-held `dragbegin`/`dragpath`/`dragend`** sequence with
  short sleeps, not a single-shot `drag` — GTK/Qt/web canvases need the motion
  spread over time or it reads as a click.
- Launch each app with `--title <X>` and match with `JAS_TITLE=<X>`. Note `JAS_TITLE`
  is a substring match, so close other `Jas*`-titled windows first (e.g. `JasSwift`
  matches a bare `Jas` query).

## Results — ALL PASS

| App | Framework | S1 Launch | S2 Draw (drag) | S3 Scale/Pen no-crash | S4 File▸New |
|-----|-----------|-----------|----------------|-----------------------|-------------|
| Rust / Dioxus | web/wasm (chromeless Chrome) | PASS | PASS | **PASS** (scale `+` ref-cross drawn; no panic) | PASS |
| Swift | AppKit | PASS | PASS | PASS | n/a (was fine) |
| OCaml | lablgtk3 | PASS | PASS | PASS | n/a (was fine) |
| Python | PySide6/Qt | PASS | PASS | PASS | n/a (was fine) |

The Rust S3 is the key result: selecting Scale on a selected shape draws the
reference-point cross overlay and selecting Pen switches cleanly — both formerly
panicked (`js-sys QueueState::run_all` `RefCell already borrowed`, the red-herring
surfacing of an un-activated tool's uninitialized state). Confirms `5fc91a61`.

## Minor observations (not blockers)

- Rust File▸New labels the new tab `Untitled-1` again (duplicate) rather than
  advancing to `Untitled-2`, when the session already restored an `Untitled-1`.
  The untitled counter is not advanced past the restored document's name. Cosmetic;
  the document itself is created correctly (fresh empty artboard, made active).
