# S-C.2 — THE SYNC PROTOCOL, AND C2 MEASURED AGAINST ITS GATE

**Windows/kenai, 2026-08-25.** The write path exists; C2 is measured at two
document sizes; C3 was probed on the surface that exists and is **stopped —
needs construction**. Written against the S-C sequencing ruling as amended
through Amendment 10, which is held in the project's private working record and
is not reproduced here.

⚖️ **WHAT THIS REPORT LICENSES: one thing — continuing S-C.2 on the materializer
route.** Not a ratification of the native-materialized arm, not a discharge of
the fork, not evidence for paper v2. The gate is a **regression gate**, and a
pass says only that the protocol did not regress past the trivial alternative.

📌 **EVERY WIDGET COUNT IN THIS REPORT IS A TREE-RECORD COUNT WITH ITS
MATERIALIZATION SPLIT STATED.** "156 widgets" is never written; "156 tree
records — 108 typed controls, 48 labelled placeholders" is. The three hard
widgets (hue bar, gradient/swatch grid, fill-stroke composite) are a separate,
**unfunded** stage, so a materialized panel here is partial by design and the
denominator has to travel with the number.

---

## 1. C2 — one colour-drag tick

**A TICK, pinned:** *one pointer-move during a colour drag that CHANGES THE
ACTIVE COLOUR, from the shell receiving the input to every dependent control
showing the new value.* Not a click, not a commit (C3), not a panel open (C1).

**Measured on hardware, in session 1, by the Rust-side boundary counter.** The
receipt is `sc-c2.json`, written by the run itself. A static count of the
P/Invoke sites in this project would read identically on a run that never
happened.

| | small arm | large arm |
|---|---:|---:|
| **document** | **8 artboards** | **200 artboards** |
| tree records | **156** | **1,116** |
|  — colour panel | 106 (71 typed, 35 placeholder) | 106 (71 typed, 35 placeholder) |
|  — artboards panel | 50 (37 typed, 13 placeholder) | 1,010 (805 typed, 205 placeholder) |
|  — typed / placeholder, both panels | **108 / 48** | **876 / 240** |
| **crossings / tick** | **2** | **2** |
| **bytes / tick** | **2,586** (67 in, 2,519 out) | **2,586** (67 in, 2,519 out) |
| engine rows re-evaluated | **135** | **1,287** |
| panels re-evaluated | 2 | 2 |
| rows in the reply | 22 | 22 |
| `vacuous` flag | **false** | **false** |

**Growth across the two arms:** tree records **×7.15** · crossings **+0** ·
bytes **×1.000** · engine rows **×9.53**.

📌 *The receipt reports the typed/placeholder split for the two panels TOGETHER
(108/48 and 876/240); the per-panel rows above are those minus the colour
panel's own 71/35, which C1 measured directly. Derived by subtraction from
measured figures, and said so rather than presented as separately measured.*

### The two document sizes were pinned before anything was measured

**8 and 200 TOTAL artboards.** They were fixed in the pre-design premise flags,
by the party being measured, *before* a number existed — the same free parameter
that the gate's own second-panel clause had to close one level up. A 20.2×
spread in the panel's records is what makes the flatness claim falsifiable: no
O(n) tick stays flat across it.

⚠️ **TOTAL, not created.** A fresh document already holds one artboard
(`ensure_artboards_invariant`: every document has at least one), so the harness
creates `n − 1` and **asserts the resulting count** rather than trusting the
arithmetic. Creating `n` would have made "8 and 200" quietly describe 9 and 201.

⭐ **And the document grew through the ratified channel.** `create_artboard` is a
live id-minting `op_apply` verb, so both arms were reached by
`jas_dispatch_event` and **the panel grew because the document grew.** The second
arm is not synthetic.

---

## 2. The gate, clause by clause

| # | gate | reading | |
|---|---|---|---|
| ① | crossings/tick ≤ 8 | **2** | PASS |
| ② | no growth with widget count, two sizes, growth ≤ 1 | **+0** across ×7.15 records | PASS |
| ③ | bytes/tick ≤ 7,038 | **2,586** at both arms | PASS |
| ④ | vacuity: crossings > 0 AND a value demonstrably changed | 2 crossings, 22 rows moved, `vacuous=false` | PASS |
| ⑤ | engine-side cost reported beside the crossings | **135 → 1,287 rows, ×9.53** | §4 |

