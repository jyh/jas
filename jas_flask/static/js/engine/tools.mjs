// Tool registry + event dispatcher.
//
// At page load the runtime calls `registerTools(workspace.tools)` with
// the compiled tools map from workspace.json. Each tool's `state:`
// block seeds the corresponding `tool.<id>.*` namespace in the store.
//
// `dispatchEvent(toolId, event, store, ...)` looks up the tool's
// matching `handlers.on_<type>` list and runs it through the effect
// dispatcher with $event populated. This is the glue between DOM
// events and YAML-declared tool behavior.

import { runEffects } from "./effects.mjs";
import { Scope } from "./scope.mjs";
import { registerPrimitive } from "./evaluator.mjs";
import { hitTest as hitTestImpl, hitTestFlat } from "./geometry.mjs";
import { mkNull, NUMBER } from "./value.mjs";

// Tool id → tool spec (as loaded from workspace.json).
const _tools = new Map();

/**
 * Register a dict of tools. Each entry's `state:` block seeds the
 * store's `tool.<id>.*` namespace with declared defaults.
 *
 * @param {Object} tools   Tools dict from workspace.json
 * @param {StateStore} store
 */
export function registerTools(tools, store) {
  _tools.clear();
  if (!tools || typeof tools !== "object") return;
  for (const [id, spec] of Object.entries(tools)) {
    _tools.set(id, spec);
    // Seed tool-local state defaults.
    if (spec.state && typeof spec.state === "object") {
      const slot = store.tool[id] || {};
      for (const [key, decl] of Object.entries(spec.state)) {
        if (!(key in slot)) slot[key] = decl?.default ?? null;
      }
      store.tool[id] = slot;
    }
  }
}

/**
 * Look up a registered tool spec.
 */
export function getTool(id) {
  return _tools.get(id) || null;
}

/**
 * Return the full map of registered tools — for UI that renders a
 * tool palette from workspace metadata.
 */
export function getAllTools() {
  return new Map(_tools);
}

/**
 * Dispatch an event to the named tool's matching handler.
 *
 * @param {string} toolId        The active tool's id (e.g. "selection")
 * @param {Object} event         Event record populated by the DOM layer
 * @param {StateStore} store     State store for reads + writes
 * @param {Object} [options]     Passed through to runEffects
 */
export function dispatchEvent(toolId, event, store, options = {}) {
  const tool = getTool(toolId);
  if (!tool) return;
  const handlerName = `on_${event.type}`;
  const handler = tool.handlers && tool.handlers[handlerName];
  if (!Array.isArray(handler)) return;

  // Default doc_x / doc_y to x / y when the caller didn't supply
  // them. Flask V1 has no canvas pan / zoom so doc-space and
  // screen-space coincide; tests construct event payloads with just
  // x / y and would otherwise fail YAML expressions that read
  // event.doc_x (rect / line / ellipse / pencil all do, for shape
  // creation coords that survive a panned canvas in the native
  // apps). Production canvas_bootstrap.payload sets doc_x = x for
  // the same reason; this default keeps test ergonomics aligned.
  const ev = (event && typeof event === "object"
              && (event.doc_x === undefined || event.doc_y === undefined))
    ? {
        ...event,
        doc_x: event.doc_x !== undefined ? event.doc_x : event.x,
        doc_y: event.doc_y !== undefined ? event.doc_y : event.y,
      }
    : event;

  // Build the outer scope: store namespaces + $event + tool-specific
  // defaults. Scope wraps references so effects can read the live
  // store values and see each other's writes within the dispatch.
  const scope = new Scope({
    state: store.state,
    panel: store.panel,
    tool: store.tool,
    event: ev,
    platform: options.platform || {},
    features: options.features || {},
    config: options.config || {},
    param: options.param || {},
  });

  // Register document-aware expression primitives for the duration
  // of this handler. The pure evaluator doesn't see the Model; these
  // closures bridge the gap.
  const teardown = options.model
    ? registerDocumentPrimitives(options.model)
    : () => {};
  try {
    runEffects(handler, scope, store, options);
  } finally {
    teardown();
  }
}

function registerDocumentPrimitives(model) {
  const offs = [];
  // Flat hit-test: stops at direct layer children (Selection tool's
  // "click-group-child selects the group" semantic).
  offs.push(registerPrimitive("hit_test", (args) => {
    if (args.length < 2 || args[0].kind !== NUMBER || args[1].kind !== NUMBER) {
      return mkNull();
    }
    const path = hitTestFlat(model.document, args[0].value, args[1].value);
    if (!path) return mkNull();
    return { kind: "path", value: path };
  }));
  // Deep hit-test: recurses into groups, returns the leaf path.
  // Interior Selection's hit_test_deep call.
  offs.push(registerPrimitive("hit_test_deep", (args) => {
    if (args.length < 2 || args[0].kind !== NUMBER || args[1].kind !== NUMBER) {
      return mkNull();
    }
    const path = hitTestImpl(model.document, args[0].value, args[1].value);
    if (!path) return mkNull();
    return { kind: "path", value: path };
  }));
  offs.push(registerPrimitive("selection_contains", (args) => {
    if (args.length < 1 || args[0].kind !== "path") return { kind: "bool", value: false };
    const target = args[0].value;
    const found = model.selection.some((p) => arrayEq(p, target));
    return { kind: "bool", value: found };
  }));
  offs.push(registerPrimitive("selection_empty", () => ({
    kind: "bool", value: model.selection.length === 0,
  })));
  // layer_length([0]) returns the number of children in the layer at
  // the given path. Handy for indexing the "last appended" element
  // after a doc.add_element.
  offs.push(registerPrimitive("layer_length", (args) => {
    if (args.length < 1 || args[0].kind !== "list") return { kind: "number", value: 0 };
    // Treat the first arg as a path (list of indices).
    const path = args[0].value.map((v) => v.kind === NUMBER ? v.value : 0);
    const elem = walkPath(model.document, path);
    const n = (elem && Array.isArray(elem.children)) ? elem.children.length : 0;
    return { kind: "number", value: n };
  }));
  return () => { for (const off of offs) off(); };
}

function walkPath(doc, path) {
  if (!doc || !Array.isArray(doc.layers)) return null;
  if (path.length === 0) return null;
  let cur = doc.layers[path[0]];
  for (let i = 1; i < path.length; i++) {
    if (!cur || !Array.isArray(cur.children)) return null;
    cur = cur.children[path[i]];
  }
  return cur;
}

function arrayEq(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * Fire a tool's `on_enter` handler. The dispatcher calls this when the
 * user activates a tool (e.g. clicking a toolbar icon or pressing its
 * shortcut). Also resets tool-local state to its declared defaults.
 */
export function activateTool(toolId, store, options = {}) {
  dispatchEvent(toolId, { type: "enter" }, store, options);
}

/**
 * Fire a tool's `on_leave` handler. Called when the user switches to a
 * different tool.
 */
export function deactivateTool(toolId, store, options = {}) {
  dispatchEvent(toolId, { type: "leave" }, store, options);
}

/**
 * Reset the registry. Test-only; production code should call
 * registerTools() once at startup.
 */
export function _resetForTesting() {
  _tools.clear();
}
