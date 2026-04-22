# Codebase Review Plan

Output of the 2026-04-22 codebase review, organized by priority and scope.

## Landed 2026-04-22

1. **Flask genericity Violation 1** — `_PANEL_LABELS` deleted, `_panel_label()` reads YAML `summary:` from loaded panel specs. 268 tests pass.
2. **Rust Tier 1** — 11 `pub const LABEL` deleted across `src/panels/*_panel.rs`, `panels/mod.rs panel_label()` reads YAML. Properties panel now correctly shows "Object properties" (was hardcoded "Properties"). 137 panel tests pass.
3. **Swift Tier 1** — 11 `static let label` deleted across `Sources/Panels/*Panel.swift`, duplicate `WorkspaceLayout.panelLabel()` removed (15 lines of dead code). 1351 tests pass.
4. **5 memories saved**: Swift ownership-review caveat, OCaml `.mli` backlog, arc extrema cross-language gap, Flask genericity leaks, panel menu YAML migration backlog.
5. **2 CLAUDE.md rules added**: OCaml `.mli` on new/edited files; Rust per-item `#[allow(dead_code)]` preferred over module-wide.

## Tier 1 — ship soon, each is <1 session

Ordered by value × inverse effort.

| # | Item | App | Effort | Dep |
|---|------|-----|--------|-----|
| 1 | Delete `saved_document` field in `model.rs` (4 lines, verified dead — 3 unnecessary clones on every construction + save) | Rust | 10 min | — |
| 2 | Verify `python.sh` launches; if broken, add 4-line sys.path setup to `jas_app.py`, delete hacks in `yaml_menu.py` + `yaml_menu_test.py` | Python | 30 min | — |
| 3 | Fix 3 unsafe UI sites: OCaml `type_on_path_tool.ml:498`, `type_tool.ml:475`, `canvas_subwindow.ml:961` (replace `assert false` with no-op + log); Python `jas_app.py:261` (narrow catch or propagate YAML load errors); Rust `svg.rs:861` (guard `rotate_vals.last()` unwrap) | Multi | 1h | — |
| 4 | Add `encoding='utf-8'` to Flask `app.py:41` | Flask | 1 line | — |
| 5 | Add `ARTWORK_SIZE` constant in Python `toolbar.py` (replaces 15+ magic `28`s separate from `ICON_SIZE`) | Python | 30 min | — |

## Tier 2 — one session each

| # | Item | App | Effort |
|---|------|-----|--------|
| 6 | **Dev-mode expr-eval logging** — warn when a non-empty expression yields `Null` / `None` in each of the 4 interpreters. Surfaces silent YAML-binding errors; resolves 130+ downstream bare-catch sites as a side effect (collapses items #5 + #12 from the original review) | All 4 native | ~1h/app |
| 7 | **OCaml Layers state extraction** — move 10 module-level refs from `yaml_panel_view.ml` to existing `layers_panel_state.ml`; pair with adding `.mli` for `yaml_panel_view.ml` (existing backlog) | OCaml | 2h |
| 8 | **Rust `render_tree_view` split** — 1,272-line function → 4 sibling functions (`render_tree_node`, `render_layers_filter`, `render_layers_drag_overlay`, `render_rename_overlay`) | Rust | ½ day |
| 9 | **Swift `YamlPanelBodyView` split** — extract `LayersPanelBody`, `CharacterPanelBody`, `ParagraphPanelBody` as separate `View` structs; each owns its own `@State` (fewer re-renders) | Swift | ½ day |
| 10 | **Flask Violation 3: `JAS_` → `APP_` JavaScript globals** (templates + `app.js`, ~45 sites). Mechanical find-replace | Flask | 30 min |

## Tier 3 — multi-session projects

| # | Item | Scope | Effort |
|---|------|-------|--------|
| 11 | **Panel menus migration from native → YAML** — every panel YAML has a `menu:` key but all 4 native apps re-declare, losing `enabled_when` + dynamic labels + descriptions. Each app gets a YAML → `PanelMenuItem` converter; delete per-panel `menu_items()` functions. Propagation order per CLAUDE.md: Rust → Swift → OCaml → Python | All 4 native | 1 day × 4 |
| 12 | **YAML renderer snapshot tests** — `workspace/tests/render_snapshots/` with panel-state fixtures; each app serializes its render tree to canonical JSON; cross-language test asserts identical output. Catches every future Flask→native divergence | All 5 | 1-2 day setup, ongoing |
| 13 | **Flask Violation 2: `swatch_libraries` reach-in** — `renderer.py:1200-1215` hardcodes the name + path-guesses workspace dir. Needs a schema decision on top-level workspace data exposure (e.g., `workspace/app.yaml: expose_as_data: [swatch_libraries, …]`) | Flask | 1 day w/ schema design |

## Opportunistic — do when touching the file anyway

- `.mli` for OCaml `yaml_panel_view.ml` (pair with #7)
- Narrow `except Exception:` to specific types when editing Python panel files
- **Flask Violation 4**: `recent_colors` special-case in `app.js:365-366` (pair with Color panel work)

## Explicitly not doing

- **Rust `#![allow(dead_code)]` sweep** — rule added for new code, incremental only
- **Flask CSS class name extraction** (`btn-sm`, `form-control`) — would hurt readability
- **Flask `_get_ws` workspace walk optimization** — 0.73ms, dev-only
- **Mass audit of 130+ bare `except:` / `with _ ->` sites** — collapses into #6
- **Backup files housekeeping** — already gitignored, not a repo issue
- **Arc extrema fix** — saved as project memory, fix when a bounds/alignment bug report involves arcs
- **`panelDispatch()` → YAML migration** — dispatchers are the legitimate native/platform bridge; leave alone

## Natural pairings

- **#7 + `.mli` backlog** — touch `yaml_panel_view.ml` once, do both
- **#6 + Flask log path** — both touch the expression-layer error surface
- **#12 snapshot tests + #11 menu migration** — snapshots catch any divergence during menu moves, de-risks Tier 3 work

## Suggested ordering

1. **Session 1**: #1, #2, #4, #5 (trivial wins, ~1.5h total)
2. **Session 2**: #3 (unsafe UI sites, ~1h)
3. **Session 3**: #6 in one app (prove the pattern)
4. **Session 4**: propagate #6 to the other 3 apps
5. **Sessions 5+**: Tier 2 individually; Tier 3 as standalone projects

## Genericity rule scorecard (updated post-Tier-1)

| App    | Panel bodies | Panel menus          | Panel labels          |
|--------|--------------|----------------------|-----------------------|
| Flask  | ✅ YAML      | ✅ YAML              | ✅ fixed              |
| Rust   | ✅ YAML      | ❌ native (Tier 3 #11) | ✅ fixed              |
| Swift  | ✅ YAML      | ❌ native (Tier 3 #11) | ✅ fixed              |
| OCaml  | ✅ YAML      | ❌ native (Tier 3 #11) | ✅ YAML               |
| Python | ✅ YAML      | ❌ native (Tier 3 #11) | ✅ YAML               |
