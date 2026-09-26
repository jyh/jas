//! Brush-library JSON parsers: a library entry (BRUSHES.md §Brush libraries)
//! into the parameter struct its stroke algorithm takes.
//!
//! Lifted verbatim from `canvas/render.rs`, which is web-gated, so the one
//! reader the native build has (`brush_preview`, for the panel plan) can reach
//! them. The canvas renderer imports them from here.

use super::art_along_path::ArtBrush;
use super::bristle_stroke::BristleBrush;
use super::pattern_along_path::PatternBrush;

/// Build a `BristleBrush` from the library JSON. Shared with the
/// Brushes-panel `brush_preview` thumbnail.
pub(crate) fn bristle_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<BristleBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("bristle") {
        return None;
    }
    Some(BristleBrush {
        size: brush.get("size").and_then(|v| v.as_f64()).unwrap_or(3.0),
        density: brush.get("density").and_then(|v| v.as_f64()).unwrap_or(50.0),
        thickness: brush.get("thickness").and_then(|v| v.as_f64()).unwrap_or(30.0),
        opacity: brush.get("opacity").and_then(|v| v.as_f64()).unwrap_or(30.0),
        stroke_weight,
    })
}

/// Parse a `{ width, height, polygons: [[[x,y],...],...] }` object into a
/// (width, height, polygons) tuple. Shared by the art / pattern parsers.
pub(crate) fn parse_inline_artwork(
    aw: &serde_json::Value,
) -> Option<(f64, f64, Vec<Vec<(f64, f64)>>)> {
    let width = aw.get("width").and_then(|v| v.as_f64())?;
    let height = aw.get("height").and_then(|v| v.as_f64())?;
    let polys = aw.get("polygons").and_then(|v| v.as_array())?;
    let polygons: Vec<Vec<(f64, f64)>> = polys
        .iter()
        .filter_map(|p| {
            p.as_array().map(|pts| {
                pts.iter()
                    .filter_map(|pt| {
                        let a = pt.as_array()?;
                        Some((a.first()?.as_f64()?, a.get(1)?.as_f64()?))
                    })
                    .collect()
            })
        })
        .collect();
    Some((width, height, polygons))
}

/// Build a `PatternBrush` from the library JSON. Side tile stored inline as
/// `tiles: { side: { width, height, polygons } }` (Phase 1: side only).
/// Shared with the Brushes-panel `brush_preview` thumbnail.
pub(crate) fn pattern_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<PatternBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("pattern") {
        return None;
    }
    let side = brush.get("tiles")?.get("side")?;
    let (width, height, polygons) = parse_inline_artwork(side)?;
    Some(PatternBrush {
        tile_width: width,
        tile_height: height,
        side: polygons,
        scale: brush.get("scale").and_then(|v| v.as_f64()).unwrap_or(100.0),
        spacing: brush.get("spacing").and_then(|v| v.as_f64()).unwrap_or(0.0),
        flip_across: brush.get("flip_across").and_then(|v| v.as_bool()).unwrap_or(false),
        flip_along: brush.get("flip_along").and_then(|v| v.as_bool()).unwrap_or(false),
        stroke_weight,
    })
}

/// Build an `ArtBrush` from the library JSON. Artwork is stored inline as
/// `artwork: { width, height, polygons: [[[x,y], ...], ...] }` (BRUSHES.md
/// §Brush libraries; inline polygon form for Phase 1). Shared with the
/// Brushes-panel `brush_preview` thumbnail.
pub(crate) fn art_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<ArtBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("art") {
        return None;
    }
    let aw = brush.get("artwork")?;
    let width = aw.get("width").and_then(|v| v.as_f64())?;
    let height = aw.get("height").and_then(|v| v.as_f64())?;
    let polys = aw.get("polygons").and_then(|v| v.as_array())?;
    let artwork: Vec<Vec<(f64, f64)>> = polys
        .iter()
        .filter_map(|p| {
            p.as_array().map(|pts| {
                pts.iter()
                    .filter_map(|pt| {
                        let a = pt.as_array()?;
                        Some((a.first()?.as_f64()?, a.get(1)?.as_f64()?))
                    })
                    .collect()
            })
        })
        .collect();
    Some(ArtBrush {
        artwork_width: width,
        artwork_height: height,
        artwork,
        scale: brush.get("scale").and_then(|v| v.as_f64()).unwrap_or(100.0),
        flip_across: brush.get("flip_across").and_then(|v| v.as_bool()).unwrap_or(false),
        flip_along: brush.get("flip_along").and_then(|v| v.as_bool()).unwrap_or(false),
        stroke_weight,
    })
}
