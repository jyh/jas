// Canvas layer orchestration — composes document, selection, and tool
// overlay layers into a single SVG tree driven by reactive Model /
// Store updates.
//
// Per FLASK_PARITY.md §7: all-SVG-DOM, layered SVGs, CSS transform on
// the viewport container for pan/zoom. The layer stack is now five
// elements (artboard-fill, doc, artboard-deco, selection, overlay) —
// see the artboard-rendering section below. This module owns the JS
// side of that design — DOM creation happens in the browser; the
// function below is isolated enough to test by string comparison.

import { renderDocument, renderElement } from "./renderer.mjs";
import { elementBounds, controlPoints } from "./geometry.mjs";
import { getElement, partialCpsForPath } from "./document.mjs";
import * as pointBuffers from "./point_buffers.mjs";
import * as anchorBuffers from "./anchor_buffers.mjs";
import { evaluate } from "./expr.mjs";
import { Scope } from "./scope.mjs";
import { toBool, toStringCoerce } from "./value.mjs";

/**
 * Render the complete canvas as four layered SVG strings. The caller
 * (browser code) wraps each in its own `<svg>` element; tests can
 * compare the strings directly.
 *
 * @param {Object} args
 * @param {Object} args.doc             Document
 * @param {string} [args.activeTool]    Active tool id (for overlay)
 * @param {Object} [args.toolSpec]      Tool spec (to read overlay)
 * @param {Scope|Object} [args.scope]   Scope for overlay expression
 * @param {Object} [args.viewport]      {pan_x, pan_y, zoom} for the container
 */
export function renderCanvas({
  doc, activeTool, toolSpec, scope, viewport,
  panelSelectedIds, viewBox,
} = {}) {
  return {
    artboardFillLayer: renderArtboardFillLayer(doc),
    documentLayer: renderDocumentLayer(doc),
    artboardDecorationLayer: renderArtboardDecorationLayer(doc, {
      panelSelectedIds, viewBox,
    }),
    selectionLayer: renderSelectionLayer(doc),
    overlayLayer: renderOverlayLayer(toolSpec, scope),
    viewportTransform: viewportTransform(viewport),
  };
}

// ─── Artboard layers ────────────────────────────────────────
//
// Mirrors the Rust canvas paint order (jas_dioxus/src/canvas/render.rs):
//   1. fills          → renderArtboardFillLayer  (below document)
//   2. element tree   → renderDocumentLayer
//   3. fade overlay   ┐
//   4. borders        ├ renderArtboardDecorationLayer (above document,
//   5. accent         │  below selection)
//   6. labels         │
//   7. display marks  ┘
// Display marks (center mark / cross hairs / safe areas) default to off
// in Artboard and are deferred — they ship when their toggles are
// surfaced. Cross-app contract for the Artboard shape is documented in
// jas_dioxus/src/document/artboard.rs.

const ARTBOARD_BORDER_COLOR = "rgb(48,48,48)";
const ARTBOARD_ACCENT_COLOR = "rgba(0, 120, 215, 0.95)";
const ARTBOARD_LABEL_COLOR  = "rgb(200,200,200)";
const ARTBOARD_FADE_COLOR   = "rgba(160, 160, 160, 0.5)";

export function renderArtboardFillLayer(doc) {
  if (!doc || !Array.isArray(doc.artboards) || doc.artboards.length === 0) {
    return "";
  }
  const parts = [];
  for (const ab of doc.artboards) {
    if (!ab.fill || ab.fill === "transparent") continue;
    parts.push(
      `<rect x="${num(ab.x)}" y="${num(ab.y)}" ` +
      `width="${num(ab.width)}" height="${num(ab.height)}" ` +
      `fill="${esc(ab.fill)}"/>`
    );
  }
  return parts.join("");
}

