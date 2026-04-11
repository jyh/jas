/**
 * Generic effects engine for WORKSPACE.yaml-driven UI.
 * All action logic is interpreted from the effects lists in JAS_ACTIONS.
 * No app-specific hardcoding — the engine is purely data-driven.
 */

(function () {
  "use strict";

  // ── State store ────────────────────────────────────────────

  const state = Object.assign({}, typeof JAS_STATE !== "undefined" ? JAS_STATE : {});
  const actions = typeof JAS_ACTIONS !== "undefined" ? JAS_ACTIONS : {};
  const shortcuts = typeof JAS_SHORTCUTS !== "undefined" ? JAS_SHORTCUTS : [];
  const timers = {};  // named timers for long-press etc.

  // ── Interpolation engine ───────────────────────────────────

  function resolve(template, ctx) {
    if (template === null || template === undefined) return null;
    if (typeof template === "number" || typeof template === "boolean") return template;
    var s = String(template);
    if (s.indexOf("{{") === -1) return s;
    return s.replace(/\{\{(.+?)\}\}/g, function (_, expr) {
      return evalExpr(expr.trim(), ctx);
    });
  }

  function evalExpr(expr, ctx) {
    // Simple expression evaluator for interpolation
    ctx = ctx || {};
    var parts = expr.split(".");
    if (parts[0] === "state") return state[parts[1]];
    if (parts[0] === "param" && ctx.params) return ctx.params[parts[1]];
    if (parts[0] === "event" && ctx.event) return ctx.event[parts[1]];
    if (parts[0] === "self" && ctx.self) return ctx.self[parts[1]];
    if (parts[0] === "theme") {
      var themeData = typeof JAS_THEME !== "undefined" ? JAS_THEME : {};
      var obj = themeData;
      for (var ti = 1; ti < parts.length; ti++) {
        if (obj && typeof obj === "object" && parts[ti] in obj) {
          obj = obj[parts[ti]];
        } else {
          return "";
        }
      }
      return obj;
    }
    return "";
  }

  function evalCondition(condStr, ctx) {
    if (!condStr) return true;
    // Resolve interpolations first
    var resolved = resolve(condStr, ctx);
    // Simple boolean evaluation
    if (resolved === "true" || resolved === true) return true;
    if (resolved === "false" || resolved === false || resolved === "" || resolved === "null" || resolved === null) return false;
    // Handle "not X"
    if (typeof resolved === "string" && resolved.startsWith("not ")) {
      return !evalCondition(resolved.substring(4), ctx);
    }
    // Handle "X == Y"
    var eqMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*==\s*(.+)$/) : null;
    if (eqMatch) return eqMatch[1].trim() === eqMatch[2].trim();
    var neqMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*!=\s*(.+)$/) : null;
    if (neqMatch) return neqMatch[1].trim() !== neqMatch[2].trim();
    // Truthy
    return !!resolved;
  }

  // ── State mutation + reactive update ───────────────────────

  function setState(key, value) {
    var old = state[key];
    state[key] = value;
    if (old !== value) {
      updateBindings(key, value);
    }
  }

  function updateBindings(key, value) {
    // Generic data-bind-visible: show/hide based on boolean expression
    document.querySelectorAll("[data-bind-visible]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-visible");
      var result = evalCondition(resolve(expr, {}), {});
      if (result) {
        // Restore original display (saved on first hide)
        var saved = el.getAttribute("data-original-display");
        el.style.display = saved || "";
      } else {
        // Save current display before hiding
        if (el.style.display !== "none") {
          el.setAttribute("data-original-display", el.style.display);
        }
        el.style.display = "none";
      }
    });
    // Generic data-bind-checked: toggle "active" class
    document.querySelectorAll("[data-bind-checked]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-checked");
      var result = evalCondition(resolve(expr, {}), {});
      el.classList.toggle("active", result);
    });
    // Generic data-bind-active: toggle "active" class (alias for checked)
    document.querySelectorAll("[data-bind-active]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-active");
      var result = evalCondition(resolve(expr, {}), {});
      el.classList.toggle("active", result);
    });
    // Generic data-bind-color: set background color
    document.querySelectorAll("[data-bind-color]").forEach(function (el) {
      var ref = el.getAttribute("data-bind-color");
      var color = resolve(ref, {});
      if (color && color !== "null") {
        el.style.background = color;
      } else {
        el.style.background = "#fff";
      }
    });
    // Generic data-bind-icon: swap SVG content via ternary expression
    document.querySelectorAll("[data-bind-icon]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-icon");
      var resolved = resolve(expr, {});
      var ternary = resolved.match(/^(.+?)\s*\?\s*(\S+)\s*:\s*(\S+)$/);
      if (ternary) {
        var cond = evalCondition(ternary[1], {});
        var iconName = cond ? ternary[2] : ternary[3];
        var iconDef = (typeof JAS_ICONS !== "undefined") ? JAS_ICONS[iconName] : null;
        if (iconDef) {
          var svg = el.querySelector("svg");
          if (svg) {
            svg.setAttribute("viewBox", iconDef.viewbox || "0 0 16 16");
            svg.innerHTML = iconDef.svg || "";
          }
        }
      }
    });
    // Generic data-bind-z_index: set z-index via ternary expression
    document.querySelectorAll("[data-bind-z_index]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-z_index");
      var resolved = resolve(expr, {});
      var ternary = resolved.match(/^(.+?)\s*\?\s*(\S+)\s*:\s*(\S+)$/);
      if (ternary) {
        var cond = evalCondition(ternary[1], {});
        el.style.zIndex = cond ? ternary[2] : ternary[3];
      } else {
        el.style.zIndex = resolved;
      }
    });
    // Generic data-bind-collapsed: collapse pane to collapsed_width, hide content
    document.querySelectorAll("[data-bind-collapsed]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-collapsed");
      var result = evalCondition(resolve(expr, {}), {});
      var cw = el.getAttribute("data-collapsed-width");
      if (result && cw) {
        el.style.width = cw + "px";
        var content = el.querySelector(".jas-pane-content");
        if (content) content.style.display = "none";
      } else if (!result && cw) {
        el.style.width = "";
        var content = el.querySelector(".jas-pane-content");
        if (content) content.style.display = "";
      }
    });
  }

  // ── Effects interpreter ────────────────────────────────────

  function runEffects(effects, ctx) {
    if (!effects || !effects.length) return;
    for (var i = 0; i < effects.length; i++) {
      runEffect(effects[i], ctx);
    }
  }

  function runEffect(effect, ctx) {
    if (!effect || typeof effect !== "object") return;

    // set: { key: value, ... }
    if (effect.set) {
      var pairs = effect.set;
      for (var k in pairs) {
        if (pairs.hasOwnProperty(k)) {
          var val = resolve(pairs[k], ctx);
          if (val === "null") val = null;
          if (val === "true") val = true;
          if (val === "false") val = false;
          setState(k, val);
        }
      }
      return;
    }

    // toggle: state_key
    if (effect.toggle !== undefined) {
      var toggleKey = resolve(effect.toggle, ctx);
      setState(toggleKey, !state[toggleKey]);
      return;
    }

    // swap: [key_a, key_b]
    if (effect.swap) {
      var a = effect.swap[0], b = effect.swap[1];
      var tmp = state[a];
      setState(a, state[b]);
      setState(b, tmp);
      return;
    }

    // increment: { key, by }
    if (effect.increment) {
      var incKey = effect.increment.key;
      var incBy = effect.increment.by || 1;
      setState(incKey, (state[incKey] || 0) + incBy);
      return;
    }

    // decrement: { key, by }
    if (effect.decrement) {
      var decKey = effect.decrement.key;
      var decBy = effect.decrement.by || 1;
      setState(decKey, (state[decKey] || 0) - decBy);
      return;
    }

    // reset: [keys]
    if (effect.reset) {
      var defaults = typeof JAS_STATE !== "undefined" ? JAS_STATE : {};
      effect.reset.forEach(function (rk) {
        setState(rk, defaults[rk]);
      });
      return;
    }

    // if: { condition, then, else }
    if (effect["if"]) {
      var cond = effect["if"];
      if (evalCondition(resolve(cond.condition, ctx), ctx)) {
        runEffects(cond["then"], ctx);
      } else if (cond["else"]) {
        runEffects(cond["else"], ctx);
      }
      return;
    }

    // show: element_id
    if (effect.show) {
      var showEl = document.getElementById(resolve(effect.show, ctx));
      if (showEl) showEl.style.display = "";
      return;
    }

    // hide: element_id
    if (effect.hide) {
      var hideEl = document.getElementById(resolve(effect.hide, ctx));
      if (hideEl) hideEl.style.display = "none";
      return;
    }

    // create_child: { parent, element }
    if (effect.create_child) {
      var parentId = resolve(effect.create_child.parent, ctx);
      var parentEl = document.getElementById(parentId);
      if (parentEl && effect.create_child.element) {
        var spec = effect.create_child.element;
        var child = createElementFromSpec(spec, ctx);
        parentEl.appendChild(child);
      }
      return;
    }

    // remove_child: element_id
    if (effect.remove_child) {
      var childId = resolve(effect.remove_child, ctx);
      var childEl = document.getElementById(childId);
      if (childEl) childEl.remove();
      return;
    }

    // add_class: { target, class }
    if (effect.add_class) {
      var acEl = document.getElementById(resolve(effect.add_class.target, ctx));
      if (acEl) acEl.classList.add(effect.add_class["class"]);
      return;
    }

    // remove_class: { target, class }
    if (effect.remove_class) {
      var rcEl = document.getElementById(resolve(effect.remove_class.target, ctx));
      if (rcEl) rcEl.classList.remove(effect.remove_class["class"]);
      return;
    }

    // set_style: { target, prop: val, ... }
    if (effect.set_style) {
      var ssTarget = resolve(effect.set_style.target, ctx);
      var ssEl = document.getElementById(ssTarget);
      if (ssEl) {
        for (var prop in effect.set_style) {
          if (prop !== "target" && effect.set_style.hasOwnProperty(prop)) {
            ssEl.style[prop] = resolve(effect.set_style[prop], ctx) + "px";
          }
        }
      }
      return;
    }

    // focus: element_id
    if (effect.focus) {
      var fEl = document.getElementById(resolve(effect.focus, ctx));
      if (fEl) fEl.focus();
      return;
    }

    // scroll_to: element_id
    if (effect.scroll_to) {
      var stEl = document.getElementById(resolve(effect.scroll_to, ctx));
      if (stEl) stEl.scrollIntoView({ behavior: "smooth" });
      return;
    }

    // tile: { container }
    // Horizontal single-row tile matching the Rust algorithm:
    //   1. Unhide all panes
    //   2. Sort panes left-to-right by current x, then descending y
    //   3. Classify widths: fixed_width → Fixed, collapsed_width → KeepCurrent, else → Flex
    //   4. Flex panes split remaining space equally (respecting min_width)
    //   5. Position left-to-right, full viewport height
    if (effect.tile) {
      var configs = typeof JAS_PANE_CONFIGS !== "undefined" ? JAS_PANE_CONFIGS : {};
      var container = document.getElementById(resolve(effect.tile.container, ctx));
      if (!container) return;

      // Phase 1: unhide all panes by setting any bound visible state to true
      var paneEls = Array.from(container.querySelectorAll(".jas-pane"));
      paneEls.forEach(function (p) {
        p.style.display = "";
        // Find the state key this pane's visibility is bound to and set it true
        var bindVis = p.getAttribute("data-bind-visible");
        if (bindVis) {
          var m = bindVis.match(/\{\{state\.(.+?)\}\}/);
          if (m && state.hasOwnProperty(m[1])) setState(m[1], true);
        }
      });

      // Phase 2: sort by x ascending, then y descending
      paneEls.sort(function (a, b) {
        var ax = a.offsetLeft, bx = b.offsetLeft;
        if (ax !== bx) return ax - bx;
        return b.offsetTop - a.offsetTop;
      });

      if (paneEls.length === 0) return;

      var vw = container.clientWidth || window.innerWidth;
      var vh = container.clientHeight || (window.innerHeight - 28); // subtract menubar

      // Phase 3: classify widths
      var widthTypes = paneEls.map(function (p) {
        var cfg = configs[p.id] || {};
        if (cfg.fixed_width) return { type: "fixed", value: p.offsetWidth };
        if (cfg.collapsed_width != null) return { type: "keep", value: p.offsetWidth };
        return { type: "flex", min: cfg.min_width || 50 };
      });

      // Phase 4: compute flex sizes
      var fixedTotal = 0;
      var flexCount = 0;
      var maxFlexMin = 0;
      widthTypes.forEach(function (wt) {
        if (wt.type === "fixed" || wt.type === "keep") {
          fixedTotal += wt.value;
        } else {
          flexCount++;
          if (wt.min > maxFlexMin) maxFlexMin = wt.min;
        }
      });

      var flexEach = 0;
      if (flexCount > 0) {
        flexEach = Math.max((vw - fixedTotal) / flexCount, maxFlexMin);
      }

      var finalWidths = widthTypes.map(function (wt) {
        if (wt.type === "flex") return flexEach;
        return wt.value;
      });

      // Phase 5: position left-to-right, full height
      var x = 0;
      for (var ti = 0; ti < paneEls.length; ti++) {
        paneEls[ti].style.left = x + "px";
        paneEls[ti].style.top = "0px";
        paneEls[ti].style.width = finalWidths[ti] + "px";
        paneEls[ti].style.height = vh + "px";
        x += finalWidths[ti];
      }
      return;
    }

    // reset_layout: { container }
    if (effect.reset_layout) {
      // Reset pane positions to defaults
      var configs = typeof JAS_PANE_CONFIGS !== "undefined" ? JAS_PANE_CONFIGS : {};
      for (var paneId in configs) {
        if (configs.hasOwnProperty(paneId)) {
          var pos = configs[paneId].default_position;
          if (!pos) continue;
          var paneEl = document.getElementById(paneId);
          if (paneEl) {
            paneEl.style.left = pos.x + "px";
            paneEl.style.top = pos.y + "px";
            paneEl.style.width = pos.width + "px";
            paneEl.style.height = pos.height + "px";
            paneEl.style.display = "";
          }
        }
      }
      // Reset all state variables to their declared defaults
      var defaults = typeof JAS_STATE !== "undefined" ? JAS_STATE : {};
      for (var dk in defaults) {
        if (defaults.hasOwnProperty(dk)) {
          setState(dk, defaults[dk]);
        }
      }
      return;
    }

    // open_dialog: { id, params }
    if (effect.open_dialog) {
      var dlgSpec = effect.open_dialog;
      var dlgId = typeof dlgSpec === "string" ? dlgSpec : resolve(dlgSpec.id, ctx);
      var modalEl = document.getElementById("dialog-" + dlgId);
      if (modalEl && typeof bootstrap !== "undefined") {
        var modal = bootstrap.Modal.getOrCreateInstance(modalEl);
        modal.show();
      }
      return;
    }

    // close_dialog: id (or null for topmost)
    if (effect.hasOwnProperty("close_dialog")) {
      var cdId = effect.close_dialog;
      var modalToClose;
      if (cdId) {
        modalToClose = document.getElementById("dialog-" + resolve(cdId, ctx));
      } else {
        modalToClose = document.querySelector(".modal.show");
      }
      if (modalToClose && typeof bootstrap !== "undefined") {
        var bsModal = bootstrap.Modal.getInstance(modalToClose);
        if (bsModal) bsModal.hide();
      }
      return;
    }

    // dispatch: action_id  or  { action, params }
    if (effect.dispatch) {
      var dSpec = effect.dispatch;
      if (typeof dSpec === "string") {
        dispatch(dSpec, {});
      } else {
        var dParams = {};
        if (dSpec.params) {
          for (var dp in dSpec.params) {
            if (dSpec.params.hasOwnProperty(dp)) {
              dParams[dp] = resolve(dSpec.params[dp], ctx);
            }
          }
        }
        dispatch(dSpec.action, dParams);
      }
      return;
    }

    // cursor: type  or  { target, type }
    if (effect.cursor) {
      if (typeof effect.cursor === "string") {
        document.body.style.cursor = effect.cursor;
      } else {
        var cTarget = document.getElementById(resolve(effect.cursor.target, ctx));
        if (cTarget) cTarget.style.cursor = effect.cursor.type;
      }
      return;
    }

    // flash: element_id
    if (effect.flash) {
      var flEl = document.getElementById(resolve(effect.flash, ctx));
      if (flEl) {
        flEl.classList.add("jas-flash");
        setTimeout(function () { flEl.classList.remove("jas-flash"); }, 300);
      }
      return;
    }

    // status: message
    if (effect.status) {
      console.log("[status]", resolve(effect.status, ctx));
      return;
    }

    // start_timer: { id, delay_ms, effects }
    if (effect.start_timer) {
      var tSpec = effect.start_timer;
      var tId = resolve(tSpec.id, ctx);
      cancelTimer(tId);
      var tCtx = Object.assign({}, ctx);
      timers[tId] = setTimeout(function () {
        delete timers[tId];
        runEffects(tSpec.effects, tCtx);
      }, tSpec.delay_ms || 250);
      return;
    }

    // cancel_timer: id
    if (effect.cancel_timer) {
      cancelTimer(resolve(effect.cancel_timer, ctx));
      return;
    }

    // log: message
    if (effect.log) {
      console.log("[effect]", resolve(effect.log, ctx));
      return;
    }
  }

  function cancelTimer(id) {
    if (timers[id]) {
      clearTimeout(timers[id]);
      delete timers[id];
    }
  }

  // ── Dynamic element creation ─────────────────────────────────

  function createElementFromSpec(spec, ctx) {
    var type = spec.type || "placeholder";
    var el = document.createElement("div");

    // Set id
    if (spec.id) el.id = resolve(spec.id, ctx);

    // Apply label for buttons
    var label = spec.label ? resolve(spec.label, ctx) : "";

    // Build styles
    var styles = [];
    var s = spec.style || {};
    if (s.flex) styles.push("flex:" + s.flex);
    if (s.background) styles.push("background:" + resolve(s.background, ctx));
    if (s.padding) styles.push("padding:" + s.padding.split(" ").map(function(v) { return v + "px"; }).join(" "));
    if (s.font_size) styles.push("font-size:" + s.font_size + "px");
    if (s.min_height) styles.push("min-height:" + s.min_height + "px");
    if (s.width) styles.push("width:" + s.width + "px");
    if (s.height) styles.push("height:" + s.height + "px");
    if (s.border) styles.push("border:" + resolve(s.border, ctx));
    if (s.gap != null) styles.push("gap:" + s.gap + "px");
    if (s.alignment) {
      var alignMap = {start:"flex-start", end:"flex-end", center:"center", stretch:"stretch"};
      styles.push("align-items:" + (alignMap[s.alignment] || s.alignment));
    }
    if (s.justify) {
      var justMap = {start:"flex-start", end:"flex-end", center:"center", between:"space-between", around:"space-around"};
      styles.push("justify-content:" + (justMap[s.justify] || s.justify));
    }

    if (type === "container") {
      var dir = (spec.layout === "row") ? "flex-row" : "flex-column";
      el.className = "d-flex " + dir;
      el.style.cssText = styles.join(";");
      if (spec.id) el.id = resolve(spec.id, ctx);
      // Recurse into children
      (spec.children || []).forEach(function (childSpec) {
        var childEl = createElementFromSpec(childSpec, ctx);
        el.appendChild(childEl);
      });
    } else if (type === "text") {
      el = document.createElement("span");
      if (spec.id) el.id = resolve(spec.id, ctx);
      el.textContent = resolve(spec.content || "", ctx);
      el.style.cssText = styles.join(";");
    } else if (type === "button") {
      el = document.createElement("button");
      el.className = "btn btn-sm btn-secondary";
      el.textContent = label;
      if (spec.id) el.id = resolve(spec.id, ctx);
      el.style.cssText = styles.join(";");
    } else if (type === "icon_button") {
      el = document.createElement("button");
      el.className = "btn btn-sm btn-outline-secondary jas-tool-btn p-0";
      if (spec.id) el.id = resolve(spec.id, ctx);
      var ibSz = s.size || 16;
      styles.push("width:" + ibSz + "px", "height:" + ibSz + "px",
                   "display:flex", "align-items:center", "justify-content:center");
      el.style.cssText = styles.join(";");
      var iconName = spec.icon ? resolve(spec.icon, ctx) : "";
      var iconDef = (typeof JAS_ICONS !== "undefined") ? JAS_ICONS[iconName] : null;
      if (iconDef) {
        var iconSz = Math.floor(ibSz * 0.75);
        el.innerHTML = '<svg viewBox="' + (iconDef.viewbox || "0 0 16 16") + '" width="' + iconSz +
          '" height="' + iconSz + '" fill="currentColor" style="color:#cccccc">' + (iconDef.svg || "") + '</svg>';
      } else {
        el.textContent = iconName;
      }
    } else if (type === "canvas") {
      el.className = "jas-canvas";
      styles.push("display:flex", "align-items:center", "justify-content:center",
                   "color:#999", "font-size:14px", "min-height:200px");
      el.style.cssText = styles.join(";");
      el.textContent = (spec.summary || "Canvas") + " (tier 3)";
    } else if (type === "placeholder") {
      el.className = "jas-placeholder";
      styles.push("border:1px dashed #666", "padding:12px", "color:#888",
                   "text-align:center", "font-size:11px", "min-height:40px");
      el.style.cssText = styles.join(";");
      el.textContent = spec.summary || "Placeholder";
    } else {
      el.style.cssText = styles.join(";");
      el.textContent = label || spec.summary || type;
    }

    // Deep-resolve all {{}} in an object tree (freezes state refs at creation time)
    function deepResolve(obj) {
      if (typeof obj === "string") return resolve(obj, ctx);
      if (Array.isArray(obj)) return obj.map(deepResolve);
      if (obj && typeof obj === "object") {
        var out = {};
        for (var k in obj) {
          if (obj.hasOwnProperty(k)) out[k] = deepResolve(obj[k]);
        }
        return out;
      }
      return obj;
    }

    // Apply bind attributes (resolved to freeze tab indices)
    if (spec.bind) {
      var resolvedBind = deepResolve(spec.bind);
      for (var prop in resolvedBind) {
        if (resolvedBind.hasOwnProperty(prop)) {
          el.setAttribute("data-bind-" + prop, resolvedBind[prop]);
        }
      }
    }

    // Wire behaviors (resolved to freeze tab indices in effects)
    if (spec.behavior) {
      var resolvedBehavior = deepResolve(spec.behavior);
      el.setAttribute("data-behaviors", JSON.stringify(resolvedBehavior));
      wireBehaviors(el);
    }

    return el;
  }

  function wireBehaviors(el) {
    var behaviors;
    try { behaviors = JSON.parse(el.getAttribute("data-behaviors")); } catch (ex) { return; }
    behaviors.forEach(function (b) {
      var domEvent = eventMap[b.event];
      if (!domEvent) return;
      el.addEventListener(domEvent, function (e) {
        var ctx = {
          params: {},
          event: {
            client_x: e.clientX, client_y: e.clientY,
            offset_x: e.offsetX, offset_y: e.offsetY,
            target_id: el.id,
            key: e.key, ctrl: e.ctrlKey || e.metaKey,
            shift: e.shiftKey, alt: e.altKey,
            value: e.target.value
          },
          self: { id: el.id, type: el.getAttribute("data-element-type") || "" }
        };
        if (b.condition && !evalCondition(resolve(b.condition, ctx), ctx)) return;
        if (b.prevent_default) e.preventDefault();
        if (b.stop_propagation) e.stopPropagation();
        if (b.effects) runEffects(b.effects, ctx);
        if (b.action) {
          var params = {};
          if (b.params) {
            for (var pk in b.params) {
              if (b.params.hasOwnProperty(pk)) {
                params[pk] = resolve(b.params[pk], ctx);
              }
            }
          }
          dispatch(b.action, params);
        }
      });
    });
  }

  // ── Action dispatch (generic, effects-driven) ──────────────

  function dispatch(actionId, params) {
    params = params || {};
    var def = actions[actionId];
    if (!def) {
      console.warn("[action] unknown:", actionId);
      return;
    }

    // Check enabled_when
    if (def.enabled_when) {
      if (!evalCondition(def.enabled_when, { params: params })) {
        console.log("[action] disabled:", actionId);
        return;
      }
    }

    console.log("[action]", actionId, params);

    // Build context for interpolation
    var ctx = { params: params };

    // Resolve param interpolations
    var resolvedParams = {};
    for (var k in params) {
      if (params.hasOwnProperty(k)) {
        resolvedParams[k] = resolve(params[k], ctx);
      }
    }
    ctx.params = resolvedParams;

    // Run effects
    if (def.effects) {
      runEffects(def.effects, ctx);
    }
  }

  // ── Wire data-action attributes ────────────────────────────

  document.addEventListener("DOMContentLoaded", function () {
    // Wire click handlers via event delegation
    document.addEventListener("click", function (e) {
      var el = e.target.closest("[data-action]");
      if (!el) return;
      e.preventDefault();
      var action = el.getAttribute("data-action");
      var paramsStr = el.getAttribute("data-action-params");
      var params = {};
      if (paramsStr) {
        try { params = JSON.parse(paramsStr); } catch (ex) { /* ignore */ }
      }
      dispatch(action, params);
    });

    // Wire behavior data attributes (mouse_down, mouse_up, hover)
    document.querySelectorAll("[data-behaviors]").forEach(function (el) {
      var behaviors;
      try { behaviors = JSON.parse(el.getAttribute("data-behaviors")); } catch (ex) { return; }
      behaviors.forEach(function (b) {
        var domEvent = eventMap[b.event];
        if (!domEvent) return;
        el.addEventListener(domEvent, function (e) {
          var ctx = {
            params: {},
            event: {
              client_x: e.clientX, client_y: e.clientY,
              offset_x: e.offsetX, offset_y: e.offsetY,
              target_id: el.id,
              key: e.key, ctrl: e.ctrlKey || e.metaKey,
              shift: e.shiftKey, alt: e.altKey,
              value: e.target.value
            },
            self: { id: el.id, type: el.getAttribute("data-element-type") || "" }
          };
          if (b.condition && !evalCondition(resolve(b.condition, ctx), ctx)) return;
          if (b.prevent_default) e.preventDefault();
          if (b.stop_propagation) e.stopPropagation();
          if (b.effects) runEffects(b.effects, ctx);
          if (b.action) {
            var params = {};
            if (b.params) {
              for (var pk in b.params) {
                if (b.params.hasOwnProperty(pk)) {
                  params[pk] = resolve(b.params[pk], ctx);
                }
              }
            }
            dispatch(b.action, params);
          }
        });
      });
    });

    // Initialize bindings
    for (var key in state) {
      if (state.hasOwnProperty(key)) {
        updateBindings(key, state[key]);
      }
    }
  });

  // Map schema event names to DOM event names
  var eventMap = {
    click: "click",
    double_click: "dblclick",
    mouse_down: "mousedown",
    mouse_up: "mouseup",
    mouse_move: "mousemove",
    hover_enter: "mouseenter",
    hover_leave: "mouseleave",
    key_down: "keydown",
    key_up: "keyup",
    change: "change",
    resize: "resize",
    right_click: "contextmenu"
  };

  // ── Keyboard shortcuts ─────────────────────────────────────

  function normalizeKey(keyStr) {
    return keyStr.split("+").map(function (k) { return k.trim().toLowerCase(); }).sort().join("+");
  }

  function buildKeyString(e) {
    var parts = [];
    if (e.ctrlKey || e.metaKey) parts.push("ctrl");
    if (e.altKey) parts.push("alt");
    if (e.shiftKey) parts.push("shift");
    var key = e.key;
    if (key === " ") key = "space";
    if (key.length === 1) key = key.toLowerCase();
    parts.push(key);
    return parts.sort().join("+");
  }

  document.addEventListener("keydown", function (e) {
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA" || e.target.isContentEditable) return;
    var pressed = buildKeyString(e);
    for (var i = 0; i < shortcuts.length; i++) {
      var s = shortcuts[i];
      if (normalizeKey(s.key) === pressed) {
        e.preventDefault();
        dispatch(s.action, s.params || {});
        return;
      }
    }
  });

  // ── Pane dragging ──────────────────────────────────────────

  var dragState = null;

  document.addEventListener("mousedown", function (e) {
    var title = e.target.closest(".jas-pane-title");
    if (!title) return;
    var pane = title.closest(".jas-pane");
    if (!pane) return;
    e.preventDefault();
    dragState = {
      pane: pane,
      offsetX: e.clientX - pane.offsetLeft,
      offsetY: e.clientY - pane.offsetTop
    };
    document.body.style.cursor = "grabbing";
    // Bring to front
    document.querySelectorAll(".jas-pane").forEach(function (p) {
      p.style.zIndex = p === pane ? "100" : "";
    });
  });

  document.addEventListener("mousemove", function (e) {
    if (!dragState) return;
    dragState.pane.style.left = (e.clientX - dragState.offsetX) + "px";
    dragState.pane.style.top = (e.clientY - dragState.offsetY) + "px";
  });

  document.addEventListener("mouseup", function () {
    if (dragState) {
      document.body.style.cursor = "";
      dragState = null;
    }
  });

  // ── Edge resize ────────────────────────────────────────────

  var resizeState = null;

  document.addEventListener("mousedown", function (e) {
    var handle = e.target.closest(".jas-edge-handle");
    if (!handle) return;
    var pane = handle.closest(".jas-pane");
    if (!pane) return;
    e.preventDefault();
    e.stopPropagation();
    resizeState = {
      pane: pane,
      startX: e.clientX, startY: e.clientY,
      startLeft: pane.offsetLeft, startTop: pane.offsetTop,
      startW: pane.offsetWidth, startH: pane.offsetHeight,
      isLeft: handle.classList.contains("left"),
      isRight: handle.classList.contains("right"),
      isTop: handle.classList.contains("top"),
      isBottom: handle.classList.contains("bottom")
    };
  });

  document.addEventListener("mousemove", function (e) {
    if (!resizeState) return;
    var r = resizeState, dx = e.clientX - r.startX, dy = e.clientY - r.startY;
    if (r.isRight) {
      r.pane.style.width = Math.max(50, r.startW + dx) + "px";
    } else if (r.isLeft) {
      var newW = Math.max(50, r.startW - dx);
      r.pane.style.width = newW + "px";
      r.pane.style.left = (r.startLeft + r.startW - newW) + "px";
    }
    if (r.isBottom) {
      r.pane.style.height = Math.max(50, r.startH + dy) + "px";
    } else if (r.isTop) {
      var newH = Math.max(50, r.startH - dy);
      r.pane.style.height = newH + "px";
      r.pane.style.top = (r.startTop + r.startH - newH) + "px";
    }
  });

  document.addEventListener("mouseup", function () {
    resizeState = null;
  });

})();
