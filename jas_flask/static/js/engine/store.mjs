// State store for the thick-client runtime.
//
// Mirrors `workspace_interpreter/state_store.py`. Holds the mutable
// non-document state: the global `state` namespace plus per-panel and
// per-tool local state. Documents live in the Model (model.mjs); the
// StateStore holds everything else that expression paths refer to.
//
// Path mutations take a dotted string like "state.fill_color" or
// "tool.selection.mode" and walk to the target key, creating
// intermediate objects as needed. Reads return the raw JS value.

/**
 * @typedef {Object} StoreInit
 * @property {Object} [state]     Global state scope
 * @property {Object} [panel]     Per-panel sub-scopes keyed by id
 * @property {Object} [tool]      Per-tool sub-scopes keyed by id
 */

export class StateStore {
  constructor(init = {}) {
    this.state = init.state ? { ...init.state } : {};
    this.panel = init.panel ? { ...init.panel } : {};
    this.tool = init.tool ? { ...init.tool } : {};
    this._listeners = [];
  }

  /**
   * Return a plain-object snapshot of the store. Used to build the
   * Scope passed to expression evaluation.
   */
  asContext() {
    return {
      state: this.state,
      panel: this.panel,
      tool: this.tool,
    };
  }

  /**
   * Read a dotted path like "state.fill_color" or "tool.selection.mode".
   * Returns undefined if any intermediate is missing.
   */
  get(path) {
    const segs = path.split(".");
    if (segs.length === 0) return undefined;
    let cur = this[segs[0]];
    for (let i = 1; i < segs.length; i++) {
      if (cur == null || typeof cur !== "object") return undefined;
      cur = cur[segs[i]];
    }
    return cur;
  }

  /**
   * Write a dotted path, creating intermediate objects as needed.
   * Fires listeners with the path and new value.
   *
   * @param {string} path  Dotted path, e.g. "tool.selection.mode"
   * @param {*} value      Raw JS value (not a Value tagged object)
   */
  set(path, value) {
    const segs = path.split(".");
    if (segs.length < 2) {
      // Need at least "<scope>.<key>"; reject for safety.
      throw new Error(`StateStore.set: path "${path}" too shallow`);
    }
    const scope = segs[0];
    if (!(scope in this)) {
      throw new Error(`StateStore.set: unknown scope "${scope}"`);
    }
    let cur = this[scope];
    for (let i = 1; i < segs.length - 1; i++) {
      const k = segs[i];
      if (cur[k] == null || typeof cur[k] !== "object") {
        cur[k] = {};
      }
      cur = cur[k];
    }
    cur[segs[segs.length - 1]] = value;
    this._notify(path, value);
  }

  /** Register a listener called as (path, newValue) on every write. */
  addListener(fn) {
    this._listeners.push(fn);
    return () => {
      const i = this._listeners.indexOf(fn);
      if (i >= 0) this._listeners.splice(i, 1);
    };
  }

  _notify(path, value) {
    for (const fn of this._listeners) fn(path, value);
  }
}
