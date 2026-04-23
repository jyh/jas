// Tests for the JS port of fit_curve. Mirrors
// jas/algorithms/fit_curve_test.py.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { fitCurve } from "../../static/js/engine/fit_curve.mjs";

function approxEq(a, b, tol = 1e-9) {
  return Math.abs(a - b) < tol;
}
function pointApproxEq(a, b, tol = 1e-9) {
  return approxEq(a[0], b[0], tol) && approxEq(a[1], b[1], tol);
}

describe("fitCurve — degenerate input", () => {
  it("empty returns empty", () => {
    assert.deepEqual(fitCurve([], 1.0), []);
  });
  it("single point returns empty", () => {
    assert.deepEqual(fitCurve([[0, 0]], 1.0), []);
  });
  it("two points returns one segment", () => {
    const r = fitCurve([[0, 0], [10, 0]], 1.0);
    assert.equal(r.length, 1);
  });
});

describe("fitCurve — endpoints preserved", () => {
  it("two points preserve endpoints", () => {
    const pts = [[0, 0], [10, 0]];
    const seg = fitCurve(pts, 1.0)[0];
    assert.ok(pointApproxEq([seg[0], seg[1]], pts[0]));
    assert.ok(pointApproxEq([seg[6], seg[7]], pts[1]));
  });

  it("quarter-arc preserves endpoints", () => {
    const pts = [];
    for (let i = 0; i <= 20; i++) {
      const a = (i / 20) * (Math.PI / 2);
      pts.push([10 * Math.cos(a), 10 * Math.sin(a)]);
    }
    const r = fitCurve(pts, 0.5);
    assert.ok(r.length > 0);
    assert.ok(pointApproxEq([r[0][0], r[0][1]], pts[0]));
    assert.ok(pointApproxEq([r[r.length - 1][6], r[r.length - 1][7]], pts[pts.length - 1]));
  });
});

describe("fitCurve — continuity", () => {
  it("segments are C0 continuous at joins", () => {
    // Wavy line that needs to split into multiple segments at low tol.
    const pts = [];
    for (let i = 0; i < 30; i++) pts.push([i, 5 * Math.sin(i * 0.3)]);
    const r = fitCurve(pts, 0.5);
    assert.ok(r.length >= 2, `expected ≥2 segments, got ${r.length}`);
    for (let i = 0; i < r.length - 1; i++) {
      const endPrev = [r[i][6], r[i][7]];
      const startNext = [r[i + 1][0], r[i + 1][1]];
      assert.ok(
        pointApproxEq(endPrev, startNext),
        `join ${i}: ${JSON.stringify(endPrev)} vs ${JSON.stringify(startNext)}`,
      );
    }
  });
});

describe("fitCurve — error tolerance", () => {
  it("looser tolerance produces fewer or equal segments", () => {
    const pts = [];
    for (let i = 0; i < 30; i++) pts.push([i, 5 * Math.sin(i * 0.3)]);
    const tight = fitCurve(pts, 0.1);
    const loose = fitCurve(pts, 5.0);
    assert.ok(loose.length <= tight.length,
      `loose=${loose.length} > tight=${tight.length}`);
  });
});
