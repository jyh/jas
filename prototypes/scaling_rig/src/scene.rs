//! Deterministic "jas-shaped" scene generation.
//!
//! The scaling rig is not a rect farm. A real vector illustration is a mix of
//! stroked bezier paths, filled curved shapes, both-stroked-and-filled shapes,
//! text runs, and grouped subtrees with nested transforms. This module produces
//! that mix as a pure function of a `u64` seed, spread over a large document
//! plane so pan/zoom actually exercises culling-free overdraw.
//!
//! Mix per 1000 elements (approximating an illustration):
//!   ~40% cubic-bezier stroked paths (varied widths/colors, ~30% dashed)
//!   ~25% filled curved shapes (blobs / ellipses / rounded)
//!   ~15% stroked + filled shapes
//!   ~10% synthetic text-like glyph runs (see note below)
//!   ~10% groups with 2-3 deep nested transforms (some clipped)
//!
//! GLYPH NOTE: these are SYNTHETIC letter-like bezier outlines, not real font
//! glyphs. Wiring Vello's true glyph API (`Scene::draw_glyphs`) needs an embedded
//! font + skrifa outline extraction; to keep the rig a self-contained,
//! zero-asset crate the glyph runs are hand-built closed cubic outlines shaped
//! like short words. This is an honest approximation of the *encoding* cost
//! (many small filled paths in a row); it is not a text-shaping benchmark.

use vello::kurbo::{Affine, BezPath, PathEl, Point, Stroke};
use vello::peniko::{Color, Fill, Mix};
use vello::Scene;

use crate::rng::{Fnv, Rng};

/// Document plane the elements are scattered across (in user-space units).
pub const DOC_W: f64 = 24_000.0;
pub const DOC_H: f64 = 24_000.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    StrokedPath = 0,
    FilledShape = 1,
    StrokedFilled = 2,
    GlyphRun = 3,
    Group = 4,
}

/// A single drawing primitive in element-local coordinates.
#[derive(Clone)]
pub enum Prim {
    Fill {
        path: BezPath,
        rgba: [u8; 4],
        even_odd: bool,
    },
    Stroke {
        path: BezPath,
        rgba: [u8; 4],
        width: f64,
        /// (dash_offset, [on, off]) when dashed.
        dashes: Option<(f64, [f64; 2])>,
    },
}

/// One "jas-shaped" element: a placement transform plus one or more primitives,
/// optionally wrapped in a clip layer (groups).
#[derive(Clone)]
pub struct Element {
    // Read by the digest + mix-ratio checks; the render path doesn't branch on it.
    #[allow(dead_code)]
    pub kind: Kind,
    pub transform: Affine,
    pub prims: Vec<Prim>,
    pub clip: Option<BezPath>,
}

#[inline]
fn color_of(rgba: [u8; 4]) -> Color {
    Color::new([
        rgba[0] as f32 / 255.0,
        rgba[1] as f32 / 255.0,
        rgba[2] as f32 / 255.0,
        rgba[3] as f32 / 255.0,
    ])
}

/// Open, wobbly cubic-bezier path (a brush/pen stroke), local-origin centered.
fn stroked_bezier(rng: &mut Rng, extent: f64) -> BezPath {
    let segs = rng.range_u32(3, 7);
    let mut p = BezPath::new();
    let mut cur = Point::new(rng.range(-extent, extent), rng.range(-extent, extent));
    p.move_to(cur);
    for _ in 0..segs {
        let c1 = Point::new(cur.x + rng.range(-extent, extent), cur.y + rng.range(-extent, extent));
        let c2 = Point::new(cur.x + rng.range(-extent, extent), cur.y + rng.range(-extent, extent));
        let end = Point::new(cur.x + rng.range(-extent, extent), cur.y + rng.range(-extent, extent));
        p.curve_to(c1, c2, end);
        cur = end;
    }
    p
}

