//! Bezier curve fitting using the Schneider algorithm.
//!
//! Fits a sequence of points to a piecewise cubic Bezier curve.
//! Based on "An Algorithm for Automatically Fitting Digitized Curves"
//! by Philip J. Schneider, Graphics Gems I, 1990.

/// A fitted Bezier segment: (p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y).
pub type BezierSegment = (f64, f64, f64, f64, f64, f64, f64, f64);

const MAX_ITERATIONS: usize = 4;

/// Fit a cubic Bezier spline to a sequence of 2D points.
pub fn fit_curve(points: &[(f64, f64)], error: f64) -> Vec<BezierSegment> {
    if points.len() < 2 {
        return Vec::new();
    }
    let t_hat1 = left_tangent(points, 0);
    let t_hat2 = right_tangent(points, points.len() - 1);
    let mut result = Vec::new();
    fit_cubic(points, 0, points.len() - 1, t_hat1, t_hat2, error, &mut result);
    result
}

fn fit_cubic(
    d: &[(f64, f64)],
    first: usize,
    last: usize,
    t_hat1: (f64, f64),
    t_hat2: (f64, f64),
    error: f64,
    result: &mut Vec<BezierSegment>,
) {
    let n_pts = last - first + 1;

    if n_pts == 2 {
        let dist = distance(d[first], d[last]) / 3.0;
        result.push((
            d[first].0,
            d[first].1,
            d[first].0 + t_hat1.0 * dist,
            d[first].1 + t_hat1.1 * dist,
            d[last].0 + t_hat2.0 * dist,
            d[last].1 + t_hat2.1 * dist,
            d[last].0,
            d[last].1,
        ));
        return;
    }

    let mut u = chord_length_parameterize(d, first, last);
    let mut bez_curve = generate_bezier(d, first, last, &u, t_hat1, t_hat2);
    let (mut max_error, mut split_point) = compute_max_error(d, first, last, &bez_curve, &u);

    if max_error < error {
        result.push(bez_curve);
        return;
    }

    let iteration_error = error * error;
    if max_error < iteration_error {
        for _ in 0..MAX_ITERATIONS {
            let u_prime = reparameterize(d, first, last, &u, &bez_curve);
            bez_curve = generate_bezier(d, first, last, &u_prime, t_hat1, t_hat2);
            let (err, sp) = compute_max_error(d, first, last, &bez_curve, &u_prime);
            max_error = err;
            split_point = sp;
            if max_error < error {
                result.push(bez_curve);
                return;
            }
            u = u_prime;
        }
    }

    let t_hat_center = center_tangent(d, split_point);
    fit_cubic(d, first, split_point, t_hat1, t_hat_center, error, result);
    fit_cubic(
        d,
        split_point,
        last,
        (-t_hat_center.0, -t_hat_center.1),
        t_hat2,
        error,
        result,
    );
}

fn generate_bezier(
    d: &[(f64, f64)],
    first: usize,
    last: usize,
    u_prime: &[f64],
    t_hat1: (f64, f64),
    t_hat2: (f64, f64),
) -> BezierSegment {
    let n_pts = last - first + 1;

    let a: Vec<((f64, f64), (f64, f64))> = (0..n_pts)
        .map(|i| {
            (
                scale(t_hat1, b1(u_prime[i])),
                scale(t_hat2, b2(u_prime[i])),
            )
        })
        .collect();

    let mut c = [[0.0; 2]; 2];
    let mut x = [0.0; 2];

    for i in 0..n_pts {
        c[0][0] += dot(a[i].0, a[i].0);
        c[0][1] += dot(a[i].0, a[i].1);
        c[1][0] = c[0][1];
        c[1][1] += dot(a[i].1, a[i].1);
        let tmp = sub(
            d[first + i],
            add(
                scale(d[first], b0(u_prime[i])),
                add(
                    scale(d[first], b1(u_prime[i])),
                    add(
                        scale(d[last], b2(u_prime[i])),
                        scale(d[last], b3(u_prime[i])),
                    ),
                ),
            ),
        );
        x[0] += dot(a[i].0, tmp);
        x[1] += dot(a[i].1, tmp);
    }

    let det_c0_c1 = c[0][0] * c[1][1] - c[1][0] * c[0][1];
    let det_c0_x = c[0][0] * x[1] - c[1][0] * x[0];
    let det_x_c1 = x[0] * c[1][1] - x[1] * c[0][1];

    let alpha_l = if det_c0_c1 == 0.0 { 0.0 } else { det_x_c1 / det_c0_c1 };
    let alpha_r = if det_c0_c1 == 0.0 { 0.0 } else { det_c0_x / det_c0_c1 };

    let seg_length = distance(d[first], d[last]);
    let epsilon = 1.0e-6 * seg_length;

    if alpha_l < epsilon || alpha_r < epsilon {
        let dist = seg_length / 3.0;
        return (
            d[first].0,
            d[first].1,
            d[first].0 + t_hat1.0 * dist,
            d[first].1 + t_hat1.1 * dist,
            d[last].0 + t_hat2.0 * dist,
            d[last].1 + t_hat2.1 * dist,
            d[last].0,
            d[last].1,
        );
    }

    (
        d[first].0,
        d[first].1,
        d[first].0 + t_hat1.0 * alpha_l,
        d[first].1 + t_hat1.1 * alpha_l,
        d[last].0 + t_hat2.0 * alpha_r,
        d[last].1 + t_hat2.1 * alpha_r,
        d[last].0,
        d[last].1,
    )
}

