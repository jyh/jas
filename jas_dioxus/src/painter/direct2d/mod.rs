//! Direct2D backend for the ratified Painter seam (B1).
//!
//! Built after B1's capability study concluded PROCEED: Direct2D + DirectWrite
//! express all 14 methods. The two capabilities deliberately NOT here are masks
//! and the 15 non-Normal blend modes -- both blocked on the element-bracket
//! ruling, because the frozen contract has leaf-paint verbs and no element verb.

pub mod convert;
pub mod device;
pub mod geometry;
pub mod painter;
pub mod replay;
// Route (b): a D2D context over a caller-owned DXGI surface. This is the whole
// gap between headless B1 and a live SwapChainPanel; see the module's own note.
pub mod surface;
pub mod text;
