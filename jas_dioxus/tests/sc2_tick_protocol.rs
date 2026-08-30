//! **C2 measured through the boundary, and C1 re-measured because the scope moved.**
//!
//! Its own test BINARY for the reason `ffi_boundary_counter` states: the
//! counters are process-global, so anything else that crosses the boundary in
//! the same process pollutes the reading.
//!
//! # ⛔ And a separate binary is NOT sufficient on its own
//!
//! Tests inside one binary still run in PARALLEL. The first version of this file
//! measured correctly under `--test-threads=1` and reported three different
//! failures under the default run — a harness whose answer depends on how it was
//! invoked, which is this campaign's own class arriving inside the instrument
//! again.
//!
//! The fix is [`measure`], and it is deliberately the **only** way to read the
//! counters here: `counters()` is private to it. A test cannot forget to
//! serialise, because a test that did not go through `measure` has no way to
//! obtain a reading at all. *Immune by construction beats immune by
//! remembering* — the campaign's second law, applied to the instrument that
//! produced the campaign's numbers.
//!
//! # What is established here, and what is not
//!
//! These are the numbers the S-C.2 gate is read against, taken from the Rust
//! side of the boundary. The C# shell reproduces them on hardware in session 1;
//! **that run is the deliverable's receipt and this file is its pin** — a figure
//! nothing asserts is a figure that drifts silently, which is exactly what the
//! sequencer's C1 guard is about.
//!
//! Every count asserts a NON-ZERO amount of work examined. S-C's deliverable is
//! a count and a count has no natural failure mode: a harness that measured
//! nothing reports 0, which is well-formed and reads like a cheap interaction.

use std::sync::Mutex;

use jas_dioxus::ffi::{
    jas_bind_values, jas_dispatch_event, jas_engine_free, jas_engine_new, jas_free,
    jas_instr_counters_json, jas_instr_reset, jas_last_error_json, jas_panel_event,
    jas_widget_tree, JasBytes, JasEngine, JasStatus,
};

const COLOUR: &str = "color_panel_content";
const ARTBOARDS: &str = "artboards_panel_content";

/// The two document sizes, pinned in the S-C.2 premise flags BEFORE anything
/// was measured, and accepted as pinned. **TOTAL artboards, not created ones** —
/// see [`grow_document`].
///
/// ⚠️ Named by ROLE, not by document path: the working record they were filed in
/// is private, and a public source file should not carry a handle into it.
const SMALL: usize = 8;
const LARGE: usize = 200;

static SERIAL: Mutex<()> = Mutex::new(());

fn take(b: JasBytes) -> String {
    if b.ptr.is_null() {
        return String::new();
    }
    let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
    let out = String::from_utf8(s.to_vec()).unwrap();
    unsafe { jas_free(b) };
    out
}

/// Run one named interaction under the counter lock and return its value beside
/// the dump. **The only way to read the counters in this binary.**
///
/// `setup` runs INSIDE the lock and BEFORE the reset, so its crossings are not
/// in the reading — that is where an engine is created, a document grown, and
/// panels opened. `act` is the interaction being priced.
///
/// The lock is taken poison-tolerantly on purpose: one panicking test must not
/// convert every other test in this file into a failure pointing at a lock line
/// nowhere near the defect. That cascade cost this campaign five reds, four of
/// them innocent.
fn measure<S, R>(
    setup: impl FnOnce() -> S,
    act: impl FnOnce(&mut S) -> R,
) -> (S, R, serde_json::Value) {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut state = setup();
    jas_instr_reset();
    let r = act(&mut state);
    // Taken LAST: releasing the dump calls `jas_free`, itself a counted
    // crossing, which would land in the next reading.
    let dump: serde_json::Value =
        serde_json::from_str(&take(jas_instr_counters_json())).expect("counter dump is JSON");
    (state, r, dump)
}

