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
    if (parts[0] === "theme") return ""; // theme resolved server-side
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
    // Update visibility bindings (pane_visible, etc.)
    if (key.endsWith("_visible")) {
      var paneId = key.replace("_visible", "_pane");
      var el = document.getElementById(paneId);
      if (el) el.style.display = value ? "" : "none";
    }
    // Update checked state on tool buttons
    document.querySelectorAll("[data-bind-checked]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-checked");
      var result = evalCondition(expr, {});
      el.classList.toggle("active", result);
    });
    // Update bound colors on swatches
    document.querySelectorAll("[data-bind-color]").forEach(function (el) {
      var ref = el.getAttribute("data-bind-color");
      var color = resolve(ref, {});
      if (color && color !== "null") {
        el.style.background = color;
      } else {
        el.style.background = "#fff";
      }
    });
    // Update collapsed state
    if (key === "dock_collapsed") {
      var dock = document.getElementById("dock_pane");
      if (dock) {
        dock.style.width = value ? "36px" : "";
        var content = dock.querySelector(".jas-pane-content");
        if (content) content.style.display = value ? "none" : "";
      }
    }
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
    //   1. Unhide all panes, unmaximize canvas
    //   2. Sort panes left-to-right by current x, then descending y
    //   3. Classify widths: fixed_width → Fixed, collapsed_width → KeepCurrent, else → Flex
    //   4. Flex panes split remaining space equally (respecting min_width)
    //   5. Position left-to-right, full viewport height
    if (effect.tile) {
      var configs = typeof JAS_PANE_CONFIGS !== "undefined" ? JAS_PANE_CONFIGS : {};
      var container = document.getElementById(resolve(effect.tile.container, ctx));
      if (!container) return;

      // Phase 1: unhide all panes, unmaximize
      setState("canvas_maximized", false);
      var paneEls = Array.from(container.querySelectorAll(".jas-pane"));
      paneEls.forEach(function (p) { p.style.display = ""; });
      for (var vid in configs) {
        if (vid.endsWith("_pane")) {
          var visKey = vid.replace("_pane", "") + "_visible";
          if (state.hasOwnProperty(visKey)) setState(visKey, true);
        }
      }

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
      // Reset visibility state
      setState("toolbar_visible", true);
      setState("canvas_visible", true);
      setState("dock_visible", true);
      setState("dock_collapsed", false);
      setState("canvas_maximized", false);
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
