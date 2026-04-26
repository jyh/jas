// Canvas bootstrap — Phase 1 of FLASK_INTEGRATION_GAPS.md.
//
// On page load:
//   1. Construct one Model (with undo/redo) and StateStore.
//   2. Register tool yamls (window.APP_TOOLS — populated by
//      normal.html from the workspace.json compile output).
//   3. Listen to model changes; re-render the 3 SVG canvas layers
//      via engine/canvas.mjs.
//
// Phase 1 stops short of mouse-event wiring — that lands in
// Phase 2 alongside the Selection + Rect tools. This module's
// only job today is to prove the canvas is reachable from the
// engine and that re-rendering on Model.snapshot() produces
// correct SVG markup.
//
// Imports use `/static/js/engine/...` absolute paths because Flask
// serves static assets from /static and ES modules require fully-
// qualified URLs at the import site. Browsers cache by the
// cache-busted <script> URL, so module-internal paths don't need
// per-deploy versioning.

import { Model } from "/static/js/engine/model.mjs";
import { emptyDocument } from "/static/js/engine/document.mjs";
import { StateStore } from "/static/js/engine/store.mjs";
import { registerTools, dispatchEvent } from "/static/js/engine/tools.mjs";
import {
  renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
} from "/static/js/engine/canvas.mjs";
import { saveSession, loadSession } from "/static/js/engine/session.mjs";

const SESSION_AUTOSAVE_MS = 30000;

let model = null;
let store = null;

/**
 * One-time setup. Call from a `<script type="module">` block in
 * normal.html after APP_TOOLS / APP_STATE etc. are defined on
 * `window`. Idempotent — second call is a no-op.
 */
export function bootstrap() {
  if (model) return { model, store };

  // Bail quietly when the page has no canvas (wireframe mode,
  // tests, etc.). Production normal.html includes one.
  const docLayer = document.querySelector('[data-canvas-layer="doc"]');
  if (!docLayer) return null;

  store = new StateStore({
    state: globalThis.APP_STATE ? { ...globalThis.APP_STATE } : {},
  });

  // Restore saved session if present; otherwise start blank.
  const saved = loadSession();
  model = saved
    ? new Model(saved.document, saved.filename)
    : new Model(emptyDocument());

  // Register tool yamls so dispatchEvent can find on_<event>
  // handlers. APP_TOOLS is the compiled tools dict the server
  // injects into normal.html via {{ tools_json | safe }}.
  if (globalThis.APP_TOOLS) {
    registerTools(globalThis.APP_TOOLS, store);
  }

  // Re-render whenever the model mutates. Keep this simple
  // (full layer redraw) until profiling shows a need for
  // per-element diff updates.
  model.addListener(renderAll);
  renderAll();

  // Expose to global for easy debugging from devtools, and so
  // app.js's setState can mirror state-namespace writes into the
  // engine store (see globalThis.JAS.mirrorState below).
  globalThis.JAS = Object.assign(globalThis.JAS || {}, {
    model,
    store,
    /**
     * app.js calls this from setState() so changes to the
     * canonical state live in app.js (driving panels) also reach
     * the engine store, where tool yamls read them.
     */
    mirrorState(key, value) {
      try { store.set("state." + key, value); }
      catch (_) { /* unknown scope or shallow path — ignore */ }
    },
  });

  // ── Persistence ──────────────────────────────────────
  //
  // Save the current document on tab close + every 30 seconds
  // so an unexpected reload (browser crash, accidental Cmd+W)
  // doesn't lose work. Mirror's the Rust session.rs cadence.
  // The Model's listener already fires on every mutation; we
  // throttle saves to the autosave interval rather than writing
  // on every mouse-driven mutation, to keep localStorage I/O
  // off the drag hot path.
  let saveDebounceTimer = null;
  function scheduleSave() {
    if (saveDebounceTimer != null) return;
    saveDebounceTimer = setTimeout(() => {
      saveDebounceTimer = null;
      saveSession(model);
    }, SESSION_AUTOSAVE_MS);
  }
  model.addListener(scheduleSave);
  window.addEventListener("beforeunload", () => saveSession(model));

  // ── Mouse-event wiring ────────────────────────────────
  //
  // Translate DOM events on the document layer into the
  // dispatchEvent payload the engine's tools expect. Pointer
  // capture: mousedown attaches mousemove + mouseup listeners
  // to the *document* so the user can drag past the canvas
  // edge without losing the gesture.
  wireCanvasEvents(docLayer);

  return { model, store };
}

function wireCanvasEvents(docLayer) {
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

  // mousemove + mouseup attach to the document so a drag that
  // leaves the canvas keeps tracking until release.
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

function renderAll() {
  setLayer("doc", renderDocumentLayer(model.document));
  setLayer("selection", renderSelectionLayer(model.document));
  // Overlay needs an active-tool spec + scope; no tool wired yet
  // in Phase 1, so leave it blank. Phase 2 fills this in.
  setLayer("overlay", "");
}

function setLayer(name, svgFragment) {
  const el = document.querySelector(`[data-canvas-layer="${name}"]`);
  if (el) el.innerHTML = svgFragment || "";
}

// Auto-bootstrap on DOMContentLoaded. The script is loaded with
// type="module", which defers execution until after parsing, so
// the canvas DOM is ready by the time this runs.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrap);
} else {
  bootstrap();
}
