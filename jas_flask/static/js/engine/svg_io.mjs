// Minimal SVG import / export for V1 element primitives:
//   rect, circle, ellipse, line, path, text, group, layer.
//
// Lives client-side (per FLASK_PARITY.md §2 thick-client decision)
// rather than calling out to jas/geometry/svg.py which would couple
// Flask to the PySide6 app's Python deps. Server-side svg.py
// remains the canonical implementation for the native apps;
// matching extends to attribute names (fill, stroke, stroke-width,
// d, x, y, …) so files round-trip across all five apps.
//
// V1 limits — gradient / pattern fills, opacity masks, blend
// modes, transforms, brushes, hyphenation, and text layout are
// out of scope. Round-trip drops anything not in the allowlist
// rather than raising; we trade fidelity for the ability to
// open a file at all.

const SVG_NS = "http://www.w3.org/2000/svg";

// ── Export ─────────────────────────────────────────────

/**
 * Serialize a Document to an SVG document string.
 * @param {Object} doc      Document (engine/document.mjs shape)
 * @param {Object} [opts]   { width, height } default canvas size
 */
export function exportSVG(doc, opts = {}) {
  const width = opts.width ?? 800;
  const height = opts.height ?? 600;
  const layers = (doc?.layers || []).map(serializeElement).join("");
  return (
    `<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n` +
    `<svg xmlns="${SVG_NS}" width="${width}" height="${height}" ` +
    `viewBox="0 0 ${width} ${height}">${layers}</svg>\n`
  );
}

function serializeElement(elem) {
  if (!elem || typeof elem !== "object") return "";
  switch (elem.type) {
    case "layer":
    case "group": {
      const children = (elem.children || []).map(serializeElement).join("");
      const attrs = [];
      if (elem.type === "layer" && elem.name) {
        attrs.push(`inkscape:label="${esc(elem.name)}"`);
      }
      return `<g${commonAttrs(elem)}${attrs.length ? " " + attrs.join(" ") : ""}>${children}</g>`;
    }
    case "rect":
      return `<rect x="${num(elem.x)}" y="${num(elem.y)}" ` +
             `width="${num(elem.width)}" height="${num(elem.height)}"` +
             commonAttrs(elem) + paintAttrs(elem) + "/>";
    case "circle":
      return `<circle cx="${num(elem.cx)}" cy="${num(elem.cy)}" ` +
             `r="${num(elem.r)}"` + commonAttrs(elem) + paintAttrs(elem) + "/>";
    case "ellipse":
      return `<ellipse cx="${num(elem.cx)}" cy="${num(elem.cy)}" ` +
             `rx="${num(elem.rx)}" ry="${num(elem.ry)}"` +
             commonAttrs(elem) + paintAttrs(elem) + "/>";
    case "line":
      return `<line x1="${num(elem.x1)}" y1="${num(elem.y1)}" ` +
             `x2="${num(elem.x2)}" y2="${num(elem.y2)}"` +
             commonAttrs(elem) + paintAttrs(elem) + "/>";
    case "path": {
      const d = pathCmdsToD(elem.d || []);
      return `<path d="${esc(d)}"` +
             commonAttrs(elem) + paintAttrs(elem) + "/>";
    }
    case "text":
      return `<text x="${num(elem.x)}" y="${num(elem.y)}" ` +
             `font-size="${num(elem.font_size ?? 12)}"` +
             commonAttrs(elem) + paintAttrs(elem) +
             `>${esc(elem.content || "")}</text>`;
    default:
      return "";
  }
}

function pathCmdsToD(cmds) {
  const parts = [];
  for (const c of cmds) {
    switch (c.type) {
      case "M": parts.push(`M ${num(c.x)} ${num(c.y)}`); break;
      case "L": parts.push(`L ${num(c.x)} ${num(c.y)}`); break;
      case "C": parts.push(`C ${num(c.x1)} ${num(c.y1)} ${num(c.x2)} ${num(c.y2)} ${num(c.x)} ${num(c.y)}`); break;
      case "Q": parts.push(`Q ${num(c.x1)} ${num(c.y1)} ${num(c.x)} ${num(c.y)}`); break;
      case "Z": parts.push("Z"); break;
    }
  }
  return parts.join(" ");
}

function commonAttrs(elem) {
  const out = [];
  if (elem.opacity != null && elem.opacity !== 1) out.push(`opacity="${num(elem.opacity)}"`);
  if (elem.locked) out.push(`data-locked="true"`);
  return out.length ? " " + out.join(" ") : "";
}

function paintAttrs(elem) {
  const out = [];
  if (elem.fill !== undefined) out.push(`fill="${esc(String(elem.fill ?? "none"))}"`);
  if (elem.stroke !== undefined) out.push(`stroke="${esc(String(elem.stroke ?? "none"))}"`);
  if (elem.stroke_width != null) out.push(`stroke-width="${num(elem.stroke_width)}"`);
  return out.length ? " " + out.join(" ") : "";
}

function num(n) {
  if (n == null || isNaN(Number(n))) return "0";
  const v = Number(n);
  return Number.isInteger(v) ? String(v) : v.toFixed(3).replace(/\.?0+$/, "");
}

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── Import ─────────────────────────────────────────────

