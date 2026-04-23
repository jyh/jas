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

// Path bounds from endpoint coordinates only — approximation, matches
// the Python / Rust / Swift / OCaml behavior we shipped on
// codebase-review-tier1 (arc extrema is a known cross-language gap,
// documented in project_arc_extrema_gap memory).
function pathBoundsApprox(commands) {
  if (!commands || commands.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  let cx = 0, cy = 0, sx = 0, sy = 0;
  for (const cmd of commands) {
    const { type } = cmd;
    let nx = cx, ny = cy;
    switch (type) {
      case "M": case "L": case "T":
        nx = cmd.x; ny = cmd.y; break;
      case "H":
        nx = cmd.x; break;
      case "V":
        ny = cmd.y; break;
      case "C":
      case "S":
      case "Q":
      case "A":
        nx = cmd.x; ny = cmd.y; break;
      case "Z":
        nx = sx; ny = sy; break;
    }
    if (type === "M") { sx = nx; sy = ny; }
    if (nx < minX) minX = nx;
    if (ny < minY) minY = ny;
    if (nx > maxX) maxX = nx;
    if (ny > maxY) maxY = ny;
    cx = nx; cy = ny;
  }
  if (minX === Infinity) return { x: 0, y: 0, width: 0, height: 0 };
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
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
