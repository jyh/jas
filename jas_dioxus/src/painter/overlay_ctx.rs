//! A canvas-shaped imperative façade over the [`Painter`] seam, for TOOL
//! OVERLAYS.
//!
//! ⭐ ROW DU / PR 1 — the node-2 move, on a seam one method wide. Ruled
//! 2026-09-02, option (c).
//!
//! `CanvasTool::draw_overlay` took a `&CanvasRenderingContext2d`, and that ONE
//! parameter is why the whole `tools/` module is `#[cfg(feature = "web")]` —
//! measured: 26 web references across ~11,400 lines, **every one about drawing**,
//! and fifteen trait methods of which only this one carries a web type. The
//! input half (`on_press` / `on_move` / `on_release`) has no web dependency at
//! all. So a Windows app could not take the pointer because the SELECTION
//! HANDLES could not be drawn.
//!
//! # Why a façade instead of rewriting the call sites
//!
//! ⛔ THERE ARE 251 `ctx.*` SITES IN `tools/` OVER 22 DISTINCT METHODS. Rewriting
//! each into display-list calls by hand is 251 chances to transpose a coordinate
//! in code no golden covers directly. This type presents the SAME imperative
//! vocabulary — `begin_path` / `move_to` / `stroke` — over a `Painter`, so the
//! call sites keep their shape and the diff stays readable.
//!
//! ⚖️ THAT IS A DELIBERATE DIFFERENCE FROM `element_render`, which lowered
//! `render.rs` by rewriting it. The document walk earns a rewrite: it is the
//! product, it has goldens, and its shape is worth improving. An overlay is
//! chrome — the cheapest correct port is the one that changes the fewest lines,
//! and the risk here is transcription, not design.
//!
//! # What it does NOT do
//!
//! It is not a canvas. It carries exactly the vocabulary the overlays use, and
//! anything else is absent rather than approximated — a method that silently did
//! nothing would be an overlay that silently stopped drawing.

use crate::geometry::element::{Color, LineCap, LineJoin, PathCommand};
use crate::painter::{StrokeAlign, Brush, EllipseArc, FillRule, Painter, Rect, StrokeStyle, Transform};

/// Parse the CSS colour forms the tool overlays actually use.
///
/// ⛔ `None` FOR ANYTHING ELSE, AND THE CALLER SKIPS THE DRAW. Substituting a
/// default would paint a handle in the wrong colour, which reads as a rendering
/// bug in the tool rather than a gap in this parser. The overlay palette was
/// measured, not guessed: hex (3 and 6 digit), `rgb()`, `rgba()`, `white`,
/// `black`, and the sentinel `none`.
pub fn css_color(css: &str) -> Option<Color> {
    let s = css.trim();
    // ⚠️ THIS BRANCH IS INTENT, NOT BEHAVIOUR, and a mutation pass proved it:
    // deleting it changes nothing, because "none" matches no other form and
    // falls out of the `rgb(`/`rgba(` parse as `None` anyway. It is kept
    // because `none` is a SENTINEL the overlays set deliberately ("draw no
    // fill"), and a future named-colour table would otherwise have to remember
    // not to swallow it. Named as an equivalent mutant so nobody adds a test
    // that cannot fail.
    if s.eq_ignore_ascii_case("none") || s.is_empty() {
        return None;
    }
    if s.eq_ignore_ascii_case("white") {
        return Some(Color::new(1.0, 1.0, 1.0, 1.0));
    }
    if s.eq_ignore_ascii_case("black") {
        return Some(Color::new(0.0, 0.0, 0.0, 1.0));
    }
    if let Some(hex) = s.strip_prefix('#') {
        let n = |i: usize, w: usize| -> Option<f64> {
            let part = hex.get(i..i + w)?;
            let v = u8::from_str_radix(&part.repeat(3 - w), 16).ok()?;
            Some(v as f64 / 255.0)
        };
        return match hex.len() {
            3 => Some(Color::new(n(0, 1)?, n(1, 1)?, n(2, 1)?, 1.0)),
            6 => Some(Color::new(n(0, 2)?, n(2, 2)?, n(4, 2)?, 1.0)),
            _ => None,
        };
    }
    let lower = s.to_ascii_lowercase();
    let inner = lower
        .strip_prefix("rgba(")
        .or_else(|| lower.strip_prefix("rgb("))?
        .strip_suffix(')')?;
    let parts: Vec<f64> = inner
        .split(',')
        .map(|p| p.trim().parse::<f64>())
        .collect::<Result<_, _>>()
        .ok()?;
    match parts.len() {
        3 => Some(Color::new(parts[0] / 255.0, parts[1] / 255.0, parts[2] / 255.0, 1.0)),
        // ⚠️ THE ALPHA IS 0..1, NOT 0..255 — CSS's own asymmetry, and getting it
        // backwards makes every translucent overlay opaque.
        4 => Some(Color::new(parts[0] / 255.0, parts[1] / 255.0, parts[2] / 255.0, parts[3])),
        _ => None,
    }
}

