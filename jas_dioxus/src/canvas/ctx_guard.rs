//! `CtxSaveGuard` — RAII balance for the Canvas2D drawing-state stack.
//!
//! Extracted from `canvas::render` so every painter of a canvas context can
//! reach it: the renderer, the arrowhead pass, the tool overlays
//! (`tools/type_tool.rs`, `tools/type_on_path_tool.rs`) and the repaint
//! entry point in `workspace/app_state.rs`. It is a general Canvas2D
//! utility, not a renderer detail, so it lives in its own module with its
//! own tests instead of being buried in the 3000-line render module.

use web_sys::CanvasRenderingContext2d;

/// The Canvas2D drawing-state stack, as the one pair of calls
/// `CtxSaveGuard` balances. Production always uses the web-sys context;
/// the trait exists so the guard's contract is testable on the host —
/// a real `CanvasRenderingContext2d` cannot be constructed under
/// `cargo test` (wasm-bindgen imports are not callable off-wasm), so the
/// unit tests drive the guard through a counting double instead.
pub(crate) trait CtxStateStack {
    /// Push the current drawing state (`ctx.save()`).
    fn push_ctx_state(&self);
    /// Pop the top drawing state (`ctx.restore()`).
    fn pop_ctx_state(&self);
}

impl CtxStateStack for CanvasRenderingContext2d {
    fn push_ctx_state(&self) {
        self.save();
    }
    fn pop_ctx_state(&self) {
        self.restore();
    }
}

/// Balanced `ctx.save()`: the paired `restore()` runs when this guard
/// drops — on ANY scope exit, including early `return`s. Rust's RAII is
/// the `with`-block equivalent: the type system enforces the balance a
/// comment can only request. Motivated by WEDGESTORM (2026-07-25): a
/// brushed-path branch `return`ed between a manual save() and the
/// function-end restore(), leaking one save per brushed frame; every
/// later repaint then compounded the view transform on the leaked state
/// (the receding-artboard cascade).
///
/// Two usage laws, both pinned by unit tests below:
///
/// 1. Bind to a NAMED variable (`let _ctx_guard = ...`). Binding to bare
///    `_` is NOT a binding — the temporary drops at the end of that very
///    statement, restoring on the spot and leaving the "guarded" body
///    running unbalanced. This is the one footgun of the pattern.
/// 2. The guarded span is the binding's SCOPE. When the save must cover
///    less than the enclosing scope (code after the old `restore()` that
///    relies on the popped state), wrap it in an explicit `{ ... }`
///    block — or, for a conditional save, hold an `Option<CtxSaveGuard>`
///    and `drop()` it exactly where the manual `restore()` stood.
pub(crate) struct CtxSaveGuard<'a, C: CtxStateStack>(&'a C);

impl<'a, C: CtxStateStack> CtxSaveGuard<'a, C> {
    pub(crate) fn new(ctx: &'a C) -> Self {
        ctx.push_ctx_state();
        Self(ctx)
    }
}

