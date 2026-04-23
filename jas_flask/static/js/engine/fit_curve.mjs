// Bezier curve fitting using the Schneider algorithm.
//
// Port of jas/algorithms/fit_curve.py. Fits a sequence of 2D points
// to a piecewise cubic Bezier spline. Used by the Pencil and
// Paintbrush tools to convert raw drag samples into a smooth path.
//
// Reference: Philip J. Schneider, "An Algorithm for Automatically
// Fitting Digitized Curves," Graphics Gems I, 1990.

const MAX_ITERATIONS = 4;

/**
 * Fit a cubic Bezier spline to a sequence of [x, y] points.
 *
 * @param {Array<[number, number]>} points  Polyline samples.
 * @param {number} error                    RMS deviation tolerance (pt).
 * @returns {Array<[number, number, number, number, number, number, number, number]>}
 *   List of 8-tuples (p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y).
 */
export function fitCurve(points, error) {
  if (!Array.isArray(points) || points.length < 2) return [];
  const tHat1 = leftTangent(points, 0);
  const tHat2 = rightTangent(points, points.length - 1);
  const result = [];
  fitCubic(points, 0, points.length - 1, tHat1, tHat2, error, result);
  return result;
}

function fitCubic(d, first, last, tHat1, tHat2, error, result) {
  const nPts = last - first + 1;

  if (nPts === 2) {
    const dist = distance(d[first], d[last]) / 3.0;
    result.push([
      d[first][0], d[first][1],
      d[first][0] + tHat1[0] * dist, d[first][1] + tHat1[1] * dist,
      d[last][0] + tHat2[0] * dist, d[last][1] + tHat2[1] * dist,
      d[last][0], d[last][1],
    ]);
    return;
  }

  let u = chordLengthParameterize(d, first, last);
  let bezCurve = generateBezier(d, first, last, u, tHat1, tHat2);
  let { maxError, splitPoint } = computeMaxError(d, first, last, bezCurve, u);

  if (maxError < error) {
    result.push(bezCurve);
    return;
  }

  const iterationError = error * error;
  if (maxError < iterationError) {
    for (let i = 0; i < MAX_ITERATIONS; i++) {
      const uPrime = reparameterize(d, first, last, u, bezCurve);
      bezCurve = generateBezier(d, first, last, uPrime, tHat1, tHat2);
      const m = computeMaxError(d, first, last, bezCurve, uPrime);
      maxError = m.maxError;
      splitPoint = m.splitPoint;
      if (maxError < error) {
        result.push(bezCurve);
        return;
      }
      u = uPrime;
    }
  }

  const tHatCenter = centerTangent(d, splitPoint);
  fitCubic(d, first, splitPoint, tHat1, tHatCenter, error, result);
  const negCenter = [-tHatCenter[0], -tHatCenter[1]];
  fitCubic(d, splitPoint, last, negCenter, tHat2, error, result);
}

function generateBezier(d, first, last, uPrime, tHat1, tHat2) {
  const nPts = last - first + 1;
  const A = new Array(nPts);
  for (let i = 0; i < nPts; i++) {
    A[i] = [scale(tHat1, B1(uPrime[i])), scale(tHat2, B2(uPrime[i]))];
  }
  const C = [[0, 0], [0, 0]];
  const X = [0, 0];
  for (let i = 0; i < nPts; i++) {
    C[0][0] += dot(A[i][0], A[i][0]);
    C[0][1] += dot(A[i][0], A[i][1]);
    C[1][0] = C[0][1];
    C[1][1] += dot(A[i][1], A[i][1]);
    const tmp = sub(
      d[first + i],
      add(
        scale(d[first], B0(uPrime[i])),
        add(
          scale(d[first], B1(uPrime[i])),
          add(
            scale(d[last], B2(uPrime[i])),
            scale(d[last], B3(uPrime[i])),
          ),
        ),
      ),
    );
    X[0] += dot(A[i][0], tmp);
    X[1] += dot(A[i][1], tmp);
  }
  const detC0C1 = C[0][0] * C[1][1] - C[1][0] * C[0][1];
  const detC0X = C[0][0] * X[1] - C[1][0] * X[0];
  const detXC1 = X[0] * C[1][1] - X[1] * C[0][1];

  const alphaL = detC0C1 === 0 ? 0 : detXC1 / detC0C1;
  const alphaR = detC0C1 === 0 ? 0 : detC0X / detC0C1;

  const segLength = distance(d[first], d[last]);
  const epsilon = 1e-6 * segLength;

  if (alphaL < epsilon || alphaR < epsilon) {
    const dist = segLength / 3.0;
    return [
      d[first][0], d[first][1],
      d[first][0] + tHat1[0] * dist, d[first][1] + tHat1[1] * dist,
      d[last][0] + tHat2[0] * dist, d[last][1] + tHat2[1] * dist,
      d[last][0], d[last][1],
    ];
  }
  return [
    d[first][0], d[first][1],
    d[first][0] + tHat1[0] * alphaL, d[first][1] + tHat1[1] * alphaL,
    d[last][0] + tHat2[0] * alphaR, d[last][1] + tHat2[1] * alphaR,
    d[last][0], d[last][1],
  ];
}

