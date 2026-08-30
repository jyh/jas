# S-C.1 — C1 MEASURED, and what it does and does not license

**Windows/kenai, 2026-08-25.** S-C.1 is complete at the **read half**; the write
path is booked as S-C.2 and was not started. Written against the S-C sequencing
ruling as amended through Amendment 5, which is held in the project's private
working record and is not reproduced here.

---

## 1. C1 — open the colour panel cold

**Measured on hardware, in session 1, by the Rust-side boundary counter.** The
receipt is `sc-c1.json`, written by the run itself; a static count of the
P/Invoke sites in this project would read identically on a run that never
happened.

| | |
|---|---|
| **crossings** | **4** |
| **bytes** | **23,050** (in 38 / out 23,012) |
| widget records walked | 106 |
| materialized as native controls | **71** |
| placeholders (S-C.2 kinds) | 35 |
| values applied | 15 |
| `vacuous` flag | **false** |

**The nine kinds, named — the breakdown, not the total** (Amendment 5 and the
sequencer's standing note that the fork's answer lives in the breakdown):

| crossing | calls | bytes in | bytes out |
|---|---|---|---|
| `jas_widget_tree` | **1** | 19 | **15,974** |
| `jas_bind_values` | **1** | 19 | **7,038** |
| `jas_free` | **2** | 0 | 0 |
| `jas_engine_new` | 0 | 0 | 0 |
| `jas_engine_free` | 0 | 0 | 0 |
| `jas_version` | 0 | 0 | 0 |
| `jas_document_json` | 0 | 0 | 0 |
| `jas_dispatch_event` | 0 | 0 | 0 |
| `jas_last_error_json` | 0 | 0 | 0 |

⚠️ **Two frees for two reads** — see §1a. This is the one durable structure C1
produced, and it is stated there rather than as a footnote here.

📌 **Where the reset falls.** The counter is reset **after** `jas_engine_new`:
C1 is the cost of opening a *panel*, and engine creation is app startup. Stated
because that boundary is a choice, and a reader should not have to infer which
side it fell on.

---

## 1a. ⭐ THE ONE DURABLE STRUCTURE C1 PRODUCED: a Rust-owns-it ABI doubles every value FETCH

**Every value this shell reads costs two crossings — the read and the release.**
`JasBytes` is Rust-owned (BL4), so a fetch is `jas_widget_tree` **plus**
`jas_free`. C1's four crossings are two fetches and their two frees.

⇒ **Unlike the missing write path (§4), this is NOT incompleteness.** It is a
property of the boundary's ownership model, it does not go away when the surface
is finished, and **painter-drawn chrome pays none of it, because it never
crosses** — it redraws from engine state. It is therefore the only asymmetry
between the two arms that C1 was in a position to observe.

📌 **PIN THE UNIT, because the multiplier does not apply to everything.** The
doubling is **on CROSSINGS, not on bytes**: the `jas_free` carries a payload of
zero. C1's 23,050 bytes are *not* doubled; its crossing count is.

*This matters for S-C.2's protocol design, and it is an input for the council
rather than a conclusion of this report:*

| protocol shape | crossings | bytes |
|---|---|---|
| many small targeted fetches | **doubled per fetch** — the multiplier lands hardest here | small |
| few whole-panel fetches | doubled, but on very few fetches | large |

**So "chatty in calls, cheap in bytes" and "few calls, whole-panel payload" are
not symmetric under this ABI**: a protocol must minimise **value fetches**, not
calls in general, because the doubling attaches to the fetch and not to the
byte. A design chosen on a call count alone would be chosen on the wrong
denominator.

⛔ **AND THIS IS STRUCTURE, NOT A VERDICT.** 4 crossings and 23,050 bytes to open
a panel cold is a **one-shot**, and the one-shot amortises — the sequencer ruled
that before the measurement, and the measurement does not disturb it. Nothing
here says the materializer loses; it says what any future protocol will be priced
in.

---

## 2. Line counts (§3.1: raw `wc -l`, whole files, per-file, populations in words)

**Population — C#:** every file whose sole purpose is materializing this panel:
the boundary bindings, the widget mapper, the window that hosts it and runs C1,
and the application entry point.

| lines | file |
|---:|---|
| 116 | `JasCore.cs` |
| 236 | `Materializer.cs` |
| 127 | `MainWindow.xaml.cs` |
| 16 | `App.xaml.cs` |
| **495** | **C# total** |

**Population — XAML:** the two markup files, counted separately because a
generated markup line and a hand-written C# line are not the same animal.

| lines | file |
|---:|---|
| 13 | `App.xaml` |
| 12 | `MainWindow.xaml` |
| **25** | **XAML total** |

**520 C# + XAML.** Project and harness files are listed but **excluded** from
that figure, since the painter-drawn reference has no counterpart to them:
`ScPanel.csproj` 42, `run_c1.ps1` 66.

⛔ **THIS NUMBER IS NOT COMPARABLE TO THE 1,298 YET, AND MUST NOT BE PRESENTED
AS IF IT WERE.** The reference is a *complete* colour panel; this materializes
**71 of 106 widgets** and applies **15 values**. It is a partial implementation,
and the honest reading is that 520 lines bought two thirds of the widgets and a
fraction of the content — not that the materializer is 2.5× cheaper.

