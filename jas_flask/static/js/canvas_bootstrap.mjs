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
import { registerTools } from "/static/js/engine/tools.mjs";
import {
  renderDocumentLayer, renderSelectionLayer, renderOverlayLayer,
} from "/static/js/engine/canvas.mjs";

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
  model = new Model(emptyDocument());

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
  // Phase 2 mouse-event wiring (lives in app.js) can reach the
  // engine without re-importing everything.
  globalThis.JAS = Object.assign(globalThis.JAS || {}, { model, store });

  return { model, store };
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