⛔ **THE PASS ON ③ IS REPORTED AS THIS AND NOTHING MORE: NO WORSE THAN RE-READING
EVERYTHING.** The trivial whole-panel re-read costs **7,042 bytes** measured in
the same session on the same panel at the same colour (§5 explains why it is not
7,038). 2,586 is **36.7 %** of it. That is the entire content of the ③ result: a
delta protocol that came in under the naive one. It is not validation of the
delta design.

📌 **BYTES-GROWTH RATIO, REPORTED AND UNGATED: ×1.000.** No threshold, because
there is no basis for a constant. ② is a shape test on *crossings*; ③ is a
magnitude test on *bytes*; nothing is a shape test on bytes, and the two axes
move independently. Whoever sets that threshold later now has two points.

### ② had to be given a guard that its variable varied

**The two arms differ in tree records by construction, and the harness asserts
it.** `large.widgets > small.widgets` is a RED condition, not a comment. This
clause exists because the originally-ruled second panel would have satisfied ②
with the widget count held constant — growth 0 because *nothing varied* — and the
vacuity clause could not have caught it: crossings were > 0 and a value did
change. **What would not have happened is that the arms were ever different.**

---

## 3. The protocol — three decisions, and the gate sees the consequence of each

### 3a. The reply carries the delta — so a tick is 2 crossings, not 3

`jas_panel_event` takes the event and **returns the changed rows**. One crossing
out, one `jas_free` back. A dispatch-then-fetch protocol is three, because a
fetch is two crossings under Rust-owns-it (BL4).

⚠️ **This is below the gate's derived floor of 3, and that is not cleverness.**
The floor assumed dispatch and fetch were separate calls; folding them removes
the extra fetch *and its free*. Under this ABI the free is half the cost of every
fetch, so the cheapest protocol is the one that **fetches least** — which is
exactly what C1's one durable finding said any future protocol would be priced
in.

### 3b. Only rows that CHANGED are sent

22 rows of the colour panel's 82, 2,519 bytes out against the 7,042 a whole-panel
re-read costs.

### 3c. ⭐ EVERY OPEN PANEL IS RE-RESOLVED, NOT ONLY THE EDITED ONE

**Refreshing only the edited panel is cheaper and is wrong in the general case.**
A colour change with a selection moves what *other* panels display; a protocol
keyed on panel identity rather than on dependency goes stale the first time that
happens.

So the engine re-resolves every enrolled panel and returns the union of what
moved. The consequence is the ⑤ row: **crossings and bytes stay flat while
`rows_evaluated` grows ×9.53 with the document.** The correctness is paid for on
the engine side, where the boundary cannot see it.

### The event names a WIDGET, never a channel

    {"widget":"cp_h","key":"bind.value","value":210}

The engine reads that widget's `bind.value` out of the panel spec — `"panel.h"` —
and applies it. **Nothing about colour crosses from the shell**: no channel name,
no conversion, no mode. A shell sending `{"h":210}` would be naming the engine's
model; one sending a hex would be doing the arithmetic. That is the property that
makes this a materializer and not a third interpreter.

Enrolment is a side effect of `jas_bind_values`: reading a panel's values is what
tells the engine the shell holds it. An explicit `jas_panel_open` would have
spent a boundary function to say something the engine can already see.

---

## 4. Engine-side cost — gate ⑤, and what the gate cannot see

**135 → 1,287 bind rows re-evaluated per tick, ×9.53 against ×7.15 the records.**
Reported because a protocol can be cheap at the boundary *precisely by* being
expensive behind it, and a crossing count would call that a win.

⚖️ **AND THE HONEST CAVEAT ON READING IT: this number is not yet attributable to
materializing.** Painter-drawn chrome must also re-resolve panel state in order
to redraw. Whether ×9.53 is a cost *of the materializer* or a cost *of having
panels at all* is not answerable from inside this arm — the painter-drawn arm is
deliberately unbuilt — and it is docketed rather than claimed.

### Engine-side lines, per §3.1 (raw `wc -l`, per file, population in words)

**Population — the Rust engine work S-C.2 added, against the S-C.1 branch head:**

| lines | file | what |
|---:|---|---|
| 718 | `src/panel_scope.rs` (new) | the panel slice, the scope, the write, the registry — **374 production, 344 tests** |
| +223 / −86 | `src/ffi.rs` | `jas_panel_event`, registry wiring, the NULL-ctx rule |
| +161 | `src/interpreter/color_util.rs` | `color_from_panel_edit` + its tests |
| +95 | `src/ffi_instr.rs` | the tenth crossing, the engine counters |
| +48 / −34 | `src/interpreter/renderer.rs` | the extraction's adapter (a **net reduction** in that file) |
| +5 | `src/lib.rs` | module wiring |
| +29 | `Cargo.toml` | three test targets |
| +73 | `include/jas_ffi.h` | regenerated, cbindgen 0.29.4 |