---

## 3. Engine-side cost, beside the extern count (Amendment 3, Condition 3)

The disproportion gate counts **externs**. This work is **one** extern and a
meaningful amount of engine work, so it passes the gate cheaply while costing
more than the gate can see. Reported here for exactly that reason.

| lines | what |
|---:|---|
| +182 / −7 | `ffi.rs` — `PanelState`, `panel_ctx`, `jas_bind_values`, two apparatus externs |
| 308 | `ffi_instr.rs` — the boundary counter (new file) |
| 350 | `tests/ffi_boundary_counter.rs` — wiring tests (new file) |
| +11 | `Cargo.toml` — the separate test target |
| +5 | `lib.rs` — module wiring |
| +4 / −4 | `bind_values.rs` — `allow(dead_code)` retired |

**Extern count added: 1. Engine-side lines: ~860.** A metric counting boundary
functions can always be satisfied by pushing complexity behind one of them; the
gate was not rewritten to catch this, because a gate rewritten to catch the case
in front of it stops being a gate. The report shows what the gate cannot.

**Surface, stated separately** (Amendment 2): **9 materializer** externs
(budget-bearing) + **2 apparatus** (`jas_instr_reset`,
`jas_instr_counters_json`, not budget-bearing). Remaining materializer budget
**6–11** against the ~15–20 target.

---

## 4. ⛔ The write path is INCOMPLETENESS, not a chatter result

C2 (one drag tick) and C3 (commit) **were not measured, because they cannot be
performed on this surface**:

* `jas_dispatch_event` reaches `op_apply`, whose vocabulary is **156 document
  verbs**. None sets the panel's working colour.
* The colour-tick write path is `set_active_color_live`, which exists only in
  `interpreter/renderer.rs`, operates on `AppState`, and both are
  `#[cfg(feature = "web")]` — unreachable from the FFI build.

⚖️ **This says NOTHING about the fork, and must not be quoted as if it did.** It
is surface incompleteness, which nobody disputes, and it is implementable inside
the remaining 6–11 budget. The withdrawn kill-gate fired on exactly this
confusion — "a new extern is needed" read as "chatter has lost" — and the same
confusion must not re-enter through a report.

📌 **And the deeper reason C2 was never a cheap measurement.** The fork's cost
difference lies entirely in a **state-sync protocol** that native-materialized
needs and painter-drawn does not: painter-drawn chrome never syncs native
controls, it redraws from engine state, while native-materialized must keep 71
live controls agreeing with engine state across a boundary. **So C2 would not
have measured the fork — it would have measured whatever sync protocol someone
built.** A whole-panel re-read is small in crossings and large in bytes; a
since-revision delta inverts that. Both are "the materializer".

---

## 5. What Amendment 5 caught, which is worth more than the number it saved

**Ruled at ~21:00; it caught its case within the hour.** Had C2 been run with a
valid no-op verb, the counter would have reported **0 crossings for the colour
change** — and **0 is a well-formed number that reads as "the tick is cheap"**,
in the headline figure, in the direction that flatters the materializer. That
would have been the **fifth vacuous pass of one evening**, after: a category-D
discharge by `--no-run` (compiles is not passes), `jas_instr_*` described in a
module doc and never built, a test asserting every counter dump reads zero (which
would have certified a **deaf** instrument), and a derivation test that asserted
nothing at all.

**Five instances, one class, one spike, one night — that is a property of the
deliverable, not five mistakes.** S-C's output is a **count**, and a count has no
natural failure mode: a check that examines nothing produces 0, which is
perfectly well-formed and looks exactly like a measurement. Everywhere else a
broken check throws or returns garbage; here it returns a plausible integer.

The C1 harness therefore asserts a **non-zero amount of work examined** —
`crossings > 0 && nodes > 0 && materialized > 0` — and publishes a `vacuous` flag
beside the numbers. It reads `false`.

---

## 6. Known gaps in this materializer, stated rather than left to inference

* **Only `bind.value` rows are consumed.** `bind_values` also emits `content` and
  `label` rows for nodes carrying `{{ }}`, and this mapper ignores them — which
  is why **15** values were applied and not more. A complete materializer is
  longer than 520 lines.
* **35 widgets are placeholders**, rendered as a labelled `[kind]` box so what is
  *not* built stays visible in the window rather than reading as empty space.
* **No interaction is wired**, because there is nowhere for it to land (§4).

---

## 7. What this licenses

**One thing only: the fork stays open.**

Not "proceed with the materializer", not a ratification, not a discharge of S-C.
The 1,298-line reference is a Dioxus-port number and only a **lower bound** on a
Windows painter arm, and the painter arm is deliberately unbuilt — so S-C could
have shown the materializer **loses** and did not. On the read half it came in at
one extern plus engine state for 67 % of the widgets, which is favourable. **The
chatter half is not a cheap measurement and never was**, and that is a
premise-level finding about S-C's scope rather than a result from inside it.
