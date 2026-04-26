// Canvas bootstrap — wires the JS engine to per-tab canvas DOM.
//
// Each tab in the UI corresponds to one document with one canvas. The
// canvases are added dynamically by actions.yaml::new_document (and
// open_file) via app.js's create_child effect; this module watches the
// drawing surface for new app-canvas-stack elements and binds a fresh
// Model (with one default artboard, see emptyDocument) to each.
//
// Active canvas: tracked via state.active_tab. Cross-cutting hooks
// (save / open / undo / redo, color/stroke writes) operate on the
// active Model. Mouse events land on whichever canvas is visible —
// app.js's bind:visible toggles display:none on the inactive ones.
//
// Imports use absolute /static/js/engine paths so cache-busted module
// URLs don't infect module-internal references.

import { Model } from "/static/js/engine/model.mjs";
import { emptyDocument } from "/static/js/engine/document.mjs";
import { StateStore } from "/static/js/engine/store.mjs";
import { registerTools, dispatchEvent } from "/static/js/engine/tools.mjs";
import {
  renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
  renderArtboardFillLayer, renderArtboardDecorationLayer,
} from "/static/js/engine/canvas.mjs";
import { exportSVG, importSVG } from "/static/js/engine/svg_io.mjs";
import { setElementAttr } from "/static/js/engine/effects.mjs";

let store = null;

// canvasId → { canvasEl, model }
const canvases = new Map();
let activeCanvasId = null;

/**
 * One-time setup. Idempotent — second call is a no-op.
 */