/// The imperative façade. Holds the pending path and paint state, exactly as a
/// canvas context does, and flushes to the [`Painter`] on `stroke()` / `fill()`.
pub struct OverlayCtx<'a> {
    p: &'a mut dyn Painter,
    path: Vec<PathCommand>,
    /// Where the current sub-path began, for `close_path` and for the implicit
    /// `move_to` a `line_to` needs when no sub-path is open.
    start: Option<(f64, f64)>,
    /// ⛔ NOT AN `Option`. Canvas IGNORES an unparseable style assignment and
    /// leaves the previous value in place -- this codebase's own style parser
    /// says so in `yaml_tool::parse_style` ("Canvas2D's
    /// set_fill_style_str(\"none\") silently fails and leaves the previous
    /// fillStyle in place"). Modelling an unparseable colour as "draw nothing"
    /// instead SILENTLY BLANKED two overlays whose YAML passes an unevaluated
    /// expression (`stroke_color: "state.fill_color"`) as the colour: on canvas
    /// they drew in the default black, through the facade they vanished.
    /// `fill: none` is handled where it always was -- the style parser sets the
    /// paint to `None` and the caller skips the draw entirely.
    stroke_color: Color,
    fill_color: Color,
    line_width: f64,
    dash: Vec<f64>,
    alpha: f64,
    /// How many `push_state` frames this context has opened, so `restore`-less
    /// tool code cannot leave the painter unbalanced.
    frames: usize,
    /// An `arc`/`ellipse` awaiting its `fill()` or `stroke()`.
    ///
    /// ⛔ IT IS SEPARATE FROM `path`, NOT APPENDED TO IT, because `Painter` has
    /// an arc PRIMITIVE and not an arc path segment (contract A2/A5) — an
    /// ellipse arc cannot be expressed as `PathCommand`s without the bézier
    /// approximation RP3 needed a ruling for, and an overlay handle has no need
    /// to pay that.
    pending_arc: Option<EllipseArc>,
}

impl<'a> OverlayCtx<'a> {
    pub fn new(p: &'a mut dyn Painter) -> Self {
        Self {
            p,
            path: Vec::new(),
            start: None,
            // Canvas defaults: black stroke and fill, 1px, no dash, opaque.
            stroke_color: Color::new(0.0, 0.0, 0.0, 1.0),
            fill_color: Color::new(0.0, 0.0, 0.0, 1.0),
            line_width: 1.0,
            dash: Vec::new(),
            alpha: 1.0,
            frames: 0,
            pending_arc: None,
        }
    }

    /// ⛔ CLOSE ANY FRAMES THE TOOL LEFT OPEN. A canvas `save()` without its
    /// `restore()` is scoped by the browser's own stack; a `Painter` frame is
    /// not, and an unbalanced `push_state` poisons everything drawn after the
    /// overlay. Call once when the overlay is done.
    pub fn finish(mut self) {
        while self.frames > 0 {
            self.p.pop_state();
            self.frames -= 1;
        }
    }

    // -- paint state ------------------------------------------------------
    pub fn set_stroke_style_str(&mut self, css: &str) {
        if let Some(c) = css_color(css) { self.stroke_color = c; }
    }
    pub fn set_fill_style_str(&mut self, css: &str) {
        if let Some(c) = css_color(css) { self.fill_color = c; }
    }
    pub fn set_line_width(&mut self, w: f64) { self.line_width = w; }
    pub fn set_line_dash(&mut self, d: &[f64]) { self.dash = d.to_vec(); }
    pub fn set_global_alpha(&mut self, a: f64) { self.alpha = a; }
    pub fn global_alpha(&self) -> f64 { self.alpha }

