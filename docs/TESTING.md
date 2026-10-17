# Testing: the three levels

**Status:** DRAFT, 2026-10-10. It records the three-level testing process the owner ruled on 2026-10-10, together with
the mechanism that exists today and the coverage it reaches. `TESTING_STRATEGY.md` remains the doctrine for what is
verified at which layer; this page is the PROCESS: which level a test belongs to, what decides it, and what a run
must certify.

A naming note, as everywhere: this is a **vector illustration application**.

---

## 1. The three levels

| level | what | cost | when |
|---|---|---|---|
| **1** | unit tests | cheap | any time |
| **2** | automated UI testing of **LOOK** and **FUNCTION**: input is driven by a machine, and results are examined by machine | expensive | on a new UI element, or on a regression |
| **3** | human testing of **FEEL** | the most expensive | ideally once |

**Two hard constraints, the owner's words:**
* **"~100% yaml test coverage."** Every item of the YAML spec has a check, or a stated reason why it has none (§4).
* **A level-3 test "must be level 3, there are no other options."** A thing goes to a human only when no level-2
  observable can decide it.

**The level-3 tests are listed, sorted by priority, in `docs/LEVEL3_TESTS.md`**, each with the reason no machine can
decide it and the level-2 asset its verdict becomes.

**Every human finding becomes a level-2 item.** A defect a person finds at level 3 is a missing level-2 check. A
missing selection highlight, for example, is a level-1 or level-2 catch.

## 2. What decides each kind of claim at level 2

| claim | deciding observable | form of the check |
|---|---|---|
| **FUNCTION** | the core's **STATE** | the same input script gives the same document, byte for byte (canonical test JSON) |
| **LOOK, structure** | the **WIDGET TREE** | the same spec gives the same tree of widgets: kinds, ids, visibility |
| **LOOK, pixels** | a **SCREENSHOT** | compared against a **FROZEN baseline**, within a stated tolerance |

**A baseline changes only with the spec, never on its own.** A PR that changes a pixel baseline must also change the
spec item that baseline renders, and a tool must enforce this: `scripts/check_baseline_spec_change.py`, run in CI on
every PR's own delta. A baseline is any file under an `e2e_baselines/<item>/` directory; its item maps to the spec
through the input script naming that item (§6). A baseline that changes with no change to that spec passes only when
a commit in the PR declares why, on its own line: `Baseline-Refreeze: <item>: <reason>`. A spec is not the only honest
cause: `selection.drag` was re-frozen once because the app had been wrong, and once because the box's desktop moved
the window. The declaration makes that a named act a reviewer reads, never a silent one.

**Windows parity is DIFFERENTIAL against the Mac**, fully automated at levels 1 and 2: the same input script must give
the same core state, the same widget tree, and a screenshot within tolerance of the Mac's render.
⚠️ This supersedes, for the Windows-parity comparison only, the "never as cross-app pixels" clause of
`TESTING_STRATEGY.md` §1. That clause still governs every other pair of apps.

## 3. The certificate

Every level-2 run emits a machine-written **certificate**:
* its key is **spec hash × build sha × platform**;
* for each spec item it records the deciding observable and its receipt;
* every uncovered item is **declared**, never omitted.

The first certificate is the YAML coverage census (§4). It is platform-independent because it reads corpora, not a
live app.

## 4. YAML coverage: `scripts/yaml_coverage_census.py`

For every item of the classes it censuses, the census reports the deciding observable and the check that decides it.
An uncovered item goes into exactly one of three bins:

* **NOT_INSTRUMENTABLE:** a level-3 candidate, with the reason stated.
* **NOT_YET_BUILT:** the check is work that has not been done.
* **UNDERSPECIFIED:** the spec does not state the behaviour in a form a check could take its expectation from. For
  example, an action whose only effect is `log`. The statement must change before a check can exist.

The bins come from rules in the tool, never from a hand list.

Spec classes not yet censused are declared with their counts, and a spec class in neither list refuses the run. CI
runs the census's self-test and a full run in the `workspace-json-fresh` job.

