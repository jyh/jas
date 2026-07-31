pub mod align;
pub mod arrangement;
pub mod arrow_trim;
pub mod gradient_remap;
pub mod boolean;
pub mod calligraphic_outline;
pub mod art_along_path;
pub mod pattern_along_path;
pub mod bristle_stroke;
pub mod dash_renderer;
pub mod fit_curve;
pub mod simplify;
pub mod hit_test;
pub mod boolean_normalize;
pub mod planar;
pub mod path_text_layout;
// Pencil shape recognition; consumed by the algorithm_roundtrip
// cross-language test binary, not the main app lib.
#[allow(dead_code)]
pub mod shape_recognize;
pub mod corpus_text_measure;
// Region metrics for the boolean conformance harness. Every item is
// test/harness-only by design — the app never measures a PolygonSet — so
// the allow is module-wide rather than per item.
#[allow(dead_code)]
pub mod polygon_metrics;
pub mod text_layout;
pub mod text_layout_paragraph;
// NOT gated: only three DRAWING functions inside need a canvas context, and
// they carry the gate themselves. All six of its tests exercise the
// width-profile arithmetic, which is a document law every port must agree on.
pub mod offset_path;
pub mod hyphenator;
pub mod knuth_plass;
pub mod layers_filter;
pub mod magic_wand;
pub mod eyedropper;
pub mod transform_apply;