fn reparameterize(
    d: &[(f64, f64)],
    first: usize,
    last: usize,
    u: &[f64],
    bez_curve: &BezierSegment,
) -> Vec<f64> {
    let pts = [
        (bez_curve.0, bez_curve.1),
        (bez_curve.2, bez_curve.3),
        (bez_curve.4, bez_curve.5),
        (bez_curve.6, bez_curve.7),
    ];
    (first..=last)
        .map(|i| newton_raphson(&pts, d[i], u[i - first]))
        .collect()
}

fn newton_raphson(q: &[(f64, f64)], p: (f64, f64), u: f64) -> f64 {
    let q_u = bezier_ii(3, q, u);

    let q1 = [
        ((q[1].0 - q[0].0) * 3.0, (q[1].1 - q[0].1) * 3.0),
        ((q[2].0 - q[1].0) * 3.0, (q[2].1 - q[1].1) * 3.0),
        ((q[3].0 - q[2].0) * 3.0, (q[3].1 - q[2].1) * 3.0),
    ];
    let q2 = [
        ((q1[1].0 - q1[0].0) * 2.0, (q1[1].1 - q1[0].1) * 2.0),
        ((q1[2].0 - q1[1].0) * 2.0, (q1[2].1 - q1[1].1) * 2.0),
    ];

    let q1_u = bezier_ii(2, &q1, u);
    let q2_u = bezier_ii(1, &q2, u);

    let numerator = (q_u.0 - p.0) * q1_u.0 + (q_u.1 - p.1) * q1_u.1;
    let denominator =
        q1_u.0 * q1_u.0 + q1_u.1 * q1_u.1 + (q_u.0 - p.0) * q2_u.0 + (q_u.1 - p.1) * q2_u.1;

    if denominator == 0.0 {
        return u;
    }
    u - numerator / denominator
}

fn bezier_ii(degree: usize, v: &[(f64, f64)], t: f64) -> (f64, f64) {
    let mut v_temp: Vec<(f64, f64)> = v.to_vec();
    for i in 1..=degree {
        for j in 0..=(degree - i) {
            v_temp[j] = (
                (1.0 - t) * v_temp[j].0 + t * v_temp[j + 1].0,
                (1.0 - t) * v_temp[j].1 + t * v_temp[j + 1].1,
            );
        }
    }
    v_temp[0]
}

fn compute_max_error(
    d: &[(f64, f64)],
    first: usize,
    last: usize,
    bez_curve: &BezierSegment,
    u: &[f64],
) -> (f64, usize) {
    let pts = [
        (bez_curve.0, bez_curve.1),
        (bez_curve.2, bez_curve.3),
        (bez_curve.4, bez_curve.5),
        (bez_curve.6, bez_curve.7),
    ];
    let mut split_point = (last - first + 1) / 2;
    let mut max_dist = 0.0;
    for i in (first + 1)..last {
        let p = bezier_ii(3, &pts, u[i - first]);
        let dx = p.0 - d[i].0;
        let dy = p.1 - d[i].1;
        let dist = dx * dx + dy * dy;
        if dist >= max_dist {
            max_dist = dist;
            split_point = i;
        }
    }
    (max_dist, split_point)
}

fn chord_length_parameterize(d: &[(f64, f64)], first: usize, last: usize) -> Vec<f64> {
    let n = last - first + 1;
    let mut u = vec![0.0; n];
    for i in (first + 1)..=last {
        u[i - first] = u[i - first - 1] + distance(d[i], d[i - 1]);
    }
    let total = u[last - first];
    if total > 0.0 {
        for i in (first + 1)..=last {
            u[i - first] /= total;
        }
    }
    u
}

fn left_tangent(d: &[(f64, f64)], end: usize) -> (f64, f64) {
    normalize(sub(d[end + 1], d[end]))
}