/// Anything that crosses the boundary WITHOUT taking a reading still has to
/// serialise, or it pollutes whatever measurement is running next door.
fn serialised<R>(f: impl FnOnce() -> R) -> R {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

fn n(c: &serde_json::Value, field: &str) -> i64 {
    c[field].as_i64().unwrap_or(-1)
}

fn per_fn(c: &serde_json::Value, name: &str) -> (i64, i64, i64) {
    let row = c["per_fn"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["fn"] == name)
        .unwrap_or_else(|| panic!("no row for {name}"));
    (
        row["calls"].as_i64().unwrap(),
        row["bytes_in"].as_i64().unwrap(),
        row["bytes_out"].as_i64().unwrap(),
    )
}

/// Grow the document to a TOTAL of `artboards` through the RATIFIED channel —
/// `create_artboard` is a live id-minting `op_apply` verb — so the second panel
/// grows because the DOCUMENT grew, not because a harness handed it a longer
/// list.
///
/// ⚠️ **A fresh document already holds ONE artboard** (`ensure_artboards_invariant`:
/// every document has at least one). So this creates `artboards - 1`, and the
/// arm sizes in the report are TOTALS. Creating `artboards` of them would have
/// made the pinned "8 and 200" quietly describe 9 and 201 — a number in a report
/// meaning something other than what it says, which is the denominator error
/// this campaign has now paid for six times.
fn grow_document(e: *mut JasEngine, artboards: usize) {
    const SEEDED: usize = 1;
    assert!(artboards >= SEEDED, "a document cannot hold fewer than one");
    for i in SEEDED..artboards {
        let op = format!(r#"{{"op":"create_artboard","id":"sc2ab{i:03}"}}"#);
        let st = unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) };
        assert_eq!(st, JasStatus::Ok, "create_artboard {i} was refused");
    }
    // Asserted, not assumed: if the seeded count ever changes, the arm sizes go
    // wrong silently and every ratio in the report is off by one artboard.
    let rows: serde_json::Value = serde_json::from_str(&take(unsafe {
        jas_bind_values(e, ARTBOARDS.as_ptr(), ARTBOARDS.len())
    }))
    .unwrap();
    let count = rows.as_array().unwrap().iter().filter(|r| r["id"] == "ap_number").count();
    assert_eq!(count, artboards, "the document holds the number the arm names");
}

/// Open a panel: read its structure and its values, exactly as the materializer
/// does. The `bind_values` call is also what ENROLS it for later ticks.
///
/// Passes a **NULL** ctx, which is the production call: the engine assembles the
/// scope. A shell that supplied one would be holding app state in C# (BL1).
fn open(e: *mut JasEngine, panel: &str) -> usize {
    let tree =
        take(unsafe { jas_widget_tree(e, panel.as_ptr(), panel.len(), std::ptr::null(), 0) });
    let rows = take(unsafe { jas_bind_values(e, panel.as_ptr(), panel.len()) });
    assert!(!rows.is_empty(), "{panel}: no bind rows");
    let records: serde_json::Value = serde_json::from_str(&tree).unwrap();
    records.as_array().unwrap().len()
}