export function renderArtboardDecorationLayer(doc, opts = {}) {
  if (!doc || !Array.isArray(doc.artboards) || doc.artboards.length === 0) {
    return "";
  }
  const panelSelectedIds = Array.isArray(opts.panelSelectedIds)
    ? opts.panelSelectedIds : [];
  const parts = [];

  // Fade overlay first (lowest in this layer).
  const fadeOn = doc.artboard_options &&
    doc.artboard_options.fade_region_outside_artboard;
  if (fadeOn && opts.viewBox) {
    parts.push(fadePath(doc.artboards, opts.viewBox));
  }

  // Default 1px border per artboard.
  for (const ab of doc.artboards) {
    parts.push(
      `<rect x="${num(ab.x)}" y="${num(ab.y)}" ` +
      `width="${num(ab.width)}" height="${num(ab.height)}" ` +
      `fill="none" stroke="${ARTBOARD_BORDER_COLOR}" stroke-width="1"/>`
    );
  }

  // 2px accent border on panel-selected artboards. The accent is
  // padded by 1.5 units so its outer edge sits one pixel outside the
  // default border (matches the Rust drawer).
  if (panelSelectedIds.length > 0) {
    const pad = 1.5;
    for (const ab of doc.artboards) {
      if (!panelSelectedIds.includes(ab.id)) continue;
      parts.push(
        `<rect x="${num(ab.x - pad)}" y="${num(ab.y - pad)}" ` +
        `width="${num(ab.width + 2 * pad)}" height="${num(ab.height + 2 * pad)}" ` +
        `fill="none" stroke="${ARTBOARD_ACCENT_COLOR}" stroke-width="2"/>`
      );
    }
  }

  // Number-prefixed name above the top-left corner.
  for (let i = 0; i < doc.artboards.length; i++) {
    const ab = doc.artboards[i];
    parts.push(
      `<text x="${num(ab.x)}" y="${num(ab.y - 3)}" ` +
      `font-size="11" font-family="sans-serif" ` +
      `fill="${ARTBOARD_LABEL_COLOR}">` +
      `${esc(`${i + 1}  ${ab.name || ""}`)}</text>`
    );
  }

  return parts.join("");
}

// Build a single <path> with even-odd fill — outer rectangle covers
// the whole viewBox, inner rectangles (one per artboard) punch holes
// through. Equivalent to Rust's destination-out compositing without
// needing canvas-state tricks.
function fadePath(artboards, viewBox) {
  const parts = [
    `M ${num(viewBox.x)} ${num(viewBox.y)} `,
    `h ${num(viewBox.width)} `,
    `v ${num(viewBox.height)} `,
    `h ${num(-viewBox.width)} Z`,
  ];
  for (const ab of artboards) {
    parts.push(
      ` M ${num(ab.x)} ${num(ab.y)} `,
      `h ${num(ab.width)} `,
      `v ${num(ab.height)} `,
      `h ${num(-ab.width)} Z`,
    );
  }
  return (
    `<path d="${parts.join("")}" fill-rule="evenodd" ` +
    `fill="${ARTBOARD_FADE_COLOR}"/>`
  );
}

// Local helpers — kept private to avoid colliding with renderer.mjs's.
function num(n) {
  if (typeof n !== "number") return "0";
  if (Number.isInteger(n)) return String(n);
  return parseFloat(n.toFixed(6)).toString();
}
function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ─── Document layer ─────────────────────────────────────────

export function renderDocumentLayer(doc) {
  return renderDocument(doc);
}

// ─── Selection layer ────────────────────────────────────────
//
// V1: dashed bounding-box per selected element. Handles (resize, rotate)
// land when a tool-specific selection HUD is designed.

// Selection HUD colour and handle size — matches the native apps
// (jas_dioxus/src/canvas/render.rs HANDLE_DRAW_SIZE = 10, sel_color
// rgba(0, 120, 215, 0.9)).
const SELECTION_COLOR = "rgba(0, 120, 215, 0.9)";
const HANDLE_SIZE = 10;

