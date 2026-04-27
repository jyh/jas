// Geometry primitives — bounds, hit-test, intersection.
//
// Mirrors the bounds / hit-test math from the native apps'
// `geometry/element.{rs,swift,ml,py}` files. V1 scope: rect, circle,
// ellipse, line, polygon, polyline, path (endpoint-only
// approximation), text. Groups and layers recurse into children.
//
// These functions take plain Document Element objects (from
// document.mjs) — no Value wrapping. Callers in the expression layer
// convert return values via fromJson() when exposing to YAML.

import { isContainer } from "./document.mjs";

/**
 * Compute an axis-aligned bounding box for an element.
 * Returns `{x, y, width, height}` in document coordinates.
 * Groups / layers return the union of their children's bounds.
 * Unknown / degenerate elements return a zero-size box.
 */
/**
 * Anchor positions used to draw selection handles, mirroring
 * `jas_dioxus/src/geometry/element.rs::control_points`. Returns an
 * array of `[x, y]` pairs in document coordinates.
 *
 * Per-type:
 *   - line   → both endpoints
 *   - rect   → 4 corners (TL, TR, BR, BL)
 *   - circle → 4 cardinal points (top, right, bottom, left)
 *   - ellipse→ 4 cardinals using rx/ry
 *   - polygon→ all points, in order
 *   - path   → anchor of each command (Z contributes none)
 *   - else   → bounding-box corners
 */
export function controlPoints(elem) {
  if (!elem || typeof elem !== "object") return [];
  switch (elem.type) {
    case "line":
      return [[elem.x1, elem.y1], [elem.x2, elem.y2]];
    case "rect":
      return [
        [elem.x, elem.y],
        [elem.x + elem.width, elem.y],
        [elem.x + elem.width, elem.y + elem.height],
        [elem.x, elem.y + elem.height],
      ];
    case "circle":
      return [
        [elem.cx, elem.cy - elem.r],
        [elem.cx + elem.r, elem.cy],
        [elem.cx, elem.cy + elem.r],
        [elem.cx - elem.r, elem.cy],
      ];
    case "ellipse":
      return [
        [elem.cx, elem.cy - elem.ry],
        [elem.cx + elem.rx, elem.cy],
        [elem.cx, elem.cy + elem.ry],
        [elem.cx - elem.rx, elem.cy],
      ];
    case "polygon":
    case "polyline":
      return (elem.points || []).map((p) =>
        Array.isArray(p) ? [p[0], p[1]] : [p.x, p.y]);
    case "path":
      return pathAnchorPoints(elem.d || []);
    default: {
      const b = elementBounds(elem);
      return [
        [b.x, b.y],
        [b.x + b.width, b.y],
        [b.x + b.width, b.y + b.height],
        [b.x, b.y + b.height],
      ];
    }
  }
}

function pathAnchorPoints(commands) {
  const pts = [];
  for (const cmd of commands) {
    switch (cmd.type) {
      case "M":
      case "L":
      case "T":
      case "C":
      case "S":
      case "Q":
      case "A":
        pts.push([cmd.x, cmd.y]);
        break;
      case "H":
        pts.push([cmd.x, pts.length ? pts[pts.length - 1][1] : 0]);
        break;
      case "V":
        pts.push([pts.length ? pts[pts.length - 1][0] : 0, cmd.y]);
        break;
      // Z contributes no anchor.
    }
  }
  return pts;
}

