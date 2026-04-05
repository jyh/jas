"""Bezier curve fitting using the Schneider algorithm.

Fits a sequence of points to a piecewise cubic Bezier curve.
Based on "An Algorithm for Automatically Fitting Digitized Curves"
by Philip J. Schneider, Graphics Gems I, 1990.
"""

from __future__ import annotations

import math


def fit_curve(
    points: list[tuple[float, float]], error: float
) -> list[tuple[float, float, float, float, float, float, float, float]]:
    """Fit a cubic Bezier spline to a sequence of 2D points.

    Returns a list of segments, each an 8-tuple:
        (p1x, p1y, c1x, c1y, c2x, c2y, p2x, p2y)
    """
    if len(points) < 2:
        return []
    tHat1 = _left_tangent(points, 0)
    tHat2 = _right_tangent(points, len(points) - 1)
    result: list[tuple[float, float, float, float, float, float, float, float]] = []
    _fit_cubic(points, 0, len(points) - 1, tHat1, tHat2, error, result)
    return result


_MAX_ITERATIONS = 4


def _fit_cubic(
    d: list[tuple[float, float]],
    first: int,
    last: int,
    tHat1: tuple[float, float],
    tHat2: tuple[float, float],
    error: float,
    result: list[tuple[float, float, float, float, float, float, float, float]],
) -> None:
    nPts = last - first + 1

    if nPts == 2:
        dist = _distance(d[first], d[last]) / 3.0
        seg = (
            d[first][0], d[first][1],
            d[first][0] + tHat1[0] * dist, d[first][1] + tHat1[1] * dist,
            d[last][0] + tHat2[0] * dist, d[last][1] + tHat2[1] * dist,
            d[last][0], d[last][1],
        )
        result.append(seg)
        return

    u = _chord_length_parameterize(d, first, last)
    bezCurve = _generate_bezier(d, first, last, u, tHat1, tHat2)
    maxError, splitPoint = _compute_max_error(d, first, last, bezCurve, u)

    if maxError < error:
        result.append(bezCurve)
        return

    iterationError = error * error
    if maxError < iterationError:
        for _ in range(_MAX_ITERATIONS):
            uPrime = _reparameterize(d, first, last, u, bezCurve)
            bezCurve = _generate_bezier(d, first, last, uPrime, tHat1, tHat2)
            maxError, splitPoint = _compute_max_error(d, first, last, bezCurve, uPrime)
            if maxError < error:
                result.append(bezCurve)
                return
            u = uPrime

    tHatCenter = _center_tangent(d, splitPoint)
    _fit_cubic(d, first, splitPoint, tHat1, tHatCenter, error, result)
    tHatCenter = (-tHatCenter[0], -tHatCenter[1])
    _fit_cubic(d, splitPoint, last, tHatCenter, tHat2, error, result)


def _generate_bezier(
    d: list[tuple[float, float]],
    first: int,
    last: int,
    uPrime: list[float],
    tHat1: tuple[float, float],
    tHat2: tuple[float, float],
) -> tuple[float, float, float, float, float, float, float, float]:
    nPts = last - first + 1

    A = [
        (_scale(tHat1, _B1(uPrime[i])), _scale(tHat2, _B2(uPrime[i])))
        for i in range(nPts)
    ]

    C = [[0.0, 0.0], [0.0, 0.0]]
    X = [0.0, 0.0]

    for i in range(nPts):
        C[0][0] += _dot(A[i][0], A[i][0])
        C[0][1] += _dot(A[i][0], A[i][1])
        C[1][0] = C[0][1]
        C[1][1] += _dot(A[i][1], A[i][1])
        tmp = _sub(
            d[first + i],
            _add(
                _scale(d[first], _B0(uPrime[i])),
                _add(
                    _scale(d[first], _B1(uPrime[i])),
                    _add(
                        _scale(d[last], _B2(uPrime[i])),
                        _scale(d[last], _B3(uPrime[i])),
                    ),
                ),
            ),
        )
        X[0] += _dot(A[i][0], tmp)
        X[1] += _dot(A[i][1], tmp)

    det_C0_C1 = C[0][0] * C[1][1] - C[1][0] * C[0][1]
    det_C0_X = C[0][0] * X[1] - C[1][0] * X[0]
    det_X_C1 = X[0] * C[1][1] - X[1] * C[0][1]

    alpha_l = 0.0 if det_C0_C1 == 0 else det_X_C1 / det_C0_C1
    alpha_r = 0.0 if det_C0_C1 == 0 else det_C0_X / det_C0_C1

    segLength = _distance(d[first], d[last])
    epsilon = 1.0e-6 * segLength

    if alpha_l < epsilon or alpha_r < epsilon:
        dist = segLength / 3.0
        return (
            d[first][0], d[first][1],
            d[first][0] + tHat1[0] * dist, d[first][1] + tHat1[1] * dist,
            d[last][0] + tHat2[0] * dist, d[last][1] + tHat2[1] * dist,
            d[last][0], d[last][1],
        )

    return (
        d[first][0], d[first][1],
        d[first][0] + tHat1[0] * alpha_l, d[first][1] + tHat1[1] * alpha_l,
        d[last][0] + tHat2[0] * alpha_r, d[last][1] + tHat2[1] * alpha_r,
        d[last][0], d[last][1],
    )


