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
  getElement,
} from "./document.mjs";
import { hitTestRect, translateElement } from "./geometry.mjs";

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
        case "doc.translate_selection": {
          const dx = Number(toJson(evaluate(String(spec.dx ?? "0"), scope))) || 0;
          const dy = Number(toJson(evaluate(String(spec.dy ?? "0"), scope))) || 0;
          if (dx === 0 && dy === 0) return;
          model.mutate((d) => translateSelectedElements(d, dx, dy));
          return;
        }
        case "doc.select_in_rect": {
          const x1 = Number(toJson(evaluate(String(spec.x1 ?? "0"), scope))) || 0;
          const y1 = Number(toJson(evaluate(String(spec.y1 ?? "0"), scope))) || 0;
          const x2 = Number(toJson(evaluate(String(spec.x2 ?? "0"), scope))) || 0;
          const y2 = Number(toJson(evaluate(String(spec.y2 ?? "0"), scope))) || 0;
          const additive = toBool(evaluate(String(spec.additive ?? "false"), scope));
          const rect = {
            x: Math.min(x1, x2), y: Math.min(y1, y2),
            width: Math.abs(x2 - x1), height: Math.abs(y2 - y1),
          };
          model.mutate((d) => {
            const paths = hitTestRect(d, rect);
            if (additive) {
              let next = d;
              for (const p of paths) next = addToSelection(next, p);
              return next;
            }
            return setSelection(d, paths);
          });
          return;
        }
        case "doc.delete_selection": {
          model.mutate(deleteSelectedElements);
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

/**
 * Apply a translation to every selected element. Runs recursively
 * through container paths so dragging a group moves all its children.
 * Returns a new Document; input is not mutated.
 */
function translateSelectedElements(doc, dx, dy) {
  if (!doc.selection || doc.selection.length === 0) return doc;
  const layers = doc.layers.slice();
  const touchedTop = new Set();
  for (const path of doc.selection) {
    if (path.length === 0) continue;
    const topIdx = path[0];
    if (!touchedTop.has(topIdx)) {
      touchedTop.add(topIdx);
      layers[topIdx] = layers[topIdx];
    }
  }
  // Build the new layers by walking each selected path and replacing
  // the leaf element with its translated counterpart.
  const replaceAt = (layerIdx, subpath, replacer) => {
    if (subpath.length === 0) {
      layers[layerIdx] = replacer(layers[layerIdx]);
      return;
    }
    layers[layerIdx] = replaceElementAt(layers[layerIdx], subpath, replacer);
  };
  for (const path of doc.selection) {
    if (path.length === 0) continue;
    const [li, ...rest] = path;
    replaceAt(li, rest, (e) => translateElement(e, dx, dy));
  }
  return { ...doc, layers };
}

function replaceElementAt(elem, subpath, replacer) {
  if (subpath.length === 0) return replacer(elem);
  const [head, ...rest] = subpath;
  if (!elem || !Array.isArray(elem.children)) return elem;
  const children = elem.children.slice();
  if (head < 0 || head >= children.length) return elem;
  children[head] = replaceElementAt(children[head], rest, replacer);
  return { ...elem, children };
}

/**
 * Remove every selected element and clear the selection. Deletions
 * happen deepest-first (paths sorted by descending length, then by
 * descending last-index) so index shifts don't invalidate other paths.
 */
function deleteSelectedElements(doc) {
  if (!doc.selection || doc.selection.length === 0) return doc;
  const sorted = doc.selection.slice().sort((a, b) => {
    if (a.length !== b.length) return b.length - a.length;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return b[i] - a[i];
    }
    return 0;
  });
  let layers = doc.layers.slice();
  for (const path of sorted) {
    if (path.length === 0) continue;
    layers = deleteAtPath(layers, path);
  }
  return { ...doc, layers, selection: [] };
}

function deleteAtPath(layers, path) {
  if (path.length === 1) {
    const out = layers.slice();
    out.splice(path[0], 1);
    return out;
  }
  const [li, ...rest] = path;
  const out = layers.slice();
  out[li] = deleteInElement(out[li], rest);
  return out;
}

function deleteInElement(elem, subpath) {
  if (!elem || !Array.isArray(elem.children)) return elem;
  if (subpath.length === 1) {
    const children = elem.children.slice();
    children.splice(subpath[0], 1);
    return { ...elem, children };
  }
  const [head, ...rest] = subpath;
  const children = elem.children.slice();
  children[head] = deleteInElement(children[head], rest);
  return { ...elem, children };
}
