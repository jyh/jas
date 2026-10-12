# Level-3 tests: what only a person can judge

**Status:** DRAFT, 2026-10-12. `docs/TESTING.md` defines the three levels; this page is the list of level-3 tests,
sorted by priority. A naming note, as everywhere: this is a **vector illustration application**.

The owner's rule for this list is that a level-3 test *"must be level 3, there are no other options."* So every
entry below states three things:

* **What a person judges.** The question, in words a tester can act on.
* **Why no machine can.** The specific level-2 observable that is missing. "It is hard to automate" is not a reason.
  An entry is admitted only when no state read-back, widget-tree read, screenshot or measurement can decide it.
* **What the verdict becomes.** Most level-3 verdicts should be needed **once**. A person's answer is turned into a
  level-2 asset (an approved baseline, a stated threshold, a spec sentence), and from then on a machine checks it.
  An entry whose verdict cannot become such an asset recurs, and says so.

**Everything that is not on this list belongs at level 1 or 2.** A defect a person finds while running a level-3
test is a missing level-2 check (`TESTING.md` §1), and it is filed as one.

There is nothing missing from this list by accident. An item that is absent was judged decidable by a machine; if
that judgement is wrong, the remedy is to add the item here with its reason, not to widen an existing entry.

---

## The list

| # | priority | what a person judges | why no machine can | what the verdict becomes |
|---|---|---|---|---|
| L3-1 | **1** | **Every pixel baseline is RIGHT the first time it is frozen.** For each panel, dialog, icon and canvas item the census counts under `pixels` (206 today), a person looks at the first frozen screenshot and confirms it shows what the spec describes. | A frozen baseline can only say that a later screenshot is the SAME as an earlier one (`TESTING.md` §2). Nothing can say that the first one was correct: the spec is prose, and a screenshot of a wrong rendering is just as stable as one of a right rendering. | The approved baseline. After that, a machine compares every later screenshot against it, and the baseline changes only with the spec (`check_baseline_spec_change.py`). Needed once per baseline, and again only when the spec item changes. |
| L3-2 | **1** | **The native file dialogs work:** Open and Save As, the two the spec names (`open_file`, `save_as`). Each opens, shows the right file types, proposes a sensible name and folder, and Cancel leaves the document unchanged. | These are the operating system's windows, not the application's (the census bins `open_file` and `save_as` as NOT_INSTRUMENTABLE). They are outside the widget tree, and their contents depend on the tester's own disk. | A short checklist run per platform release. The application's side of each dialog (the request it makes, and what it does with the answer) is level 2 and is checked there. Recurs per OS release, because the OS owns the dialog. |
| L3-3 | **2** | **Direct manipulation feels immediate.** Dragging, moving, resizing, rotating and drawing track the hand, without perceptible lag, jitter or a jump at the start of a drag. | Frame times and input-to-paint latency can be measured, but "immediate" is a perceptual threshold that nothing in the spec states. Until a person sets it, there is no number to compare against. | A latency and frame-time budget per gesture, written into the spec. After that, a level-2 run measures against the budget. Needed once, and again only if the budget is challenged. |
| L3-4 | **2** | **Text entry through a real input method** (Chinese, Japanese and Korean composition, dead keys and accented letters) composes, commits and cancels correctly in the type tools and in every text field. | An input method is an operating-system service with its own composition window. Synthetic key events reach the application without passing through it, so a machine drives a path a real tester never takes. | Each composition defect found becomes a level-2 case at the application's text-input seam. The pass itself recurs per OS release, because the OS owns the input method. |
| L3-5 | **3** | **A pressure-sensitive pen feels natural.** On a real tablet, the brush tools' pressure variation (the brush options' variation widget) responds smoothly across the pen's range, with no dead zone and no sudden step. | Synthetic pointer events can carry any pressure value, and the response to a given value is level 2. Whether the response CURVE feels natural under a physical pen is perceptual, and nothing in the spec states the curve. | A stated response curve in the spec, after which the mapping is level 2. Needed once per curve. |
| L3-6 | **3** | **Trackpad gestures feel natural:** two-finger pan and pinch zoom, including momentum and where a zoom anchors. | The view the gesture produces can be read back (level 2). The momentum and smoothness of the motion are perceptual, and they depend on the OS's own gesture recogniser. | A statement of the intended behaviour (momentum on or off, the zoom anchor), after which the resulting view is level 2. Needed once per platform. |
| L3-7 | **3** | **Colour looks right on a colour-managed display:** swatches, gradients and the colour panel's models match what the numbers say, and RGB-to-CMYK previews are plausible. | Every colour value is a number and is checked at level 1. Whether the DISPLAYED colour matches depends on the display and its profile, which no screenshot of the frame buffer can see. | A per-platform statement of the colour-management path. Recurs only when that path changes. |
| L3-8 | **4** | **The application is usable with a screen reader** (VoiceOver on macOS, Narrator on Windows): a person can reach and operate the tools, panels and dialogs, and what is spoken makes sense in order. | That every widget has an accessible name and role is level 2, since the accessibility tree can be read. Whether the spoken sequence is USABLE is a judgement about a listening experience. | Each defect becomes a level-2 check on the accessibility tree (a missing name, a wrong order). Recurs when the panel set changes materially. |
| L3-9 | **4** | **Snap distances feel right:** a pane dragged near another pane's edge docks neither too eagerly nor too reluctantly (`theme.sizes.snap_distance`, 6 pixels), and, once smart guides are built, the canvas snap threshold (`preferences.smart_guides.snap_threshold_px`, 8 pixels) is neither sticky nor useless. | Snapping at a given distance is level 2. The right DISTANCE is a perceptual choice, and both numbers were chosen, not derived. (No tool reads the smart-guide threshold yet, so its half of this entry waits on that feature.) | Confirmed distances in the spec. Needed once each. |
| L3-10 | **5** | **A window moved between displays with different scale factors stays crisp:** canvas, icons and text re-render at the new density with no blur and no size jump. | The test needs two physical displays with different scale factors, a configuration that no CI runner has. A screenshot on one display cannot show the transition. | A per-platform pass when the windowing layer changes. Recurs with it. |

## How the list is kept

* **Priority** is ordered by how many people meet the item and how often, then by how much the verdict unlocks
  afterwards. L3-1 comes first because one verdict per baseline turns 206 uncovered pixel items into level-2
  checks. L3-2 comes next because every user meets a file dialog.
* **An entry leaves the list** when its verdict has become a level-2 asset and nothing about it recurs. Entries
  L3-3, L3-5, L3-6 and L3-9 are expected to leave after one pass.
* **An entry joins the list** only with all three columns filled. A judgement with no "why no machine can" column is
  a level-2 test that has not been built yet.