def _reparameterize(
    d: list[tuple[float, float]],
    first: int,
    last: int,
    u: list[float],
    bezCurve: tuple[float, float, float, float, float, float, float, float],
) -> list[float]:
    pts = [
        (bezCurve[0], bezCurve[1]),
        (bezCurve[2], bezCurve[3]),
        (bezCurve[4], bezCurve[5]),
        (bezCurve[6], bezCurve[7]),
    ]
    return [
        _newton_raphson(pts, d[i], u[i - first])
        for i in range(first, last + 1)
    ]


def _newton_raphson(
    Q: list[tuple[float, float]], P: tuple[float, float], u: float
) -> float:
    Q_u = _bezier_ii(3, Q, u)

    Q1 = [
        ((Q[1][0] - Q[0][0]) * 3, (Q[1][1] - Q[0][1]) * 3),
        ((Q[2][0] - Q[1][0]) * 3, (Q[2][1] - Q[1][1]) * 3),
        ((Q[3][0] - Q[2][0]) * 3, (Q[3][1] - Q[2][1]) * 3),
    ]
    Q2 = [
        ((Q1[1][0] - Q1[0][0]) * 2, (Q1[1][1] - Q1[0][1]) * 2),
        ((Q1[2][0] - Q1[1][0]) * 2, (Q1[2][1] - Q1[1][1]) * 2),
    ]

    Q1_u = _bezier_ii(2, Q1, u)
    Q2_u = _bezier_ii(1, Q2, u)

    numerator = (Q_u[0] - P[0]) * Q1_u[0] + (Q_u[1] - P[1]) * Q1_u[1]
    denominator = (
        Q1_u[0] * Q1_u[0]
        + Q1_u[1] * Q1_u[1]
        + (Q_u[0] - P[0]) * Q2_u[0]
        + (Q_u[1] - P[1]) * Q2_u[1]
    )

    if denominator == 0:
        return u
    return u - numerator / denominator


def _bezier_ii(
    degree: int, V: list[tuple[float, float]], t: float
) -> tuple[float, float]:
    Vtemp = list(V)
    for i in range(1, degree + 1):
        for j in range(degree - i + 1):
            Vtemp[j] = (
                (1.0 - t) * Vtemp[j][0] + t * Vtemp[j + 1][0],
                (1.0 - t) * Vtemp[j][1] + t * Vtemp[j + 1][1],
            )
    return Vtemp[0]


def _compute_max_error(
    d: list[tuple[float, float]],
    first: int,
    last: int,
    bezCurve: tuple[float, float, float, float, float, float, float, float],
    u: list[float],
) -> tuple[float, int]:
    pts = [
        (bezCurve[0], bezCurve[1]),
        (bezCurve[2], bezCurve[3]),
        (bezCurve[4], bezCurve[5]),
        (bezCurve[6], bezCurve[7]),
    ]
    splitPoint = (last - first + 1) // 2
    maxDist = 0.0
    for i in range(first + 1, last):
        P = _bezier_ii(3, pts, u[i - first])
        dx = P[0] - d[i][0]
        dy = P[1] - d[i][1]
        dist = dx * dx + dy * dy
        if dist >= maxDist:
            maxDist = dist
            splitPoint = i
    return maxDist, splitPoint


def _chord_length_parameterize(
    d: list[tuple[float, float]], first: int, last: int
) -> list[float]:
    u = [0.0] * (last - first + 1)
    for i in range(first + 1, last + 1):
        u[i - first] = u[i - first - 1] + _distance(d[i], d[i - 1])
    total = u[last - first]
    if total > 0:
        for i in range(first + 1, last + 1):
            u[i - first] /= total
    return u


def _left_tangent(
    d: list[tuple[float, float]], end: int
) -> tuple[float, float]:
    return _normalize(_sub(d[end + 1], d[end]))


def _right_tangent(
    d: list[tuple[float, float]], end: int
) -> tuple[float, float]:
    return _normalize(_sub(d[end - 1], d[end]))


def _center_tangent(
    d: list[tuple[float, float]], center: int
) -> tuple[float, float]:
    v1 = _sub(d[center - 1], d[center])
    v2 = _sub(d[center], d[center + 1])
    return _normalize(((v1[0] + v2[0]) / 2, (v1[1] + v2[1]) / 2))


# Bernstein basis functions
def _B0(u: float) -> float:
    t = 1 - u
    return t * t * t

def _B1(u: float) -> float:
    t = 1 - u
    return 3 * u * t * t

def _B2(u: float) -> float:
    t = 1 - u
    return 3 * u * u * t

def _B3(u: float) -> float:
    return u * u * u


# Vector helpers
def _add(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    return (a[0] + b[0], a[1] + b[1])

def _sub(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    return (a[0] - b[0], a[1] - b[1])

def _scale(v: tuple[float, float], s: float) -> tuple[float, float]:
    return (v[0] * s, v[1] * s)

def _dot(a: tuple[float, float], b: tuple[float, float]) -> float:
    return a[0] * b[0] + a[1] * b[1]

def _distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])

def _normalize(v: tuple[float, float]) -> tuple[float, float]:
    length = math.hypot(v[0], v[1])
    if length == 0:
        return v
    return (v[0] / length, v[1] / length)
