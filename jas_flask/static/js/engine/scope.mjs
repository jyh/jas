// Nested scope for expression evaluation.
//
// Mirrors `workspace_interpreter/scope.py` and the Rust /Swift / OCaml
// equivalents. Unlike those, the thick-client JS runtime needs to expose
// several scope namespaces simultaneously: $state.*, $panel.<id>.*,
// $tool.<id>.*, $event.*, $platform.*, $features.*, $config.*.
//
// This Scope class is a thin wrapper over a plain object whose keys are
// scope names. The parser reaches into a given sub-scope via path
// access; this module just keeps the top-level map lookup-friendly.

import { fromJson, mkNull } from "./value.mjs";

/**
 * A Scope holds a mapping of top-level variable names to JSON values.
 * Expression path access (`foo.bar.baz`) walks into the JSON tree via
 * `resolvePath`. Missing keys evaluate to Null rather than throwing,
 * matching the other interpreters.
 */
export class Scope {
  constructor(initial = {}) {
    // Shallow clone so mutations don't leak back to the caller.
    this._data = { ...initial };
  }

  /** Return the underlying JSON-like dict. Read-only by convention. */
  toDict() {
    return this._data;
  }

  /**
   * Look up a top-level name, returning a raw JSON value or undefined.
   * Path access (`foo.bar`) is the parser's job; this method only
   * resolves the first segment.
   */
  get(name) {
    return this._data[name];
  }

  /**
   * Write a top-level name. Used for namespace setup — e.g. the
   * dispatcher writes `$event.*` into a fresh Scope before evaluating
   * a tool handler.
   */
  set(name, value) {
    this._data[name] = value;
  }

  /**
   * Return a new Scope with additional top-level bindings merged in.
   * Used by foreach / let to push an extended scope without mutating
   * the parent.
   */
  extend(overrides) {
    return new Scope({ ...this._data, ...overrides });
  }

  /**
   * Resolve a dotted path (array of string segments) into a Value.
   * Returns `mkNull()` for any missing intermediate.
   *
   * Example: resolvePath(["event", "modifiers", "shift"])
   *   → lookups event→modifiers→shift in the JSON tree.
   */
  resolvePath(segments) {
    if (!segments || segments.length === 0) return mkNull();
    let cur = this._data[segments[0]];
    for (let i = 1; i < segments.length; i++) {
      if (cur == null) return mkNull();
      if (typeof cur !== "object") return mkNull();
      // Special handling for the __path__ marker — treat as opaque.
      if (Array.isArray(cur)) {
        // Path indices are numeric strings in the parser.
        const idx = Number(segments[i]);
        if (!Number.isInteger(idx)) return mkNull();
        cur = cur[idx];
      } else {
        cur = cur[segments[i]];
      }
    }
    if (cur === undefined) return mkNull();
    return fromJson(cur);
  }
}

/**
 * Build the canonical outer Scope for a tool-handler invocation.
 * The dispatcher populates event, tool, state, panel, platform, and
 * features before evaluating the handler's effect list.
 */
export function buildHandlerScope({
  state = {},
  panel = {},
  tool = {},
  event = {},
  platform = {},
  features = {},
  config = {},
  param = {},
} = {}) {
  return new Scope({
    state,
    panel,
    tool,
    event,
    platform,
    features,
    config,
    param,
  });
}