    // -- transform --------------------------------------------------------
    pub fn translate(&mut self, x: f64, y: f64) {
        self.p.push_state(Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: x, f: y });
        self.frames += 1;
    }
    pub fn rotate(&mut self, rad: f64) {
        let (s, c) = rad.sin_cos();
        self.p.push_state(Transform { a: c, b: s, c: -s, d: c, e: 0.0, f: 0.0 });
        self.frames += 1;
    }
    pub fn scale(&mut self, sx: f64, sy: f64) {
        self.p.push_state(Transform { a: sx, b: 0.0, c: 0.0, d: sy, e: 0.0, f: 0.0 });
        self.frames += 1;
    }
    /// Undo the most recent `translate`/`rotate`/`scale`.
    pub fn restore(&mut self) {
        if self.frames > 0 {
            self.p.pop_state();
            self.frames -= 1;
        }
    }

    // -- path building ----------------------------------------------------
    pub fn begin_path(&mut self) {
        self.path.clear();
        self.start = None;
        self.pending_arc = None;
    }
    pub fn move_to(&mut self, x: f64, y: f64) {
        self.path.push(PathCommand::MoveTo { x, y });
        self.start = Some((x, y));
    }
    pub fn line_to(&mut self, x: f64, y: f64) {
        // A `line_to` with no open sub-path begins one, as canvas does.
        if self.start.is_none() {
            self.move_to(x, y);
            return;
        }
        self.path.push(PathCommand::LineTo { x, y });
    }
    pub fn quadratic_curve_to(&mut self, x1: f64, y1: f64, x: f64, y: f64) {
        self.path.push(PathCommand::QuadTo { x1, y1, x, y });
    }
    pub fn bezier_curve_to(&mut self, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) {
        self.path.push(PathCommand::CurveTo { x1, y1, x2, y2, x, y });
    }
    pub fn close_path(&mut self) {
        self.path.push(PathCommand::ClosePath);
    }

    // -- painting ---------------------------------------------------------
    fn stroke_style(&self) -> StrokeStyle {
        StrokeStyle {
            width: self.line_width,
            cap: LineCap::Butt,
            join: LineJoin::Miter,
            miter: 10.0,
            dash: self.dash.clone(),
        }
    }

    pub fn stroke(&mut self) {
        let c = self.stroke_color;
        let st = self.stroke_style();
        if let Some(arc) = self.pending_arc {
            self.p.stroke_ellipse_arc(&arc, &Brush::Solid(c), &st, StrokeAlign::Center, self.alpha);
        }
        if !self.path.is_empty() {
            self.p.stroke_path(&self.path, &Brush::Solid(c), &st, self.alpha);
        }
    }

    pub fn fill(&mut self) {
        let c = self.fill_color;
        if let Some(arc) = self.pending_arc {
            self.p.fill_ellipse_arc(&arc, FillRule::NonZero, &Brush::Solid(c), self.alpha);
        }
        if !self.path.is_empty() {
            self.p.fill_path(&self.path, FillRule::NonZero, &Brush::Solid(c), self.alpha);
        }
    }

    pub fn stroke_rect(&mut self, x: f64, y: f64, w: f64, h: f64) {
        let c = self.stroke_color;
        let st = self.stroke_style();
        self.p.stroke_rect(Rect { x, y, w, h }, &Brush::Solid(c), &st, self.alpha);
    }

    pub fn fill_rect(&mut self, x: f64, y: f64, w: f64, h: f64) {
        let c = self.fill_color;
        self.p.fill_rect(Rect { x, y, w, h }, &Brush::Solid(c), self.alpha);
    }

    /// A full circle/arc, appended as its own painted primitive.
    ///
    /// ⚠️ CANVAS `arc()` ADDS TO THE CURRENT PATH; this paints immediately when
    /// `fill`/`stroke` follows, because `Painter` has an arc PRIMITIVE rather
    /// than an arc path segment (contract A2/A5). Every overlay use is a
    /// standalone handle dot, so the two agree — and the ones that are not
    /// standalone would be visibly wrong rather than subtly so.
    pub fn arc(&mut self, cx: f64, cy: f64, r: f64, start: f64, end: f64) {
        self.pending_arc = Some(EllipseArc {
            cx, cy, rx: r, ry: r, rotation: 0.0, start, end, ccw: false,
        });
    }

    pub fn ellipse(&mut self, cx: f64, cy: f64, rx: f64, ry: f64, rot: f64, start: f64, end: f64) {
        self.pending_arc = Some(EllipseArc {
            cx, cy, rx, ry, rotation: rot, start, end, ccw: false,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::recording::{Command, RecordingPainter};

    fn drawn(f: impl FnOnce(&mut OverlayCtx)) -> Vec<Command> {
        let mut rec = RecordingPainter::new();
        {
            let mut ctx = OverlayCtx::new(&mut rec);
            f(&mut ctx);
            ctx.finish();
        }
        rec.commands().to_vec()
    }

    /// ⛔ THE PALETTE THE OVERLAYS ACTUALLY USE, measured from the call sites
    /// rather than guessed — hex 3 and 6, `rgb()`, `rgba()`, the two named
    /// colours, and the `none` sentinel.
    #[test]
    fn css_color_parses_the_overlay_palette() {
        assert_eq!(css_color("#ffffff"), Some(Color::new(1.0, 1.0, 1.0, 1.0)));
        assert_eq!(css_color("#666"), Some(Color::new(0.4, 0.4, 0.4, 1.0)));
        assert_eq!(css_color("white"), Some(Color::new(1.0, 1.0, 1.0, 1.0)));
        assert_eq!(css_color("rgb(255,140,0)"),
                   Some(Color::new(1.0, 140.0 / 255.0, 0.0, 1.0)));

        // ⛔ THE ALPHA IS 0..1 WHILE THE CHANNELS ARE 0..255 — CSS's own
        // asymmetry. Reading it as 0..255 makes every translucent overlay
        // opaque, which is a plausible picture and the wrong one.
        let a = css_color("rgba(0, 120, 215, 0.1)").expect("rgba parses");
        assert!((a.to_rgba().3 - 0.1).abs() < 1e-9,
                "alpha must be 0..1, got {:?}", a.to_rgba().3);

        // `none` and anything unrecognised are None, so the caller SKIPS the
        // draw rather than painting a substituted colour.
        assert_eq!(css_color("none"), None);
        assert_eq!(css_color("chartreuse"), None, "an unlisted name is None, not a guess");
        assert_eq!(css_color("#12345"), None, "a malformed hex is None");
    }

    /// A begin/move/line/stroke sequence becomes ONE `stroke_path` carrying the
    /// path that was built — the whole point of the façade.
    #[test]
    fn a_built_path_strokes_as_one_command() {
        let cmds = drawn(|c| {
            c.set_stroke_style_str("#ff0000");
            c.set_line_width(3.0);
            c.begin_path();
            c.move_to(1.0, 2.0);
            c.line_to(10.0, 2.0);
            c.line_to(10.0, 20.0);
            c.stroke();
        });
        assert_eq!(cmds.len(), 1, "one stroke, not one per segment: {cmds:?}");
        let Command::StrokePath { path, brush, stroke, .. } = &cmds[0] else {
            panic!("expected StrokePath, got {cmds:?}")
        };
        assert_eq!(path.len(), 3, "the whole path travels: {path:?}");
        assert_eq!(*brush, Brush::Solid(Color::new(1.0, 0.0, 0.0, 1.0)));
        assert_eq!(stroke.width, 3.0);
    }

    /// ⛔ AN UNPARSEABLE STYLE LEAVES THE PREVIOUS COLOUR IN PLACE — canvas's
    /// own rule, and the one this façade exists to reproduce.
    ///
    /// This arm replaced its opposite. I first modelled an unrecognised colour
    /// as "draw nothing", which is a plausible reading and the wrong one: two
    /// workspace overlays pass an UNEVALUATED expression as their colour
    /// (`blob_brush`'s `stroke_color: "state.fill_color"`), which canvas
    /// ignores — so they drew in the default black, and under the first
    /// reading they silently vanished. `every_workspace_overlay_draws_through_
    /// the_painter_seam` is what caught it.
    #[test]
    fn an_unparseable_style_keeps_the_previous_colour() {
        let cmds = drawn(|c| {
            c.set_stroke_style_str("#ff0000");
            c.set_stroke_style_str("state.fill_color"); // an expression, not a colour
            c.begin_path();
            c.move_to(0.0, 0.0);
            c.line_to(4.0, 4.0);
            c.stroke();
        });
        assert_eq!(cmds.len(), 1, "it must still draw: {cmds:?}");
        let Command::StrokePath { brush, .. } = &cmds[0] else { panic!("{cmds:?}") };
        assert_eq!(*brush, Brush::Solid(Color::new(1.0, 0.0, 0.0, 1.0)),
                   "the red set before the bad assignment survives it");
    }

    /// And with NO assignment at all the colour is canvas's default black,
    /// which is what the two expression-coloured overlays actually render in.
    #[test]
    fn the_default_colour_is_opaque_black() {
        let cmds = drawn(|c| {
            c.begin_path();
            c.move_to(0.0, 0.0);
            c.line_to(4.0, 4.0);
            c.stroke();
        });
        let Command::StrokePath { brush, .. } = &cmds[0] else { panic!("{cmds:?}") };
        assert_eq!(*brush, Brush::Solid(Color::new(0.0, 0.0, 0.0, 1.0)));
    }

    /// The dash pattern reaches the stroke — the overlays' marquee is dashed,
    /// and a dropped dash is a solid rectangle over the user's document.
    #[test]
    fn the_dash_pattern_reaches_the_stroke() {
        let cmds = drawn(|c| {
            c.set_line_dash(&[4.0, 2.0]);
            c.begin_path();
            c.move_to(0.0, 0.0);
            c.line_to(9.0, 0.0);
            c.stroke();
        });
        let Command::StrokePath { stroke, .. } = &cmds[0] else { panic!("{cmds:?}") };
        assert_eq!(stroke.dash, vec![4.0, 2.0]);
    }

    /// ⛔ AN UNBALANCED `translate` MUST NOT LEAK. Canvas scopes a `save()` by
    /// its own stack; a `Painter` frame is not scoped, and a left-open
    /// `push_state` transforms everything drawn AFTER the overlay — the
    /// document included. `finish()` closes what the tool forgot.
    #[test]
    fn finish_closes_frames_the_tool_left_open() {
        let cmds = drawn(|c| {
            c.translate(5.0, 7.0);
            c.rotate(0.5);
            c.begin_path();
            c.move_to(0.0, 0.0);
            c.line_to(1.0, 1.0);
            c.stroke();
            // deliberately no restore()
        });
        let pushes = cmds.iter().filter(|c| matches!(c, Command::PushState { .. })).count();
        let pops = cmds.iter().filter(|c| matches!(c, Command::PopState)).count();
        assert_eq!(pushes, 2, "translate and rotate each open a frame");
        assert_eq!(pops, 2, "and finish() closes BOTH -- got {cmds:?}");
    }

    /// `restore` closes exactly one frame, and an extra `restore` is harmless
    /// rather than an underflow.
    #[test]
    fn restore_closes_one_frame_and_an_extra_is_harmless() {
        let cmds = drawn(|c| {
            c.translate(1.0, 1.0);
            c.restore();
            c.restore(); // one too many
        });
        assert_eq!(cmds.iter().filter(|c| matches!(c, Command::PushState { .. })).count(), 1);
        assert_eq!(cmds.iter().filter(|c| matches!(c, Command::PopState)).count(), 1,
                   "an extra restore must not pop a frame this context never pushed");
    }

    /// An `arc` becomes the arc PRIMITIVE, not a path — `Painter` has one, and
    /// using it keeps a handle dot exact rather than bézier-approximated.
    #[test]
    fn an_arc_becomes_the_arc_primitive() {
        let cmds = drawn(|c| {
            c.set_fill_style_str("#ffffff");
            c.begin_path();
            c.arc(10.0, 20.0, 4.0, 0.0, std::f64::consts::TAU);
            c.fill();
        });
        assert_eq!(cmds.len(), 1);
        let Command::FillEllipseArc { arc, .. } = &cmds[0] else { panic!("{cmds:?}") };
        assert_eq!((arc.cx, arc.cy, arc.rx, arc.ry), (10.0, 20.0, 4.0, 4.0));
    }

    /// ⛔ `begin_path` CLEARS A PENDING ARC TOO. Without that, a handle drawn in
    /// one pass would be repainted in the next — a stale primitive is the kind
    /// of overlay bug that only shows on the second frame.
    #[test]
    fn begin_path_clears_a_pending_arc() {
        let cmds = drawn(|c| {
            c.begin_path();
            c.arc(0.0, 0.0, 1.0, 0.0, 6.28);
            c.begin_path();
            c.move_to(0.0, 0.0);
            c.line_to(2.0, 0.0);
            c.stroke();
        });
        assert_eq!(cmds.len(), 1, "the abandoned arc must not paint: {cmds:?}");
        assert!(matches!(cmds[0], Command::StrokePath { .. }));
    }
}
