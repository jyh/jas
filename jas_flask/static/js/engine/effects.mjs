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
import { toBool, toJson } from "./value.mjs";

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
  if ("set" in effect) {
    const target = normalizeTarget(effect.set);
    const value = effect.value !== undefined
      ? toJson(evaluate(String(effect.value), scope))
      : null;
    store.set(target, value);
    return;
  }

  // ── Debug / diagnostics ──────────────────────────────
  if ("log" in effect) {
    if (options.onLog) options.onLog(String(effect.log));
    else if (typeof console !== "undefined") console.log("[effect log]", effect.log);
    return;
  }

  // ── Doc-mutation placeholders ────────────────────────
  // V1 recognizes the doc.* effect names so tool YAMLs that use them
  // don't fail; the actual mutations land in Phase 7+. Each is a
  // no-op that optionally calls options.onDocEffect for test harnesses.
  const docEffectKey = Object.keys(effect).find((k) => k.startsWith("doc."));
  if (docEffectKey) {
    if (options.onDocEffect) options.onDocEffect(docEffectKey, effect[docEffectKey], scope);
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