/**
 * Parse an SVG string into a Document. Returns the Document
 * shape (`{ layers, selection, artboards }`) or null if the
 * input doesn't parse as SVG. Drops elements / attributes
 * outside the V1 allowlist silently.
 */
export function importSVG(svgText) {
  if (typeof svgText !== "string" || !svgText.trim()) return null;
  let doc;
  try {
    doc = new DOMParser().parseFromString(svgText, "image/svg+xml");
  } catch (_) {
    return null;
  }
  const root = doc.documentElement;
  if (!root || root.localName !== "svg") return null;

  // Children of the <svg> root land in a single Layer named
  // "Layer 1", matching emptyDocument()'s default.
  const layer = { type: "layer", name: "Layer 1", children: [],
                  visibility: "preview", locked: false, opacity: 1 };
  for (const child of root.children) {
    const e = parseElement(child);
    if (e) layer.children.push(e);
  }
  return { layers: [layer], selection: [], artboards: [] };
}

function parseElement(node) {
  switch (node.localName) {
    case "g": {
      const elem = { type: "group", children: [], visibility: "preview",
                     locked: false, opacity: parseOpacity(node) };
      for (const child of node.children) {
        const e = parseElement(child);
        if (e) elem.children.push(e);
      }
      return elem;
    }
    case "rect": return {
      type: "rect",
      x: f(node, "x"), y: f(node, "y"),
      width: f(node, "width"), height: f(node, "height"),
      ...paintFromNode(node), ...commonFromNode(node),
    };
    case "circle": return {
      type: "circle",
      cx: f(node, "cx"), cy: f(node, "cy"), r: f(node, "r"),
      ...paintFromNode(node), ...commonFromNode(node),
    };
    case "ellipse": return {
      type: "ellipse",
      cx: f(node, "cx"), cy: f(node, "cy"),
      rx: f(node, "rx"), ry: f(node, "ry"),
      ...paintFromNode(node), ...commonFromNode(node),
    };
    case "line": return {
      type: "line",
      x1: f(node, "x1"), y1: f(node, "y1"),
      x2: f(node, "x2"), y2: f(node, "y2"),
      ...paintFromNode(node), ...commonFromNode(node),
    };
    case "path": return {
      type: "path",
      d: parsePathD(node.getAttribute("d") || ""),
      ...paintFromNode(node), ...commonFromNode(node),
    };
    case "text": return {
      type: "text",
      x: f(node, "x"), y: f(node, "y"),
      content: node.textContent || "",
      font_size: f(node, "font-size") || 12,
      ...paintFromNode(node), ...commonFromNode(node),
    };
    default: return null;
  }
}

function f(node, attr) {
  const v = node.getAttribute(attr);
  if (v == null || v === "") return 0;
  // Strip "px" / "pt" suffix; convert pt → px if present.
  if (/pt$/.test(v)) return parseFloat(v) * (96 / 72);
  return parseFloat(v) || 0;
}

function paintFromNode(node) {
  const out = {};
  const fill = node.getAttribute("fill");
  if (fill != null) out.fill = fill;
  const stroke = node.getAttribute("stroke");
  if (stroke != null) out.stroke = stroke;
  const sw = node.getAttribute("stroke-width");
  if (sw != null) out.stroke_width = parseFloat(sw) || 0;
  return out;
}

function commonFromNode(node) {
  return {
    opacity: parseOpacity(node),
    visibility: "preview",
    locked: node.getAttribute("data-locked") === "true",
  };
}

function parseOpacity(node) {
  const v = node.getAttribute("opacity");
  if (v == null) return 1;
  const n = parseFloat(v);
  return isNaN(n) ? 1 : n;
}

// Minimal SVG path-d parser. Handles M / L / C / Q / Z (absolute
// only, or implicitly absolute when written without explicit
// command letter after the first M). Matches the path-command
// shape engine/document.mjs::mkPath produces.
function parsePathD(d) {
  const out = [];
  if (!d) return out;
  const tokens = d.match(/[MLCQZmlcqz]|-?\d*\.?\d+(?:e[-+]?\d+)?/gi) || [];
  let i = 0;
  let cmd = null;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[MLCQZmlcqz]$/.test(t)) {
      cmd = t.toUpperCase();
      i++;
      if (cmd === "Z") { out.push({ type: "Z" }); cmd = null; }
      continue;
    }
    if (cmd === "M" || cmd === "L") {
      out.push({ type: cmd, x: +t, y: +tokens[i + 1] }); i += 2;
    } else if (cmd === "C") {
      out.push({
        type: "C",
        x1: +t, y1: +tokens[i + 1],
        x2: +tokens[i + 2], y2: +tokens[i + 3],
        x: +tokens[i + 4], y: +tokens[i + 5],
      });
      i += 6;
    } else if (cmd === "Q") {
      out.push({
        type: "Q",
        x1: +t, y1: +tokens[i + 1],
        x: +tokens[i + 2], y: +tokens[i + 3],
      });
      i += 4;
    } else {
      // Unknown / unhandled — bail to avoid an infinite loop.
      i++;
    }
  }
  return out;
}
