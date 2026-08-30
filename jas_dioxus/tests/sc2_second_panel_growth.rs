//! **The S-C.2 gate-② premise, measured rather than assumed.**
//!
//! Amendment 8 ruled two things about the gate's SECOND panel:
//!
//! * ① the second panel **must be LARGER** than the colour panel (106 widgets),
//!   so that ③'s 7,038-byte ceiling is tested in the direction that can fail;
//! * ④ the second size **should be a DATA-DRIVEN panel at two DOCUMENT sizes** —
//!   `layers` was named, because "the colour panel is 106 widgets always;
//!   `layers` grows with the document, unbounded and user-controlled."
//!
//! Both are true of the **application**. This file asks whether either is true
//! of the **surface being measured** — the panel description a materializer
//! actually receives through `jas_widget_tree`. That is a different question,
//! and the campaign's own generalisation-error law says a claim true where it
//! was made can be silently false one module over.
//!
//! # Why a running probe and not a reading of the YAML
//!
//! §3.3 of the sequencing ruling: the count must be emitted by running code. A
//! grep of `foreach:` in `workspace/panels/*.yaml` would answer a question about
//! the SOURCE; the gate is measured against what the boundary EMITS, and the two
//! coincide only if the interpreter expands what the YAML declares.
//!
//! # The positive control, and why it is not decoration
//!
//! Every measurement here is a COUNT, and this campaign's first law is that a
//! count has no natural failure mode: a probe that expands nothing reports a
//! stable number, and stability is exactly the result being claimed. So
//! `the_probe_can_see_growth_at_all` varies a source the interpreter is KNOWN to
//! expand (`panel.isolation_stack`, layers' one real `foreach`) and requires the
//! count to move. Without it, "layers does not grow with the document" and "this
//! probe cannot see growth" are the same output.

use jas_dioxus::ffi::{
    jas_bind_values, jas_engine_free, jas_engine_new, jas_free, jas_widget_tree, JasBytes,
};

/// Copy a Rust-owned span out and release it (BL4).
fn take(b: JasBytes) -> String {
    if b.ptr.is_null() {
        return String::new();
    }
    let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
    let out = String::from_utf8(s.to_vec()).unwrap();
    unsafe { jas_free(b) };
    out
}

/// Records emitted by `jas_widget_tree` for `panel` under `ctx`.
///
/// Goes through the ABI on purpose: this is the number a shell can obtain, not
/// the number the interpreter could produce if called differently.
fn records(panel: &str, ctx: &serde_json::Value) -> usize {
    let e = jas_engine_new();
    assert!(!e.is_null(), "jas_engine_new returned NULL");
    let ctx_s = serde_json::to_string(ctx).unwrap();
    let out = take(unsafe {
        jas_widget_tree(
            e,
            panel.as_ptr(),
            panel.len(),
            ctx_s.as_ptr(),
            ctx_s.len(),
        )
    });
    unsafe { jas_engine_free(e) };
    let v: serde_json::Value =
        serde_json::from_str(&out).unwrap_or_else(|_| panic!("{panel}: ABI returned non-JSON"));
    let n = v.as_array().map(|a| a.len()).unwrap_or(0);
    // Amendment 5, applied to this probe: a zero is RED, never "the panel is
    // small". A misspelled panel id returns the empty span, which parses to an
    // empty array and would read as a perfectly well-formed measurement.
    assert!(n > 0, "{panel}: zero records — nothing was examined");
    n
}

/// `active_document.element_tree` with `n` flat rows, shaped as the layers
/// panel's `row_template` reads it (`node.*`).
fn element_tree(n: usize) -> serde_json::Value {
    (0..n)
        .map(|i| {
            serde_json::json!({
                "id": format!("el{i}"),
                "name": format!("Path {i}"),
                "type": "path",
                "type_label": "Path",
                "depth": 0,
                "is_container": false,
                "locked": false,
                "visibility": "preview",
                "element_selected": false,
                "panel_selected": false,
                "search_ancestor_only": false,
                "ancestor_layer_color": "#4080ff",
            })
        })
        .collect::<Vec<_>>()
        .into()
}

fn artboards(n: usize) -> serde_json::Value {
    (0..n)
        .map(|i| serde_json::json!({ "name": format!("Artboard {}", i + 1), "number": i + 1 }))
        .collect::<Vec<_>>()
        .into()
}

fn symbols(n: usize) -> serde_json::Value {
    (0..n)
        .map(|i| {
            serde_json::json!({ "id": format!("m{i}"), "name": format!("Sym {i}"), "usage_count": i })
        })
        .collect::<Vec<_>>()
        .into()
}

// ---------------------------------------------------------------------------
// The control — run this first when reading a failure
// ---------------------------------------------------------------------------

