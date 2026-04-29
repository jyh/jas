// Arrowhead shape definitions and SVG marker emission.
//
// Mirrors jas_dioxus/src/canvas/arrowheads.rs but emits SVG <marker>
// definitions instead of drawing on a canvas. The SVG markers go in
// a <defs> block prepended to the document; paths reference them via
// `marker-start` / `marker-end`.
//
// Each shape is defined in unit coordinates: the tip is at (0,0)
// pointing along +x; coordinates are integer multiples of stroke
// width at 100% scale. The marker viewBox + marker dimensions
// translate that to SVG marker space.

// Stable list of the 15 enum values that workspace/state.yaml
// declares for stroke_start_arrowhead / stroke_end_arrowhead.
// Includes "none" so callers can normalize.
export const ARROWHEAD_NAMES = [
  "none",
  "simple_arrow", "open_arrow", "closed_arrow", "stealth_arrow",
  "barbed_arrow", "half_arrow_upper", "half_arrow_lower",
  "circle", "open_circle", "square", "open_square",
  "diamond", "open_diamond", "slash",
];

// Bezier circle control-point offset (4/3 × (sqrt(2) - 1)).
const K = 0.5522847498;
const CIRCLE_R = 2.0;

// Each shape: { d, style, back, vbox: [minX, minY, w, h] }
//   d:     SVG path data string in unit coordinates (tip at origin,
//          pointing along +x).
//   style: "filled"  → marker uses fill=context-stroke, stroke=none.
//          "outline" → marker uses fill=none, stroke=context-stroke.
//   back:  Setback distance from the tip in unit coords. The
//          renderer can shorten the path by `back × stroke_width
//          × scale_pct/100` so the stroke ends at the marker base
//          instead of the tip. Currently informational; SVG markers
//          render at the path endpoint without explicit shortening.
//   vbox:  viewBox for the marker. The marker's coordinate system is
//          this box; the path's unit coords sit inside.
const SHAPE_DEFS = {
  simple_arrow: {
    d: "M 0 0 L -4 -2 L -4 2 Z",
    style: "filled", back: 4.0, vbox: [-4, -2, 4, 4],
  },
  open_arrow: {
    d: "M -4 -2 L 0 0 L -4 2",
    style: "outline", back: 4.0, vbox: [-4, -2, 4, 4],
  },
  closed_arrow: {
    // Filled triangle plus a bar at the base.
    d: "M 0 0 L -4 -2 L -4 2 Z M -4.5 -2 L -4.5 2",
    style: "filled", back: 4.0, vbox: [-4.5, -2, 4.5, 4],
  },
  stealth_arrow: {
    d: "M 0 0 L -4.5 -1.8 L -3 0 L -4.5 1.8 Z",
    style: "filled", back: 3.0, vbox: [-4.5, -1.8, 4.5, 3.6],
  },
  barbed_arrow: {
    d: "M 0 0 C -2 -0.5 -3.5 -1.5 -4.5 -2 L -3 0 L -4.5 2 C -3.5 1.5 -2 0.5 0 0 Z",
    style: "filled", back: 3.0, vbox: [-4.5, -2, 4.5, 4],
  },
  half_arrow_upper: {
    d: "M 0 0 L -4 -2 L -4 0 Z",
    style: "filled", back: 4.0, vbox: [-4, -2, 4, 2],
  },
  half_arrow_lower: {
    d: "M 0 0 L -4 0 L -4 2 Z",
    style: "filled", back: 4.0, vbox: [-4, 0, 4, 2],
  },
  circle: (() => {
    // Bezier-approximated circle of radius CIRCLE_R centered at
    // (-CIRCLE_R, 0). Tip touches origin.
    const r = CIRCLE_R;
    const k = K * r;
    return {
      d: `M 0 0 C 0 ${-k} ${-r + k} ${-r} ${-r} ${-r} `
       + `C ${-r - k} ${-r} ${-2 * r} ${-k} ${-2 * r} 0 `
       + `C ${-2 * r} ${k} ${-r - k} ${r} ${-r} ${r} `
       + `C ${-r + k} ${r} 0 ${k} 0 0 Z`,
      style: "filled",
      back: 2.0 * r,
      vbox: [-2 * r, -r, 2 * r, 2 * r],
    };
  })(),
  open_circle: (() => {
    const r = CIRCLE_R;
    const k = K * r;
    return {
      d: `M 0 0 C 0 ${-k} ${-r + k} ${-r} ${-r} ${-r} `
       + `C ${-r - k} ${-r} ${-2 * r} ${-k} ${-2 * r} 0 `
       + `C ${-2 * r} ${k} ${-r - k} ${r} ${-r} ${r} `
       + `C ${-r + k} ${r} 0 ${k} 0 0 Z`,
      style: "outline",
      back: 2.0 * r,
      vbox: [-2 * r, -r, 2 * r, 2 * r],
    };
  })(),
  square: {
    d: "M 0 -2 L -4 -2 L -4 2 L 0 2 Z",
    style: "filled", back: 4.0, vbox: [-4, -2, 4, 4],
  },
  open_square: {
    d: "M 0 -2 L -4 -2 L -4 2 L 0 2 Z",
    style: "outline", back: 4.0, vbox: [-4, -2, 4, 4],
  },
  diamond: {
    d: "M 0 0 L -2.5 -2 L -5 0 L -2.5 2 Z",
    style: "filled", back: 2.5, vbox: [-5, -2, 5, 4],
  },
  open_diamond: {
    d: "M 0 0 L -2.5 -2 L -5 0 L -2.5 2 Z",
    style: "outline", back: 2.5, vbox: [-5, -2, 5, 4],
  },
  slash: {
    d: "M 0.5 -2 L -0.5 2",
    style: "outline", back: 0.5, vbox: [-0.5, -2, 1, 4],
  },
};

