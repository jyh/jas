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

  // Build the outer scope: store namespaces + $event + tool-specific
  // defaults. Scope wraps references so effects can read the live
  // store values and see each other's writes within the dispatch.
  const scope = new Scope({
    state: store.state,
    panel: store.panel,
    tool: store.tool,
    event,
    platform: options.platform || {},
    features: options.features || {},
    config: options.config || {},
    param: options.param || {},
  });

  runEffects(handler, scope, store, options);
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
