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
import { registerPrimitive } from "./evaluator.mjs";
import {
  setSelection, addToSelection, toggleSelection, clearSelection,
  getElement, mkPath,
  partialCpsForPath, setPartialCps,
} from "./document.mjs";
import { hitTestRect, translateElement, controlPoints } from "./geometry.mjs";
import * as pointBuffers from "./point_buffers.mjs";
import * as anchorBuffers from "./anchor_buffers.mjs";
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

  // ── Anchor-buffer mutations (Pen tool) ──────────────
  if ("anchor.push" in effect) {
    const spec = effect["anchor.push"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      const x = Number(toJson(evaluate(String(spec.x ?? "0"), scope))) || 0;
      const y = Number(toJson(evaluate(String(spec.y ?? "0"), scope))) || 0;
      if (name) anchorBuffers.push(name, x, y);
    }
    return;
  }
  if ("anchor.pop" in effect) {
    const spec = effect["anchor.pop"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      if (name) anchorBuffers.pop(name);
    }
    return;
  }
  if ("anchor.clear" in effect) {
    const spec = effect["anchor.clear"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      if (name) anchorBuffers.clear(name);
    }
    return;
  }
  if ("anchor.set_last_out" in effect) {
    const spec = effect["anchor.set_last_out"];
    if (spec && typeof spec === "object") {
      const name = String(spec.buffer || "");
      const hx = Number(toJson(evaluate(String(spec.hx ?? "0"), scope))) || 0;
      const hy = Number(toJson(evaluate(String(spec.hy ?? "0"), scope))) || 0;
      if (name) anchorBuffers.setLastOutHandle(name, hx, hy);
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
        case "doc.copy_selection": {
          // Spec: { dx, dy }
          // Duplicate every selected element in place (translated by
          // the given delta), insert each copy as a sibling right
          // after its original, and replace the selection with the
          // copies (as whole-element). Native: Controller::copy_selection.
          // Iterates in reverse path order so sibling insertions don't
          // shift the indices of yet-to-process originals.
          const dx = Number(toJson(evaluate(String(spec.dx ?? "0"), scope))) || 0;
          const dy = Number(toJson(evaluate(String(spec.dy ?? "0"), scope))) || 0;
          model.mutate((d) => {
            if (!d.selection || d.selection.length === 0) return d;
            const sorted = d.selection.slice().sort((a, b) => {
              for (let i = 0; i < Math.min(a.length, b.length); i++) {
                if (a[i] !== b[i]) return b[i] - a[i];
              }
              return b.length - a.length;
            });
            const newSel = [];
            let next = d;
            for (const path of sorted) {
              const elem = getElement(next, path);
              if (!elem) continue;
              const copy = translateElement(deepCloneElement(elem), dx, dy);
              const copyPath = path.slice();
              copyPath[copyPath.length - 1] += 1;
              next = insertElementAt(next, copyPath, copy);
              newSel.push(copyPath);
            }
            // Reset partial entries — copies are whole-selected.
            return { ...next, selection: newSel, partial_cps: {} };
          });
          return;
        }
        case "doc.move_path_handle": {
          // Reads tool.partial_selection.{handle_path,
          // handle_anchor_idx, handle_type} and applies a handle
          // move by (dx, dy). The opposite handle on the same anchor
          // is reflected around the anchor with its original
          // distance preserved — smooth-anchor symmetry. No-op if
          // no handle is currently latched.
          const dx = Number(toJson(evaluate(String(spec.dx ?? "0"), scope))) || 0;
          const dy = Number(toJson(evaluate(String(spec.dy ?? "0"), scope))) || 0;
          if (dx === 0 && dy === 0) return;
          const hpath = store.get("tool.partial_selection.handle_path");
          if (!Array.isArray(hpath) || hpath.length === 0) return;
          const anchorIdx = Number(store.get("tool.partial_selection.handle_anchor_idx")) || 0;
          const handleType = String(store.get("tool.partial_selection.handle_type") || "");
          if (handleType !== "in" && handleType !== "out") return;
          model.mutate((d) => {
            const elem = getElement(d, hpath);
            if (!elem || elem.type !== "path") return d;
            const moved = movePathHandle(elem, anchorIdx, handleType, dx, dy);
            const layers = d.layers.slice();
            const [li, ...rest] = hpath;
            layers[li] = replaceElementAt(layers[li], rest, () => moved);
            return { ...d, layers };
          });
          return;
        }
        case "doc.path.commit_partial_marquee": {
          // Spec: { x1, y1, x2, y2, additive }
          // Walk every shape in the document; for each, list which
          // CPs fall inside the marquee rect. additive = true merges
          // into the existing partial set (and keeps the existing
          // selection); additive = false replaces both. Element
          // joins the selection iff at least one CP is hit.
          const x1 = Number(toJson(evaluate(String(spec.x1), scope))) || 0;
          const y1 = Number(toJson(evaluate(String(spec.y1), scope))) || 0;
          const x2 = Number(toJson(evaluate(String(spec.x2), scope))) || 0;
          const y2 = Number(toJson(evaluate(String(spec.y2), scope))) || 0;
          const additive = "additive" in spec
            ? toBool(evaluate(String(spec.additive), scope)) : false;
          const minX = Math.min(x1, x2), maxX = Math.max(x1, x2);
          const minY = Math.min(y1, y2), maxY = Math.max(y1, y2);
          const hits = _cpsInRect(model.document, minX, minY, maxX, maxY);
          model.mutate((d) => {
            if (additive) {
              let next = d;
              for (const [pathKey, cps] of hits) {
                const path = pathKey.split(",").map(Number);
                const inSel = next.selection.some(
                  (p) => p.length === path.length
                    && p.every((v, i) => v === path[i]));
                if (!inSel) {
                  next = { ...next, selection: [...next.selection, path.slice()] };
                }
                const cur = partialCpsForPath(next, path) || [];
                const merged = Array.from(new Set([...cur, ...cps]));
                next = setPartialCps(next, path, merged);
              }
              return next;
            }
            // Non-additive: replace selection + partial map with the hits.
            const newSel = [];
            let next = { ...d, selection: newSel, partial_cps: {} };
            for (const [pathKey, cps] of hits) {
              const path = pathKey.split(",").map(Number);
              newSel.push(path.slice());
              next = setPartialCps(next, path, cps);
            }
            return { ...next, selection: newSel };
          });
          return;
        }
        case "doc.path.probe_partial_hit": {
          // Partial Selection's press-time dispatcher. Hit-test
          // priority (matches jas_dioxus path_probe_partial_hit):
          //   1. Bezier handle on a selected Path → mode='handle',
          //      latches handle_path / handle_anchor_idx / handle_type.
          //   2. Control point on any element → mode='moving_pending',
          //      replaces (or shift-toggles) the partial-CP set.
          //   3. Miss → mode='marquee'.
          const x = Number(toJson(evaluate(String(spec.x), scope))) || 0;
          const y = Number(toJson(evaluate(String(spec.y), scope))) || 0;
          // YAML uses hit_radius (matches Rust); accept the older
          // 'radius' name too as a transition alias.
          const radius = "hit_radius" in spec
            ? (Number(toJson(evaluate(String(spec.hit_radius), scope))) || 8)
            : ("radius" in spec
                ? (Number(toJson(evaluate(String(spec.radius), scope))) || 8)
                : 8);
          const shift = "shift" in spec
            ? toBool(evaluate(String(spec.shift), scope)) : false;

          // 1. Bezier handle on a selected Path?
          const hh = _hitTestPathHandle(model.document, x, y, radius);
          if (hh) {
            store.set("tool.partial_selection.mode", "handle");
            store.set("tool.partial_selection.handle_anchor_idx", hh.anchor_idx);
            store.set("tool.partial_selection.handle_type", hh.handle_type);
            store.set("tool.partial_selection.handle_path", hh.path);
            return;
          }

          // 2. Control point hit?
          const hit = _hitTestCp(model.document, x, y, radius);
          if (hit) {
            model.snapshot();
            model.mutate((d) => {
              const cur = partialCpsForPath(d, hit.path) || [];
              let nextCps;
              let nextSel = d.selection;
              const inSel = d.selection.some(
                (p) => p.length === hit.path.length
                  && p.every((v, i) => v === hit.path[i]));
              if (!inSel) {
                nextSel = [...d.selection, hit.path.slice()];
              }
              if (shift) {
                const idx = cur.indexOf(hit.cp_index);
                nextCps = idx >= 0
                  ? cur.filter((i) => i !== hit.cp_index)
                  : [...cur, hit.cp_index];
              } else {
                // No shift: replace with just this CP.
                nextSel = [hit.path.slice()];
                nextCps = [hit.cp_index];
              }
              const withSel = { ...d, selection: nextSel };
              return setPartialCps(withSel, hit.path, nextCps);
            });
            store.set("tool.partial_selection.mode", "moving_pending");
          } else {
            store.set("tool.partial_selection.mode", "marquee");
          }
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
          applyShapeDefaults(resolved, store);
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
        case "doc.add_path_from_anchor_buffer": {
          // Spec: { buffer: <name>, closed?: <expr>,
          //         stroke?: <expr>, fill?: <expr> }
          // Walks the named anchor buffer; emits one CurveTo per
          // consecutive pair of anchors (using prev.hout + curr.hin
          // as control points — corner anchors collapse to straight
          // lines automatically). When closed is true, adds a final
          // CurveTo from the last anchor back to the first plus a
          // ClosePath. Mirrors jas_dioxus PenTool::finish.
          const name = String(spec.buffer || "");
          if (!name) return;
          const anchors = anchorBuffers.anchors(name);
          if (anchors.length < 2) return;
          const closed = "closed" in spec
            ? toBool(evaluate(String(spec.closed), scope)) : false;
          const cmds = [{ type: "M", x: anchors[0].x, y: anchors[0].y }];
          for (let i = 1; i < anchors.length; i++) {
            const prev = anchors[i - 1];
            const curr = anchors[i];
            cmds.push({
              type: "C",
              x1: prev.hout_x, y1: prev.hout_y,
              x2: curr.hin_x,  y2: curr.hin_y,
              x: curr.x, y: curr.y,
            });
          }
          if (closed) {
            const last = anchors[anchors.length - 1];
            const first = anchors[0];
            cmds.push({
              type: "C",
              x1: last.hout_x, y1: last.hout_y,
              x2: first.hin_x, y2: first.hin_y,
              x: first.x, y: first.y,
            });
            cmds.push({ type: "Z" });
          }
          const extra = {};
          if ("stroke" in spec) extra.stroke = toJson(evaluate(String(spec.stroke), scope));
          if ("fill" in spec) extra.fill = toJson(evaluate(String(spec.fill), scope));
          const elem = mkPath({ d: cmds, ...extra });
          // Open paths default to no fill (a free-standing curve is
          // rarely meant to be filled). Closed paths fall through to
          // the panel's fill colour.
          if (!closed && !("fill" in spec)) elem.fill = null;
          applyShapeDefaults(elem, store);
          model.mutate((d) => addElementAt(d, [0], elem));
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
          // Pencil shouldn't inherit a default fill — a freehand
          // stroke is rarely meant to be a filled region. Use null
          // when the spec didn't specify a fill explicitly.
          if (!("fill" in spec)) elem.fill = null;
          applyShapeDefaults(elem, store);
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
  const replaceAt = (layerIdx, subpath, replacer) => {
    if (subpath.length === 0) {
      layers[layerIdx] = replacer(layers[layerIdx]);
      return;
    }
    layers[layerIdx] = replaceElementAt(layers[layerIdx], subpath, replacer);
  };
  for (const path of doc.selection) {
    if (path.length === 0) continue;
    const partial = partialCpsForPath(doc, path);
    const [li, ...rest] = path;
    if (partial !== null) {
      // Partial selection: translate only the listed anchors.
      // Path elements get the per-anchor rewrite below; non-path
      // elements would need conversion to a Path to express
      // arbitrary anchor translation — defer that and treat
      // partial-CP non-paths as whole-element translation.
      replaceAt(li, rest, (e) => {
        if (e && e.type === "path") {
          return translatePathAnchors(e, partial, dx, dy);
        }
        return translateElement(e, dx, dy);
      });
    } else {
      // SelectionKind::All — translate the whole element.
      replaceAt(li, rest, (e) => translateElement(e, dx, dy));
    }
  }
  return { ...doc, layers };
}

// Translate the listed anchor indices of a Path element by (dx, dy).
// Anchor index `i` corresponds to non-Z command `i`; translating an
// anchor shifts the command's destination plus the Bezier handles
// attached to that anchor (the in-handle on this command's x2/y2 and
// the out-handle on the next command's x1/y1) so smooth-curve shape
// is preserved across the move.
function translatePathAnchors(elem, anchorIndices, dx, dy) {
  if (!elem.d || !Array.isArray(elem.d)) return elem;
  const sel = new Set(anchorIndices);
  const cmds = elem.d.map((c) => ({ ...c }));
  // Map each non-Z command index back to its anchor index. (Z
  // contributes no anchor.)
  const anchorOf = [];
  let ai = 0;
  for (const c of cmds) {
    anchorOf.push(c.type === "Z" ? -1 : ai);
    if (c.type !== "Z") ai += 1;
  }
  for (let i = 0; i < cmds.length; i++) {
    const a = anchorOf[i];
    if (a < 0) continue;
    if (sel.has(a)) {
      // Destination of this command moves with anchor a.
      if (typeof cmds[i].x === "number") cmds[i].x += dx;
      if (typeof cmds[i].y === "number") cmds[i].y += dy;
      // In-handle attached to anchor a (only present on C/S).
      if (typeof cmds[i].x2 === "number") cmds[i].x2 += dx;
      if (typeof cmds[i].y2 === "number") cmds[i].y2 += dy;
      // Out-handle attached to anchor a lives on the NEXT
      // command's x1/y1 (C/S/Q).
      if (i + 1 < cmds.length) {
        const next = cmds[i + 1];
        if (typeof next.x1 === "number") next.x1 += dx;
        if (typeof next.y1 === "number") next.y1 += dy;
      }
    }
  }
  return { ...elem, d: cmds };
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
export function deleteSelectedElements(doc) {
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
// Deep clone via structuredClone — handles paths/groups/etc.
function deepCloneElement(elem) {
  return JSON.parse(JSON.stringify(elem));
}

// Insert `elem` as a sibling at `path` (the existing element at
// `path` shifts right by one). `path` must end at a child slot, not
// a layer root.
function insertElementAt(doc, path, elem) {
  if (!Array.isArray(path) || path.length < 2) return doc;
  const layers = doc.layers.slice();
  const [li, ...rest] = path;
  if (li < 0 || li >= layers.length) return doc;
  layers[li] = insertInContainer(layers[li], rest, elem);
  return { ...doc, layers };
}

function insertInContainer(container, subpath, elem) {
  if (!container || !Array.isArray(container.children)) return container;
  if (subpath.length === 1) {
    const idx = subpath[0];
    const children = container.children.slice();
    const clamped = Math.max(0, Math.min(idx, children.length));
    children.splice(clamped, 0, elem);
    return { ...container, children };
  }
  const [head, ...rest] = subpath;
  const children = container.children.slice();
  if (head < 0 || head >= children.length) return container;
  children[head] = insertInContainer(children[head], rest, elem);
  return { ...container, children };
}

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

// Pen-tool primitives. Registered at module load so YAML guards
// like `anchor_buffer_length('pen') >= 2` work without dispatcher
// wiring per call. Both look up the named anchor buffer directly;
// no model needed.
registerPrimitive("anchor_buffer_length", (args) => {
  const name = args[0] && args[0].kind === "string" ? args[0].value : "";
  return { kind: "number", value: anchorBuffers.length(name) };
});
registerPrimitive("anchor_buffer_close_hit", (args) => {
  const name = args[0] && args[0].kind === "string" ? args[0].value : "";
  const x = args[1] && args[1].kind === "number" ? args[1].value : 0;
  const y = args[2] && args[2].kind === "number" ? args[2].value : 0;
  const r = args[3] && args[3].kind === "number" ? args[3].value : 8;
  return { kind: "bool", value: anchorBuffers.closeHit(name, x, y, r) };
});

// Hit-test for a control point under (x, y) within `radius`.
// Walks every shape in the document (top-down, last child wins for
// overlap) and returns the first CP within radius. Returns
// `{ path, cp_index }` on hit, null on miss. Recurses into groups
// and layers.
function _hitTestCp(doc, x, y, radius) {
  if (!doc || !Array.isArray(doc.layers)) return null;
  const r2 = radius * radius;
  function recur(elem, path) {
    if (!elem) return null;
    if (elem.type === "layer" || elem.type === "group") {
      const kids = elem.children || [];
      for (let i = kids.length - 1; i >= 0; i--) {
        const hit = recur(kids[i], [...path, i]);
        if (hit) return hit;
      }
      return null;
    }
    const cps = controlPoints(elem);
    for (let i = 0; i < cps.length; i++) {
      const dx = cps[i][0] - x, dy = cps[i][1] - y;
      if (dx * dx + dy * dy <= r2) return { path, cp_index: i };
    }
    return null;
  }
  for (let li = doc.layers.length - 1; li >= 0; li--) {
    const hit = recur(doc.layers[li], [li]);
    if (hit) return hit;
  }
  return null;
}

// Move a single handle (in or out) of an anchor on a Path. The
// opposite handle is reflected through the anchor while preserving
// its original distance — keeps smooth anchors smooth. Mirrors
// jas_dioxus/src/geometry/element.rs::move_path_handle.
function movePathHandle(elem, anchorIdx, handleType, dx, dy) {
  if (!elem || !Array.isArray(elem.d)) return elem;
  // Map anchor index → command index.
  const idxs = [];
  for (let i = 0; i < elem.d.length; i++) {
    if (elem.d[i].type !== "Z") idxs.push(i);
  }
  if (anchorIdx >= idxs.length) return elem;
  const ci = idxs[anchorIdx];
  const cmd = elem.d[ci];
  const ax = typeof cmd.x === "number" ? cmd.x : 0;
  const ay = typeof cmd.y === "number" ? cmd.y : 0;
  const cmds = elem.d.map((c) => ({ ...c }));
  const reflect = (newHx, newHy, oppHx, oppHy) => {
    const distNew = Math.hypot(newHx - ax, newHy - ay);
    const distOpp = Math.hypot(oppHx - ax, oppHy - ay);
    if (distNew < 1e-6) return [oppHx, oppHy];
    const scale = -distOpp / distNew;
    return [ax + (newHx - ax) * scale, ay + (newHy - ay) * scale];
  };

  if (handleType === "in") {
    if (typeof cmd.x2 !== "number" || typeof cmd.y2 !== "number") return elem;
    const newHx = cmd.x2 + dx, newHy = cmd.y2 + dy;
    cmds[ci].x2 = newHx;
    cmds[ci].y2 = newHy;
    const next = ci + 1 < cmds.length ? cmds[ci + 1] : null;
    if (next && typeof next.x1 === "number" && typeof next.y1 === "number") {
      const [rx, ry] = reflect(newHx, newHy, next.x1, next.y1);
      next.x1 = rx;
      next.y1 = ry;
    }
  } else if (handleType === "out") {
    const next = ci + 1 < cmds.length ? cmds[ci + 1] : null;
    if (!next || typeof next.x1 !== "number" || typeof next.y1 !== "number") return elem;
    const newHx = next.x1 + dx, newHy = next.y1 + dy;
    next.x1 = newHx;
    next.y1 = newHy;
    if (typeof cmd.x2 === "number" && typeof cmd.y2 === "number") {
      const [rx, ry] = reflect(newHx, newHy, cmd.x2, cmd.y2);
      cmds[ci].x2 = rx;
      cmds[ci].y2 = ry;
    }
  }
  return { ...elem, d: cmds };
}

// Hit-test for a Bezier handle (in or out) on a selected Path.
// Returns { path, anchor_idx, handle_type } on hit, null otherwise.
// A handle counts only when it's non-coincident with its anchor —
// otherwise corner anchors would expose phantom handles at the
// anchor position and make CP hits impossible.
function _hitTestPathHandle(doc, x, y, radius) {
  if (!doc || !Array.isArray(doc.selection)) return null;
  const r2 = radius * radius;
  for (const path of doc.selection) {
    const elem = getElement(doc, path);
    if (!elem || elem.type !== "path" || !Array.isArray(elem.d)) continue;
    const cmds = elem.d;
    // Walk anchors, mapping each non-Z command index to anchor index.
    let ai = 0;
    for (let i = 0; i < cmds.length; i++) {
      const c = cmds[i];
      if (c.type === "Z") continue;
      const anchorX = typeof c.x === "number" ? c.x : 0;
      const anchorY = typeof c.y === "number" ? c.y : 0;
      // In-handle on this command's x2/y2 (C/S only).
      if (typeof c.x2 === "number" && typeof c.y2 === "number") {
        const dx = c.x2 - anchorX, dy = c.y2 - anchorY;
        if (dx * dx + dy * dy > 0.01) {
          const hx = c.x2, hy = c.y2;
          if ((hx - x) * (hx - x) + (hy - y) * (hy - y) <= r2) {
            return { path: path.slice(), anchor_idx: ai, handle_type: "in" };
          }
        }
      }
      // Out-handle on the NEXT command's x1/y1 (C/S/Q).
      if (i + 1 < cmds.length) {
        const next = cmds[i + 1];
        if (typeof next.x1 === "number" && typeof next.y1 === "number") {
          const dx = next.x1 - anchorX, dy = next.y1 - anchorY;
          if (dx * dx + dy * dy > 0.01) {
            const hx = next.x1, hy = next.y1;
            if ((hx - x) * (hx - x) + (hy - y) * (hy - y) <= r2) {
              return { path: path.slice(), anchor_idx: ai, handle_type: "out" };
            }
          }
        }
      }
      ai += 1;
    }
  }
  return null;
}

// Find every control point inside the rect. Returns a Map keyed by
// pathKey ("0,2,1") with values being arrays of CP indices for that
// element. Visits all layers/groups recursively.
function _cpsInRect(doc, minX, minY, maxX, maxY) {
  const hits = new Map();
  if (!doc || !Array.isArray(doc.layers)) return hits;
  function recur(elem, path) {
    if (!elem) return;
    if (elem.type === "layer" || elem.type === "group") {
      const kids = elem.children || [];
      for (let i = 0; i < kids.length; i++) recur(kids[i], [...path, i]);
      return;
    }
    const cps = controlPoints(elem);
    const inside = [];
    for (let i = 0; i < cps.length; i++) {
      const [px, py] = cps[i];
      if (px >= minX && px <= maxX && py >= minY && py <= maxY) {
        inside.push(i);
      }
    }
    if (inside.length > 0) hits.set(path.join(","), inside);
  }
  for (let li = 0; li < doc.layers.length; li++) {
    recur(doc.layers[li], [li]);
  }
  return hits;
}

// Drawing tool yamls (rect, ellipse, line, …) intentionally omit fill
// and stroke from their add_element specs and rely on the engine to
// fold in the user's current panel colors. Without this, every
// freshly drawn shape would render with the SVG default black fill.
const SHAPE_TYPES = new Set([
  "rect", "circle", "ellipse", "line",
  "polygon", "polyline", "path",
]);

function applyShapeDefaults(elem, store) {
  if (!elem || !SHAPE_TYPES.has(elem.type)) return;
  const state = store && store.state ? store.state : {};
  if (!("fill" in elem) && state.fill_color !== undefined) {
    elem.fill = state.fill_color;
  }
  if (!("stroke" in elem) && state.stroke_color !== undefined) {
    elem.stroke = state.stroke_color;
  }
  if (!("stroke-width" in elem) && state.stroke_width !== undefined) {
    elem["stroke-width"] = state.stroke_width;
  }
}