fn right_tangent(d: &[(f64, f64)], end: usize) -> (f64, f64) {
    normalize(sub(d[end - 1], d[end]))
}

fn center_tangent(d: &[(f64, f64)], center: usize) -> (f64, f64) {
    let v1 = sub(d[center - 1], d[center]);
    let v2 = sub(d[center], d[center + 1]);
    normalize(((v1.0 + v2.0) / 2.0, (v1.1 + v2.1) / 2.0))
}

// Bernstein basis functions
fn b0(u: f64) -> f64 {
    let t = 1.0 - u;
    t * t * t
}

fn b1(u: f64) -> f64 {
    let t = 1.0 - u;
    3.0 * u * t * t
}

fn b2(u: f64) -> f64 {
    let t = 1.0 - u;
    3.0 * u * u * t
}

fn b3(u: f64) -> f64 {
    u * u * u
}

// Vector helpers
fn add(a: (f64, f64), b: (f64, f64)) -> (f64, f64) {
    (a.0 + b.0, a.1 + b.1)
}

fn sub(a: (f64, f64), b: (f64, f64)) -> (f64, f64) {
    (a.0 - b.0, a.1 - b.1)
}

fn scale(v: (f64, f64), s: f64) -> (f64, f64) {
    (v.0 * s, v.1 * s)
}

fn dot(a: (f64, f64), b: (f64, f64)) -> f64 {
    a.0 * b.0 + a.1 * b.1
}

fn distance(a: (f64, f64), b: (f64, f64)) -> f64 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