export function bootstrap() {
  if (store) return { store };

  store = new StateStore({
    state: globalThis.APP_STATE ? { ...globalThis.APP_STATE } : {},
  });

  // Register tool yamls so dispatchEvent can find on_<event>
  // handlers. APP_TOOLS is the compiled tools dict the server
  // injects into normal.html via {{ tools_json | safe }}.
  if (globalThis.APP_TOOLS) {
    registerTools(globalThis.APP_TOOLS, store);
  }

  // Watch drawing_surface for canvases. Per the layout spec, none
  // exist on first paint; new_document creates the first one.
  const drawingSurface = document.getElementById("drawing_surface");
  if (drawingSurface) {
    drawingSurface
      .querySelectorAll(".app-canvas-stack")
      .forEach(adoptCanvas);
    new MutationObserver(handleMutations).observe(drawingSurface, {
      childList: true, subtree: true,
    });
  }

  // Track active tab so the JAS hooks (save/undo/redo) and the panel
  // → selection writer below operate on the right document.
  store.addListener((path) => {
    if (path === "state.active_tab") refreshActiveCanvas();
  });
  refreshActiveCanvas();

  // Panel → document propagation. V1 panels (Color, Stroke) drive
  // global state.fill_color / state.stroke_color etc.; the listener
  // catches the writes and pushes the new value onto every selected
  // element of the active document. Per-change snapshot semantics:
  // every state change becomes a separate undo entry. Drag boundary
  // handling is deferred.
  const PANEL_TO_ATTR = {
    "state.fill_color": "fill",
    "state.stroke_color": "stroke",
    "state.stroke_width": "stroke-width",
  };
  store.addListener((path, value) => {
    const attr = PANEL_TO_ATTR[path];
    if (!attr) return;
    const m = activeModel();
    if (!m || !m.selection || m.selection.length === 0) return;
    m.snapshot();
    m.mutate((d) => {
      let next = d;
      for (const elemPath of d.selection) {
        next = setElementAttr(next, elemPath, attr, value);
      }
      return next;
    });
  });

  // Devtools handle + app.js bridge.
  globalThis.JAS = Object.assign(globalThis.JAS || {}, {
    store,
    /** Active model — null until at least one canvas exists. */
    get model() { return activeModel(); },
    /** Set of all canvas ids currently bound to a model. */
    canvases: () => [...canvases.keys()],

    mirrorState(key, value) {
      try { store.set("state." + key, value); }
      catch (_) { /* unknown scope — ignore */ }
    },

    saveAs(filename) {
      const m = activeModel();
      if (!m) return;
      const name = filename || (m.filename + ".svg");
      const svg = exportSVG(m.document);
      const blob = new Blob([svg], { type: "image/svg+xml" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      m.markSaved();
    },
    undo() { const m = activeModel(); if (m) m.undo(); },
    redo() { const m = activeModel(); if (m) m.redo(); },
    open() {
      return new Promise((resolve, reject) => {
        const m = activeModel();
        if (!m) { reject(new Error("no active document")); return; }
        const input = document.createElement("input");
        input.type = "file";
        input.accept = "image/svg+xml,.svg";
        input.style.display = "none";
        input.addEventListener("change", () => {
          const file = input.files && input.files[0];
          if (!file) { reject(new Error("no file")); return; }
          const reader = new FileReader();
          reader.onload = () => {
            const parsed = importSVG(String(reader.result || ""));
            if (!parsed) { reject(new Error("not an SVG document")); return; }
            m.snapshot();
            m.setDocument(parsed);
            m.filename = file.name.replace(/\.svg$/i, "") || "Untitled";
            m.markSaved();
            resolve();
          };
          reader.onerror = () => reject(reader.error);
          reader.readAsText(file);
        });
        document.body.appendChild(input);
        input.click();
        document.body.removeChild(input);
      });
    },
  });

  return { store };
}

function handleMutations(mutations) {
  for (const m of mutations) {
    for (const node of m.addedNodes) {
      if (node.nodeType !== 1) continue;
      if (node.classList && node.classList.contains("app-canvas-stack")) {
        adoptCanvas(node);
      } else if (node.querySelectorAll) {
        node.querySelectorAll(".app-canvas-stack").forEach(adoptCanvas);
      }
    }
    for (const node of m.removedNodes) {
      if (node.nodeType !== 1) continue;
      if (node.classList && node.classList.contains("app-canvas-stack")) {
        releaseCanvas(node);
      } else if (node.querySelectorAll) {
        node.querySelectorAll(".app-canvas-stack").forEach(releaseCanvas);
      }
    }
  }
}

function adoptCanvas(canvasEl) {
  const id = canvasEl.id;
  if (!id || canvases.has(id)) return;
  const model = new Model(emptyDocument());
  canvases.set(id, { canvasEl, model });
  model.addListener(() => renderCanvas(canvasEl, model));
  renderCanvas(canvasEl, model);
  wireCanvasEvents(canvasEl, model);
  refreshActiveCanvas();
}

function releaseCanvas(canvasEl) {
  const id = canvasEl.id;
  if (!id) return;
  canvases.delete(id);
  if (activeCanvasId === id) activeCanvasId = null;
  refreshActiveCanvas();
}

function refreshActiveCanvas() {
  if (!store) return;
  const tab = store.get("state.active_tab");
  if (typeof tab === "number") {
    const id = `canvas_surface_${tab}`;
    if (canvases.has(id)) { activeCanvasId = id; return; }
  }
  // Fallback to the first registered canvas, if any.
  if (!activeCanvasId || !canvases.has(activeCanvasId)) {
    activeCanvasId = canvases.size ? [...canvases.keys()][0] : null;
  }
}

function activeModel() {
  if (!activeCanvasId) return null;
  const entry = canvases.get(activeCanvasId);
  return entry ? entry.model : null;
}

function wireCanvasEvents(canvasEl, model) {
  const docLayer = canvasEl.querySelector('[data-canvas-layer="doc"]');
  if (!docLayer) return;

  function payload(type, evt) {
    const r = docLayer.getBoundingClientRect();
    return {
      type,
      x: evt.clientX - r.left,
      y: evt.clientY - r.top,
      modifiers: {
        shift: evt.shiftKey,
        ctrl: evt.ctrlKey,
        alt: evt.altKey,
        meta: evt.metaKey,
      },
    };
  }
  function activeTool() {
    return store.get("state.active_tool") || "selection";
  }

  let dragging = false;
  docLayer.addEventListener("mousedown", (evt) => {
    if (evt.button !== 0) return;
    dragging = true;
    dispatchEvent(activeTool(), payload("mousedown", evt), store, { model });
    evt.preventDefault();
  });
  // Move/up listen on document so a drag past the canvas edge keeps
  // tracking until release.
  document.addEventListener("mousemove", (evt) => {
    if (!dragging) return;
    dispatchEvent(activeTool(), payload("mousemove", evt), store, { model });
  });
  document.addEventListener("mouseup", (evt) => {
    if (!dragging) return;
    dragging = false;
    dispatchEvent(activeTool(), payload("mouseup", evt), store, { model });
  });
  docLayer.addEventListener("dblclick", (evt) => {
    if (evt.button !== 0) return;
    dispatchEvent(activeTool(), payload("dblclick", evt), store, { model });
  });
}

function renderCanvas(canvasEl, model) {
  setLayer(canvasEl, "artboard-fill", renderArtboardFillLayer(model.document));
  setLayer(canvasEl, "doc", renderDocumentLayer(model.document));
  // Fade overlay (fade_region_outside_artboard) requires a stable
  // un-transformed viewBox; the canvas applies a CSS transform for
  // pan/zoom that complicates the calculation. Fills + borders +
  // accent + labels render unconditionally; the fade overlay is
  // deferred until pan/zoom plumbing exposes the viewport rect.
  setLayer(canvasEl, "artboard-deco", renderArtboardDecorationLayer(model.document, {
    panelSelectedIds: panelSelectedArtboardIds(),
  }));
  setLayer(canvasEl, "selection", renderSelectionLayer(model.document));
  setLayer(canvasEl, "overlay", "");
}

function panelSelectedArtboardIds() {
  if (!store) return [];
  const ids = store.get("state.artboards_panel_selection_ids");
  return Array.isArray(ids) ? ids : [];
}

function setLayer(canvasEl, name, svgFragment) {
  const el = canvasEl.querySelector(`[data-canvas-layer="${name}"]`);
  if (el) el.innerHTML = svgFragment || "";
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrap);
} else {
  bootstrap();
}