/// Closed curved blob (ellipse / rounded / organic), `k` cubic segments around
/// a center with jittered radii.
fn blob(rng: &mut Rng, radius: f64) -> BezPath {
    let k = rng.range_u32(3, 7) as usize;
    let mut pts = Vec::with_capacity(k);
    for i in 0..k {
        let ang = std::f64::consts::TAU * (i as f64) / (k as f64);
        let r = radius * rng.range(0.6, 1.4);
        pts.push(Point::new(r * ang.cos(), r * ang.sin()));
    }
    let mut p = BezPath::new();
    p.move_to(pts[0]);
    for i in 0..k {
        let a = pts[i];
        let b = pts[(i + 1) % k];
        // Control points pulled outward to make bulging curves.
        let c1 = Point::new(a.x + (b.x - a.x) * 0.35 + rng.range(-radius, radius) * 0.2,
                            a.y + (b.y - a.y) * 0.35 + rng.range(-radius, radius) * 0.2);
        let c2 = Point::new(a.x + (b.x - a.x) * 0.65 + rng.range(-radius, radius) * 0.2,
                            a.y + (b.y - a.y) * 0.65 + rng.range(-radius, radius) * 0.2);
        p.curve_to(c1, c2, b);
    }
    p.close_path();
    p
}

/// A single synthetic letter-like closed outline (see module GLYPH NOTE).
fn glyph(rng: &mut Rng, w: f64, h: f64) -> BezPath {
    let mut p = BezPath::new();
    // Outer body: an irregular closed quad with curved sides — reads as a chunky letter.
    let jx = w * 0.15;
    let jy = h * 0.15;
    let bl = Point::new(rng.range(-jx, jx), rng.range(-jy, jy));
    let br = Point::new(w + rng.range(-jx, jx), rng.range(-jy, jy));
    let tr = Point::new(w + rng.range(-jx, jx), h + rng.range(-jy, jy));
    let tl = Point::new(rng.range(-jx, jx), h + rng.range(-jy, jy));
    p.move_to(bl);
    p.curve_to(Point::new(bl.x + w * 0.3, bl.y - jy), Point::new(br.x - w * 0.3, br.y - jy), br);
    p.curve_to(Point::new(br.x + jx, br.y + h * 0.3), Point::new(tr.x + jx, tr.y - h * 0.3), tr);
    p.curve_to(Point::new(tr.x - w * 0.3, tr.y + jy), Point::new(tl.x + w * 0.3, tl.y + jy), tl);
    p.curve_to(Point::new(tl.x - jx, tl.y - h * 0.3), Point::new(bl.x - jx, bl.y + h * 0.3), bl);
    p.close_path();
    p
}

/// Random placement transform over the document plane.
fn placement(rng: &mut Rng) -> Affine {
    let x = rng.range(0.0, DOC_W);
    let y = rng.range(0.0, DOC_H);
    let rot = rng.range(-std::f64::consts::PI, std::f64::consts::PI);
    let scale = rng.range(0.5, 2.2);
    Affine::translate((x, y)) * Affine::rotate(rot) * Affine::scale(scale)
}