export function elementBounds(elem) {
  if (!elem || typeof elem !== "object") {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  switch (elem.type) {
    case "rect":
      return {
        x: elem.x, y: elem.y,
        width: elem.width, height: elem.height,
      };
    case "circle":
      return {
        x: elem.cx - elem.r, y: elem.cy - elem.r,
        width: 2 * elem.r, height: 2 * elem.r,
      };
    case "ellipse":
      return {
        x: elem.cx - elem.rx, y: elem.cy - elem.ry,
        width: 2 * elem.rx, height: 2 * elem.ry,
      };
    case "line": {
      const x = Math.min(elem.x1, elem.x2);
      const y = Math.min(elem.y1, elem.y2);
      return {
        x, y,
        width: Math.abs(elem.x2 - elem.x1),
        height: Math.abs(elem.y2 - elem.y1),
      };
    }
    case "polygon":
    case "polyline":
      return pointsBounds(elem.points || []);
    case "path":
      return pathBoundsApprox(elem.d || []);
    case "text":
      return {
        x: elem.x,
        y: elem.y - (elem.font_size || 12),
        width: elem.text_width || estimateTextWidth(elem),
        height: elem.text_height || (elem.font_size || 12),
      };
    case "group":
    case "layer":
      return childrenUnion(elem.children || []);
    default:
      return { x: 0, y: 0, width: 0, height: 0 };
  }
}

function pointsBounds(points) {
  if (!points || points.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of points) {
    const [px, py] = Array.isArray(p) ? p : [p.x, p.y];
    if (px < minX) minX = px;
    if (py < minY) minY = py;
    if (px > maxX) maxX = px;
    if (py > maxY) maxY = py;
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

// Path bounds, including Bezier extrema for C and Q commands.
// Mirrors jas_dioxus/src/geometry/element.rs::path_bounds. Arc
// extrema (A command) is still endpoint-only — that's the known
// cross-language gap from codebase-review-tier1, fixed in a future
// pass.
function pathBoundsApprox(commands) {
  if (!commands || commands.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  const xs = [], ys = [];
  let cx = 0, cy = 0, sx = 0, sy = 0;
  let prevX2 = 0, prevY2 = 0, prevIsCurve = false;
  for (const cmd of commands) {
    const t = cmd.type;
    let advanceCurve = false;
    switch (t) {
      case "M":
        xs.push(cmd.x); ys.push(cmd.y);
        cx = cmd.x; cy = cmd.y; sx = cmd.x; sy = cmd.y;
        break;
      case "L":
      case "T":
        xs.push(cmd.x); ys.push(cmd.y);
        cx = cmd.x; cy = cmd.y;
        break;
      case "H":
        xs.push(cmd.x); ys.push(cy);
        cx = cmd.x;
        break;
      case "V":
        xs.push(cx); ys.push(cmd.y);
        cy = cmd.y;
        break;
      case "C":
        xs.push(cx, cmd.x); ys.push(cy, cmd.y);
        for (const tx of cubicExtrema(cx, cmd.x1, cmd.x2, cmd.x)) {
          xs.push(cubicEval(cx, cmd.x1, cmd.x2, cmd.x, tx));
        }
        for (const ty of cubicExtrema(cy, cmd.y1, cmd.y2, cmd.y)) {
          ys.push(cubicEval(cy, cmd.y1, cmd.y2, cmd.y, ty));
        }
        prevX2 = cmd.x2; prevY2 = cmd.y2;
        cx = cmd.x; cy = cmd.y;
        advanceCurve = true;
        break;
      case "S": {
        const rx1 = prevIsCurve ? 2 * cx - prevX2 : cx;
        const ry1 = prevIsCurve ? 2 * cy - prevY2 : cy;
        xs.push(cx, cmd.x); ys.push(cy, cmd.y);
        for (const tx of cubicExtrema(cx, rx1, cmd.x2, cmd.x)) {
          xs.push(cubicEval(cx, rx1, cmd.x2, cmd.x, tx));
        }
        for (const ty of cubicExtrema(cy, ry1, cmd.y2, cmd.y)) {
          ys.push(cubicEval(cy, ry1, cmd.y2, cmd.y, ty));
        }
        prevX2 = cmd.x2; prevY2 = cmd.y2;
        cx = cmd.x; cy = cmd.y;
        advanceCurve = true;
        break;
      }
      case "Q":
        xs.push(cx, cmd.x); ys.push(cy, cmd.y);
        for (const tx of quadraticExtremum(cx, cmd.x1, cmd.x)) {
          xs.push(quadraticEval(cx, cmd.x1, cmd.x, tx));
        }
        for (const ty of quadraticExtremum(cy, cmd.y1, cmd.y)) {
          ys.push(quadraticEval(cy, cmd.y1, cmd.y, ty));
        }
        cx = cmd.x; cy = cmd.y;
        break;
      case "A":
        xs.push(cmd.x); ys.push(cmd.y);
        cx = cmd.x; cy = cmd.y;
        break;
      case "Z":
        cx = sx; cy = sy;
        break;
    }
    prevIsCurve = advanceCurve;
  }
  if (xs.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

// Real roots in (0, 1) of d/dt B(t) for a cubic Bezier with the
// given 1D endpoints + control points. Used to find extrema of x(t)
// and y(t) independently. Matches jas_dioxus cubic_extrema.
function cubicExtrema(p0, p1, p2, p3) {
  const a = -3 * p0 + 9 * p1 - 9 * p2 + 3 * p3;
  const b = 6 * p0 - 12 * p1 + 6 * p2;
  const c = -3 * p0 + 3 * p1;
  const ts = [];
  if (Math.abs(a) < 1e-12) {
    if (Math.abs(b) > 1e-12) {
      const t = -c / b;
      if (t > 0 && t < 1) ts.push(t);
    }
  } else {
    const disc = b * b - 4 * a * c;
    if (disc >= 0) {
      const sq = Math.sqrt(disc);
      for (const t of [(-b + sq) / (2 * a), (-b - sq) / (2 * a)]) {
        if (t > 0 && t < 1) ts.push(t);
      }
    }
  }
  return ts;
}

function quadraticExtremum(p0, p1, p2) {
  const denom = p0 - 2 * p1 + p2;
  if (Math.abs(denom) < 1e-12) return [];
  const t = (p0 - p1) / denom;
  return t > 0 && t < 1 ? [t] : [];
}

function cubicEval(p0, p1, p2, p3, t) {
  const u = 1 - t;
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
}

function quadraticEval(p0, p1, p2, t) {
  const u = 1 - t;
  return u * u * p0 + 2 * u * t * p1 + t * t * p2;
}

function estimateTextWidth(elem) {
  const n = (elem.content || "").length;
  return n * (elem.font_size || 12) * 0.55;
}

function childrenUnion(children) {
  if (!children || children.length === 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const c of children) {
    const b = elementBounds(c);
    if (b.width <= 0 && b.height <= 0) continue;
    if (b.x < minX) minX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.x + b.width > maxX) maxX = b.x + b.width;
    if (b.y + b.height > maxY) maxY = b.y + b.height;
  }
  if (minX === Infinity) return { x: 0, y: 0, width: 0, height: 0 };
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

/**
 * Test whether a point is inside an axis-aligned rectangle.
 */
export function pointInRect(px, py, rect) {
  return px >= rect.x && px <= rect.x + rect.width
    && py >= rect.y && py <= rect.y + rect.height;
}

/**
 * Test whether two axis-aligned rectangles overlap.
 */
export function rectsIntersect(a, b) {
  return a.x < b.x + b.width
    && a.x + a.width > b.x
    && a.y < b.y + b.height
    && a.y + a.height > b.y;
}

/**
 * Recursive hit-test: find the deepest element at (px, py) and return
 * its tree path `[layer_idx, child_idx, ...]`. Returns `null` when the
 * point falls outside every element. Containers are not "hit" as
 * themselves — we descend into their children for leaf targets.
 *
 * Locked / invisible elements are skipped (matches the Python
 * `hit_test_text` convention we saw in jas_ocaml/type_tool.ml).
 *
 * V1 is AABB-only — a circle reports hits even outside its disc. A
 * proper shape-aware hit-test is a later phase.
 */
export function hitTest(doc, px, py) {
  if (!doc || !Array.isArray(doc.layers)) return null;
  // Walk layers top-to-bottom (visually topmost first — reverse-iterate).
  for (let li = doc.layers.length - 1; li >= 0; li--) {
    const layer = doc.layers[li];
    if (layerHidden(layer)) continue;
    const hit = recurseHitTest(layer, [li], px, py);
    if (hit) return hit;
  }
  return null;
}

/**
 * Flat hit-test — stops at direct layer children. Returns
 * `[li, ci]` on hit, or null. Used by the regular Selection tool,
 * which wants click-on-group-child to select the group itself.
 * Mirrors `jas_dioxus/src/interpreter/doc_primitives.rs::hit_test`
 * (the flat sibling of the recursive hit_test_deep).
 */
export function hitTestFlat(doc, px, py) {
  if (!doc || !Array.isArray(doc.layers)) return null;
  for (let li = doc.layers.length - 1; li >= 0; li--) {
    const layer = doc.layers[li];
    if (layerHidden(layer)) continue;
    const children = layer.children || [];
    for (let ci = children.length - 1; ci >= 0; ci--) {
      const child = children[ci];
      if (elemHidden(child)) continue;
      const b = elementBounds(child);
      if (pointInRect(px, py, b)) return [li, ci];
    }
  }
  return null;
}

function recurseHitTest(elem, path, px, py) {
  if (elemHidden(elem)) return null;
  if (isContainer(elem)) {
    const children = elem.children || [];
    for (let i = children.length - 1; i >= 0; i--) {
      const p = [...path, i];
      const h = recurseHitTest(children[i], p, px, py);
      if (h) return h;
    }
    return null;
  }
  const b = elementBounds(elem);
  if (pointInRect(px, py, b)) return path;
  return null;
}

function layerHidden(layer) {
  return layer.visibility === "invisible";
}
function elemHidden(elem) {
  return elem.visibility === "invisible" || elem.locked === true;
}

/**
 * Find every element whose bounding box intersects the given
 * rectangle. Returns an array of tree paths. Matches the `select in
 * rect` gesture semantics.
 */
export function hitTestRect(doc, rect) {
  if (!doc || !Array.isArray(doc.layers)) return [];
  const out = [];
  for (let li = 0; li < doc.layers.length; li++) {
    const layer = doc.layers[li];
    if (layerHidden(layer)) continue;
    collectIntersections(layer, [li], rect, out);
  }
  return out;
}

function collectIntersections(elem, path, rect, out) {
  if (elemHidden(elem)) return;
  if (isContainer(elem)) {
    const children = elem.children || [];
    for (let i = 0; i < children.length; i++) {
      collectIntersections(children[i], [...path, i], rect, out);
    }
    return;
  }
  const b = elementBounds(elem);
  if (b.width > 0 && b.height > 0 && rectsIntersect(b, rect)) {
    out.push(path);
  }
}

/**
 * Translate an element's geometry by (dx, dy). Returns a new element;
 * does not mutate the input. Leaf types translate their geometry
 * fields; containers recursively translate their children.
 */
export function translateElement(elem, dx, dy) {
  if (!elem) return elem;
  switch (elem.type) {
    case "rect":
    case "text":
      return { ...elem, x: elem.x + dx, y: elem.y + dy };
    case "circle":
    case "ellipse":
      return { ...elem, cx: elem.cx + dx, cy: elem.cy + dy };
    case "line":
      return {
        ...elem,
        x1: elem.x1 + dx, y1: elem.y1 + dy,
        x2: elem.x2 + dx, y2: elem.y2 + dy,
      };
    case "polygon":
    case "polyline":
      return {
        ...elem,
        points: (elem.points || []).map((p) =>
          Array.isArray(p) ? [p[0] + dx, p[1] + dy] : { x: p.x + dx, y: p.y + dy }
        ),
      };
    case "path":
      return { ...elem, d: (elem.d || []).map((cmd) => translatePathCmd(cmd, dx, dy)) };
    case "group":
    case "layer":
      return {
        ...elem,
        children: (elem.children || []).map((c) => translateElement(c, dx, dy)),
      };
    default:
      return elem;
  }
}

function translatePathCmd(cmd, dx, dy) {
  const out = { ...cmd };
  if ("x" in out) out.x += dx;
  if ("y" in out) out.y += dy;
  if ("x1" in out) out.x1 += dx;
  if ("y1" in out) out.y1 += dy;
  if ("x2" in out) out.x2 += dx;
  if ("y2" in out) out.y2 += dy;
  return out;
}

// ─── Calligraphic stroke outliner ──────────────────────────────
//
// Computes the variable-width outline of a Path stroked with a
// Calligraphic brush. Returns a closed SVG path "d" string suitable
// for <path d="…">. The result is a polyline approximation; bezier
// curve-fitting on the offset points is a future polish per
// BRUSHES.md §Wiring status open follow-ups.
//
// The brush is an oval pen tip with screen-fixed orientation. At
// each sample point along the path, the offset distance perpendicular
// to the path tangent equals half the projection of the oval onto
// the path normal:
//
//   φ = θ_brush − (θ_path + π/2)
//   d(φ) = √((a/2 · cos φ)² + (b/2 · sin φ)²)
//
// where a = brush.size, b = brush.size · brush.roundness / 100.
//
// Phase 1 limits: only the "fixed" variation mode is honoured; other
// modes (random, pressure, tilt, bearing, rotation) degrade to fixed
// at the brush's base value. Multi-subpath paths render the first
// subpath only.
//
// Sampling: line segments at ~1pt arc-length intervals; cubic /
// quadratic Beziers at fixed parametric resolution (32 / 24 samples).

const SAMPLE_INTERVAL_PT = 1.0;
const CUBIC_SAMPLES = 32;
const QUADRATIC_SAMPLES = 24;

/**
 * Compute the variable-width outline of `commands` stroked with a
 * Calligraphic brush. Returns the closed-path SVG `d` attribute as a
 * string. Returns "" on degenerate input (empty path, single
 * MoveTo, zero-area sweep).
 */
export function calligraphicOutline(commands, brush) {
  const samples = sampleStrokePath(commands);
  if (samples.length < 2) return "";

  const a = brush.size / 2;
  const b = (brush.size * (brush.roundness / 100)) / 2;
  const thetaBrush = ((brush.angle || 0) * Math.PI) / 180;

  const left = [];
  const right = [];
  for (const s of samples) {
    const phi = thetaBrush - (s.tangent + Math.PI / 2);
    const d = Math.sqrt(
      (a * Math.cos(phi)) ** 2 + (b * Math.sin(phi)) ** 2,
    );
    const nx = -Math.sin(s.tangent);
    const ny = Math.cos(s.tangent);
    left.push([s.x + nx * d, s.y + ny * d]);
    right.push([s.x - nx * d, s.y - ny * d]);
  }

  const parts = [`M ${fmt(left[0][0])} ${fmt(left[0][1])}`];
  for (let i = 1; i < left.length; i++) {
    parts.push(`L ${fmt(left[i][0])} ${fmt(left[i][1])}`);
  }
  for (let i = right.length - 1; i >= 0; i--) {
    parts.push(`L ${fmt(right[i][0])} ${fmt(right[i][1])}`);
  }
  parts.push("Z");
  return parts.join(" ");
}

function sampleStrokePath(commands) {
  const out = [];
  let cx = 0, cy = 0;          // current point
  let sx = 0, sy = 0;          // subpath start
  let started = false;

  for (const cmd of commands) {
    switch (cmd.type) {
      case "M":
        // Phase 1 limit: first subpath only. A second M after sampling
        // has begun ends sampling.
        if (started) return out;
        cx = cmd.x; cy = cmd.y;
        sx = cx; sy = cy;
        break;
      case "L":
        sampleLine(out, cx, cy, cmd.x, cmd.y);
        cx = cmd.x; cy = cmd.y;
        started = true;
        break;
      case "H":
        sampleLine(out, cx, cy, cmd.x, cy);
        cx = cmd.x;
        started = true;
        break;
      case "V":
        sampleLine(out, cx, cy, cx, cmd.y);
        cy = cmd.y;
        started = true;
        break;
      case "C":
        sampleCubic(out, cx, cy, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y);
        cx = cmd.x; cy = cmd.y;
        started = true;
        break;
      case "Q":
        sampleQuadratic(out, cx, cy, cmd.x1, cmd.y1, cmd.x, cmd.y);
        cx = cmd.x; cy = cmd.y;
        started = true;
        break;
      case "Z":
        if (cx !== sx || cy !== sy) {
          sampleLine(out, cx, cy, sx, sy);
        }
        cx = sx; cy = sy;
        return out;     // closing the subpath ends sampling
    }
  }
  return out;
}

function sampleLine(out, x0, y0, x1, y1) {
  const len = Math.hypot(x1 - x0, y1 - y0);
  if (len === 0) return;
  const tangent = Math.atan2(y1 - y0, x1 - x0);
  const n = Math.max(1, Math.ceil(len / SAMPLE_INTERVAL_PT));
  // Skip i=0 if out is already non-empty (avoids doubled points at
  // segment joins).
  const startI = out.length === 0 ? 0 : 1;
  for (let i = startI; i <= n; i++) {
    const t = i / n;
    out.push({
      x: x0 + (x1 - x0) * t,
      y: y0 + (y1 - y0) * t,
      tangent,
    });
  }
}

function sampleCubic(out, x0, y0, x1, y1, x2, y2, x3, y3) {
  const startI = out.length === 0 ? 0 : 1;
  for (let i = startI; i <= CUBIC_SAMPLES; i++) {
    const t = i / CUBIC_SAMPLES;
    const u = 1 - t;
    const x = u*u*u * x0 + 3*u*u*t * x1 + 3*u*t*t * x2 + t*t*t * x3;
    const y = u*u*u * y0 + 3*u*u*t * y1 + 3*u*t*t * y2 + t*t*t * y3;
    const dx = 3*u*u * (x1 - x0) + 6*u*t * (x2 - x1) + 3*t*t * (x3 - x2);
    const dy = 3*u*u * (y1 - y0) + 6*u*t * (y2 - y1) + 3*t*t * (y3 - y2);
    // Endpoint tangents may be zero-length when control points coincide
    // with endpoints; fall back to the chord direction in that case.
    let tangent;
    if (dx === 0 && dy === 0) {
      tangent = Math.atan2(y3 - y0, x3 - x0);
    } else {
      tangent = Math.atan2(dy, dx);
    }
    out.push({ x, y, tangent });
  }
}

function sampleQuadratic(out, x0, y0, x1, y1, x2, y2) {
  const startI = out.length === 0 ? 0 : 1;
  for (let i = startI; i <= QUADRATIC_SAMPLES; i++) {
    const t = i / QUADRATIC_SAMPLES;
    const u = 1 - t;
    const x = u*u * x0 + 2*u*t * x1 + t*t * x2;
    const y = u*u * y0 + 2*u*t * y1 + t*t * y2;
    const dx = 2*u * (x1 - x0) + 2*t * (x2 - x1);
    const dy = 2*u * (y1 - y0) + 2*t * (y2 - y1);
    let tangent;
    if (dx === 0 && dy === 0) {
      tangent = Math.atan2(y2 - y0, x2 - x0);
    } else {
      tangent = Math.atan2(dy, dx);
    }
    out.push({ x, y, tangent });
  }
}

function fmt(n) {
  if (Number.isInteger(n)) return String(n);
  return parseFloat(n.toFixed(3)).toString();
}
