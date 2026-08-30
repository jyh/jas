//! Wiring tests for the S-C boundary counter.
//!
//! # Why these live in their own test BINARY
//!
//! The counters are **process-global**, and that is deliberate: the shell may
//! cross the boundary from more than one thread, and a counter that missed
//! those crossings would understate chatter — the direction that flatters the
//! result.
//!
//! The cost is that **any other test in the same binary that crosses the
//! boundary pollutes the reading.** That is not hypothetical: these tests first
//! lived in `ffi.rs`'s `mod tests`, guarded by a lock, and
//! `widget_tree_matches_the_corpus_driver_exactly` — which calls
//! `jas_widget_tree` in a loop and never took that lock — inflated the counter
//! under them. **A lock only serializes the tests that agree to take it**, so
//! the guarantee depended on every present and future test in a 2,100-test
//! binary remembering to opt in. That is precisely the shape of failure this
//! campaign keeps paying for: a rule that is true where it was written and
//! silently false one test over.
//!
//! A separate binary is immune by construction rather than by discipline —
//! nothing else links into it, so nothing else can cross the boundary while it
//! measures.
//!
//! # What is actually being established here
//!
//! `ffi_instr`'s unit tests prove the counter counts what it is TOLD to count,
//! and **they would pass in full on a boundary that was never instrumented at
//! all.** These tests establish the other half: that crossing the boundary is
//! itself what moves the counter. That is the sequencing ruling's §3.3 applied
//! to the instrument rather than to the shell.

use jas_dioxus::ffi::{
    jas_bind_values, jas_dispatch_event, jas_engine_free, jas_engine_new, jas_free,
    jas_instr_counters_json, jas_instr_reset, jas_version, jas_widget_tree, JasBytes, JasStatus,
};
use jas_dioxus::ffi_instr::{self, Crossing};
use std::sync::Mutex;

/// Tests inside THIS binary still run in parallel, so they serialize on this.
/// Unlike the lock that failed in `ffi.rs`, it is sufficient here: every test in
/// this file takes it, and no other test exists in this binary.
static SERIAL: Mutex<()> = Mutex::new(());

/// Copy a Rust-owned span out and release it (BL4).
///
/// ⚠️ Releasing calls `jas_free`, **which is itself a counted crossing** — so
/// every use of this helper adds one to the reading. The tests below account for
/// that explicitly rather than working around it, because it is a real property
/// of the boundary the shell will also have to live with.
fn take(b: JasBytes) -> String {
    if b.ptr.is_null() {
        return String::new();
    }
    let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
    let out = String::from_utf8(s.to_vec()).unwrap();
    unsafe { jas_free(b) };
    out
}

#[test]
fn calling_the_real_extern_moves_the_counter() {
    let _g = SERIAL.lock().unwrap();
    ffi_instr::reset();
    assert_eq!(ffi_instr::read(Crossing::Version), (0, 0, 0), "control: zero before the call");

    let b = jas_version();
    let produced = b.len;
    let text = take(b);

    let (calls, bytes_in, bytes_out) = ffi_instr::read(Crossing::Version);
    assert_eq!(calls, 1, "the crossing itself must increment the counter");
    assert_eq!(bytes_in, 0, "jas_version takes no payload");
    // ASSERT A VALUE ONLY THE REAL CALL CAN PRODUCE. A hard-coded number here
    // would pass against a counter wired to a constant; the returned span's own
    // length cannot be known without having made the call.
    assert_eq!(bytes_out, produced as u64, "bytes_out must be the span actually returned");
    assert!(produced > 0 && text.contains("jas_dioxus"), "sanity: the call really produced the payload");
}

#[test]
fn an_uncalled_function_stays_at_zero() {
    // The negative control for the arm above. Without it, a counter that
    // incremented every function on every crossing would pass that test.
    let _g = SERIAL.lock().unwrap();
    ffi_instr::reset();
    let _ = take(jas_version());
    assert_eq!(ffi_instr::read(Crossing::Version).0, 1);
    assert_eq!(ffi_instr::read(Crossing::WidgetTree), (0, 0, 0), "never called: must be zero");
    assert_eq!(ffi_instr::read(Crossing::DispatchEvent), (0, 0, 0), "never called: must be zero");
}

