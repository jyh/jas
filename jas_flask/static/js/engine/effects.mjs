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
  getElement, mkPath,
} from "./document.mjs";
import { hitTestRect, translateElement } from "./geometry.mjs";
import * as pointBuffers from "./point_buffers.mjs";
import { fitCurve } from "./fit_curve.mjs";

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

  // ── Data namespace mutations ─────────────────────────
  // Reads/writes to workspace-loaded reference data (swatch
  // libraries, brush libraries, etc.). Currently JS-side only —
  // server-rendered panel HTML does not refresh on data writes; the
  // canvas-side renderer that walks the JS data store does pick up
  // changes at next paint.
  if ("data.set" in effect) {
    const spec = effect["data.set"];
    if (spec && typeof spec === "object") {
      const path = String(spec.path || "");
      if (!path) return;
      const value = _resolveValueOrExpr(spec.value, scope);
      _writeDataPath(store, path, value);
    }
    return;
  }
  if ("data.list_append" in effect) {
    const spec = effect["data.list_append"];
    if (spec && typeof spec === "object") {
      const path = String(spec.path || "");
      if (!path) return;
      const value = _resolveValueOrExpr(spec.value, scope);
      const cur = _readDataPath(store, path);
      const next = Array.isArray(cur) ? cur.slice() : [];
      next.push(value);
      _writeDataPath(store, path, next);
    }
    return;
  }
  if ("data.list_remove" in effect) {
    const spec = effect["data.list_remove"];
    if (spec && typeof spec === "object") {
      const path = String(spec.path || "");
      if (!path) return;
      const index = Number(toJson(evaluate(String(spec.index ?? "0"), scope))) || 0;
      const cur = _readDataPath(store, path);
      if (!Array.isArray(cur)) return;
      if (index < 0 || index >= cur.length) return;
      const next = cur.slice();
      next.splice(index, 1);
      _writeDataPath(store, path, next);
    }
    return;
  }
  if ("data.list_insert" in effect) {
    // Insert one item at the given index. Index === length is allowed
    // (append). Out-of-range indices clamp.
    const spec = effect["data.list_insert"];
    if (spec && typeof spec === "object") {
      const path = String(spec.path || "");
      if (!path) return;
      const value = _resolveValueOrExpr(spec.value, scope);
      const index = Number(toJson(evaluate(String(spec.index ?? "0"), scope))) || 0;
      const cur = _readDataPath(store, path);
      const base = Array.isArray(cur) ? cur.slice() : [];
      const i = Math.max(0, Math.min(index, base.length));
      base.splice(i, 0, value);
      _writeDataPath(store, path, base);
    }
    return;
  }
  if ("data.list_sort" in effect) {
    // Sort a list at the given path by a per-item key expression.
    // The expression is evaluated with `item` bound to each list
    // entry; sort is stable, ascending lexicographic on the
    // resulting strings.
    const spec = effect["data.list_sort"];
    if (spec && typeof spec === "object") {
      const path = String(spec.path || "");
      if (!path) return;
      const keyExpr = String(spec.key || "item");
      const cur = _readDataPath(store, path);
      if (!Array.isArray(cur)) return;
      const next = cur.slice().sort((a, b) => {
        const ka = String(toJson(evaluate(keyExpr, scope.extend({ item: a })))) || "";
        const kb = String(toJson(evaluate(keyExpr, scope.extend({ item: b })))) || "";
        return ka < kb ? -1 : ka > kb ? 1 : 0;
      });
      _writeDataPath(store, path, next);
    }
    return;
  }

  // ── Brush library shortcuts ──────────────────────────
  // Higher-level operations that compose data.* primitives in ways
  // the YAML language can't express natively (multi-item removal by
  // slug, slug uniqueness, cross-document scans). All write through
  // the data.brush_libraries store and clear panel.selected_brushes
  // when they affect the selection.
  if ("brush.delete_selected" in effect) {
    const spec = effect["brush.delete_selected"] || {};
    const libId = String(toJson(evaluate(
      String(spec.library ?? "panel.selected_library"), scope)));
    const slugs = toJson(evaluate(
      String(spec.slugs ?? "panel.selected_brushes"), scope));
    if (!libId || !Array.isArray(slugs) || slugs.length === 0) return;
    const lib = store.data.brush_libraries && store.data.brush_libraries[libId];
    if (!lib || !Array.isArray(lib.brushes)) return;
    const slugSet = new Set(slugs);
    lib.brushes = lib.brushes.filter((b) => !slugSet.has(b.slug));
    if (store._notify) store._notify(`data.brush_libraries.${libId}.brushes`, lib.brushes);
    // Clear the panel selection of the removed slugs.
    if (store.panel && store.panel.brushes) {
      store.panel.brushes.selected_brushes = [];
      if (store._notify) store._notify("panel.brushes.selected_brushes", []);
    }
    return;
  }
  if ("brush.duplicate_selected" in effect) {
    const spec = effect["brush.duplicate_selected"] || {};
    const libId = String(toJson(evaluate(
      String(spec.library ?? "panel.selected_library"), scope)));
    const slugs = toJson(evaluate(
      String(spec.slugs ?? "panel.selected_brushes"), scope));
    if (!libId || !Array.isArray(slugs) || slugs.length === 0) return;
    const lib = store.data.brush_libraries && store.data.brush_libraries[libId];
    if (!lib || !Array.isArray(lib.brushes)) return;
    const existingSlugs = new Set(lib.brushes.map((b) => b.slug));
    const newSlugs = [];
    // Walk the selected slugs in their current positional order.
    for (let i = lib.brushes.length - 1; i >= 0; i--) {
      const b = lib.brushes[i];
      if (!slugs.includes(b.slug)) continue;
      const copy = { ...b, name: (b.name || "Brush") + " copy" };
      // Generate a unique slug: <orig>_copy, _copy_2, _copy_3, …
      let newSlug = `${b.slug}_copy`;
      let n = 2;
      while (existingSlugs.has(newSlug)) {
        newSlug = `${b.slug}_copy_${n++}`;
      }
      copy.slug = newSlug;
      existingSlugs.add(newSlug);
      lib.brushes.splice(i + 1, 0, copy);
      newSlugs.push(newSlug);
    }
    if (store._notify) store._notify(`data.brush_libraries.${libId}.brushes`, lib.brushes);
    // Replace the panel selection with the new copies.
    if (store.panel && store.panel.brushes) {
      store.panel.brushes.selected_brushes = newSlugs;
      if (store._notify) store._notify("panel.brushes.selected_brushes", newSlugs);
    }
    return;
  }
  if ("brush.append" in effect) {
    // Append a new brush to the named library. Used by
    // brush_options_confirm in create mode.
    const spec = effect["brush.append"] || {};
    const libId = String(toJson(evaluate(
      String(spec.library ?? "panel.selected_library"), scope)));
    const brush = _resolveValueOrExpr(spec.brush, scope);
    if (!libId || !brush || typeof brush !== "object") return;
    const lib = store.data.brush_libraries && store.data.brush_libraries[libId];
    if (!lib || !Array.isArray(lib.brushes)) return;
    lib.brushes.push(brush);
    if (store._notify) store._notify(`data.brush_libraries.${libId}.brushes`, lib.brushes);
    return;
  }
  if ("brush.update" in effect) {
    // Update a master brush in place. Used by brush_options_confirm
    // in library_edit mode. Replaces whichever fields appear in the
    // patch object; preserves other fields.
    const spec = effect["brush.update"] || {};
    const libId = String(toJson(evaluate(
      String(spec.library ?? "panel.selected_library"), scope)));
    const slug = String(toJson(evaluate(
      String(spec.slug ?? '""'), scope)));
    const patch = _resolveValueOrExpr(spec.patch, scope);
    if (!libId || !slug || !patch || typeof patch !== "object") return;
    const lib = store.data.brush_libraries && store.data.brush_libraries[libId];
    if (!lib || !Array.isArray(lib.brushes)) return;
    const idx = lib.brushes.findIndex((b) => b.slug === slug);
    if (idx < 0) return;
    lib.brushes[idx] = { ...lib.brushes[idx], ...patch };
    if (store._notify) store._notify(`data.brush_libraries.${libId}.brushes`, lib.brushes);
    return;
  }

  // ── Buffer mutations (for accumulator tools) ────────
  if ("buffer.push" in effect) {
    const spec = effect["buffer.push"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      const x = Number(toJson(evaluate(String(spec.x ?? "0"), scope))) || 0;
      const y = Number(toJson(evaluate(String(spec.y ?? "0"), scope))) || 0;
      if (name) pointBuffers.push(name, x, y);
    }
    return;
  }
  if ("buffer.clear" in effect) {
    const spec = effect["buffer.clear"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      if (name) pointBuffers.clear(name);
    }
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
        case "doc.add_element": {
          // Spec: { parent?: <path expr>, element: <element-spec> }
          // The element-spec is a dict with `type:` + geometry fields.
          // Geometry fields may be expressions; they're evaluated
          // against the scope before the element is appended.
          //
          // `parent` defaults to [0] — the active layer. Native apps'
          // doc_add_element (jas_dioxus controller, jas controller,
          // etc.) all default to the active layer when the caller
          // doesn't specify; the Flask runtime matches that so tool
          // yamls don't have to repeat `parent: [0]` on every call.
          const elemSpec = spec.element;
          if (!elemSpec) return;
          const parentPath = spec.parent !== undefined
            ? extractPath(spec.parent, scope)
            : [0];
          if (!parentPath) return;
          const resolved = resolveElementSpec(elemSpec, scope);
          model.mutate((d) => addElementAt(d, parentPath, resolved));
          return;
        }
        case "doc.set_attr": {
          // Spec: { path: <expr>, attr: <name>, value: <expr> }
          const path = extractPath(spec.path, scope);
          const attr = String(spec.attr || "");
          if (!path || !attr) return;
          const value = _resolveValueOrExpr(spec.value, scope);
          model.mutate((d) => setElementAttr(d, path, attr, value));
          return;
        }
        case "doc.set_attr_on_selection": {
          // Spec: { attr: <name>, value: <expr> }
          // Apply setElementAttr to every path in the current
          // selection. No-op when the selection is empty. Used by
          // bulk panel-driven edits (e.g. apply_brush_to_selection).
          const attr = String(spec.attr || "");
          if (!attr) return;
          const value = _resolveValueOrExpr(spec.value, scope);
          model.mutate((d) => {
            if (!d.selection || d.selection.length === 0) return d;
            let next = d;
            for (const path of d.selection) {
              next = setElementAttr(next, path, attr, value);
            }
            return next;
          });
          return;
        }
        case "doc.add_path_from_buffer": {
          // Spec: { buffer: <name>, fit_error?: <expr>,
          //         stroke_brush?: <expr>, stroke?: <expr>,
          //         fill?: <expr> }
          // Read the named point buffer, fit a Bezier spline,
          // build a Path element, and append it to layer 0
          // (matches Pencil/Paintbrush semantics). Optional
          // stroke_brush / stroke / fill ride along on the new
          // element so a brushed stroke is rendered through the
          // brush pipeline at next paint.
          const name = String(spec.buffer || "");
          if (!name) return;
          const fitError = "fit_error" in spec
            ? Number(toJson(evaluate(String(spec.fit_error), scope))) || 4.0
            : 4.0;
          const pts = pointBuffers.points(name);
          if (pts.length < 2) return;
          const segments = fitCurve(pts, fitError);
          if (segments.length === 0) return;

          // Build path commands: MoveTo(first), then a CurveTo per
          // segment. fit_curve emits (p1x, p1y, c1x, c1y, c2x, c2y,
          // p2x, p2y) tuples; we use the first segment's p1 as the
          // initial MoveTo target.
          const cmds = [{ type: "M", x: segments[0][0], y: segments[0][1] }];
          for (const s of segments) {
            cmds.push({
              type: "C",
              x1: s[2], y1: s[3],
              x2: s[4], y2: s[5],
              x: s[6], y: s[7],
            });
          }

          // Optional attribute passthrough. Each is evaluated
          // against the current scope so authors can write
          // 'state.stroke_brush' (or 'null') in YAML.
          const extra = {};
          if ("stroke_brush" in spec) {
            extra.stroke_brush = toJson(evaluate(String(spec.stroke_brush), scope));
          }
          if ("stroke" in spec) {
            extra.stroke = toJson(evaluate(String(spec.stroke), scope));
          }
          if ("fill" in spec) {
            extra.fill = toJson(evaluate(String(spec.fill), scope));
          }

          const elem = mkPath({ d: cmds, ...extra });
          model.mutate((d) => addElementAt(d, [0], elem));
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
/**
 * Resolve a YAML-author-provided value field. Two shapes:
 * - String → treated as an expression source, parsed and evaluated.
 *   This matches the existing convention for set:, doc.set_attr,
 *   etc.
 * - Non-string (object / array / number / boolean / null) → used
 *   verbatim. Lets data.list_append etc. accept inline JSON
 *   literals where the expression language has no object literal
 *   syntax.
 *
 * Undefined defaults to null.
 */
function _resolveValueOrExpr(spec, scope) {
  if (spec === undefined) return null;
  if (typeof spec === "string") {
    return toJson(evaluate(spec, scope));
  }
  return spec;
}

/**
 * Walk a dotted path inside store.data. Returns undefined for any
 * missing intermediate. Path may use either `data.x.y` (with the
 * scope prefix) or `x.y` (bare); both resolve to the data namespace.
 */
function _readDataPath(store, rawPath) {
  if (!store || !store.data) return undefined;
  const path = rawPath.startsWith("data.") ? rawPath.slice(5) : rawPath;
  if (!path) return store.data;
  const segs = path.split(".");
  let cur = store.data;
  for (const k of segs) {
    if (cur == null || typeof cur !== "object") return undefined;
    cur = cur[k];
  }
  return cur;
}

/**
 * Write a value at a dotted path inside store.data. Intermediate
 * dicts are created on demand. Numeric path segments are interpreted
 * as array indices when the parent is already an array. Fires the
 * store's listeners with the qualified `data.<path>` key so observers
 * can re-render.
 */
function _writeDataPath(store, rawPath, value) {
  if (!store || !store.data) return;
  const path = rawPath.startsWith("data.") ? rawPath.slice(5) : rawPath;
  if (!path) return;
  const segs = path.split(".");
  let cur = store.data;
  for (let i = 0; i < segs.length - 1; i++) {
    const k = segs[i];
    if (cur[k] == null || typeof cur[k] !== "object") {
      cur[k] = {};
    }
    cur = cur[k];
  }
  const last = segs[segs.length - 1];
  if (Array.isArray(cur)) {
    const idx = Number(last);
    if (Number.isInteger(idx)) cur[idx] = value;
  } else {
    cur[last] = value;
  }
  if (store._notify) store._notify("data." + path, value);
}

function normalizeTarget(raw) {
  const s = String(raw);
  return s.startsWith("$") ? s.slice(1) : s;
}

/**
 * Pull a single path array out of a doc.* effect spec. Accepts:
 *   - A raw array of ints → treated as a path directly
 *   - A string that evaluates to a Path value → extract indices
 *   - A string that evaluates to a List of Numbers → treat as path
 *   - A {path: expr} dict — evaluates `path` as an expression
 */
function extractPath(spec, scope) {
  if (Array.isArray(spec)) return spec.slice();
  if (typeof spec === "string") {
    const v = evaluate(spec, scope);
    if (!v) return null;
    if (v.kind === PATH) return v.value.slice();
    // A list literal like "[0, 1, 2]" evaluates to a List of Numbers;
    // accept it as a path so YAML authors can write literal paths
    // without wrapping them in a path() primitive.
    if (v.kind === "list") {
      const indices = [];
      for (const item of v.value) {
        if (!item || item.kind !== "number" || !Number.isInteger(item.value)) {
          return null;
        }
        indices.push(item.value);
      }
      return indices;
    }
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

/**
 * Evaluate any expression-valued fields in an element spec, producing
 * a concrete element ready to append. Non-string fields and the `type`
 * field pass through verbatim.
 */
function resolveElementSpec(spec, scope) {
  if (!spec || typeof spec !== "object") return null;
  const out = {};
  for (const [k, v] of Object.entries(spec)) {
    if (k === "type" || typeof v !== "string") {
      out[k] = v;
      continue;
    }
    out[k] = toJson(evaluate(v, scope));
  }
  return out;
}

/**
 * Append an element to the container at `parentPath`. Path `[0]`
 * targets the top layer; `[0, 2]` targets group-index-2 inside that
 * layer. Returns a new Document; input is not mutated.
 */
function addElementAt(doc, parentPath, elem) {
  if (!Array.isArray(parentPath) || !elem) return doc;
  const layers = doc.layers.slice();
  if (parentPath.length === 1) {
    const li = parentPath[0];
    if (li < 0 || li >= layers.length) return doc;
    const layer = layers[li];
    const children = (layer.children || []).slice();
    children.push(elem);
    layers[li] = { ...layer, children };
    return { ...doc, layers };
  }
  const [li, ...rest] = parentPath;
  if (li < 0 || li >= layers.length) return doc;
  layers[li] = appendInElement(layers[li], rest, elem);
  return { ...doc, layers };
}

function appendInElement(container, subpath, elem) {
  if (!container || !Array.isArray(container.children)) return container;
  if (subpath.length === 0) {
    return { ...container, children: [...container.children, elem] };
  }
  const [head, ...rest] = subpath;
  const children = container.children.slice();
  if (head < 0 || head >= children.length) return container;
  children[head] = appendInElement(children[head], rest, elem);
  return { ...container, children };
}

/**
 * Set an attribute on the element at `path`. Shallow — replaces the
 * top-level field only (x, y, width, fill, etc.). Returns a new Doc.
 *
 * Exported so the bootstrap script can route panel-state changes
 * (Color / Stroke) onto the current selection without going
 * through the dispatchEvent path (no tool to wrap them as).
 */
export function setElementAttr(doc, path, attr, value) {
  if (!Array.isArray(path) || path.length === 0) return doc;
  const [li, ...rest] = path;
  const layers = doc.layers.slice();
  if (li < 0 || li >= layers.length) return doc;
  layers[li] = replaceElementAt(layers[li], rest, (e) => ({ ...e, [attr]: value }));
  return { ...doc, layers };
}