/// Look up the shape definition for [name]. Returns null for "none"
/// or unknown shape names.
export function getArrowShape(name) {
  if (!name || name === "none") return null;
  return SHAPE_DEFS[name] || null;
}

/// Compute the path-shortening setback in user-space pixels for an
/// arrowhead at the given stroke width and scale percentage. Returns
/// 0 for "none" / unknown shapes.
export function arrowSetback(name, strokeWidth, scalePct) {
  const shape = getArrowShape(name);
  if (!shape) return 0;
  return shape.back * strokeWidth * (scalePct / 100);
}

/// Build the deterministic marker id for a (shape, scale, side) trio.
/// Side is "start" or "end"; start markers are mirrored (the shape
/// natively points along +x but the start of a path needs the tip at
/// the path origin pointing back outward, so we negate the orient).
///
/// Scale percent is rounded to an integer to keep ids stable for
/// combo-box presets (50 / 75 / 100 / 150 / 200 / 300 / 400).
export function arrowMarkerId(shape, scalePct, side) {
  const s = (Number.isFinite(scalePct) ? scalePct : 100) | 0;
  return `jas-arr-${side}-${shape}-${s}`;
}

/// Emit a single `<marker>` definition for the given (shape, side,
/// scale) combo. Returns an SVG fragment string. Returns empty string
/// for "none" / unknown shapes.
///
/// The marker uses `markerUnits="strokeWidth"` so it scales with the
/// referencing path's stroke. `orient="auto"` rotates the marker to
/// match the path tangent at the endpoint; for start markers we use
/// `orient="auto-start-reverse"` (SVG2) so the same shape points
/// outward at both ends.
///
/// The fill / stroke uses `context-stroke` (SVG2) so the marker takes
/// the path's own stroke color without baking it into the marker id.
export function emitArrowMarker(shape, side, scalePct) {
  const def = getArrowShape(shape);
  if (!def) return "";
  const s = (Number.isFinite(scalePct) ? scalePct : 100) / 100;
  const [vx, vy, vw, vh] = def.vbox;
  // Scale viewBox dimensions by scalePct so the marker grows
  // proportionally. markerWidth/markerHeight match (in stroke-width
  // units, so 4 → 4 × stroke-width pixels).
  const sx = vx * s;
  const sy = vy * s;
  const sw = vw * s;
  const sh = vh * s;
  // refX/refY default to the tip at origin (0,0). For a start marker,
  // the auto-start-reverse on orient flips the orientation but keeps
  // the refX/refY the same — the tip still sits at the path endpoint.
  const refX = 0;
  const refY = 0;
  const orient = side === "start" ? "auto-start-reverse" : "auto";
  const id = arrowMarkerId(shape, scalePct, side);
  // Filled vs outline: `context-stroke` is SVG2; widely supported in
  // modern browsers. The path uses stroke-width="0" for filled
  // markers (no extra outline) and a sensible stroke-width for
  // outline markers.
  const paint = def.style === "filled"
    ? `fill="context-stroke" stroke="none"`
    : `fill="none" stroke="context-stroke" stroke-width="0.5"`;
  return `<marker id="${id}"`
    + ` viewBox="${num(sx)} ${num(sy)} ${num(sw)} ${num(sh)}"`
    + ` markerWidth="${num(sw)}" markerHeight="${num(sh)}"`
    + ` refX="${num(refX)}" refY="${num(refY)}"`
    + ` orient="${orient}" markerUnits="strokeWidth">`
    + `<path d="${def.d}" ${paint}/>`
    + `</marker>`;
}

/// Walk a document tree and collect every (shape, side, scale) marker
/// reference its elements need. Returns a Set of "shape|side|scale"
/// keys; the caller emits a <marker> per unique key.
export function collectArrowMarkerRefs(doc) {
  const refs = new Set();
  if (!doc || !Array.isArray(doc.layers)) return refs;
  const walk = (elem) => {
    if (!elem || typeof elem !== "object") return;
    const startShape = elem["jas-stroke-start-arrowhead"];
    const endShape = elem["jas-stroke-end-arrowhead"];
    if (typeof startShape === "string" && startShape !== "none") {
      const scale = Number.isFinite(elem["jas-stroke-start-arrowhead-scale"])
        ? elem["jas-stroke-start-arrowhead-scale"] : 100;
      refs.add(`${startShape}|start|${scale | 0}`);
    }
    if (typeof endShape === "string" && endShape !== "none") {
      const scale = Number.isFinite(elem["jas-stroke-end-arrowhead-scale"])
        ? elem["jas-stroke-end-arrowhead-scale"] : 100;
      refs.add(`${endShape}|end|${scale | 0}`);
    }
    if (Array.isArray(elem.children)) {
      for (const c of elem.children) walk(c);
    }
  };
  for (const layer of doc.layers) walk(layer);
  return refs;
}

/// Build the complete <defs> block for a document's arrowhead marker
/// references. Returns "" when no markers are needed (most docs).
export function emitArrowDefs(doc) {
  const refs = collectArrowMarkerRefs(doc);
  if (refs.size === 0) return "";
  const parts = [];
  for (const ref of refs) {
    const [shape, side, scaleStr] = ref.split("|");
    const scale = Number(scaleStr);
    parts.push(emitArrowMarker(shape, side, scale));
  }
  return `<defs>${parts.join("")}</defs>`;
}

// Format a number for SVG output. Integer values stay integer (no
// trailing ".0"); fractional values keep up to 4 decimals trimmed.
function num(n) {
  if (!Number.isFinite(n)) return "0";
  if (Number.isInteger(n)) return String(n);
  return String(Math.round(n * 10000) / 10000);
}
