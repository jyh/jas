// Effect dispatcher for the thick-client runtime.
//
// Tools and actions declare lists of effects in YAML — e.g.
//
//   - set: $tool.selection.mode
//     value: "drag_move"
//   - if: "$event.modifiers.shift"
//     then:
//       - set: $tool.selection.shift_held
//         value: true
//
// This module walks such a list and executes each effect against a
// Scope (expression context) and a StateStore (mutation target). V1
// scope: `set:`, `if/then/else`, `let/in`, `log:` (debug print), and
// a placeholder `doc.snapshot` recognized as a no-op pending the doc
// mutation API (phase 7+).
//
// Mirrors the effect dispatcher in `workspace_interpreter/effects.py`
// (shared) and the platform-specific dispatchers in the native apps.

import { evaluate } from "./expr.mjs";
import { Scope } from "./scope.mjs";
import { toBool, toJson, PATH } from "./value.mjs";
import {
  setSelection, addToSelection, toggleSelection, clearSelection,
} from "./document.mjs";

/**
 * Run a list of effects. Each effect is a YAML-derived dict with a
 * single "operation" key (set, if, let, doc.*, …) plus operation-
 * specific fields.
 *
 * @param {Array<Object>} effects   The effect list
 * @param {Scope|Object} scopeOrCtx Evaluation scope; expressions read here
 * @param {StateStore} store        Mutations land here
 * @param {Object} [options]
 * @param {Function} [options.onLog]       Called with string for `log:` effects
 * @param {Function} [options.onUnknown]   Called with (effect) for unrecognized ops
 */
export function runEffects(effects, scopeOrCtx, store, options = {}) {
  if (!Array.isArray(effects)) return;
  const scope = scopeOrCtx instanceof Scope ? scopeOrCtx : new Scope(scopeOrCtx);
  for (const effect of effects) {
    runEffect(effect, scope, store, options);
  }
}

function runEffect(effect, scope, store, options) {
  if (!effect || typeof effect !== "object") return;

  // Each effect has exactly one operation key. Dispatch on the keys
  // present rather than a single `type:` field — matches the existing
  // YAML style (e.g. `set: ...`, `doc.snapshot: {}`).

  // ── Control flow ─────────────────────────────────────
  if ("if" in effect) {
    const cond = evaluate(effect.if, scope);
    if (toBool(cond)) {
      if (Array.isArray(effect.then)) runEffects(effect.then, scope, store, options);
    } else {
      if (Array.isArray(effect.else)) runEffects(effect.else, scope, store, options);
    }
    return;
  }

  if ("let" in effect) {
    // let: { hit: "hit_test(...)" }  in: [ ...effects ]
    const bindings = {};
    const letSpec = effect.let || {};
    for (const [name, exprStr] of Object.entries(letSpec)) {
      bindings[name] = toJson(evaluate(exprStr, scope));
    }
    const extended = scope.extend(bindings);
    if (Array.isArray(effect.in)) runEffects(effect.in, extended, store, options);
    return;
  }

  // ── State mutation ───────────────────────────────────
  // Two supported shapes, matching workspace/actions.yaml convention:
  //   set: { path: expr, path2: expr2, ... }     # dict form (common)
  //   set: <path>, value: <expr>                 # scalar form
  if ("set" in effect) {
    const raw = effect.set;
    if (raw && typeof raw === "object" && !Array.isArray(raw)) {
      for (const [targetKey, valueExpr] of Object.entries(raw)) {
        const target = normalizeTarget(targetKey);
        const value = toJson(evaluate(String(valueExpr), scope));
        store.set(target, value);
      }
    } else {
      const target = normalizeTarget(raw);
      const value = effect.value !== undefined
        ? toJson(evaluate(String(effect.value), scope))
        : null;
      store.set(target, value);
    }
    return;
  }

  // ── Debug / diagnostics ──────────────────────────────
  if ("log" in effect) {
    if (options.onLog) options.onLog(String(effect.log));
    else if (typeof console !== "undefined") console.log("[effect log]", effect.log);
    return;
  }

  // ── Document mutations ───────────────────────────────
  // Routes through options.model (a Model from model.mjs) when
  // supplied; falls back to options.onDocEffect for test harnesses
  // that don't want to wire a model. Unimplemented doc.* effects stay
  // as observer-only placeholders — the set grows as phases land.
  const docEffectKey = Object.keys(effect).find((k) => k.startsWith("doc."));
  if (docEffectKey) {
    const model = options.model;
    const spec = effect[docEffectKey];

    if (model) {
      switch (docEffectKey) {
        case "doc.snapshot":
          model.snapshot();
          return;
        case "doc.clear_selection":
          model.mutate(clearSelection);
          return;
        case "doc.set_selection": {
          const paths = extractPathList(spec, scope);
          model.mutate((d) => setSelection(d, paths));
          return;
        }
        case "doc.add_to_selection": {
          const path = extractPath(spec, scope);
          if (path) model.mutate((d) => addToSelection(d, path));
          return;
        }
        case "doc.toggle_selection": {
          const path = extractPath(spec, scope);
          if (path) model.mutate((d) => toggleSelection(d, path));
          return;
        }
        // Other doc.* effects land in subsequent phases.
      }
    }

    if (options.onDocEffect) options.onDocEffect(docEffectKey, spec, scope);
    return;
  }

  // ── Unknown ─────────────────────────────────────────
  if (options.onUnknown) options.onUnknown(effect);
}

/**
 * Normalize a `set:` target string. YAML authors may write
 * `$tool.selection.mode` or `tool.selection.mode`; both should resolve
 * the same store path.
 */
function normalizeTarget(raw) {
  const s = String(raw);
  return s.startsWith("$") ? s.slice(1) : s;
}

/**
 * Pull a single path array out of a doc.* effect spec. Accepts:
 *   - A string that evaluates to a Path value → extract indices
 *   - A {path: expr} dict — evaluates `path` as an expression
 *   - A raw array of ints — treated as a path directly
 */
function extractPath(spec, scope) {
  if (Array.isArray(spec)) return spec.slice();
  if (typeof spec === "string") {
    const v = evaluate(spec, scope);
    if (v && v.kind === PATH) return v.value.slice();
    return null;
  }
  if (spec && typeof spec === "object" && "path" in spec) {
    return extractPath(spec.path, scope);
  }
  return null;
}

/**
 * Pull a list of path arrays out of a doc.* effect spec. Accepts:
 *   - {paths: [...]} where items are evaluated individually
 *   - A string that evaluates to a List of Paths
 */
function extractPathList(spec, scope) {
  if (spec && typeof spec === "object" && Array.isArray(spec.paths)) {
    const out = [];
    for (const item of spec.paths) {
      const p = extractPath(item, scope);
      if (p) out.push(p);
    }
    return out;
  }
  if (typeof spec === "string") {
    const v = evaluate(spec, scope);
    if (v && v.kind === "list") {
      const out = [];
      for (const item of v.value) {
        if (item && item.kind === PATH) out.push(item.value.slice());
      }
      return out;
    }
  }
  return [];
}