function reparameterize(d, first, last, u, bezCurve) {
  const Q = [
    [bezCurve[0], bezCurve[1]],
    [bezCurve[2], bezCurve[3]],
    [bezCurve[4], bezCurve[5]],
    [bezCurve[6], bezCurve[7]],
  ];
  const out = new Array(last - first + 1);
  for (let i = first; i <= last; i++) {
    out[i - first] = newtonRaphson(Q, d[i], u[i - first]);
  }
  return out;
}

function newtonRaphson(Q, P, u) {
  const Qu = bezierII(3, Q, u);

  const Q1 = [
    [(Q[1][0] - Q[0][0]) * 3, (Q[1][1] - Q[0][1]) * 3],
    [(Q[2][0] - Q[1][0]) * 3, (Q[2][1] - Q[1][1]) * 3],
    [(Q[3][0] - Q[2][0]) * 3, (Q[3][1] - Q[2][1]) * 3],
  ];
  const Q2 = [
    [(Q1[1][0] - Q1[0][0]) * 2, (Q1[1][1] - Q1[0][1]) * 2],
    [(Q1[2][0] - Q1[1][0]) * 2, (Q1[2][1] - Q1[1][1]) * 2],
  ];

  const Q1u = bezierII(2, Q1, u);
  const Q2u = bezierII(1, Q2, u);

  const numerator =
    (Qu[0] - P[0]) * Q1u[0] + (Qu[1] - P[1]) * Q1u[1];
  const denominator =
    Q1u[0] * Q1u[0] +
    Q1u[1] * Q1u[1] +
    (Qu[0] - P[0]) * Q2u[0] +
    (Qu[1] - P[1]) * Q2u[1];

  if (denominator === 0) return u;
  return u - numerator / denominator;
}

function bezierII(degree, V, t) {
  const Vt = V.map((p) => [p[0], p[1]]);
  for (let i = 1; i <= degree; i++) {
    for (let j = 0; j <= degree - i; j++) {
      Vt[j] = [
        (1 - t) * Vt[j][0] + t * Vt[j + 1][0],
        (1 - t) * Vt[j][1] + t * Vt[j + 1][1],
      ];
    }
  }
  return Vt[0];
}

function computeMaxError(d, first, last, bezCurve, u) {
  const Q = [
    [bezCurve[0], bezCurve[1]],
    [bezCurve[2], bezCurve[3]],
    [bezCurve[4], bezCurve[5]],
    [bezCurve[6], bezCurve[7]],
  ];
  let splitPoint = ((last - first + 1) / 2) | 0;
  let maxDist = 0.0;
  for (let i = first + 1; i < last; i++) {
    const P = bezierII(3, Q, u[i - first]);
    const dx = P[0] - d[i][0];
    const dy = P[1] - d[i][1];
    const dd = dx * dx + dy * dy;
    if (dd >= maxDist) {
      maxDist = dd;
      splitPoint = i;
    }
  }
  return { maxError: maxDist, splitPoint };
}

function chordLengthParameterize(d, first, last) {
  const u = new Array(last - first + 1).fill(0);
  for (let i = first + 1; i <= last; i++) {
    u[i - first] = u[i - first - 1] + distance(d[i], d[i - 1]);
  }
  const total = u[last - first];
  if (total > 0) {
    for (let i = first + 1; i <= last; i++) {
      u[i - first] /= total;
    }
  }
  return u;
}

function leftTangent(d, end)   { return normalize(sub(d[end + 1], d[end])); }
function rightTangent(d, end)  { return normalize(sub(d[end - 1], d[end])); }
function centerTangent(d, c)   {
  const v1 = sub(d[c - 1], d[c]);
  const v2 = sub(d[c], d[c + 1]);
  return normalize([(v1[0] + v2[0]) / 2, (v1[1] + v2[1]) / 2]);
}

// Bernstein basis
function B0(u) { const t = 1 - u; return t * t * t; }
function B1(u) { const t = 1 - u; return 3 * u * t * t; }
function B2(u) { const t = 1 - u; return 3 * u * u * t; }
function B3(u) { return u * u * u; }

// Vector helpers
function add(a, b)   { return [a[0] + b[0], a[1] + b[1]]; }
function sub(a, b)   { return [a[0] - b[0], a[1] - b[1]]; }
function scale(v, s) { return [v[0] * s, v[1] * s]; }
function dot(a, b)   { return a[0] * b[0] + a[1] * b[1]; }
function distance(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1]); }
function normalize(v) {
  const len = Math.hypot(v[0], v[1]);
  if (len === 0) return v;
  return [v[0] / len, v[1] / len];
}
