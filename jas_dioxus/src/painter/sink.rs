//! [`NoOpPainter`] — a [`Painter`] that does nothing. Used by the R10 bench to
//! measure scene-BUILD cost with rendering subtracted out: the difference
//! between "build through NoOpPainter" and "build through RecordingPainter" is
//! the recording overhead, and the NoOp number is the pure traversal/lowering
//! cost the ≤10% perf budget is measured against.
//!
//! It keeps a single call counter so the optimizer cannot delete the build loop
//! entirely (the bench reads the count via `black_box`).

use super::{StrokeAlign, 
    BlendMode, Brush, EllipseArc, FillRule, Mask, Painter, PathCommand, Rect, StrokeStyle, TextRun,
    Transform,
};

/// A do-nothing [`Painter`]. See module docs.
#[derive(Debug, Default)]
pub struct NoOpPainter {
    /// Number of calls received — kept so the build loop has an observable
    /// side effect and cannot be optimized away.
    pub calls: u64,
}

impl NoOpPainter {
    pub fn new() -> Self {
        Self { calls: 0 }
    }
}

impl Painter for NoOpPainter {
    /// A sink refuses nothing: every op is counted and none can fall into an
    /// unimplemented arm, so the narrow question `supports` asks — "does this
    /// EXECUTE here?" — is yes for all of them. It draws nothing either, which
    /// is why this impl is a bench instrument and not a routing target.
    fn supports(&self, _cap: crate::painter::capability::Capability) -> bool {
        true
    }

    fn fill_path(&mut self, _path: &[PathCommand], _winding: FillRule, _brush: &Brush, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn stroke_path(&mut self, _path: &[PathCommand], _brush: &Brush, _stroke: &StrokeStyle, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn fill_rect(&mut self, _rect: Rect, _brush: &Brush, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn stroke_rect(&mut self, _rect: Rect, _brush: &Brush, _stroke: &StrokeStyle, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn fill_ellipse_arc(&mut self, _arc: &EllipseArc, _winding: FillRule, _brush: &Brush, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn stroke_ellipse_arc(&mut self, _arc: &EllipseArc, _brush: &Brush, _stroke: &StrokeStyle, _align: StrokeAlign, _paint_alpha: f64) {
        self.calls += 1;
    }
    fn clip(&mut self, _path: &[PathCommand], _winding: FillRule) {
        self.calls += 1;
    }
    fn push_state(&mut self, _transform: Transform) {
        self.calls += 1;
    }
    fn pop_state(&mut self) {
        self.calls += 1;
    }
    fn push_group(&mut self, _alpha: f64, _blend: BlendMode) {
        self.calls += 1;
    }
    fn pop_group(&mut self) {
        self.calls += 1;
    }
    fn push_mask_layer(&mut self, _mask: Mask) {
        self.calls += 1;
    }
    fn pop_mask_layer(&mut self) {
        self.calls += 1;
    }

    fn push_isolated_layer(&mut self, _alpha: f64, _blend: BlendMode) {
        self.calls += 1;
    }

    fn pop_isolated_layer(&mut self) {
        self.calls += 1;
    }
    fn draw_text_run(&mut self, _run: &TextRun, _brush: &Brush, _paint_alpha: f64) {
        self.calls += 1;
    }
}