#[test]
fn dispatch_counts_the_payload_it_was_handed() {
    let _g = SERIAL.lock().unwrap();
    ffi_instr::reset();
    let e = jas_engine_new();
    let op = "{\"verb\":\"nope\"}";
    let _ = unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) };

    let (calls, bytes_in, _) = ffi_instr::read(Crossing::DispatchEvent);
    assert_eq!(calls, 1);
    assert_eq!(bytes_in, op.len() as u64, "bytes_in must be the payload's real length");
    unsafe { jas_engine_free(e) };
}

#[test]
fn a_rejected_call_still_counts_as_a_crossing() {
    // A NULL handle is refused before any work happens -- but the call DID cross
    // the boundary, and chatter is a count of crossings, not of successes.
    // Counting only the happy path would understate chatter by exactly the calls
    // a chatty shell makes and gets nothing for.
    let _g = SERIAL.lock().unwrap();
    ffi_instr::reset();
    let op = "{}";
    let st = unsafe { jas_dispatch_event(std::ptr::null_mut(), op.as_ptr(), op.len()) };
    assert_eq!(st, JasStatus::NullHandle);
    assert_eq!(ffi_instr::read(Crossing::DispatchEvent).0, 1, "a refused call is still a crossing");
}

#[test]
fn widget_tree_counts_both_directions() {
    let _g = SERIAL.lock().unwrap();
    ffi_instr::reset();
    let e = jas_engine_new();
    let id = "color";
    let b = unsafe { jas_widget_tree(e, id.as_ptr(), id.len(), std::ptr::null(), 0) };
    let produced = b.len;
    let _ = take(b);

    let (calls, bytes_in, bytes_out) = ffi_instr::read(Crossing::WidgetTree);
    assert_eq!(calls, 1);
    assert_eq!(bytes_in, id.len() as u64);
    assert_eq!(bytes_out, produced as u64);
    unsafe { jas_engine_free(e) };
}

#[test]
fn the_instrumentation_externs_do_not_count_themselves() {
    // The apparatus must not appear in its own measurement. `Crossing` has no
    // variant for either entry point, which is the structural guarantee; this is
    // the behavioural one.
    let _g = SERIAL.lock().unwrap();
    jas_instr_reset();
    let first = take(jas_instr_counters_json());
    assert!(
        first.contains("\"crossings\":0"),
        "a dump taken immediately after reset must read zero: {first}"
    );
    assert!(first.contains("\"surface\":\"main@22e5e30e+jas_bind_values\""), "the dump must name its surface: {first}");

    // AND THE OTHER HALF, which the first version of this test got wrong: the
    // dump does not count itself, but RELEASING it does, because `jas_free` is a
    // real crossing. So the second reading is 1 -- and that 1 is the free, not
    // the dump. Asserting "still zero" here would have been asserting that the
    // boundary is not instrumented.
    let second = take(jas_instr_counters_json());
    assert!(second.contains("\"crossings\":1"), "the free of the first dump must show: {second}");
    assert!(
        second.contains("\"fn\":\"jas_free\",\"calls\":1"),
        "and it must be attributed to jas_free, not to the dump: {second}"
    );
}

#[test]
fn the_c_side_can_reset_and_read_a_real_crossing() {
    // The end-to-end path the shell uses for C1/C2/C3, asserted through the
    // EXTERNS rather than the Rust helpers, because the externs are what the
    // shell has. Note the ordering rule this demonstrates: DUMP LAST. A dump
    // taken mid-interaction has to be freed, and that free lands in the reading.
    let _g = SERIAL.lock().unwrap();
    jas_instr_reset();

    let v = jas_version();
    let produced = v.len;
    let _ = take(v); // one jas_version + one jas_free

    let dump = take(jas_instr_counters_json());
    assert!(dump.contains("\"crossings\":2"), "one version + one free: {dump}");
    assert!(
        dump.contains(&format!("\"fn\":\"jas_version\",\"calls\":1,\"bytes_in\":0,\"bytes_out\":{produced}")),
        "the dump must carry the span the call really returned: {dump}"
    );

    jas_instr_reset();
    let cleared = take(jas_instr_counters_json());
    assert!(cleared.contains("\"crossings\":0"), "reset must clear from the C side: {cleared}");
}

