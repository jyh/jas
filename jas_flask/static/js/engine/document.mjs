// Document model — JS port skeleton.
//
// Mirrors the Document + Element types from `jas/document/*`,
// `jas_dioxus/src/document/*`, `JasSwift/Sources/Document/*`,
// `jas_ocaml/lib/document/*`. V1 scope covers just enough to let
// tools mutate structure: create / delete / modify elements, path-
// based addressing, and JSON round-trip for autosave / file I/O.
//
// Element types are discriminated by a `type:` string — not a JS
// class hierarchy — so Document instances are JSON-serializable and
// can flow through postMessage / IndexedDB without custom revivers.
//
// Rendering (element → SVG nodes) lives in a separate module; this
// file is pure data.

// ─── Element types ──────────────────────────────────────────
//
// Each element has a `type` field identifying the variant. Optional
// common fields: `id` (UUID or stable slug), `name` (user-editable),
// `visibility` ("preview" | "outline" | "invisible"), `locked`,
// `opacity`, `transform`, `fill`, `stroke`.
//
// Geometry fields are per-type (rect has x/y/width/height; path has
// d; etc.).

/** Construct a Rect element. */
export function mkRect({ x = 0, y = 0, width = 0, height = 0, ...common } = {}) {
  return { type: "rect", x, y, width, height, ...defaults(common) };
}

/** Construct a Circle element. */
export function mkCircle({ cx = 0, cy = 0, r = 0, ...common } = {}) {
  return { type: "circle", cx, cy, r, ...defaults(common) };
}

/** Construct an Ellipse element. */
export function mkEllipse({ cx = 0, cy = 0, rx = 0, ry = 0, ...common } = {}) {
  return { type: "ellipse", cx, cy, rx, ry, ...defaults(common) };
}

/** Construct a Line element. */
export function mkLine({ x1 = 0, y1 = 0, x2 = 0, y2 = 0, ...common } = {}) {
  return { type: "line", x1, y1, x2, y2, ...defaults(common) };
}

/** Construct a Path element. `d` is an array of PathCommand objects. */
export function mkPath({ d = [], ...common } = {}) {
  return { type: "path", d: d.slice(), ...defaults(common) };
}

/** Construct a Text element. */
export function mkText({ x = 0, y = 0, content = "", font_size = 12, ...common } = {}) {
  return { type: "text", x, y, content, font_size, ...defaults(common) };
}

/** Construct a Group element — container with no own geometry. */
export function mkGroup({ children = [], ...common } = {}) {
  return { type: "group", children: children.slice(), ...defaults(common) };
}

/** Construct a Layer element — top-level container, commonly named. */
export function mkLayer({ name = "Layer", children = [], ...common } = {}) {
  return { type: "layer", name, children: children.slice(), ...defaults(common) };
}

function defaults(common) {
  return {
    visibility: "preview",
    locked: false,
    opacity: 1.0,
    ...common,
  };
}

/** Return true if the element has a `children` array (Group, Layer). */
export function isContainer(elem) {
  return elem && (elem.type === "group" || elem.type === "layer");
}

// ─── Document ───────────────────────────────────────────────

/**
 * Create an empty Document with a single empty layer and a single
 * Letter-sized artboard. The artboard structure matches the native
 * apps' Document::default (jas_dioxus/src/document/document.rs); the
 * fill diverges intentionally — Flask defaults to white so the page
 * is visible against the dark pasteboard, whereas the Rust struct
 * default is transparent (it sits on a white canvas).
 */
export function emptyDocument() {
  return {
    layers: [mkLayer({ name: "Layer 1" })],
    selection: [],
    artboards: [makeDefaultArtboard({ fill: "#ffffff" })],
    artboard_options: {
      fade_region_outside_artboard: true,
      update_while_dragging: true,
    },
  };
}

const ARTBOARD_ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz";

/** Mint an 8-char base36 id matching the Rust artboard id format. */
export function generateArtboardId() {
  let s = "";
  for (let i = 0; i < 8; i++) {
    const idx = Math.floor(Math.random() * ARTBOARD_ID_ALPHABET.length);
    s += ARTBOARD_ID_ALPHABET[idx];
  }
  return s;
}

/** Canonical default artboard — Letter 612x792 at origin, transparent
 * fill, all display toggles off. */
export function makeDefaultArtboard(over = {}) {
  return {
    id: generateArtboardId(),
    name: "Artboard 1",
    x: 0, y: 0, width: 612, height: 792,
    fill: "transparent",
    show_center_mark: false,
    show_cross_hairs: false,
    show_video_safe_areas: false,
    video_ruler_pixel_aspect_ratio: 1.0,
    ...over,
  };
}

/**
 * Walk to an element by its tree path. Path is an array of indices:
 *   [0]     → first layer
 *   [0, 2]  → third child of first layer
 *   [0, 2, 1] → second child of that
 * Returns `null` for any invalid intermediate index.
 */
export function getElement(doc, path) {
  if (!path || path.length === 0) return null;
  if (path[0] < 0 || path[0] >= doc.layers.length) return null;
  let elem = doc.layers[path[0]];
  for (let i = 1; i < path.length; i++) {
    if (!isContainer(elem)) return null;
    const idx = path[i];
    if (idx < 0 || idx >= elem.children.length) return null;
    elem = elem.children[idx];
  }
  return elem;
}

/**
 * Return a deep-cloned Document. Used by the Model before pushing onto
 * the undo stack. Native apps use structural sharing where possible;
 * JS starts with plain deep clone, swap for structural sharing
 * (im-js / Immer) later if profiling shows need.
 */
export function cloneDocument(doc) {
  return structuredClone(doc);
}

/** Serialize a Document to a JSON-plain object. */
export function docToJson(doc) {
  return structuredClone(doc);
}

/** Parse a Document from JSON. Shallow validation only. */
export function docFromJson(json) {
  if (!json || !Array.isArray(json.layers)) return emptyDocument();
  return structuredClone(json);
}

// ─── Pure mutations ─────────────────────────────────────────
//
// Each function returns a NEW Document with the change applied; the
// input is not mutated. Callers who want undo history should clone +
// snapshot via Model.snapshot() before invoking these.

/**
 * Replace the selection with a given list of path-arrays. Paths that
 * don't resolve to elements are silently dropped.
 */
export function setSelection(doc, paths) {
  const valid = paths.filter((p) => getElement(doc, p) !== null);
  return { ...doc, selection: valid.map((p) => p.slice()) };
}

/** Add a path to the selection, if not already present. */
export function addToSelection(doc, path) {
  if (doc.selection.some((p) => arraysEqual(p, path))) return doc;
  return { ...doc, selection: [...doc.selection, path.slice()] };
}

/** Toggle a path's membership in the selection. */
export function toggleSelection(doc, path) {
  const hasIt = doc.selection.some((p) => arraysEqual(p, path));
  if (hasIt) {
    return {
      ...doc,
      selection: doc.selection.filter((p) => !arraysEqual(p, path)),
    };
  }
  return addToSelection(doc, path);
}

/** Clear the selection. */
export function clearSelection(doc) {
  return { ...doc, selection: [] };
}

function arraysEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