**The reading on 2026-10-10** (spec sha256/16 `93c08c304810d2a0`, build `24fd5ca2`, with the counting rules of #321): **184 of 753 censused
item-observables are covered.**

| observable | covered |
|---|---|
| state | 113 of 441 |
| tree | 71 of 106 |
| pixels | 0 of 206 |

The bins:

| bin | count | what is in it |
|---|---|---|
| NOT_INSTRUMENTABLE | 2 | native file dialogs |
| UNDERSPECIFIED | 48 | log-only actions |
| NOT_YET_BUILT | 519 | everything else that is uncovered |

⚠️ **The census's limits print beside its numbers, and they are part of the reading:**
* "Covered" means a committed corpus or golden names the item and an active port consumes it. It does **not** mean a
  live window was driven.
* Tree coverage is the shared interpreter's **plan**, not the rendered widgets.
* Widgets are counted at their panel's or dialog's granularity.
* A golden counts only when a port runs it. One that only a script compares with the bundle does not count, and
  neither does one a port emits from a typed literal. The state-defaults golden is the second kind, so the census
  counts no state variable as covered.

## 5. The mechanism today, and what level 2 still needs

What exists:
* **FUNCTION:** corpora at named seams in each port's core, compared across Rust, Swift and the Python reference
  (`CROSS_LANGUAGE_TESTING.md`). The seams are `CanvasTool` gestures, `dispatch_action`, key resolution, `op_apply` and
  widget events. These run **below the app**: no corpus drives a live window.
* **Into the live Mac app:**
  * `--mcp-socket` reads the document (`jas://document`) and previews ops. It has no input verb.
  * `--test-fifo` selects tools and dispatches actions, one-way, with no reply.
  * `jas_gui_harness.py` injects OS events (Quartz `CGEventPost`).
  * `screencapture -l <window>` captures a window. It needs an unlocked, awake console.
* **LOOK-structure:** the shared panel layout and widget-tree passes (`panel_layout`, `widget_tree`), byte-gated across
  the reference, Rust and Swift for all 16 panels and all 33 dialogs. The Mac app attaches an
  accessibility identifier to every rendered widget (`YamlPanelBodyView`), but nothing reads them yet.
* **LOOK-pixels:** one baseline exists, `selection.drag` on Windows (`prototypes/sb_winui/e2e_baselines/`): an EXACT
  hash of the back buffer, pinned to the box that froze it, run by hand there and never in CI. The canvas is
  otherwise compared as a display list (`TESTING_STRATEGY.md` §2), not as pixels.
* **CI:** levels 1 and the below-the-app half of 2, on macOS, Linux and Windows. No CI job launches an app or compares
  a screenshot.

What level 2 needs, in the order the census prices it:
1. An input script driven through the **live** app, with the document read back. On Windows it runs:
   `prove_e2e.ps1 -Script` replays `selection.drag` and reads it back byte for byte. On the Mac the read-back exists
   (`jas://document`); a channel for the input does not.
2. A reader of the **rendered** widget tree: accessibility identifiers on macOS, UI Automation on Windows. (Dialogs
   are in the widget-tree pass.)
3. **Pixel baselines** for panels, dialogs and icons. The tool that refuses a baseline change with no spec change
   exists (§2); beyond `selection.drag`'s, the baselines do not.
4. Corpus cases for the uncovered actions, tools and state (the NOT_YET_BUILT bin), and a restatement of the
   UNDERSPECIFIED bin.

## 6. The input script: the one artifact both platforms share

**Ruled 2026-10-10 by the port owner, on the Windows shell author's proposal.** Parity is differential, so "the same
input" must be one artifact, not two people's readings of a spec item.

A script is a JSON file in `test_fixtures/input_scripts/`, one per spec item. **It extends the gesture corpus's case shape**
(`test_fixtures/gestures/*.json`), so the same script replays at level 1 in each port's core and at level 2 through
each live app:

```json
{
  "item": "selection.drag",
  "spec": "workspace/tools/selection.yaml",
  "setup_svg": "complex_document.svg",
  "tool": "selection",
  "app_state": {},
  "steps": [
    {"kind": "press",   "x": 36, "y": 36},
    {"kind": "move",    "x": 72, "y": 60, "dragging": true},
    {"kind": "release", "x": 72, "y": 60},
    {"key": "Z", "ctrl": true},
    {"panel": "align_panel_content", "widget": "align_left_button", "event": "click"},
    {"panel": "magic_wand_panel_content", "widget": "fill_tolerance", "event": "commit", "value": "40"},
    {"read": "document"}
  ]
}
```

* **Pointer steps** are the gesture corpus's events, unchanged: `kind`, document coordinates `x`/`y`, `dragging`, and
  the named modifiers `shift`/`alt`/`ctrl`/`meta`, each `false` when absent. A driver converts document units to device
  pixels **itself**, and delivers whatever its injector quantises to. **The read-back is compared, never the input.**
  ⚠️ So a script's coordinates are **even document units**, which convert to whole device pixels at 1×, 1.5× and 2×.
  An odd or fractional unit lands a fraction off at 1.5×: a drag asked as (37, 23) was delivered as (36.67, 22.67),
  and an exact comparison then fails for a reason that is not the app's.
* **Key steps** use the key corpus's chord form (`test_fixtures/keys/`): `key` is the canonical token.
  A key takes the engine's key order, `route_key` (Rust) and `routeKey` (Swift): an unclaimed Delete or Backspace
  deletes the selection; Escape, Enter and a claimed Delete go to the active tool; a command chord acts only for undo
  and redo; an unmodified tool letter selects that tool. `jas_key_event` and both level-1 runners call it, so a
  script replays a key the way the app takes it. `meta` is refused: the engine's key route takes none.
* **Panel steps** name a panel content id and a widget id, which are the ids the widget-tree pass emits, the Mac app
  exposes as accessibility identifiers, and WinUI exposes as `AutomationId`. `event` is `click` or `commit`, with
  `value` the text a person entered (the widget-event corpus's form).
* **Menu steps** name a menubar item by its id: `{"menu": "menu_group"}`, the id `workspace/menubar.yaml` gives the
  item and `jas_menu_state` reports. Like a key step, a menu step comes after the pointer steps. The first menu script
  is `object.group`.
* **`read` steps** say what is compared at that point:
  * `document` is the canonical test JSON (`document_to_test_json`), the cross-language form, never a port's own
    serialisation;
  * `tree` is the rendered widget tree;
  * `pixels` is a window-only capture.

  A script without a `read` step asserts nothing and is refused.

**Who replays it:**
1. **Level 1:** each port's core. This is the EXPECTED read-back.
   * **Rust** has two runners. The gesture runner (`script_corpus`, web build) replays the pointer and key scripts
     it lists. The engine replay (`ffi_script_replay`, FFI build) replays every step through the calls a native shell
     makes: `jas_set_tool`, `jas_pointer_event`, `jas_dispatch_action` for a key or a menu item, and
     `jas_panel_behavior` for a panel step. It sets aside the open's one artboard exactly as the Windows oracle does, and it derives its scripts
     from the directory. A panel script's Rust read-back comes from the engine replay, because the panel behaviour
     is engine-only and no build has both.
   * **Swift** replays pointer and key steps through the gesture runner, then panel and menu steps on the model the
     gesture leaves: a panel step through the app's widget route (`PanelWidgetEvents`: `click`, `press`, `commit`),
     a menu step through the live menu's table (`MenuActions.run`, Rust's `menu_native::run`). A pointer or key step
     after a panel or menu step is refused by name, and so is a menu item whose action is not in that table.
2. **Level 2 on the Mac:** `jas_gui_harness.py` for pointer and key steps; a panel step by accessibility identifier.
3. **Level 2 on Windows:** `send_hand.ps1` replays pointer steps (shift held from the press or the first move), then
   key steps, which it delivers after the release as real key events (`keybd_event`), so the shell's own key route
   runs. Panel steps come last, by UI Automation. The hand first opens the script's panel as a person does, choosing
   it in the pane's selector (`PanePicker`, whose items carry the panel content ids) unless it is already shown. The
   widget is found by `AutomationId` = widget id, inside the panel's `AutomationId` = panel content id, and a click
   goes through its Invoke, Toggle or SelectionItem pattern, a commit through its Value pattern and then Enter, and a
   select's commit by choosing the item whose `AutomationId` is the option's value. Menu steps ride with the panel
   steps, in script order: the hand opens each top menu of the menubar in turn until one shows the item whose
   `AutomationId` is the step's node id, and Invokes it. A key step inside the gesture, `meta`, a key or pointer step
   after a panel or menu step, a panel step whose widget is not found, is found twice, is disabled, or has no pattern
   for its event, and a menu item no menu holds, found twice, or disabled are refused by name. The first panel script
   is `align.left`, the first menu script `object.group`.

A level-2 run passes when its `read`-back equals the level-1 read-back for that step. Windows parity is the same
comparison, with the Mac's live read-back as the other side.

**What is not ruled here:** the pixel tolerance. It comes with the first pixel baselines. (The tool that refuses a
baseline change with no spec change is built; §2.)