export function renderSelectionLayer(doc) {
  if (!doc || !Array.isArray(doc.selection) || doc.selection.length === 0) {
    return "";
  }
  const parts = [];
  for (const path of doc.selection) {
    const elem = getElement(doc, path);
    if (!elem) continue;
    const b = elementBounds(elem);
    if (b.width <= 0 && b.height <= 0) continue;
    // Dashed bounding-box outline (uses the cooler selection-blue).
    parts.push(
      `<rect x="${b.x}" y="${b.y}" width="${b.width}" height="${b.height}" ` +
      `fill="none" stroke="${SELECTION_COLOR}" stroke-width="1" stroke-dasharray="4 2"/>`
    );
    // Square handles at every control point. SelectionKind::All
    // (no partial entry) → every handle filled solid. Partial(cps)
    // → only listed CPs solid; others white with a selection-blue
    // outline. Mirrors jas_dioxus' draw loop.
    const half = HANDLE_SIZE / 2;
    const partial = partialCpsForPath(doc, path);
    const cps = controlPoints(elem);
    // For selected anchors of a Path, also draw the in/out Bezier
    // handle indicators (line + 3px circle at each non-coincident
    // handle position). Without these, the user has no visible
    // affordance to drag handles via the Partial Selection tool.
    if (elem.type === "path" && Array.isArray(elem.d)) {
      const handleParts = bezierHandleIndicators(elem, partial);
      if (handleParts.length) parts.push(handleParts);
    }
    for (let i = 0; i < cps.length; i++) {
      const [px, py] = cps[i];
      const selected = partial == null || partial.includes(i);
      const fill = selected ? SELECTION_COLOR : "white";
      parts.push(
        `<rect x="${px - half}" y="${py - half}" ` +
        `width="${HANDLE_SIZE}" height="${HANDLE_SIZE}" ` +
        `fill="${fill}" stroke="${SELECTION_COLOR}" stroke-width="1"/>`
      );
    }
  }
  return parts.join("");
}

// Render in/out handle indicators (anchor→handle line + circle at
// the handle position) for every Path anchor that's selected and
// has at least one non-coincident Bezier handle. `partial` is the
// partial-CP array (null = SelectionKind::All — every anchor counts
// as selected). Mirrors the live affordance the Pen overlay shows
// during placement; here it's the post-commit version, draggable
// by the Partial Selection tool.
function bezierHandleIndicators(elem, partial) {
  const out = [];
  // Map each non-Z command index to anchor index.
  let ai = 0;
  for (let i = 0; i < elem.d.length; i++) {
    const c = elem.d[i];
    if (c.type === "Z") continue;
    const anchorIdx = ai++;
    const selected = partial == null || partial.includes(anchorIdx);
    if (!selected) continue;
    const ax = typeof c.x === "number" ? c.x : 0;
    const ay = typeof c.y === "number" ? c.y : 0;
    // In-handle on this command's x2/y2 (C / S).
    if (typeof c.x2 === "number" && typeof c.y2 === "number") {
      const dx = c.x2 - ax, dy = c.y2 - ay;
      if (dx * dx + dy * dy > 0.01) {
        out.push(handleIndicator(ax, ay, c.x2, c.y2));
      }
    }
    // Out-handle on the next command's x1/y1 (C / S / Q).
    const next = i + 1 < elem.d.length ? elem.d[i + 1] : null;
    if (next && typeof next.x1 === "number" && typeof next.y1 === "number") {
      const dx = next.x1 - ax, dy = next.y1 - ay;
      if (dx * dx + dy * dy > 0.01) {
        out.push(handleIndicator(ax, ay, next.x1, next.y1));
      }
    }
  }
  return out.join("");
}

function handleIndicator(ax, ay, hx, hy) {
  return (
    `<line x1="${ax}" y1="${ay}" x2="${hx}" y2="${hy}" ` +
    `stroke="${SELECTION_COLOR}" stroke-width="1"/>` +
    `<circle cx="${hx}" cy="${hy}" r="3" ` +
    `fill="white" stroke="${SELECTION_COLOR}" stroke-width="1"/>`
  );
}

// ─── Tool overlay layer ─────────────────────────────────────
//
// Drives the `overlay:` block in the tool YAML. The block has shape:
//   overlay:
//     if: "<guard_expr>"
//     render:
//       type: rect
//       x: "<expr>"
//       y: "<expr>"
//       ...

