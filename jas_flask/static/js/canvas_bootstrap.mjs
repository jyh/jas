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
import {
  registerTools, dispatchEvent, getTool,
  activateTool, deactivateTool,
} from "/static/js/engine/tools.mjs";
import {
  renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
  renderArtboardFillLayer, renderArtboardDecorationLayer,
} from "/static/js/engine/canvas.mjs";
import { Scope } from "/static/js/engine/scope.mjs";
import { exportSVG, importSVG } from "/static/js/engine/svg_io.mjs";
import {
  setElementAttr, deleteSelectedElements,
  groupSelection, ungroupSelection,
} from "/static/js/engine/effects.mjs";
import { saveSession, loadSession } from "/static/js/engine/session.mjs";
import {
  elementToStateWrites, buildDasharray,
} from "/static/js/engine/stroke_sync.mjs";

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
  // local state mutates (so drag previews stay glued to the cursor)
  // and refresh the canvas cursor when the active tool changes.
  // Tracks the prior active_tool so the store listener can fire
  // on_leave for it before on_enter for the new tool. Tools that
  // accumulate buffer state (Pen, Pencil) commit / clear in their
  // on_leave handler — without this, switching tools mid-flow
  // would strand anchors / points in the buffer.
  let prevActiveTool = store.get("state.active_tool") || "selection";
  store.addListener((path, value) => {
    if (path === "state.active_tab") {
      refreshActiveCanvas();
      return;
    }
    if (path === "state.active_tool") {
      const next = String(value || "selection");
      const m = activeModel();
      if (m && prevActiveTool && prevActiveTool !== next) {
        deactivateTool(prevActiveTool, store, { model: m });
        activateTool(next, store, { model: m });
      }
      prevActiveTool = next;
      applyCanvasCursors();
    }
    if (path === "state.active_tool" || path.startsWith("tool.")) {
      const entry = activeCanvasId ? canvases.get(activeCanvasId) : null;
      if (entry) renderToolOverlay(entry.canvasEl);
    }
  });
  refreshActiveCanvas();
  applyCanvasCursors();

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
    "state.stroke_cap": "stroke-linecap",
    "state.stroke_join": "stroke-linejoin",
    "state.stroke_miter_limit": "stroke-miterlimit",
    "state.stroke_dasharray": "stroke-dasharray",
    "state.stroke_dashoffset": "stroke-dashoffset",
    // Arrowhead fields ride on jas-* element keys: SVG markers are
    // built from the document tree at render time (engine/arrowheads
    // emitArrowDefs), so they need to land on the element rather
    // than be stripped to a CSS-style attribute.
    "state.stroke_start_arrowhead": "jas-stroke-start-arrowhead",
    "state.stroke_end_arrowhead": "jas-stroke-end-arrowhead",
    "state.stroke_start_arrowhead_scale": "jas-stroke-start-arrowhead-scale",
    "state.stroke_end_arrowhead_scale": "jas-stroke-end-arrowhead-scale",
  };
  // State fields that contribute to the derived stroke-dasharray
  // string. When any of them changes, recompute and apply.
  const DASH_FIELDS = new Set([
    "state.stroke_dashed",
    "state.stroke_dash_1", "state.stroke_gap_1",
    "state.stroke_dash_2", "state.stroke_gap_2",
    "state.stroke_dash_3", "state.stroke_gap_3",
  ]);

  store.addListener((path, value) => {
    const m = activeModel();
    if (!m || !m.selection || m.selection.length === 0) return;
    if (DASH_FIELDS.has(path)) {
      const dasharray = buildDasharray(store.state || {});
      m.snapshot();
      m.mutate((d) => {
        let next = d;
        for (const elemPath of d.selection) {
          next = setElementAttr(next, elemPath, "stroke-dasharray", dasharray);
        }
        return next;
      });
      return;
    }
    const attr = PANEL_TO_ATTR[path];
    if (!attr) return;
    m.snapshot();
    m.mutate((d) => {
      let next = d;
      for (const elemPath of d.selection) {
        next = setElementAttr(next, elemPath, attr, value);
      }
      return next;
    });
  });

  // ── Keyboard wiring for canvas tools ──────────────────
  //
  // The Pen and Pencil tools have on_keydown handlers (Escape / Enter
  // commit or cancel an in-progress path). Capture-phase listener so
  // we win against app.js's bubble-phase Escape→wireframe toggle.
  // Only intercept the keys our tools care about, and only when the
  // active tool actually defines on_keydown — leaves the rest of the
  // keyboard (shortcuts, Escape outside drawing, etc.) to app.js.
  const TOOL_KEYS = new Set(["Escape", "Enter"]);
  document.addEventListener("keydown", (evt) => {
    if (!TOOL_KEYS.has(evt.key)) return;
    if (evt.target && (evt.target.tagName === "INPUT"
        || evt.target.tagName === "TEXTAREA"
        || evt.target.isContentEditable)) return;
    const m = activeModel();
    if (!m) return;
    const toolId = store.get("state.active_tool") || "selection";
    const tool = getTool(toolId);
    if (!tool || !tool.handlers || !tool.handlers.on_keydown) return;
    evt.preventDefault();
    evt.stopPropagation();
    dispatchEvent(toolId, {
      type: "keydown",
      key: evt.key,
      modifiers: {
        shift: evt.shiftKey, ctrl: evt.ctrlKey,
        alt: evt.altKey, meta: evt.metaKey,
      },
    }, store, { model: m });
    const entry = activeCanvasId ? canvases.get(activeCanvasId) : null;
    if (entry) renderToolOverlay(entry.canvasEl);
  }, true);

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

    /** Edit → Select All. Selects every direct child of every layer
     * that's neither locked nor invisible. Group/Layer recursion is
     * deferred — top-level children only, matching Illustrator-style
     * "the group itself is one selection" semantics. */
    selectAll() {
      const m = activeModel();
      if (!m) return;
      const paths = [];
      m.document.layers.forEach((layer, li) => {
        if (!layer || layer.visibility === "invisible") return;
        const children = Array.isArray(layer.children) ? layer.children : [];
        children.forEach((child, ci) => {
          if (!child) return;
          if (child.locked) return;
          if (child.visibility === "invisible") return;
          paths.push([li, ci]);
        });
      });
      m.snapshot();
      m.mutate((d) => ({ ...d, selection: paths.map((p) => p.slice()) }));
    },

    /** Edit → Delete Selection. Removes every currently-selected
     * element via the engine's deleteSelectedElements helper, in
     * reverse path order so sibling indices stay valid. */
    deleteSelection() {
      const m = activeModel();
      if (!m || !m.selection || m.selection.length === 0) return;
      m.snapshot();
      m.mutate(deleteSelectedElements);
    },

    /** Object → Group. Wraps the current selection (≥2 siblings) in
     * a new Group at the frontmost selected position. */
    groupSelection() {
      const m = activeModel();
      if (!m) return;
      m.snapshot();
      m.mutate(groupSelection);
    },

    /** Object → Ungroup. Promotes children of selected Groups one
     * level. Non-group elements in the selection are untouched. */
    ungroupSelection() {
      const m = activeModel();
      if (!m) return;
      m.snapshot();
      m.mutate(ungroupSelection);
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
  // Sessions saved before resolve() learned to evaluate the "not X"
  // prefix may carry literal "not …" strings in fields that were
  // supposed to hold booleans (e.g. stroke_dashed). Drop those so the
  // default kicks in — leaving them in place would keep the checkbox
  // bindings out of sync with the rendered dashes.
  const SKIP = new Set(["tab_count"]);
  const setStateFn = globalThis.APP_SET_STATE;
  for (const [k, v] of Object.entries(saved.state || {})) {
    if (SKIP.has(k)) continue;
    if (k === "active_tab") continue; // applied below
    if (typeof v === "string" && v.startsWith("not ")) continue;
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
  // Selection → panel sync. Whenever the model mutates, mirror the
  // first selected element's fill / stroke / stroke-width onto the
  // global state.* keys (and through APP_SET_STATE → panelState),
  // so the Color and Stroke panels reflect what's actually selected.
  // Skips when the canvas isn't the active one — non-active models
  // shouldn't drive the (single) panel state.
  let lastSelectionKey = "";
  model.addListener(() => {
    if (id !== activeCanvasId) return;
    const sel = model.document.selection || [];
    const key = sel.map((p) => p.join(",")).join("|");
    if (key === lastSelectionKey) return;
    lastSelectionKey = key;
    if (sel.length === 0) return;
    const elem = walkPath(model.document, sel[0]);
    if (!elem) return;
    syncStateFromElement(elem);
  });
  renderCanvas(canvasEl, model);
  wireCanvasEvents(canvasEl, model);
  applyCanvasCursors();
  refreshActiveCanvas();
}

function walkPath(doc, path) {
  if (!doc || !Array.isArray(doc.layers) || !Array.isArray(path) || path.length === 0) return null;
  let cur = doc.layers[path[0]];
  for (let i = 1; i < path.length; i++) {
    if (!cur || !Array.isArray(cur.children)) return null;
    cur = cur.children[path[i]];
  }
  return cur || null;
}

// Element → state mirror. Reads the selected element's stroke attrs
// via [elementToStateWrites] (engine/stroke_sync) and writes each
// (key, value) through APP_SET_STATE so app.js's panelState (and any
// data-bind UI) refreshes. The pure helper lives in engine/ so node
// tests can exercise it without DOM globals.
export function syncStateFromElement(elem) {
  const setState = globalThis.APP_SET_STATE;
  if (typeof setState !== "function") return;
  for (const { key, value } of elementToStateWrites(elem)) {
    setState(key, value);
  }
}

// Map the YAML tool's `cursor:` field to a CSS cursor value and
// apply it to every canvas-stack. Mapping mirrors the cursor names
// used in workspace/tools/*.yaml; unknown / not-yet-supported names
// fall through to "default".
const CURSOR_CSS = {
  arrow: "default",
  crosshair: "crosshair",
  // CSS has no native eyedropper; the native apps use a custom
  // bitmap. Crosshair is a reasonable fallback until a custom URL
  // cursor lands.
  eyedropper: "crosshair",
  none: "none",
  open_hand: "grab",
  zoom_in: "zoom-in",
};

function applyCanvasCursors() {
  if (!store) return;
  const toolId = store.get("state.active_tool") || "selection";
  const tool = getTool(toolId);
  const cursorName = tool && tool.cursor ? tool.cursor : "arrow";
  const css = CURSOR_CSS[cursorName] || "default";
  for (const { canvasEl } of canvases.values()) {
    canvasEl.style.cursor = css;
  }
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
    // Browsers fire mousedown on each click of a multi-click; the
    // dblclick event arrives separately *after* the second mouseup.
    // Tools like Pen that handle dblclick by popping the most recent
    // anchor would over-count if both mousedowns also pushed one.
    // Suppress all mousedowns past the first; let dblclick stand on
    // its own.
    if (evt.detail >= 2) {
      evt.preventDefault();
      return;
    }
    dragging = true;
    dispatchAndRefresh("mousedown", evt);
    evt.preventDefault();
  });
  // Hover (no drag in progress): dispatch to the active tool so
  // tools that need to track the cursor between clicks (Pen's
  // preview curve, hover-state cursors, etc.) get the events. The
  // document-level handler below covers the during-drag case so a
  // drag past the canvas edge keeps tracking.
  canvasEl.addEventListener("mousemove", (evt) => {
    if (dragging) return;
    dispatchAndRefresh("mousemove", evt);
  });
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