// ---------------------------------------------------------------------------
// jas_bind_values -- the ninth MATERIALIZER extern (apparatus still excluded).
//
// It exists because `widget_tree` is value-blind BY DESIGN, so the eight-function
// surface could materialize 71 native controls with nothing in them. These tests
// pin the two things that make it worth adding: that it returns REAL resolved
// values, and that the engine assembles the data scope ITSELF.
// ---------------------------------------------------------------------------

#[test]
fn bind_values_resolves_real_values_not_key_names() {
    // The whole point of the ninth function. `widget_tree` gives `bind:
    // ["disabled","value"]` -- the NAMES. This must give what those resolve to.
    let _g = SERIAL.lock().unwrap();
    let e = jas_engine_new();
    let id = "color_panel_content";
    let out = take(unsafe { jas_bind_values(e, id.as_ptr(), id.len()) });

    let rows: serde_json::Value = serde_json::from_str(&out)
        .unwrap_or_else(|_| panic!("bind_values must return JSON: {out}"));
    let rows = rows.as_array().expect("a pre-order array");
    assert!(!rows.is_empty(), "the colour panel has bindings; an empty array means the ctx was blank");

    // A row is {path,id,key,type,value}. Assert the SHAPE and that at least one
    // row carries a non-null resolved value -- an all-null snapshot is exactly
    // the "subtler empty shell" this function exists to prevent.
    let mut non_null = 0;
    for r in rows {
        assert!(r.get("path").is_some() && r.get("key").is_some() && r.get("value").is_some(),
            "row missing a required field: {r}");
        if r["type"] != "null" { non_null += 1; }
    }
    assert!(non_null > 0, "every binding resolved to null -- the engine did not assemble a ctx: {out}");
    unsafe { jas_engine_free(e) };
}

#[test]
fn bind_values_serves_the_corpus_pinned_channel_derivation() {
    // The channels must come from `panel_channels`, which QUANTISES TO 8 BITS
    // BEFORE converting. `color_panel_view::sync_from_color` asks the FLOAT
    // colour for its own hue/saturation/brightness instead and can answer up to
    // a whole unit differently -- the shape of COLORTIERS, where Swift committed
    // 664040 and this port committed 664141 for the same drag.
    //
    // ⛔ THE FIRST VERSION OF THIS TEST WAS VACUOUS AND PASSED. It looked for rows
    // keyed `bind.r` / `bind.g` / `bind.bl` and guarded the assertions behind an
    // `if let`, so when no such key existed it asserted NOTHING and went green.
    // The rows are keyed by widget PROPERTY (`bind.value`, `bind.color`, ...) and
    // identified by widget ID. Removing the guard turned the false green red in
    // one run, which is the only reason this test now checks anything.
    let _g = SERIAL.lock().unwrap();
    let e = jas_engine_new();
    let id = "color_panel_content";
    let out = take(unsafe { jas_bind_values(e, id.as_ptr(), id.len()) });
    unsafe { jas_engine_free(e) };

    let rows: serde_json::Value = serde_json::from_str(&out).expect("JSON");
    let arr = rows.as_array().expect("pre-order array");
    let ids = || {
        let mut v: Vec<String> = arr.iter()
            .filter_map(|r| r["id"].as_str().filter(|s| !s.is_empty()).map(str::to_string))
            .collect();
        v.sort();
        v.dedup();
        v.join(",")
    };
    let value_of = |wid: &str| -> Option<String> {
        arr.iter()
            .find(|r| r["id"] == wid && r["key"] == "bind.value")
            .and_then(|r| r["value"].as_str().map(str::to_string))
    };

    // `cp_hex` is the mode-independent anchor: whatever colour the engine holds,
    // the hex the panel displays must be the one the pinned derivation produces.
    let hex = value_of("cp_hex")
        .unwrap_or_else(|| panic!("no bind.value row for cp_hex; widget ids present: {}", ids()));
    assert_eq!(hex.len(), 6, "hex must be 6 chars, got {hex:?}: {out}");

    // Re-derive every channel from that hex with the corpus-pinned function and
    // require the panel's own channel inputs to agree. A float-first derivation
    // disagrees on exactly the colours the 16 corpus vectors were written to
    // catch.
    let byte = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex byte") as f64 / 255.0;
    let pinned = jas_dioxus::interpreter::color_util::panel_channels(byte(0), byte(2), byte(4));
    assert_eq!(pinned.hex, hex, "panel_channels must round-trip its own hex: {out}");

    let expected = [
        ("cp_r_val", pinned.r.to_string()),
        ("cp_g_val", pinned.g.to_string()),
        ("cp_bl_val", pinned.bl.to_string()),
        ("cp_h_val", pinned.h.to_string()),
        ("cp_s_val", pinned.s.to_string()),
        ("cp_b_val", pinned.b.to_string()),
        ("cp_c_val", pinned.c.to_string()),
        ("cp_m_val", pinned.m.to_string()),
        ("cp_y_val", pinned.y.to_string()),
        ("cp_k_cmyk_val", pinned.k.to_string()),
    ];
    // Count what was actually compared and REQUIRE it to be non-trivial, so this
    // test can never again go green by finding nothing to check.
    let mut checked = 0;
    for (wid, want) in expected {
        if let Some(got) = value_of(wid) {
            assert_eq!(got, want, "{wid} must match the 8-bit-first derivation: {out}");
            checked += 1;
        }
    }
    assert!(
        checked >= 6,
        "expected to compare at least 6 channel inputs, compared {checked}; ids present: {}",
        ids()
    );
}

