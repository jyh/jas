// Pure helpers used by canvas_bootstrap.mjs to sync element stroke
// attributes into global state and to build the SVG `stroke-dasharray`
// string from the Stroke panel's individual dash / gap fields.
//
// Lives in engine/ (rather than next to canvas_bootstrap) because it
// needs to be import-able from Node tests, which don't resolve
// canvas_bootstrap's server-absolute "/static/..." imports.

/// Compute the sequence of (key, value) state writes that should fire
/// when the active selection becomes [elem]. Returns an array of
/// { key, value } pairs. The caller writes them to global state via
/// APP_SET_STATE so the Color and Stroke panels reflect what's
/// actually selected.
///
/// Mirrors fill / stroke / stroke-width plus the five stroke shape
/// attributes (cap, join, miterlimit, dasharray, dashoffset) and the
/// derived stroke_dashed boolean. Falls back to SVG defaults
/// (cap=butt / join=miter / dasharray="") for missing values so the
/// panel buttons reset when selecting an element with no explicit
/// shape attrs.
export function elementToStateWrites(elem) {
  if (!elem) return [];
  const writes = [];
  const push = (key, value) => writes.push({ key, value });

  if (typeof elem.fill === "string" || elem.fill === null) {
    push("fill_color", elem.fill === null ? null : elem.fill);
  }
  if (typeof elem.stroke === "string" || elem.stroke === null) {
    push("stroke_color", elem.stroke === null ? null : elem.stroke);
  } else if (elem.stroke && typeof elem.stroke === "object" && elem.stroke.color) {
    push("stroke_color", elem.stroke.color);
  }
  if (typeof elem["stroke-width"] === "number") {
    push("stroke_width", elem["stroke-width"]);
  } else if (elem.stroke && typeof elem.stroke === "object"
             && typeof elem.stroke.width === "number") {
    push("stroke_width", elem.stroke.width);
  }
  if (typeof elem["stroke-linecap"] === "string") {
    push("stroke_cap", elem["stroke-linecap"]);
  } else {
    push("stroke_cap", "butt");
  }
  if (typeof elem["stroke-linejoin"] === "string") {
    push("stroke_join", elem["stroke-linejoin"]);
  } else {
    push("stroke_join", "miter");
  }
  if (typeof elem["stroke-miterlimit"] === "number") {
    push("stroke_miter_limit", elem["stroke-miterlimit"]);
  }
  if (typeof elem["stroke-dasharray"] === "string") {
    push("stroke_dasharray", elem["stroke-dasharray"]);
  } else {
    push("stroke_dasharray", "");
  }
  const dashStr = elem["stroke-dasharray"];
  const isDashed = typeof dashStr === "string"
    && dashStr !== "" && dashStr !== "none";
  push("stroke_dashed", isDashed);

  // Arrowhead state — mirror the jas-* fields back to global state so
  // selecting an element with arrowheads updates the Stroke panel
  // dropdowns. Falls back to "none" / 100 when the element doesn't
  // carry arrowhead state, so the panel resets cleanly.
  const startArr = elem["jas-stroke-start-arrowhead"];
  push("stroke_start_arrowhead",
    typeof startArr === "string" ? startArr : "none");
  const endArr = elem["jas-stroke-end-arrowhead"];
  push("stroke_end_arrowhead",
    typeof endArr === "string" ? endArr : "none");
  const startScale = elem["jas-stroke-start-arrowhead-scale"];
  push("stroke_start_arrowhead_scale",
    Number.isFinite(startScale) ? startScale : 100);
  const endScale = elem["jas-stroke-end-arrowhead-scale"];
  push("stroke_end_arrowhead_scale",
    Number.isFinite(endScale) ? endScale : 100);

  return writes;
}

/// Build the SVG `stroke-dasharray` string from the Stroke panel's
/// individual dash / gap fields. Returns "" when stroke_dashed is
/// off, signalling "no dasharray" to the renderer (which omits the
/// attribute entirely).
///
/// Walk the three (dash_N, gap_N) pairs in order. Each pair
/// contributes both numbers as long as both are finite numbers; a
/// pair with either side missing ends the pattern. This yields
/// "12 6 0 6" for the Dash-Dot preset
/// (d1=12, g1=6, d2=0, g2=6, d3=null, g3=null).
export function buildDasharray(state) {
  if (!state || !state.stroke_dashed) return "";
  const parts = [];
  for (const i of [1, 2, 3]) {
    const d = state[`stroke_dash_${i}`];
    const g = state[`stroke_gap_${i}`];
    if (!Number.isFinite(d) || !Number.isFinite(g)) break;
    parts.push(String(d), String(g));
  }
  return parts.join(" ");
}