export function renderOverlayLayer(toolSpec, scope) {
  if (!toolSpec || !toolSpec.overlay) return "";
  const overlay = toolSpec.overlay;
  const s = scope instanceof Scope ? scope : new Scope(scope || {});

  if (overlay.if && !toBool(evaluate(overlay.if, s))) return "";
  if (!overlay.render) return "";

  return renderOverlaySpec(overlay.render, s);
}

function renderOverlaySpec(spec, scope) {
  if (!spec || typeof spec !== "object") return "";
  // Evaluate each expression-valued field. Non-expression fields (like
  // `style:`) pass through verbatim.
  const evaluated = {};
  for (const [k, v] of Object.entries(spec)) {
    // type / style / buffer are literal strings, not expressions —
    // matches how the rest of the runtime reads them (effects.mjs's
    // buffer.* effects, the per-type overlay element tag).
    if (k === "type" || k === "style" || k === "buffer") {
      evaluated[k] = v;
      continue;
    }
    if (typeof v === "string") {
      const r = evaluate(v, scope);
      evaluated[k] = toStringCoerce(r);
    } else {
      evaluated[k] = v;
    }
  }
  // Custom overlay types short-circuit to specialised renderers.
  // Plain SVG element types fall through to buildOverlayElement.
  if (evaluated.type === "partial_selection_overlay") {
    return renderPartialSelectionOverlay(evaluated);
  }
  if (evaluated.type === "buffer_polyline") {
    return renderBufferPolyline(evaluated);
  }
  if (evaluated.type === "pen_overlay") {
    return renderPenOverlay(evaluated);
  }
  return buildOverlayElement(evaluated);
}

// Live preview for the Pen tool. Draws the in-progress path through
// the anchors so far, plus a preview segment from the last anchor to
// the cursor when the tool is in 'placing' mode (between clicks),
// plus a small ring around the first anchor when the cursor is
// within close_radius of it (the close-path indicator).
function renderPenOverlay(evaluated) {
  const name = String(evaluated.buffer || "");
  if (!name) return "";
  const anchors = anchorBuffers.anchors(name);
  if (anchors.length === 0) return "";
  const placing = String(evaluated.placing) === "true";
  const mouseX = Number(evaluated.mouse_x) || 0;
  const mouseY = Number(evaluated.mouse_y) || 0;
  const closeR = Number(evaluated.close_radius) || 8;

  const parts = [];
  // Stroked path through the placed anchors.
  let d = `M ${num(anchors[0].x)} ${num(anchors[0].y)}`;
  for (let i = 1; i < anchors.length; i++) {
    const prev = anchors[i - 1], cur = anchors[i];
    d += ` C ${num(prev.hout_x)} ${num(prev.hout_y)}` +
         ` ${num(cur.hin_x)} ${num(cur.hin_y)}` +
         ` ${num(cur.x)} ${num(cur.y)}`;
  }
  // Preview segment from the last anchor to the cursor (only while
  // placing — don't draw during an active drag).
  if (placing && anchors.length >= 1) {
    const last = anchors[anchors.length - 1];
    d += ` C ${num(last.hout_x)} ${num(last.hout_y)}` +
         ` ${num(mouseX)} ${num(mouseY)}` +
         ` ${num(mouseX)} ${num(mouseY)}`;
  }
  parts.push(
    `<path d="${d}" fill="none" ` +
    `stroke="rgba(0, 120, 215, 0.9)" stroke-width="1"/>`
  );

  // Anchor handle indicators: lines from anchor to its in/out
  // handles for any smooth anchor.
  for (const a of anchors) {
    if (!a.smooth) continue;
    parts.push(
      `<line x1="${num(a.hin_x)}" y1="${num(a.hin_y)}" ` +
      `x2="${num(a.hout_x)}" y2="${num(a.hout_y)}" ` +
      `stroke="rgba(0, 120, 215, 0.5)" stroke-width="1"/>`
    );
    for (const [hx, hy] of [[a.hin_x, a.hin_y], [a.hout_x, a.hout_y]]) {
      parts.push(
        `<circle cx="${num(hx)}" cy="${num(hy)}" r="3" ` +
        `fill="white" stroke="rgba(0, 120, 215, 0.9)" stroke-width="1"/>`
      );
    }
  }

  // Anchor squares — first anchor gets the close-hit ring when the
  // cursor is within close_radius (and there are 2+ anchors so close
  // is even possible).
  for (let i = 0; i < anchors.length; i++) {
    const a = anchors[i];
    parts.push(
      `<rect x="${num(a.x - 3)}" y="${num(a.y - 3)}" ` +
      `width="6" height="6" ` +
      `fill="white" stroke="rgba(0, 120, 215, 0.9)" stroke-width="1"/>`
    );
  }
  if (anchors.length >= 2) {
    const first = anchors[0];
    const dx = mouseX - first.x, dy = mouseY - first.y;
    if (dx * dx + dy * dy <= closeR * closeR) {
      parts.push(
        `<circle cx="${num(first.x)}" cy="${num(first.y)}" ` +
        `r="${num(closeR)}" ` +
        `fill="none" stroke="rgba(0, 120, 215, 0.9)" stroke-width="2"/>`
      );
    }
  }

  return parts.join("");
}