/// The instrument is alive: varying a source the interpreter DOES expand moves
/// the count. If this fails, every "does not grow" result below is unreadable.
#[test]
fn the_probe_can_see_growth_at_all() {
    let stack = |n: usize| {
        serde_json::json!({ "panel": { "isolation_stack":
            (0..n).map(|i| serde_json::json!({ "container_name": format!("L{i}") }))
                  .collect::<Vec<_>>() } })
    };
    let none = records("layers_panel_content", &stack(0));
    let three = records("layers_panel_content", &stack(3));
    assert!(
        three > none,
        "the probe cannot see foreach growth: {none} -> {three}"
    );
    // The rate is stated so a later reader can tell a real expansion from an
    // off-by-one: layers' breadcrumb template is 3 records per stack level.
    assert_eq!(three - none, 9, "isolation_stack: 3 records per level, x3");
}

// ---------------------------------------------------------------------------
// The finding
// ---------------------------------------------------------------------------

/// **The colour panel is the LARGEST panel in the workspace at an empty scope**,
/// so "a second panel LARGER than the colour panel" cannot be met by picking a
/// different panel — only by picking a data-driven one and giving it items.
///
/// Asserted over every panel rather than stated, because "no other panel is
/// bigger" is the claim that makes picking one a dead end, and a claim that
/// closes off an option should be the one that is checked.
#[test]
fn the_colour_panel_is_the_largest_and_layers_is_ten() {
    const PANELS: [&str; 16] = [
        "align_panel_content", "artboards_panel_content", "boolean_panel_content",
        "brushes_panel_content", "character_panel_content", "color_panel_content",
        "concepts_panel_content", "gradient_panel_content", "layers_panel_content",
        "magic_wand_panel_content", "opacity_panel_content", "paragraph_panel_content",
        "properties_panel_content", "stroke_panel_content", "swatches_panel_content",
        "symbols_panel_content",
    ];

    let colour = records("color_panel_content", &serde_json::json!({}));
    assert_eq!(colour, 106, "the C1 population, pinned");

    let mut checked = 0;
    for p in PANELS {
        let n = records(p, &serde_json::json!({}));
        assert!(
            n <= colour,
            "{p} emits {n} records, more than the colour panel's {colour} — \
             this test's premise has moved"
        );
        checked += 1;
    }
    // A loop that iterated nothing would pass every assertion inside it.
    assert_eq!(checked, 16, "every panel in the workspace was examined");

    // 10, not the golden's 19: that 19 is an isolation_stack of three.
    let layers = records(
        "layers_panel_content",
        &serde_json::json!({ "panel": { "isolation_stack": [] } }),
    );
    assert_eq!(layers, 10, "layers' static size, document-independent");
    assert!(
        layers < colour,
        "layers ({layers}) is SMALLER than the colour panel ({colour}), \
         which is the direction Amendment 8 ① ruled out"
    );
}

/// ⛔ **THE FLAG.** `layers` does not grow with the document *on this surface*.
///
/// Its rows are a `tree_view` + `row_template`, and neither `widget_tree` nor
/// `bind_values` expands a `row_template` — both expand `foreach`/`do` and
/// recurse `children`, and a `row_template` is neither. The tree is ONE record
/// (`lp_tree`) at every document size.
///
/// So measuring `layers` "at two document sizes" satisfies gate ② with the
/// widget count held CONSTANT: growth is 0 because nothing varied. That is a
/// pass by construction, which is the defect flag 1 identified, arriving one
/// level down.
#[test]
fn layers_does_not_grow_with_the_document_on_this_surface() {
    let at = |n: usize| {
        records(
            "layers_panel_content",
            &serde_json::json!({
                "panel": { "isolation_stack": [] },
                "active_document": { "element_tree": element_tree(n) },
            }),
        )
    };
    let small = at(8);
    let large = at(500);
    assert_eq!(
        small, large,
        "if these ever differ, the interpreter learned to expand row_template \
         and this flag is stale — re-read it before quoting it"
    );
}

/// The remedy, measured: `artboards` and `symbols` DO grow, because their item
/// lists are real `foreach` sources over `active_document.*`.
#[test]
fn artboards_and_symbols_do_grow_with_the_document() {
    let art = |n: usize| {
        records(
            "artboards_panel_content",
            &serde_json::json!({ "active_document": { "artboards": artboards(n) } }),
        )
    };
    let sym = |n: usize| {
        records(
            "symbols_panel_content",
            &serde_json::json!({
                "active_document": { "symbols": symbols(n), "selection_count": 1 },
                "panel": { "selected_symbol": "m0" },
            }),
        )
    };

    let (a3, a200) = (art(3), art(200));
    assert!(a200 > a3, "artboards must grow: {a3} -> {a200}");
    // Per-item rate, stated so the report can quote a slope and not two points.
    let per_artboard = (a200 - a3) / 197;
    assert!(per_artboard >= 1, "artboards: {per_artboard} records/item");

    let (s3, s200) = (sym(3), sym(200));
    assert!(s200 > s3, "symbols must grow: {s3} -> {s200}");

    // ⭐ The number the gate actually needs: a document size at which a
    // data-driven panel EXCEEDS the colour panel's 106, so ③ is tested in the
    // direction that can fail.
    assert!(
        a200 > 106,
        "artboards at 200 ({a200}) must exceed the colour panel's 106"
    );
}

