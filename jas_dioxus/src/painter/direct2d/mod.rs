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
pub mod text;
