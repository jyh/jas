//! ⭐ ROW DU / NODE 5, PR 1 — THE ARM THE RULING NAMES.
//!
//! *"the web path keeps its behaviour through the existing Painter adapter
//! over CanvasRenderingContext2d, and the arm that proves it is the web
//! goldens + the live overlay unchanged (the trait change is safe exactly
//! when that arm is green)."*
//!
//! The web goldens are the DOCUMENT half and they run already. This file is
//! the OVERLAY half, and it is the half that had no arm at all: before this
//! node `draw_overlay` took a `CanvasRenderingContext2d`, so the only way to
//! see its output was to open a browser and look. Nothing in CI ever did.
//!
//! Now that the overlay draws into a `&mut dyn Painter`, a `RecordingPainter`
//! can read back the exact display list every workspace tool emits — no
//! browser, on both lanes. That is what these arms do.

use crate::painter::overlay_ctx::OverlayCtx;
use crate::painter::recording::{Command, RecordingPainter};
use crate::painter::Brush;
use crate::tools::tool::CanvasTool;
use crate::tools::yaml_tool::YamlTool;
use crate::document::document::Document;
use crate::document::model::Model;
use crate::geometry::element::{CommonProps, Element, LayerElem, RectElem};

/// The embedded workspace bundle's tool spec, the same one the running app
/// builds from (`recorder::replay::build_gesture_tool`, inlined because that
/// helper is itself still `#[cfg(feature = "web")]`).
fn tool(id: &str) -> YamlTool {
    let ws = crate::interpreter::workspace::Workspace::load()
        .expect("embedded workspace must parse");
    let spec = ws.data().get("tools").and_then(|t| t.get(id))
        .unwrap_or_else(|| panic!("workspace declares no tool '{id}'"));
    YamlTool::from_workspace_tool(spec)
        .unwrap_or_else(|| panic!("tool spec '{id}' failed to parse"))
}

/// One layer holding one 100x80 rect at (20,30), SELECTED — the state most
/// overlays are about (handles, bounds, the reference-point cross).
fn model_with_a_selected_rect() -> Model {
    let rect = Element::Rect(RectElem {
        x: 20.0, y: 30.0, width: 100.0, height: 80.0,
        rx: 0.0, ry: 0.0, fill: None, stroke: None,
        fill_gradient: None, stroke_gradient: None,
        common: CommonProps { name: Some("R".to_string()), ..Default::default() },
    });
    let layer = Element::Layer(LayerElem {
        children: vec![std::rc::Rc::new(rect)],
        isolated_blending: false,
        knockout_group: false,
        common: CommonProps { name: Some("L".to_string()), ..Default::default() },
    });
    Model::new(
        Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![crate::document::document::ElementSelection::all(vec![0, 0])],
            ..Document::default()
        },
        None,
    )
}

fn overlay_of(t: &dyn CanvasTool, m: &Model) -> Vec<Command> {
    let mut rec = RecordingPainter::new();
    {
        let mut ctx = OverlayCtx::new(&mut rec);
        t.draw_overlay(m, &mut ctx);
        ctx.finish();
    }
    rec.commands().to_vec()
}