#[test]
fn bind_values_counts_as_one_crossing_both_directions() {
    let _g = SERIAL.lock().unwrap();
    let e = jas_engine_new();
    ffi_instr::reset();
    let id = "color_panel_content";
    let b = unsafe { jas_bind_values(e, id.as_ptr(), id.len()) };
    let produced = b.len;
    let _ = take(b);

    let (calls, bytes_in, bytes_out) = ffi_instr::read(Crossing::BindValues);
    assert_eq!(calls, 1);
    assert_eq!(bytes_in, id.len() as u64, "the panel id is what crossed inward");
    assert_eq!(bytes_out, produced as u64);
    unsafe { jas_engine_free(e) };
}

#[test]
fn bind_values_takes_no_caller_supplied_ctx() {
    // CONDITION 1, as a test rather than as a comment. The signature accepts a
    // PANEL IDENTIFIER and nothing else; the engine assembles the data scope.
    // Exposing the pure `bind_values(panel_node, ctx)` would have forced the
    // shell to build the scope, which puts app state in C# -- BL1 gone, and the
    // third interpreter's state half smuggled in through a parameter list.
    //
    // The compiler enforces the arity; what this test adds is that the values
    // are NOT blank, i.e. the engine really did assemble a scope rather than
    // defaulting to `{}`.
    let _g = SERIAL.lock().unwrap();
    let e = jas_engine_new();
    let id = "color_panel_content";
    let out = take(unsafe { jas_bind_values(e, id.as_ptr(), id.len()) });
    assert!(out.contains("\"value\""), "rows must carry values: {out}");
    assert!(!out.contains("\"type\":\"null\",\"value\":\"\"}]"),
        "a wholly-null snapshot means ctx was {{}}: {out}");
    unsafe { jas_engine_free(e) };
}

#[test]
fn an_unknown_panel_is_empty_not_a_crash() {
    let _g = SERIAL.lock().unwrap();
    let e = jas_engine_new();
    let id = "no_such_panel";
    let out = take(unsafe { jas_bind_values(e, id.as_ptr(), id.len()) });
    assert!(out == "[]" || out.is_empty(), "unknown panel must be empty, got: {out}");
    unsafe { jas_engine_free(e) };
}