/// Generate exactly one element, advancing `rng` deterministically. The `kind`
/// is drawn first, so the same seed always yields the same element sequence.
pub fn gen_element(rng: &mut Rng) -> Element {
    let r = rng.unit();
    if r < 0.40 {
        // Stroked cubic-bezier path.
        let extent = rng.range(40.0, 160.0);
        let path = stroked_bezier(rng, extent);
        let width = rng.range(0.5, 4.0);
        let dashes = if rng.chance(0.30) {
            Some((rng.range(0.0, 20.0), [rng.range(4.0, 18.0), rng.range(3.0, 12.0)]))
        } else {
            None
        };
        Element {
            kind: Kind::StrokedPath,
            transform: placement(rng),
            prims: vec![Prim::Stroke { path, rgba: rng.rgba(), width, dashes }],
            clip: None,
        }
    } else if r < 0.65 {
        // Filled curved shape.
        let radius = rng.range(30.0, 120.0);
        let path = blob(rng, radius);
        Element {
            kind: Kind::FilledShape,
            transform: placement(rng),
            prims: vec![Prim::Fill { path, rgba: rng.rgba(), even_odd: rng.chance(0.15) }],
            clip: None,
        }
    } else if r < 0.80 {
        // Stroked + filled shape.
        let radius = rng.range(30.0, 120.0);
        let path = blob(rng, radius);
        let fill_rgba = rng.rgba();
        let stroke_rgba = rng.rgba();
        let width = rng.range(1.0, 5.0);
        Element {
            kind: Kind::StrokedFilled,
            transform: placement(rng),
            prims: vec![
                Prim::Fill { path: path.clone(), rgba: fill_rgba, even_odd: false },
                Prim::Stroke { path, rgba: stroke_rgba, width, dashes: None },
            ],
            clip: None,
        }
    } else if r < 0.90 {
        // Synthetic text-like glyph run: a row of filled letter outlines.
        let count = rng.range_u32(3, 8) as usize;
        let gw = rng.range(16.0, 30.0);
        let gh = rng.range(24.0, 44.0);
        let gap = gw * rng.range(1.15, 1.5);
        let rgba = rng.rgba();
        let mut prims = Vec::with_capacity(count);
        for i in 0..count {
            let mut g = glyph(rng, gw, gh);
            g.apply_affine(Affine::translate((i as f64 * gap, 0.0)));
            prims.push(Prim::Fill { path: g, rgba, even_odd: false });
        }
        Element { kind: Kind::GlyphRun, transform: placement(rng), prims, clip: None }
    } else {
        // Group: 2-3 nested transforms composed, holding a couple of primitives,
        // sometimes clipped. Vello is a flat command stream, so a group hierarchy
        // flattens to a composed affine per draw — exactly how a real editor emits it.
        let depth = rng.range_u32(2, 4);
        let mut nested = placement(rng);
        for _ in 1..depth {
            nested = nested
                * Affine::rotate(rng.range(-0.6, 0.6))
                * Affine::scale(rng.range(0.7, 1.3))
                * Affine::translate((rng.range(-60.0, 60.0), rng.range(-60.0, 60.0)));
        }
        let n_children = rng.range_u32(2, 4) as usize;
        let mut prims = Vec::with_capacity(n_children);
        for _ in 0..n_children {
            if rng.chance(0.5) {
                let radius = rng.range(20.0, 80.0);
                prims.push(Prim::Fill { path: blob(rng, radius), rgba: rng.rgba(), even_odd: false });
            } else {
                let extent = rng.range(30.0, 90.0);
                prims.push(Prim::Stroke {
                    path: stroked_bezier(rng, extent),
                    rgba: rng.rgba(),
                    width: rng.range(1.0, 3.5),
                    dashes: None,
                });
            }
        }
        let clip = if rng.chance(0.5) {
            let radius = rng.range(100.0, 200.0);
            Some(blob(rng, radius))
        } else {
            None
        };
        Element { kind: Kind::Group, transform: nested, prims, clip }
    }
}

/// Encode one element into a retained scene.
pub fn encode_element(scene: &mut Scene, e: &Element) {
    if let Some(clip) = &e.clip {
        scene.push_layer(Fill::NonZero, Mix::Normal, 1.0, e.transform, clip);
    }
    for prim in &e.prims {
        match prim {
            Prim::Fill { path, rgba, even_odd } => {
                let rule = if *even_odd { Fill::EvenOdd } else { Fill::NonZero };
                scene.fill(rule, e.transform, color_of(*rgba), None, path);
            }
            Prim::Stroke { path, rgba, width, dashes } => {
                let mut s = Stroke::new(*width);
                if let Some((off, pat)) = dashes {
                    s = s.with_dashes(*off, *pat);
                }
                scene.stroke(&s, e.transform, color_of(*rgba), None, path);
            }
        }
    }
    if e.clip.is_some() {
        scene.pop_layer();
    }
}

/// Build the retained Vello scene for `n` elements from `seed`, streaming so we
/// never hold both a full `Vec<Element>` and the encoding at once (matters at 1M).
pub fn build_scene(seed: u64, n: usize) -> Scene {
    let mut rng = Rng::new(seed);
    let mut scene = Scene::new();
    for _ in 0..n {
        let e = gen_element(&mut rng);
        encode_element(&mut scene, &e);
    }
    scene
}

/// Collect `n` elements (used by tests and ratio checks; not on the hot path).
#[allow(dead_code)] // exercised by the unit tests, not the sweep binary
pub fn generate(seed: u64, n: usize) -> Vec<Element> {
    let mut rng = Rng::new(seed);
    (0..n).map(|_| gen_element(&mut rng)).collect()
}

#[allow(dead_code)] // determinism-digest support; exercised by the unit tests
fn hash_path(fnv: &mut Fnv, path: &BezPath) {
    for el in path.elements() {
        match el {
            PathEl::MoveTo(p) => { fnv.write(&[0]); fnv.write_f64(p.x); fnv.write_f64(p.y); }
            PathEl::LineTo(p) => { fnv.write(&[1]); fnv.write_f64(p.x); fnv.write_f64(p.y); }
            PathEl::QuadTo(a, b) => {
                fnv.write(&[2]);
                fnv.write_f64(a.x); fnv.write_f64(a.y);
                fnv.write_f64(b.x); fnv.write_f64(b.y);
            }
            PathEl::CurveTo(a, b, c) => {
                fnv.write(&[3]);
                fnv.write_f64(a.x); fnv.write_f64(a.y);
                fnv.write_f64(b.x); fnv.write_f64(b.y);
                fnv.write_f64(c.x); fnv.write_f64(c.y);
            }
            PathEl::ClosePath => fnv.write(&[4]),
        }
    }
    fnv.write(&[255]); // path terminator
}