**Population — the Rust tests, counted separately because a test line and an
engine line are not the same animal:** `tests/sc2_second_panel_growth.rs` 370,
`tests/sc2_tick_protocol.rs` 458, `tests/sc3_commit_probe.rs` 243, plus 9 lines
of edits to `tests/ffi_boundary_counter.rs`.

**Population — the C# / XAML shell, whole files whose sole purpose is this
panel**, at HEAD rather than as a diff, so it is comparable to C1's 520:

| lines | file |
|---:|---|
| 133 | `JasCore.cs` |
| 385 | `Materializer.cs` |
| 354 | `MainWindow.xaml.cs` |
| 16 | `App.xaml.cs` |
| **888** | **C# total** |
| 13 | `App.xaml` |
| 23 | `MainWindow.xaml` |
| **36** | **XAML total** |

**924 C# + XAML**, against C1's 520. Project and harness files listed but
excluded, since the painter-drawn reference has no counterpart to them:
`ScPanel.csproj` 42, `run_c2.ps1` 80.

⛔ **924 IS STILL NOT COMPARABLE TO THE 1,298 PAINTER-DRAWN REFERENCE, and the
gap has WIDENED rather than narrowed.** That reference is a *complete* colour
panel; this materializes 71 of 106 widgets and now also a second panel, and it
buys a tick protocol the reference number does not price at all. Two figures with
different populations do not become comparable by being adjacent.

---

## 5. ⛔ FINDING — gate ③'s ceiling is not a constant of the panel

Amendment 8 states the trivial whole-panel re-read passes ③ *by construction*,
"exactly 7,038 bytes because ③ was derived from that number."

**Measured: 7,038 is the payload at the C1 seed colour (`664040`). Sweep the hue
and the same trivial re-read reaches 7,044** — the resolved values are decimal
strings and their digit counts move with the colour.

⇒ **The naive implementation the ceiling was defined to bound breaches its own
ceiling.** By 6 bytes, so it is not the O(n) regression ③ was built to catch —
but **a pass or a breach within a few bytes of 7,038 says nothing**, and no
report should treat the threshold as sharp. Nothing in §1 turns on the slack:
2,586 is 36.7 % of it.

**Reported, not patched.** Re-deriving the constant to a worst case would be
setting a threshold from the thing being gated. The gate has since been amended
to a within-session comparison against the trivial re-read, which is why §2
quotes 7,042 — measured in the same run, on the same panel, at the same colour —
rather than the frozen 7,038.

---

## 6. Two defects found by measuring, both in the read half C1 shipped

### 6a. A NULL `ctx` to `jas_widget_tree` meant an EMPTY scope

Growing the engine-assembled scope with an `active_document` namespace fixed the
**values** half. The **structure** half had the identical hole: a data-driven
panel reported its *static* size at every document size.

**It was found only because both arms came back at 156 records.** Gate ②'s second
arm would have been identical to its first for the second time and by a second
mechanism.

**NULL now means "engine, assemble it"; `"{}"` still means an explicit empty
scope.** The cross-language round-trip is untouched: every corpus fixture passes
an explicit `"{}"`, and **none passes NULL**.

### 6b. `panel.*` did not follow `fill_on_top`

C1's scope derived the eleven channels from the **fill**, unconditionally.
`color.yaml`'s own `init` block says every channel is
`hsb_h(if state.fill_on_top then state.fill_color else state.stroke_color)`, and
the web port resolves it the same way. **With the stroke active, the sliders
would have shown the fill's channels.** Never caught, because `fill_on_top` was
true for the whole of C1.

### The shared write half, and why it moved rather than being rewritten

Turning "the H slider now reads 210" into a colour is a rule that already existed
— and was `feature = "web"`-gated, so the native shell could not reach it.
Writing a second one is the shape of the parity bug this project has already paid
for (`664040` vs `664141` on the same drag), with both implementations inside ONE
port instead of across two. The arithmetic moved to
`color_util::color_from_panel_edit`, beside the read half it inverts; the web
renderer keeps a three-line adapter and got **34 lines shorter**.

