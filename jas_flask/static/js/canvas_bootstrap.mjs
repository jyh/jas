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
import { emptyDocument, ensureDocumentInvariants } from "/static/js/engine/document.mjs";
import { StateStore } from "/static/js/engine/store.mjs";
import { registerTools, dispatchEvent, getTool } from "/static/js/engine/tools.mjs";
import {
  renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
  renderArtboardFillLayer, renderArtboardDecorationLayer,
} from "/static/js/engine/canvas.mjs";
import { Scope } from "/static/js/engine/scope.mjs";
import { exportSVG, importSVG } from "/static/js/engine/svg_io.mjs";
import { setElementAttr } from "/static/js/engine/effects.mjs";
import { saveSession, loadSession } from "/static/js/engine/session.mjs";

const SESSION_AUTOSAVE_MS = 30000;

let store = null;

// canvasId → { canvasEl, model }
const canvases = new Map();
let activeCanvasId = null;

// On startup, when restoring saved tabs, the bootstrap dispatches
// new_document once per saved doc. Each dispatch synchronously
// creates a canvas via app.js's create_child effect; the
// MutationObserver fires, adoptCanvas runs, and pops the next saved
// doc off this queue instead of seeding emptyDocument().
const pendingRestoreDocs = [];

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
  } else {
    console.warn("[bootstrap] APP_TOOLS missing — tools won't dispatch");
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
  // → selection writer below operate on the right document. Also
  // re-render the overlay layer of the active canvas whenever tool-
  // local state mutates, so drag previews (rect dashed outline, pen
  // anchor handles, …) follow the cursor.
  store.addListener((path) => {
    if (path === "state.active_tab") {
      refreshActiveCanvas();
      return;
    }
    if (path === "state.active_tool" || path.startsWith("tool.")) {
      const entry = activeCanvasId ? canvases.get(activeCanvasId) : null;
      if (entry) renderToolOverlay(entry.canvasEl);
    }
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

  // ── Session persistence ─────────────────────────────────
  //
  // beforeunload flushes immediately. Per-mutation autosave is wired
  // inside adoptCanvas (each new model gets a debounced listener);
  // see scheduleSave / flushSession below.
  window.addEventListener("beforeunload", flushSession);

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

  restoreSavedWorkspace();
  return { store };
}

/**
 * Hydrate the workspace from localStorage. Called once during
 * bootstrap, after JAS is exposed and the MutationObserver is armed.
 *
 * Strategy: queue the saved documents, then dispatch new_document
 * once per saved tab via app.js's APP_DISPATCH. Each dispatch
 * synchronously creates a tab + canvas (matching the YAML spec's
 * happy path); the MutationObserver fires, adoptCanvas pops the next
 * pending doc and binds a Model around it. After the dispatch loop
 * the engine state is folded back in (active_tool, fill_color, …),
 * and active_tab is overridden to the saved value (the dispatch loop
 * leaves it pointing at the most-recently created tab).
 */
function restoreSavedWorkspace() {
  const saved = loadSession();
  if (!saved || saved.documents.length === 0) return;
  if (typeof globalThis.APP_DISPATCH !== "function") {
    console.warn("[session] APP_DISPATCH not available; skipping restore");
    return;
  }

  pendingRestoreDocs.push(...saved.documents);
  const N = saved.documents.length;
  for (let i = 0; i < N; i++) {
    globalThis.APP_DISPATCH("new_document", {});
  }

  // Restore the rest of the engine state. tab_count / active_tab
  // were just driven by the dispatch loop, so let those stand for
  // tab_count and override active_tab from the saved value.
  const SKIP = new Set(["tab_count"]);
  const setStateFn = globalThis.APP_SET_STATE;
  for (const [k, v] of Object.entries(saved.state || {})) {
    if (SKIP.has(k)) continue;
    if (k === "active_tab") continue; // applied below
    if (typeof setStateFn === "function") {
      setStateFn(k, v);
    } else {
      try { store.set("state." + k, v); } catch (_) { /* ignore */ }
    }
  }
  // active_tab last so panel-visibility bindings settle on the right
  // canvas.
  if (saved.state && Object.prototype.hasOwnProperty.call(saved.state, "active_tab")) {
    if (typeof setStateFn === "function") {
      setStateFn("active_tab", saved.state.active_tab);
    } else {
      try { store.set("state.active_tab", saved.state.active_tab); } catch (_) {}
    }
  }
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
  // Pull a saved document off the pending-restore queue if one is
  // waiting; otherwise seed a fresh empty doc with one default
  // artboard. The queue is populated only at startup from
  // localStorage, so runtime new_document calls fall through to the
  // empty-doc branch.
  const restored = pendingRestoreDocs.shift();
  let model;
  if (restored) {
    // Defensive: an old localStorage payload may predate a schema
    // bump (e.g. saved before artboards were a thing). Patch the doc
    // up to the current invariants before binding.
    const doc = ensureDocumentInvariants(restored.document);
    model = new Model(doc, restored.filename || undefined);
    model.markSaved();
  } else {
    model = new Model(emptyDocument());
  }
  canvases.set(id, { canvasEl, model });
  model.addListener(() => renderCanvas(canvasEl, model));
  model.addListener(scheduleSave);
  renderCanvas(canvasEl, model);
  wireCanvasEvents(canvasEl, model);
  refreshActiveCanvas();
}

// ── Session persistence helpers ──────────────────────────
//
// scheduleSave: debounced autosave (every model mutation arms a
// timer; localStorage write fires once per 30s window). flushSession:
// synchronous snapshot used on beforeunload and as the timer body.
let saveDebounceTimer = null;
function scheduleSave() {
  if (saveDebounceTimer != null) return;
  saveDebounceTimer = setTimeout(() => {
    saveDebounceTimer = null;
    flushSession();
  }, SESSION_AUTOSAVE_MS);
}
function flushSession() {
  if (!store) return;
  const entries = [];
  for (const [canvas_id, { model }] of canvases.entries()) {
    entries.push({ canvas_id, model });
  }
  saveSession(entries, store.state || {});
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
  // Hit target is the canvas-stack itself, not a single SVG layer.
  // The doc-layer SVG defaults to pointer-events: visiblePainted, so
  // an empty SVG (fresh document, no shapes drawn yet) wouldn't catch
  // the user's first mousedown and tools like Rect couldn't even
  // start a drag. The other layers above doc all have
  // pointer-events: none, so events naturally fall through to the
  // canvas-stack.
  function payload(type, evt) {
    const r = canvasEl.getBoundingClientRect();
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

  // Re-render the active tool's overlay after each dispatch.
  // Tools backed by tool-local state (Rect, Selection) already
  // trigger a re-render via the store listener wired in bootstrap.
  // Tools backed by buffer state (Pencil's freehand drag, Pen's
  // anchor accumulator) mutate point_buffers / anchor_buffers
  // outside the store, so the overlay needs an explicit refresh
  // after every mouse event to keep the live preview in sync.
  function dispatchAndRefresh(type, evt) {
    dispatchEvent(activeTool(), payload(type, evt), store, { model });
    renderToolOverlay(canvasEl);
  }

  let dragging = false;
  canvasEl.addEventListener("mousedown", (evt) => {
    if (evt.button !== 0) return;
    dragging = true;
    dispatchAndRefresh("mousedown", evt);
    evt.preventDefault();
  });
  // Move/up listen on document so a drag past the canvas edge keeps
  // tracking until release.
  document.addEventListener("mousemove", (evt) => {
    if (!dragging) return;
    dispatchAndRefresh("mousemove", evt);
  });
  document.addEventListener("mouseup", (evt) => {
    if (!dragging) return;
    dragging = false;
    dispatchAndRefresh("mouseup", evt);
  });
  canvasEl.addEventListener("dblclick", (evt) => {
    if (evt.button !== 0) return;
    dispatchAndRefresh("dblclick", evt);
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
  renderToolOverlay(canvasEl);
}

// Render the active tool's overlay (the dashed preview most drawing
// tools draw during a drag). Re-runs on every relevant store change
// — see the listener wired in bootstrap().
function renderToolOverlay(canvasEl) {
  if (!store) return;
  const toolId = store.get("state.active_tool") || "selection";
  const toolSpec = getTool(toolId);
  if (!toolSpec || !toolSpec.overlay) {
    setLayer(canvasEl, "overlay", "");
    return;
  }
  const scope = new Scope({
    state: store.state,
    panel: store.panel,
    tool: store.tool,
  });
  setLayer(canvasEl, "overlay", renderOverlayLayer(toolSpec, scope));
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