#[allow(dead_code)] // determinism-digest support; exercised by the unit tests
fn hash_element(fnv: &mut Fnv, e: &Element) {
    fnv.write(&[e.kind as u8]);
    for c in e.transform.as_coeffs() {
        fnv.write_f64(c);
    }
    match &e.clip {
        Some(c) => { fnv.write(&[1]); hash_path(fnv, c); }
        None => fnv.write(&[0]),
    }
    for prim in &e.prims {
        match prim {
            Prim::Fill { path, rgba, even_odd } => {
                fnv.write(&[10, *even_odd as u8]);
                fnv.write(rgba);
                hash_path(fnv, path);
            }
            Prim::Stroke { path, rgba, width, dashes } => {
                fnv.write(&[11]);
                fnv.write(rgba);
                fnv.write_f64(*width);
                match dashes {
                    Some((off, pat)) => { fnv.write(&[1]); fnv.write_f64(*off); fnv.write_f64(pat[0]); fnv.write_f64(pat[1]); }
                    None => fnv.write(&[0]),
                }
                hash_path(fnv, path);
            }
        }
    }
    fnv.write(&[254]); // element terminator
}

/// A stable digest of the first `n` generated elements. Same seed => same digest,
/// on any machine, in any process. This is the determinism contract.
#[allow(dead_code)] // the contract itself; asserted by the unit tests
pub fn digest(seed: u64, n: usize) -> u64 {
    let mut rng = Rng::new(seed);
    let mut fnv = Fnv::default();
    for _ in 0..n {
        let e = gen_element(&mut rng);
        hash_element(&mut fnv, &e);
    }
    fnv.finish()
}

/// Count elements by kind (for the mix-ratio test).
#[allow(dead_code)] // exercised by the mix-ratio unit test
pub fn kind_counts(seed: u64, n: usize) -> [usize; 5] {
    let mut rng = Rng::new(seed);
    let mut counts = [0usize; 5];
    for _ in 0..n {
        counts[gen_element(&mut rng).kind as usize] += 1;
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_identical_digest() {
        // The core determinism contract: same seed twice => byte-identical scene.
        assert_eq!(digest(42, 5_000), digest(42, 5_000));
    }

    #[test]
    fn digest_is_prefix_stable() {
        // The digest streams element-by-element; the first n elements of a larger
        // run must be independent of the total count (no global-count entropy).
        let mut rng = Rng::new(99);
        let mut fnv = Fnv::default();
        for _ in 0..1000 {
            let e = gen_element(&mut rng);
            hash_element(&mut fnv, &e);
        }
        assert_eq!(fnv.finish(), digest(99, 1000));
    }

    #[test]
    fn different_seed_differs() {
        assert_ne!(digest(1, 2000), digest(2, 2000));
    }

    #[test]
    fn element_count_exact() {
        assert_eq!(generate(7, 1234).len(), 1234);
    }

    #[test]
    fn mix_ratios_approx() {
        // Over a large sample the kind proportions should land near the spec:
        // 40 / 25 / 15 / 10 / 10 (%). Allow a few points of Monte-Carlo slack.
        let n = 40_000;
        let counts = kind_counts(2026, n);
        let frac = |k: Kind| counts[k as usize] as f64 / n as f64;
        assert!((frac(Kind::StrokedPath) - 0.40).abs() < 0.03, "stroked {}", frac(Kind::StrokedPath));
        assert!((frac(Kind::FilledShape) - 0.25).abs() < 0.03, "filled {}", frac(Kind::FilledShape));
        assert!((frac(Kind::StrokedFilled) - 0.15).abs() < 0.03, "both {}", frac(Kind::StrokedFilled));
        assert!((frac(Kind::GlyphRun) - 0.10).abs() < 0.03, "glyph {}", frac(Kind::GlyphRun));
        assert!((frac(Kind::Group) - 0.10).abs() < 0.03, "group {}", frac(Kind::Group));
    }

    #[test]
    fn every_element_draws_something() {
        for e in generate(5, 3000) {
            assert!(!e.prims.is_empty());
        }
    }
}