/// ⛔ **THE SECOND HALF OF THE FLAG, and the one that decides scope.**
///
/// `jas_widget_tree` takes a shell-supplied `ctx`; `jas_bind_values` does NOT —
/// the engine assembles the scope itself (`ffi::panel_ctx`, BL1, so app state
/// never lands in C#). That scope carries `state.*` and `panel.*` **for the
/// colour panel only**: there is no `active_document` namespace in it at all.
///
/// So a data-driven second panel resolves its `foreach` source to null through
/// this extern and emits its static rows and nothing more — **flat in the
/// document by construction**, whatever the document holds. Gate ③'s bytes/tick
/// and the ungated bytes-growth ratio are both measured through this call.
///
/// ⇒ Building the second panel is not enough. `panel_ctx` must grow an
/// `active_document` namespace, or ② and the bytes ratio are measured against a
/// scope that cannot vary. That is engine work, and it spends **no** boundary
/// budget — but it is work, and it was not in the released scope.
#[test]
fn bind_values_cannot_see_the_document_at_all() {
    let rows = |panel: &str| -> usize {
        let e = jas_engine_new();
        assert!(!e.is_null());
        let out = take(unsafe { jas_bind_values(e, panel.as_ptr(), panel.len()) });
        unsafe { jas_engine_free(e) };
        let v: serde_json::Value = serde_json::from_str(&out).unwrap_or(serde_json::json!([]));
        v.as_array().map(|a| a.len()).unwrap_or(0)
    };

    // The control: the colour panel DOES resolve, because `panel_ctx` was built
    // for it. Without this arm, "the second panel is flat" and "bind_values is
    // broken" are the same output.
    let colour = rows("color_panel_content");
    assert!(colour > 0, "colour panel must resolve rows: {colour}");

    // The engine has no artboards and no way to be given any through this call,
    // so the panel's one `foreach` expands zero times at every document size.
    let art = rows("artboards_panel_content");
    let sym = rows("symbols_panel_content");
    println!(
        "\nbind_values rows (engine-assembled scope): colour={colour} \
         artboards={art} symbols={sym}"
    );
    assert!(
        art < 25 && sym < 16,
        "if these now match the widget_tree counts, panel_ctx grew an \
         active_document namespace and this flag is stale"
    );
}

/// The table, printed. `cargo test -- --nocapture` puts the whole measurement
/// in front of a reader without their having to re-derive it from assertions.
#[test]
fn print_the_measurement() {
    let rows: Vec<(String, usize)> = vec![
        (
            "color_panel_content @ {}".into(),
            records("color_panel_content", &serde_json::json!({})),
        ),
        (
            "layers @ 8 elements".into(),
            records(
                "layers_panel_content",
                &serde_json::json!({ "panel": { "isolation_stack": [] },
                                     "active_document": { "element_tree": element_tree(8) } }),
            ),
        ),
        (
            "layers @ 500 elements".into(),
            records(
                "layers_panel_content",
                &serde_json::json!({ "panel": { "isolation_stack": [] },
                                     "active_document": { "element_tree": element_tree(500) } }),
            ),
        ),
        (
            "artboards @ 3".into(),
            records(
                "artboards_panel_content",
                &serde_json::json!({ "active_document": { "artboards": artboards(3) } }),
            ),
        ),
        (
            "artboards @ 200".into(),
            records(
                "artboards_panel_content",
                &serde_json::json!({ "active_document": { "artboards": artboards(200) } }),
            ),
        ),
        (
            "symbols @ 3".into(),
            records(
                "symbols_panel_content",
                &serde_json::json!({ "active_document": { "symbols": symbols(3), "selection_count": 1 },
                                     "panel": { "selected_symbol": "m0" } }),
            ),
        ),
        (
            "symbols @ 200".into(),
            records(
                "symbols_panel_content",
                &serde_json::json!({ "active_document": { "symbols": symbols(200), "selection_count": 1 },
                                     "panel": { "selected_symbol": "m0" } }),
            ),
        ),
    ];
    println!("\nSC2 SECOND-PANEL PREMISE — widget_tree records through the ABI");
    for (label, n) in &rows {
        println!("  {n:>5}  {label}");
    }
    println!();
}