/// One tick: drag a control to `value`. Returns `(changed_rows, reply_bytes)`.
fn tick(e: *mut JasEngine, widget: &str, value: f64) -> (usize, usize) {
    let ev = format!(r#"{{"widget":"{widget}","key":"bind.value","value":{value}}}"#);
    let reply =
        take(unsafe { jas_panel_event(e, COLOUR.as_ptr(), COLOUR.len(), ev.as_ptr(), ev.len()) });
    let bytes = reply.len();
    let rows: serde_json::Value = serde_json::from_str(&reply).unwrap_or(serde_json::json!([]));
    (rows.as_array().map(|a| a.len()).unwrap_or(0), bytes)
}

fn whole_panel_bytes(e: *mut JasEngine) -> usize {
    take(unsafe { jas_bind_values(e, COLOUR.as_ptr(), COLOUR.len()) }).len()
}

// ---------------------------------------------------------------------------
// C1 — re-measured, because the scope the engine assembles CHANGED
// ---------------------------------------------------------------------------

/// ⚖️ **The sequencer's guard on its own ruling (Amendment 9), discharged.**
///
/// Route (a) grew the engine-assembled scope with an `active_document`
/// namespace, and that changes what the engine assembles **for every panel**.
/// C1's published figure — 4 crossings / 23,050 bytes — is a number in a report,
/// and a published baseline that silently stops describing what it names is
/// worse than no baseline. Ruled: re-run and report unchanged, or report the
/// delta. **Measured, not assumed.**
///
/// It comes back unchanged, and the reason is checkable rather than lucky:
/// `color.yaml` contains **zero** `active_document` references, so nothing it
/// binds can see the new namespace. The `panel.*`-follows-`fill_on_top`
/// correction is likewise invisible here, because C1 opens with `fill_on_top`
/// true — where the active colour IS the fill.
#[test]
fn c1_is_unchanged_by_the_scope_growth() {
    let (e, nodes, c) = measure(
        || {
            let e = jas_engine_new();
            assert!(!e.is_null());
            e
        },
        // Reset falls AFTER the engine exists: C1 is the cost of opening a
        // PANEL, and engine creation is app startup. The same boundary the
        // shell's harness draws, drawn the same way.
        |e| open(*e, COLOUR),
    );

    assert_eq!(nodes, 106, "the C1 population");
    assert_eq!(n(&c, "crossings"), 4, "C1 crossings");
    assert_eq!(n(&c, "bytes_in"), 38, "C1 bytes in");
    assert_eq!(n(&c, "bytes_out"), 23_012, "C1 bytes out");
    assert_eq!(n(&c, "bytes_total"), 23_050, "the published C1 figure");

    // The BREAKDOWN, not just the total — the fork's answer lives there.
    assert_eq!(per_fn(&c, "jas_widget_tree"), (1, 19, 15_974));
    assert_eq!(per_fn(&c, "jas_bind_values"), (1, 19, 7_038));
    assert_eq!(per_fn(&c, "jas_free"), (2, 0, 0), "two frees for two reads");
    assert_eq!(per_fn(&c, "jas_panel_event"), (0, 0, 0), "C1 does not tick");
    // C1 performs no tick, so no engine-side sync work may be attributed to it.
    assert_eq!(c["engine"]["ticks"], 0);

    serialised(|| unsafe { jas_engine_free(e) });
}

/// The other half of the same guard: with **200 artboards in the document**, C1
/// on the colour panel is STILL 23,050. If this ever moves, the colour panel has
/// grown a document binding and C1's published figure is describing something
/// else.
#[test]
fn c1_does_not_move_when_the_document_is_large() {
    let (e, nodes, c) = measure(
        || {
            let e = jas_engine_new();
            grow_document(e, LARGE);
            e
        },
        |e| open(*e, COLOUR),
    );
    assert_eq!(nodes, 106);
    assert_eq!(n(&c, "bytes_total"), 23_050, "C1 is document-independent");
    serialised(|| unsafe { jas_engine_free(e) });
}

// ---------------------------------------------------------------------------
// C2 — the tick
// ---------------------------------------------------------------------------

/// **C2.** One pointer-move that changes the active colour, from the shell
/// receiving the input to every dependent row being told.
#[test]
fn one_tick_is_two_crossings() {
    let (e, (rows, bytes), c) = measure(
        || {
            let e = jas_engine_new();
            grow_document(e, SMALL);
            open(e, COLOUR);
            open(e, ARTBOARDS);
            e
        },
        |e| tick(*e, "cp_h", 210.0),
    );

    // ④ VACUITY: crossings > 0 AND a value demonstrably changed. A zero here is
    // RED, never "the tick is cheap".
    assert!(rows > 0, "the tick changed no row — RED, not cheap");
    assert!(bytes > 0);
    assert_eq!(n(&c, "crossings"), 2, "one event + its free");
    assert_eq!(per_fn(&c, "jas_panel_event").0, 1);
    assert_eq!(per_fn(&c, "jas_free"), (1, 0, 0), "one free: the reply's");
    assert_eq!(per_fn(&c, "jas_bind_values").0, 0, "no re-read: the reply carried it");

    // ⑤ the engine work the boundary cannot see
    assert_eq!(c["engine"]["ticks"], 1);
    assert!(c["engine"]["rows_evaluated"].as_i64().unwrap() > 0);
    assert_eq!(c["engine"]["panels_evaluated"], 2, "both open panels re-resolved");

    serialised(|| unsafe { jas_engine_free(e) });
}

/// ⚠️ Gate ④ from the other side: a drag that lands where the channel already
/// was must NOT read as a successful tick. The empty reply is honest, and the
/// diagnostic channel says WHICH kind of empty it is.
#[test]
fn a_tick_that_moves_nothing_says_so_rather_than_looking_cheap() {
    serialised(|| {
        let e = jas_engine_new();
        open(e, COLOUR);

        // Read the current hue out of the panel's own rows, then drag to it.
        let rows: serde_json::Value = serde_json::from_str(&take(unsafe {
            jas_bind_values(e, COLOUR.as_ptr(), COLOUR.len())
        }))
        .unwrap();
        let current: f64 = rows
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == "cp_h" && r["key"] == "bind.value")
            .expect("the H slider's row")["value"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();

        let (changed, _) = tick(e, "cp_h", current);
        assert_eq!(changed, 0, "a no-op drag moves no row");
        let err = take(unsafe { jas_last_error_json(e) });
        assert!(err.contains("\"panel_event\":\"Unchanged\""), "{err}");

        // The CONTROL: a real drag on the same slider does move rows. Without
        // it, "nothing moved" and "this path never moves anything" are one
        // output.
        let (moved, _) = tick(e, "cp_h", current + 40.0);
        assert!(moved > 0, "the control drag must move rows");
        unsafe { jas_engine_free(e) };
    });
}

/// ⛔ The event names a WIDGET, and an unknown one is refused rather than
/// silently landing somewhere plausible.
#[test]
fn an_unknown_widget_is_refused() {
    serialised(|| {
        let e = jas_engine_new();
        open(e, COLOUR);
        assert_eq!(tick(e, "cp_not_a_widget", 1.0), (0, 0));
        let err = take(unsafe { jas_last_error_json(e) });
        assert!(err.contains("\"panel_event\":\"MissingTarget\""), "{err}");
        unsafe { jas_engine_free(e) };
    });
}

// ---------------------------------------------------------------------------
// ② — the same tick at two DOCUMENT sizes
// ---------------------------------------------------------------------------

struct Arm {
    artboards: usize,
    widgets: usize,
    crossings: i64,
    bytes: i64,
    rows_evaluated: i64,
}

/// One arm: a document of `artboards`, both panels open, one tick priced.
fn arm(artboards: usize) -> Arm {
    let (e, (widgets, rows), c) = measure(
        || {
            let e = jas_engine_new();
            grow_document(e, artboards);
            let w = open(e, COLOUR) + open(e, ARTBOARDS);
            (e, w)
        },
        |(e, w)| (*w, tick(*e, "cp_h", 210.0).0),
    );
    assert!(rows > 0, "arm {artboards}: the tick changed nothing — RED");
    serialised(|| unsafe { jas_engine_free(e.0) });
    Arm {
        artboards,
        widgets,
        crossings: n(&c, "crossings"),
        bytes: n(&c, "bytes_total"),
        rows_evaluated: c["engine"]["rows_evaluated"].as_i64().unwrap(),
    }
}

/// **Gate ②, and the finding gate ⑤ exists to surface.**
///
/// The two document sizes are **8 and 200 artboards**, pinned before measuring
/// and accepted as pinned. The spread is what makes the claim falsifiable: an
/// O(n) tick cannot stay flat across it.
#[test]
fn the_tick_is_flat_across_two_document_sizes_and_the_engine_is_not() {
    let small = arm(SMALL);
    let large = arm(LARGE);

    // ⛔ The arms MUST differ, or ② was measured with the widget count held
    // constant — a pass with two arms that were never different. This is the
    // clause the `layers` panel would have failed silently.
    assert!(
        large.widgets > small.widgets,
        "the arms must differ in widget count: {} vs {}",
        small.widgets,
        large.widgets
    );
    assert!(large.widgets > 106, "the LARGE arm must exceed the colour panel");

    assert!(small.crossings <= 8 && large.crossings <= 8, "gate ①");
    assert!((large.crossings - small.crossings).abs() <= 1, "gate ②");
    assert!(small.bytes <= 7_038 && large.bytes <= 7_038, "gate ③");

    // ⑤ The engine's work DOES grow — the cost the boundary cannot see. If this
    // ever stops growing, the second arm stopped being data-driven and every
    // "flat" result above became unreadable.
    assert!(
        large.rows_evaluated > small.rows_evaluated,
        "engine work must grow with the document: {} vs {}",
        small.rows_evaluated,
        large.rows_evaluated
    );

    println!("\nC2 — one colour-drag tick, both arms");
    for a in [&small, &large] {
        println!(
            "  {:>4} artboards | {:>5} widgets | {} crossings | {:>5} bytes | {:>6} rows evaluated",
            a.artboards, a.widgets, a.crossings, a.bytes, a.rows_evaluated
        );
    }
    println!(
        "  widgets {:.2}x | bytes {:.2}x (UNGATED) | engine {:.2}x\n",
        large.widgets as f64 / small.widgets as f64,
        large.bytes as f64 / small.bytes.max(1) as f64,
        large.rows_evaluated as f64 / small.rows_evaluated.max(1) as f64
    );
}

/// ⛔ **GATE ③'s CEILING IS NOT A CONSTANT OF THE PANEL — it is the payload at
/// ONE COLOUR, and the naive re-read exceeds it at others.**
///
/// Amendment 8 ② states that the trivial whole-panel re-read passes ③ *by
/// construction*, "exactly 7,038 bytes because ③ was derived from that number."
/// Measured: 7,038 is the payload at the **C1 seed** (`664040`). Sweep the hue
/// and the same trivial re-read reaches **7,044** — the resolved values are
/// decimal strings and their DIGIT COUNTS move with the colour.
///
/// So the naive implementation the ceiling was defined to bound **breaches the
/// ceiling** at colours the seed happens not to be. That does not make ③
/// useless — a 6-byte overshoot is not the O(n) regression it was built to catch
/// — but **a pass or a breach within a few bytes of 7,038 says nothing**, and a
/// report must not treat the threshold as sharp.
///
/// Reported, not patched. Re-deriving the constant to a worst case would be
/// setting a threshold from the thing being gated, which is the error the
/// sequencer refused at 21:00 and is not mine to make unilaterally.
#[test]
fn the_naive_re_read_is_not_a_constant_and_exceeds_the_ceiling() {
    serialised(|| {
        let e = jas_engine_new();
        open(e, COLOUR);

        // At the seed, the ceiling's own number.
        assert_eq!(whole_panel_bytes(e), 7_038, "the payload gate ③ was derived from");

        let mut sizes = vec![];
        for h in [45.0, 120.0, 210.0, 300.0, 359.0] {
            let (moved, _) = tick(e, "cp_h", h);
            assert!(moved > 0, "hue {h} moved nothing — the sweep is not sweeping");
            sizes.push(whole_panel_bytes(e));
        }
        let (min, max) = (*sizes.iter().min().unwrap(), *sizes.iter().max().unwrap());
        println!("\nNAIVE WHOLE-PANEL RE-READ, colour panel, one hue sweep");
        println!("  seed 664040 : 7038 bytes  (gate ③'s ceiling)");
        println!("  sweep       : min {min}, max {max}  -> spread {} bytes\n", max - min);

        assert!(max > 7_038, "if it never exceeds 7,038 this flag is stale: max {max}");
        // PIN THE UNIT: the overshoot is BYTES and it is small. Bounded so a
        // change turning 6 bytes into 600 fails here rather than quietly
        // widening the claim.
        assert!(max - 7_038 < 100, "the overshoot is small: {} bytes", max - 7_038);

        unsafe { jas_engine_free(e) };
    });
}
