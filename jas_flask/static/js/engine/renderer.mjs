// Document → SVG renderer.
//
// Pure function: takes an Element and returns an SVG string (or
// DOM-append-friendly element in a future revision). Drives the
// document layer of the canvas. Selection and overlay layers have
// their own modules.
//
// String form is easier to test in Node; browser code either innerHTMLs
// the result into a container or uses a tiny parser. Either way, the
// shape of the output is a valid SVG fragment.

import { isContainer } from "./document.mjs";

/**
 * Render an element to an SVG string fragment. Recurses into
 * containers. Leaf elements emit a single SVG node with geometry +
 * style attributes.
 *
 * The result is suitable for insertion as the child of an `<svg>`
 * container — no `<svg>` wrapper is emitted.
 */
export function renderElement(elem) {
  if (!elem || typeof elem !== "object") return "";
  if (elem.visibility === "invisible") return "";
  switch (elem.type) {
    case "rect": return renderRect(elem);
    case "circle": return renderCircle(elem);
    case "ellipse": return renderEllipse(elem);
    case "line": return renderLine(elem);
    case "polygon": return renderPolygon(elem);
    case "polyline": return renderPolyline(elem);
    case "path": return renderPath(elem);
    case "text": return renderText(elem);
    case "group":
    case "layer":
      return renderContainer(elem);
    default:
      return "";
  }
}

/**
 * Render an entire document to an SVG string.
 */
export function renderDocument(doc) {
  if (!doc || !Array.isArray(doc.layers)) return "";
  return doc.layers.map(renderElement).join("");
}

// ─── Per-type renderers ─────────────────────────────────────

function renderRect(e) {
  const attrs = [
    `x="${num(e.x)}"`,
    `y="${num(e.y)}"`,
    `width="${num(e.width)}"`,
    `height="${num(e.height)}"`,
    styleAttrs(e),
  ].filter(Boolean).join(" ");
  return `<rect ${attrs}/>`;
}

function renderCircle(e) {
  const attrs = [
    `cx="${num(e.cx)}"`,
    `cy="${num(e.cy)}"`,
    `r="${num(e.r)}"`,
    styleAttrs(e),
  ].filter(Boolean).join(" ");
  return `<circle ${attrs}/>`;
}

function renderEllipse(e) {
  const attrs = [
    `cx="${num(e.cx)}"`,
    `cy="${num(e.cy)}"`,
    `rx="${num(e.rx)}"`,
    `ry="${num(e.ry)}"`,
    styleAttrs(e),
  ].filter(Boolean).join(" ");
  return `<ellipse ${attrs}/>`;
}

function renderLine(e) {
  const attrs = [
    `x1="${num(e.x1)}"`,
    `y1="${num(e.y1)}"`,
    `x2="${num(e.x2)}"`,
    `y2="${num(e.y2)}"`,
    styleAttrs(e),
  ].filter(Boolean).join(" ");
  return `<line ${attrs}/>`;
}

function renderPolygon(e) {
  return `<polygon points="${pointsStr(e.points)}" ${styleAttrs(e)}/>`;
}

function renderPolyline(e) {
  return `<polyline points="${pointsStr(e.points)}" ${styleAttrs(e)}/>`;
}

function renderPath(e) {
  return `<path d="${pathDStr(e.d)}" ${styleAttrs(e)}/>`;
}

function renderText(e) {
  const attrs = [
    `x="${num(e.x)}"`,
    `y="${num(e.y)}"`,
    e.font_size ? `font-size="${num(e.font_size)}"` : "",
    e.font_family ? `font-family="${esc(e.font_family)}"` : "",
    styleAttrs(e),
  ].filter(Boolean).join(" ");
  return `<text ${attrs}>${esc(e.content || "")}</text>`;
}

function renderContainer(e) {
  const inner = (e.children || []).map(renderElement).join("");
  const opacity = typeof e.opacity === "number" && e.opacity !== 1.0
    ? ` opacity="${num(e.opacity)}"`
    : "";
  return `<g${opacity}>${inner}</g>`;
}

// ─── Helpers ────────────────────────────────────────────────

function num(n) {
  if (typeof n !== "number") return "0";
  // Canonical number formatting — integers without decimal, floats
  // with up to 6 decimal places trimmed.
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

function pointsStr(points) {
  if (!points || !points.length) return "";
  return points
    .map((p) => Array.isArray(p) ? `${num(p[0])},${num(p[1])}` : `${num(p.x)},${num(p.y)}`)
    .join(" ");
}

function pathDStr(commands) {
  if (!commands || !commands.length) return "";
  return commands.map(pathCmdStr).join(" ");
}

function pathCmdStr(cmd) {
  const t = cmd.type;
  switch (t) {
    case "M": case "L": case "T":
      return `${t} ${num(cmd.x)} ${num(cmd.y)}`;
    case "H": return `H ${num(cmd.x)}`;
    case "V": return `V ${num(cmd.y)}`;
    case "C":
      return `C ${num(cmd.x1)} ${num(cmd.y1)} ${num(cmd.x2)} ${num(cmd.y2)} ${num(cmd.x)} ${num(cmd.y)}`;
    case "S":
      return `S ${num(cmd.x2)} ${num(cmd.y2)} ${num(cmd.x)} ${num(cmd.y)}`;
    case "Q":
      return `Q ${num(cmd.x1)} ${num(cmd.y1)} ${num(cmd.x)} ${num(cmd.y)}`;
    case "A":
      return `A ${num(cmd.rx)} ${num(cmd.ry)} ${num(cmd.rotation || 0)} ${cmd.large_arc ? 1 : 0} ${cmd.sweep ? 1 : 0} ${num(cmd.x)} ${num(cmd.y)}`;
    case "Z": return "Z";
    default: return "";
  }
}

function styleAttrs(elem) {
  const parts = [];
  if (elem.fill === null) {
    parts.push('fill="none"');
  } else if (typeof elem.fill === "string") {
    parts.push(`fill="${esc(elem.fill)}"`);
  }
  if (elem.stroke === null) {
    parts.push('stroke="none"');
  } else if (elem.stroke && typeof elem.stroke === "object") {
    if (elem.stroke.color) parts.push(`stroke="${esc(elem.stroke.color)}"`);
    if (typeof elem.stroke.width === "number") {
      parts.push(`stroke-width="${num(elem.stroke.width)}"`);
    }
  }
  if (typeof elem.opacity === "number" && elem.opacity !== 1.0) {
    parts.push(`opacity="${num(elem.opacity)}"`);
  }
  if (elem.visibility === "outline") {
    // Outline mode: show as thin stroked path, no fill.
    parts.push('fill="none"', 'stroke="#666"', 'stroke-width="1"');
  }
  return parts.join(" ");
}
