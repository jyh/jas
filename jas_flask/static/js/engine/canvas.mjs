// Canvas layer orchestration — composes document, selection, and tool
// overlay layers into a single SVG tree driven by reactive Model /
// Store updates.
//
// Per FLASK_PARITY.md §7: all-SVG-DOM, four layers, CSS transform on
// the viewport container for pan/zoom. This module owns the JS side
// of that design — DOM creation happens in the browser; the function
// below is isolated enough to test by string comparison.

import { renderDocument, renderElement } from "./renderer.mjs";
import { elementBounds } from "./geometry.mjs";
import { getElement } from "./document.mjs";
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
export function renderCanvas({ doc, activeTool, toolSpec, scope, viewport } = {}) {
  return {
    documentLayer: renderDocumentLayer(doc),
    selectionLayer: renderSelectionLayer(doc),
    overlayLayer: renderOverlayLayer(toolSpec, scope),
    viewportTransform: viewportTransform(viewport),
  };
}

// ─── Document layer ─────────────────────────────────────────

export function renderDocumentLayer(doc) {
  return renderDocument(doc);
}

// ─── Selection layer ────────────────────────────────────────
//
// V1: dashed bounding-box per selected element. Handles (resize, rotate)
// land when a tool-specific selection HUD is designed.

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
    parts.push(
      `<rect x="${b.x}" y="${b.y}" width="${b.width}" height="${b.height}" ` +
      `fill="none" stroke="#4a90d9" stroke-width="1" stroke-dasharray="4 2"/>`
    );
  }
  return parts.join("");
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
    if (k === "type" || k === "style") {
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
  // Build an SVG element matching `type`.
  const inner = buildOverlayElement(evaluated);
  return inner;
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