⚠️ **This DID touch an active-port file**, which the sequencing ruling had
previously listed as a benefit of *not* moving a different function. It is a
departure and is flagged as one. The body was extracted verbatim, and the full
default-feature suite passes: **2,954 tests plus 35 cross-language**.

---

## 7. C3 — probed, and STOPPED: it needs construction

**C3 is *commit a colour*:** set the active attribute's colour **and** push it to
the front of `recent_colors`. It is what a swatch click, a slider release, a hex
Enter and a colour-bar pointer-up all dispatch.

**It cannot be performed on this surface.** Three arms, each paired with a
positive control on its own channel so a refusal cannot be read as a dead extern:

| arm | attempt | result |
|---|---|---|
| 1 | `jas_dispatch_event` `{"op":"set_active_color", …}`, both spellings | **UnknownVerb.** `set_active_color` is a PANEL ACTION, not a document verb; `op_apply` contains **zero** occurrences of `recent_colors` |
| 2 | `jas_panel_event` on the committing swatch, four addressings | **MissingTarget / BadParamType.** The swatch declares `behavior: click → set_active_color` and binds only `bind.color`, a literal to display. The event shape has no action half |
| 3 | the nearest reachable interaction — a `bind.value` write to the hex field | the colour moves; `recent_colors` **does not**. A tick wearing a commit's clothes |

**Controls:** the panel-event channel carries a value edit; the op channel
accepts `create_artboard`. Both alive.

⛔ **Every arm asserts `recent_colors` did NOT move** — the vacuity guard run
backwards, because the claim is that a thing did not happen and the evidence is a
state a success would have changed.

⇒ **Reporting arm 3's cost as C3 would be reporting an interaction that did not
occur.** No C3 number is offered. The apply path was not built to obtain one.

### The denominator question, answered by measurement

**A `recent_colors` push does NOT move the panel's record count.** The panel
declares **ten fixed slots** (`cp_recent_0` … `cp_recent_9`), each binding
`panel.recent_colors.<n>`; an empty slot renders as a hollow square rather than
not rendering. Measured at list lengths **0, 1 and 10**: the row count is
identical and only the values move — with a control asserting the values *do*
move, so the test cannot pass on a scope that ignored the list entirely.

⇒ **C2 and C3 will share a denominator** whenever C3 becomes measurable.

---

## 8. Where the delta lands in the shell, and the one number that would be a defect

The pinned tick has two clauses, and the second is the shell's: *every dependent
control showing the new value*. Of the 22 rows the tick returns —

| | rows | |
|---:|---|---|
| 21 | carry `bind.value` | the only key a displayed value comes from |
| 11 | landed on a typed control | shown |
| 10 | landed on a labelled placeholder | the sliders — the unfunded hard-widget stage |
| **0** | **unplaced** | **every row the engine says moved has somewhere to go** |

**Identical at both arms.** The zero is the number that would have been a defect:
a row the engine reports as changed and the shell cannot place is a control
displaying a stale value, and a crossing count would never see it.

---

## 9. Two harness defects, found by running

**The first receipt was well-formed, said `"vacuous": false`, and carried
`"c1": {}, "arms": [{}, {}]`.** `System.Text.Json` serializes properties only
unless `IncludeFields` is set, and every reading is a public field. The
measurement was real and the file carrying it was empty — and the run script
reports the file's *existence* as success. **A receipt that exists is not a
receipt that says anything.** `WriteReceipt` now refuses to write one that lost
its numbers.

**The tick harness measured correctly under `--test-threads=1` and failed three
different ways under the default run.** A separate test binary is not enough:
tests inside one binary still run in parallel over process-global counters. The
fix is that `measure` is the **only** way to read the counters — the dump is
private to it — so a test cannot forget to serialise, because a test that did not
go through it has no way to obtain a reading at all.

*Both are the same class as the five vacuous passes this spike has already
booked, arriving inside the instrument rather than inside the subject.*

---

## 10. What is NOT here

* **The three hard widgets** — hue bar, gradient/swatch grid, fill-stroke
  composite — are a separate, unfunded stage. 35 of the colour panel's 106
  records remain labelled placeholders, and every count above states its split.
* **C3.** Probed, refused, unbuilt (§7).
* **The painter-drawn arm.** Deliberately unbuilt, so this spike can show the
  materializer loses and cannot show it wins.
* **Any timing figure.** S-C measures construction and chatter; route cost was
  S-B's and the equation of the two was struck.