fn normalize(v: (f64, f64)) -> (f64, f64) {
    let length = (v.0 * v.0 + v.1 * v.1).sqrt();
    if length == 0.0 {
        return v;
    }
    (v.0 / length, v.1 / length)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Sample a cubic Bezier segment at parameter t.
    fn bezier_at(seg: BezierSegment, t: f64) -> (f64, f64) {
        let (p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y) = seg;
        let mt = 1.0 - t;
        let b0 = mt * mt * mt;
        let b1 = 3.0 * t * mt * mt;
        let b2 = 3.0 * t * t * mt;
        let b3 = t * t * t;
        (
            b0 * p1x + b1 * c1x + b2 * c2x + b3 * p2x,
            b0 * p1y + b1 * c1y + b2 * c2y + b3 * p2y,
        )
    }

    fn approx_eq(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    fn point_approx_eq(a: (f64, f64), b: (f64, f64), tol: f64) -> bool {
        approx_eq(a.0, b.0, tol) && approx_eq(a.1, b.1, tol)
    }

    // ---- Degenerate input ----

    #[test]
    fn fit_empty_returns_empty() {
        assert!(fit_curve(&[], 1.0).is_empty());
    }

    #[test]
    fn fit_single_point_returns_empty() {
        assert!(fit_curve(&[(0.0, 0.0)], 1.0).is_empty());
    }

    #[test]
    fn fit_two_points_returns_one_segment() {
        let r = fit_curve(&[(0.0, 0.0), (10.0, 0.0)], 1.0);
        assert_eq!(r.len(), 1);
    }

    // ---- Endpoints preserved ----

    #[test]
    fn fit_two_points_endpoints_preserved() {
        let pts: &[(f64, f64)] = &[(0.0, 0.0), (10.0, 0.0)];
        let r = fit_curve(pts, 1.0);
        let seg = r[0];
        assert!(point_approx_eq((seg.0, seg.1), pts[0], 1e-9));
        assert!(point_approx_eq((seg.6, seg.7), *pts.last().unwrap(), 1e-9));
    }

    #[test]
    fn fit_curve_endpoints_preserved_arc() {
        // Quarter circle arc, 20 sample points.
        let pts: Vec<(f64, f64)> = (0..=20)
            .map(|i| {
                let t = i as f64 / 20.0 * std::f64::consts::FRAC_PI_2;
                (10.0 * t.cos(), 10.0 * t.sin())
            })
            .collect();
        let r = fit_curve(&pts, 0.5);
        assert!(!r.is_empty());
        assert!(point_approx_eq((r[0].0, r[0].1), pts[0], 1e-9));
        let last = r[r.len() - 1];
        assert!(point_approx_eq((last.6, last.7), *pts.last().unwrap(), 1e-9));
    }

    // ---- Continuity at segment joins ----

    #[test]
    fn fit_segments_are_c0_continuous() {
        // S-curve: 30 points along sin(x).
        let pts: Vec<(f64, f64)> = (0..30)
            .map(|i| {
                let x = i as f64;
                (x, 5.0 * (x * 0.3).sin())
            })
            .collect();
        let r = fit_curve(&pts, 0.5);
        assert!(r.len() >= 2, "expected at least 2 segments, got {}", r.len());
        for w in r.windows(2) {
            let end_prev = (w[0].6, w[0].7);
            let start_next = (w[1].0, w[1].1);
            assert!(
                point_approx_eq(end_prev, start_next, 1e-9),
                "segment join not C0: {:?} vs {:?}",
                end_prev,
                start_next
            );
        }
    }

    // ---- Approximation quality ----

    #[test]
    fn fit_two_points_segment_passes_through_endpoints() {
        let pts: &[(f64, f64)] = &[(0.0, 0.0), (100.0, 50.0)];
        let r = fit_curve(pts, 1.0);
        let seg = r[0];
        let p_at_0 = bezier_at(seg, 0.0);
        let p_at_1 = bezier_at(seg, 1.0);
        assert!(point_approx_eq(p_at_0, pts[0], 1e-9));
        assert!(point_approx_eq(p_at_1, pts[1], 1e-9));
    }

    #[test]
    fn fit_curve_input_points_within_error_tolerance() {
        // For a smooth input, every input point should lie within `error`
        // of *some* sample of the fitted curve. We approximate by sampling
        // the fit densely and finding the closest sample.
        let pts: Vec<(f64, f64)> = (0..15)
            .map(|i| {
                let x = i as f64;
                (x, 0.1 * x * x)
            })
            .collect();
        let error = 1.0;
        let segs = fit_curve(&pts, error);
        let samples_per_seg = 100;
        let samples: Vec<(f64, f64)> = segs
            .iter()
            .flat_map(|&seg| {
                (0..=samples_per_seg).map(move |i| {
                    bezier_at(seg, i as f64 / samples_per_seg as f64)
                })
            })
            .collect();
        for &p in &pts {
            let min_dist = samples
                .iter()
                .map(|&s| ((s.0 - p.0).powi(2) + (s.1 - p.1).powi(2)).sqrt())
                .fold(f64::INFINITY, f64::min);
            assert!(
                min_dist <= error * 2.0,
                "point {:?} too far from fitted curve: dist {}",
                p,
                min_dist
            );
        }
    }

    // ---- Error parameter affects segment count ----

    #[test]
    fn tighter_error_gives_at_least_as_many_segments() {
        let pts: Vec<(f64, f64)> = (0..50)
            .map(|i| {
                let x = i as f64 * 0.5;
                (x, 5.0 * (x * 0.5).sin())
            })
            .collect();
        let loose = fit_curve(&pts, 5.0);
        let tight = fit_curve(&pts, 0.1);
        assert!(
            tight.len() >= loose.len(),
            "tight={} loose={}",
            tight.len(),
            loose.len()
        );
    }

    // ---- Specific shapes ----

    #[test]
    fn fit_straight_line_collinear_points() {
        // 10 evenly spaced collinear points should fit with 1 segment.
        let pts: Vec<(f64, f64)> = (0..10).map(|i| (i as f64, 2.0 * i as f64)).collect();
        let r = fit_curve(&pts, 1.0);
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn fit_horizontal_line() {
        let pts: Vec<(f64, f64)> = (0..10).map(|i| (i as f64, 5.0)).collect();
        let r = fit_curve(&pts, 1.0);
        assert_eq!(r.len(), 1);
        assert!(point_approx_eq((r[0].0, r[0].1), (0.0, 5.0), 1e-9));
        assert!(point_approx_eq((r[0].6, r[0].7), (9.0, 5.0), 1e-9));
    }

    #[test]
    fn fit_vertical_line() {
        let pts: Vec<(f64, f64)> = (0..10).map(|i| (3.0, i as f64)).collect();
        let r = fit_curve(&pts, 1.0);
        assert_eq!(r.len(), 1);
        assert!(point_approx_eq((r[0].0, r[0].1), (3.0, 0.0), 1e-9));
        assert!(point_approx_eq((r[0].6, r[0].7), (3.0, 9.0), 1e-9));
    }

    #[test]
    fn fit_circular_arc_returns_some_segments() {
        // Half circle, 60 points.
        let pts: Vec<(f64, f64)> = (0..=60)
            .map(|i| {
                let t = i as f64 / 60.0 * std::f64::consts::PI;
                (50.0 * t.cos(), 50.0 * t.sin())
            })
            .collect();
        let r = fit_curve(&pts, 0.5);
        assert!(!r.is_empty());
        assert!(r.len() <= pts.len());
    }

    #[test]
    fn fit_two_coincident_points_does_not_panic() {
        let _ = fit_curve(&[(5.0, 5.0), (5.0, 5.0)], 1.0);
    }
}
