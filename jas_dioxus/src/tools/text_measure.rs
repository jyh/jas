//! Re-export shim. The measurer moved to `crate::text_measure` (crate root,
//! NOT `feature = "web"`-gated) so `Element::bounds` can use the one shared
//! width law in a native build. Every existing
//! `crate::tools::text_measure::...` path still resolves through here.

pub use crate::text_measure::*;