/// ⭐ EVERY WORKSPACE OVERLAY, DRIVEN THROUGH THE REAL SEAM.
///
/// Eighteen of the twenty tools that declare an overlay emit a real display
/// list from a hover and a drag. The list is pinned BY NAME: a tool that goes
/// dark fails here, which is the regression this node could otherwise
/// introduce invisibly (the old signature could only be watched by eye, in a
/// browser).
#[test]
fn every_workspace_overlay_draws_through_the_painter_seam() {
    // ⛔ THE FILTER READS THE PARSER, NOT THE JSON. `overlay:` is authored in
    // two shapes -- a single `{if, render}` object and a list of them -- and a
    // filter that knew only about the list saw 5 of 20. The spec parser
    // already normalises both, so ask IT what a tool declares.
    let ws = crate::interpreter::workspace::Workspace::load().unwrap();
    let ids: Vec<String> = ws.data().get("tools").unwrap().as_object().unwrap()
        .keys()
        .filter(|id| !tool(id).spec().overlay.is_empty())
        .cloned()
        .collect();
    assert_eq!(ids.len(), 20, "the workspace's overlay tools: {ids:?}");

    let mut drew: Vec<String> = Vec::new();
    let mut dark: Vec<String> = Vec::new();
    for id in &ids {
        let mut t = tool(id);
        let mut m = model_with_a_selected_rect();

        // BOTH gestures, because tools guard on different ones: a marquee
        // needs a DRAG, while `blob_brush` / `eyedropper` gate a cursor
        // ornament on `has_hovered`, which a non-dragging move is what sets.
        // Driving only the drag and calling the rest dark was my own first
        // reading of this list.
        t.on_move(&mut m, 45.0, 55.0, false, false, false);
        let hovered = overlay_of(&t, &m);
        t.on_press(&mut m, 10.0, 20.0, false, false);
        t.on_move(&mut m, 60.0, 90.0, false, false, true);
        let dragged = overlay_of(&t, &m);

        // ⛔ AND NEITHER PASS MAY LEAK A FRAME. ⚠️ FOR THESE TWENTY THIS IS A
        // TRIPWIRE, NOT A PROOF: no YAML overlay opens a frame at all, so it
        // asserts 0 == 0 and a mutant that gutted `finish()` survived it. The
        // arm below is the one that actually loads it -- `type_tool` and
        // `type_on_path_tool` are hand-written and DO translate/rotate/scale. `OverlayCtx::finish` closes
        // what a tool left open; without it a stray `translate` would transform
        // everything drawn AFTER the overlay -- in the app, the next frame's
        // document. Asserted per tool, not once, because only one tool needs
        // to be unbalanced for the app to be wrong.
        for cmds in [&hovered, &dragged] {
            let push = cmds.iter().filter(|c| matches!(c, Command::PushState { .. })).count();
            let pop = cmds.iter().filter(|c| matches!(c, Command::PopState)).count();
            assert_eq!(push, pop, "tool '{id}' leaked {} frame(s)", push as i64 - pop as i64);
        }

        if hovered.is_empty() && dragged.is_empty() { dark.push(id.clone()); }
        else { drew.push(id.clone()); }
    }

    assert_eq!(
        drew,
        ["artboard", "blob_brush", "ellipse", "interior_selection", "lasso",
         "line", "paintbrush", "partial_selection", "pen", "pencil",
         "polygon", "rect", "rotate", "rounded_rect", "scale", "selection",
         "shear", "star", "zoom"],
        "the overlays that reach the seam",
    );

    // ⛔ NAMED, NOT SHRUGGED AT — and this list is one shorter than my first
    // reading of it. `blob_brush` was dark here, and I wrote a comment blaming
    // its guard; a mutant that forced EVERY guard open survived, which proved
    // the guard was not the cause. It was this node's own regression: its YAML
    // passes an unevaluated expression as the stroke colour, canvas ignores an
    // unparseable style and draws in black, and the façade's first draft
    // treated it as "draw nothing" (see `an_unparseable_style_keeps_the_
    // previous_colour`). `eyedropper` alone stays dark, and legitimately -- but
    // NOT for the reason its guard advertises: a mutant that forces every guard
    // open leaves it dark all the same, because `draw_cursor_color_chip_overlay`
    // resolves `state.eyedropper_cache` ITSELF and returns on a null. The gate
    // is the renderer, not the `if:`. (Twice now in this file a plausible
    // reading blamed the guard; twice the mutant said otherwise.) An APP-level
    // cache no gesture sets is what it wants. Pinned so that if it ever starts
    // drawing, this arm says so rather than quietly widening.
    assert_eq!(dark, ["eyedropper"], "the overlays still dark");
}