impl<C: CtxStateStack> Drop for CtxSaveGuard<'_, C> {
    fn drop(&mut self) {
        self.0.pop_ctx_state();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- CtxSaveGuard: the WEDGESTORM class kill -----------------------------
    //
    // A real CanvasRenderingContext2d cannot be built under `cargo test`
    // (its methods are wasm-bindgen imports and are not callable off-wasm),
    // so these drive the guard through `CtxStateStack` with a counting
    // double. What they pin is the guard's OWN contract — one push on
    // construction, one pop on every scope exit — which is exactly the
    // invariant the leaked save() violated. The live-context end of the
    // contract is pinned separately by the `canvas_transform_balance` GUI
    // check, which reads getTransform() across a brushed render + repaints.

    #[derive(Default)]
    struct CountingCtx {
        depth: std::cell::Cell<i32>,
        pushes: std::cell::Cell<u32>,
        pops: std::cell::Cell<u32>,
    }

    impl CtxStateStack for CountingCtx {
        fn push_ctx_state(&self) {
            self.depth.set(self.depth.get() + 1);
            self.pushes.set(self.pushes.get() + 1);
        }
        fn pop_ctx_state(&self) {
            self.depth.set(self.depth.get() - 1);
            self.pops.set(self.pops.get() + 1);
        }
    }

    #[test]
    fn ctx_save_guard_restores_at_scope_end() {
        let c = CountingCtx::default();
        {
            let _ctx_guard = CtxSaveGuard::new(&c);
            assert_eq!(c.depth.get(), 1, "save taken on construction");
        }
        assert_eq!(c.depth.get(), 0, "restored when the scope ended");
        assert_eq!((c.pushes.get(), c.pops.get()), (1, 1));
    }

    #[test]
    fn ctx_save_guard_restores_on_early_return() {
        // The WEDGESTORM shape verbatim: a branch returns from the middle of
        // the guarded span. With a manual save()/end-of-function restore()
        // that path leaked one save per call, and every later repaint
        // compounded the view transform on the leaked state. Drop runs on
        // the early-return path too, so the balance holds.
        fn guarded(c: &CountingCtx, bail: bool) -> &'static str {
            let _ctx_guard = CtxSaveGuard::new(c);
            if bail {
                return "early";
            }
            "end"
        }
        let c = CountingCtx::default();
        assert_eq!(guarded(&c, true), "early");
        assert_eq!(c.depth.get(), 0, "early return still restored");
        assert_eq!(guarded(&c, false), "end");
        assert_eq!(c.depth.get(), 0, "fall-through still restored");
        // Repeat the leak-capable path: a leak of one save per call is what
        // made the cascade advance one copy per frame.
        for _ in 0..16 {
            guarded(&c, true);
        }
        assert_eq!(c.depth.get(), 0, "no drift across repeated frames");
        assert_eq!(c.pushes.get(), c.pops.get());
    }

    #[test]
    fn ctx_save_guard_block_scopes_a_narrow_span() {
        // Usage law 2: an explicit block makes the guarded span exactly the
        // former save/restore span, so code that must run in the POPPED
        // state (selection handles, the mask blit) still does.
        let c = CountingCtx::default();
        {
            let _ctx_guard = CtxSaveGuard::new(&c);
            assert_eq!(c.depth.get(), 1);
        }
        assert_eq!(c.depth.get(), 0, "popped before the trailing code runs");
        assert_eq!(c.pops.get(), 1);
    }

    #[test]
    fn ctx_save_guard_optional_guard_drops_where_restore_stood() {
        // The conditional-save shape (Text v/h-scale, per-tspan frames):
        // `Option<CtxSaveGuard>` — Some only when the save was taken — and
        // an explicit drop() at the old restore() site.
        fn run(c: &CountingCtx, needs_scale: bool) {
            let guard = if needs_scale {
                Some(CtxSaveGuard::new(c))
            } else {
                None
            };
            assert_eq!(c.depth.get(), if needs_scale { 1 } else { 0 });
            drop(guard);
            assert_eq!(c.depth.get(), 0, "back to the parent frame");
        }
        let c = CountingCtx::default();
        run(&c, true);
        run(&c, false);
        assert_eq!((c.pushes.get(), c.pops.get()), (1, 1), "no save when unneeded");
    }

    #[test]
    fn ctx_save_guard_nests() {
        let c = CountingCtx::default();
        let _outer = CtxSaveGuard::new(&c);
        {
            let _inner = CtxSaveGuard::new(&c);
            assert_eq!(c.depth.get(), 2, "nested save");
        }
        assert_eq!(c.depth.get(), 1, "inner popped, outer still held");
        drop(_outer);
        assert_eq!(c.depth.get(), 0);
    }

    #[test]
    fn ctx_save_guard_bare_underscore_drops_immediately() {
        // Usage law 1, the footgun, pinned executably: `let _ = ...` is not
        // a binding. The guard is a temporary that drops at the end of the
        // statement, so the restore lands on the spot and everything after
        // it runs in the parent state — the exact bug the guard exists to
        // prevent, reintroduced by one character.
        let c = CountingCtx::default();
        let _ = CtxSaveGuard::new(&c);
        assert_eq!(c.depth.get(), 0, "bare `_` restored on the spot");
        let _ctx_guard = CtxSaveGuard::new(&c);
        assert_eq!(c.depth.get(), 1, "a NAMED binding holds the save open");
    }
}