// Polyline preview tracking the live drag of an accumulator tool
// (Pencil's freehand drag, etc.). Reads the named point buffer
// directly. Returns "" for buffers with fewer than two points so
// SVG doesn't choke on a degenerate <polyline>.
function renderBufferPolyline(evaluated) {
  const name = String(evaluated.buffer || "");
  if (!name) return "";
  const pts = pointBuffers.points(name);
  if (pts.length < 2) return "";
  const pointsAttr = pts.map(([x, y]) => `${num(x)},${num(y)}`).join(" ");
  const styleAttr = evaluated.style
    ? ` style="${String(evaluated.style).replace(/"/g, "&quot;")}"`
    : "";
  return `<polyline points="${pointsAttr}" fill="none"${styleAttr}/>`;
}

// Marquee rect for the Partial Selection tool. The selected-element
// path handles are already drawn by renderSelectionLayer, so the
// overlay's only job here is the rubber-band rect — and only when
// the tool is in the marquee mode.
function renderPartialSelectionOverlay(evaluated) {
  if (evaluated.mode !== "marquee") return "";
  const x1 = num(Number(evaluated.marquee_start_x) || 0);
  const y1 = num(Number(evaluated.marquee_start_y) || 0);
  const x2 = num(Number(evaluated.marquee_cur_x) || 0);
  const y2 = num(Number(evaluated.marquee_cur_y) || 0);
  const minX = Math.min(Number(x1), Number(x2));
  const minY = Math.min(Number(y1), Number(y2));
  const w = Math.abs(Number(x2) - Number(x1));
  const h = Math.abs(Number(y2) - Number(y1));
  return (
    `<rect x="${num(minX)}" y="${num(minY)}" ` +
    `width="${num(w)}" height="${num(h)}" ` +
    `fill="rgba(0, 120, 215, 0.08)" ` +
    `stroke="rgba(0, 120, 215, 0.9)" stroke-width="1" ` +
    `stroke-dasharray="4 2"/>`
  );
}

function buildOverlayElement(evaluated) {
  const tag = evaluated.type || "g";
  const attrs = [];
  for (const [k, v] of Object.entries(evaluated)) {
    if (k === "type") continue;
    attrs.push(`${k}="${String(v).replace(/"/g, "&quot;")}"`);
  }
  return `<${tag} ${attrs.join(" ")}/>`;
}

// ─── Viewport transform ─────────────────────────────────────

function viewportTransform(viewport) {
  if (!viewport) return "translate(0,0) scale(1)";
  const panX = Number(viewport.pan_x) || 0;
  const panY = Number(viewport.pan_y) || 0;
  const zoom = Number(viewport.zoom) || 1;
  return `translate(${panX}px, ${panY}px) scale(${zoom})`;
}