/// ⭐ THE PICTURE ITSELF, not merely that something was drawn: the selection
/// marquee is the rectangle the drag described, in the colours the YAML names.
///
/// This is the overlay half of "the live overlay unchanged". Every number here
/// comes from the workspace spec and the two pointer positions below, so a
/// facade that dropped the dash, lost the alpha, or mislaid the rectangle
/// fails on the number rather than on a screenshot nobody runs.
#[test]
fn the_selection_marquee_is_the_rectangle_the_drag_described() {
    let mut t = tool("selection");
    let mut m = model_with_a_selected_rect();
    t.on_press(&mut m, 10.0, 20.0, false, false);
    t.on_move(&mut m, 60.0, 90.0, false, false, true);
    let cmds = overlay_of(&t, &m);

    assert_eq!(cmds.len(), 2, "a translucent body and a dashed outline: {cmds:?}");

    let Command::FillRect { rect, brush, .. } = &cmds[0] else {
        panic!("the marquee body must be a fill: {cmds:?}")
    };
    assert_eq!((rect.x, rect.y, rect.w, rect.h), (10.0, 20.0, 50.0, 70.0),
               "press (10,20) -> move (60,90)");
    let Brush::Solid(body) = brush else { panic!("solid: {brush:?}") };
    // ⛔ THE BODY IS NEARLY TRANSPARENT (0.08) AND THE OUTLINE IS NOT. A facade
    // that read CSS alpha as 0..255 would make this an opaque blue slab over
    // the user's document -- a plausible picture, and the wrong one.
    assert!((body.to_rgba().3 - 0.08).abs() < 1e-9, "body alpha: {:?}", body.to_rgba());

    let Command::StrokeRect { rect, brush, stroke, .. } = &cmds[1] else {
        panic!("the marquee outline must be a stroke: {cmds:?}")
    };
    assert_eq!((rect.x, rect.y, rect.w, rect.h), (10.0, 20.0, 50.0, 70.0),
               "outline and body describe the SAME rectangle");
    let Brush::Solid(edge) = brush else { panic!("solid: {brush:?}") };
    assert!((edge.to_rgba().3 - 1.0).abs() < 1e-9, "the outline is opaque");
    assert_eq!(edge.to_rgba().0, body.to_rgba().0, "same hue as the body");
    assert_eq!(stroke.dash, vec![4.0, 4.0], "the marquee is DASHED");
    assert_eq!(stroke.width, 1.0);
}


/// ⭐ THE FRAME-BALANCE LAW, WHERE IT IS LOAD-BEARING.
///
/// `TypeTool` opens its overlay with `translate` + `scale`. Before this node it
/// carried its own `CtxSaveGuard` for exactly the reason its comment gives --
/// two early returns between the save and the restore; now
/// `OverlayCtx::finish()` closes what it opens, for every overlay at once. If
/// it ever stops doing so, a stray transform survives the overlay and poisons
/// the NEXT thing painted -- in the app, the document.
///
/// ⛔ THE `push > 0` LINE IS A POSITIVE CONTROL, NOT DECORATION. It is what
/// told me `TypeOnPathTool` opens no frame from a bare model (it wants a
/// TextPath edit session, which no gesture on a rect can produce) -- so it is
/// named here rather than sitting in the list proving nothing.
#[test]
fn the_hand_written_overlay_leaves_no_frame_open() {
    let m = model_with_a_selected_rect();
    let t = crate::tools::type_tool::TypeTool::new();
    let cmds = overlay_of(&t, &m);
    let push = cmds.iter().filter(|c| matches!(c, Command::PushState { .. })).count();
    let pop = cmds.iter().filter(|c| matches!(c, Command::PopState)).count();
    assert_eq!(push, 2, "translate + scale each open one: {cmds:?}");
    assert_eq!(pop, push, "and finish() closes both");
}
