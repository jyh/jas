pub mod align;
pub mod boolean;
pub mod calligraphic_outline;
pub mod dash_renderer;
pub mod fit_curve;
pub mod hit_test;
pub mod boolean_normalize;
pub mod planar;
pub mod path_text_layout;
// Pencil shape recognition; consumed by the algorithm_roundtrip
// cross-language test binary, not the main app lib.
#[allow(dead_code)]
pub mod shape_recognize;
pub mod text_layout;
pub mod text_layout_paragraph;
#[cfg(feature = "web")]
pub mod offset_path;
pub mod hyphenator;
pub mod knuth_plass;
pub mod magic_wand;
pub mod eyedropper;
pub mod transform_apply;
