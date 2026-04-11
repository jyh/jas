/**
 * Normal mode: reactive state, action dispatch, keyboard shortcuts, pane drag/resize.
 */

(function () {
  "use strict";

  // ── State store ────────────────────────────────────────────
  // JAS_STATE, JAS_ACTIONS, JAS_SHORTCUTS are injected by the template.

  const state = Object.assign({}, typeof JAS_STATE !== "undefined" ? JAS_STATE : {});
  const actions = typeof JAS_ACTIONS !== "undefined" ? JAS_ACTIONS : {};
  const shortcuts = typeof JAS_SHORTCUTS !== "undefined" ? JAS_SHORTCUTS : [];

  function setState(key, value) {
    state[key] = value;
    console.log(`[state] ${key} = ${JSON.stringify(value)}`);
    // Update tool button active states
    if (key === "active_tool") {
      document.querySelectorAll(".jas-tool-btn").forEach(function (btn) {
        const action = btn.getAttribute("data-action");
        const paramsStr = btn.getAttribute("data-action-params");
        if (action === "select_tool" && paramsStr) {
          try {
            const params = JSON.parse(paramsStr);
            btn.classList.toggle("active", params.tool === value);
          } catch (e) { /* ignore */ }
        }
      });
    }
  }

  // ── Action dispatch ────────────────────────────────────────

  function dispatch(actionId, params) {
    params = params || {};
    const def = actions[actionId];
    const tier = def ? def.tier : null;
    console.log(`[action] ${actionId}`, params, tier ? `(tier ${tier})` : "");

    if (actionId === "select_tool" && params.tool) {
      setState("active_tool", params.tool);
    } else if (actionId === "toggle_fill_on_top") {
      setState("fill_on_top", !state.fill_on_top);
    } else if (actionId === "swap_fill_stroke") {
      const f = state.fill_color;
      setState("fill_color", state.stroke_color);
      setState("stroke_color", f);
    } else if (actionId === "reset_fill_stroke") {
      setState("fill_color", "#ffffff");
      setState("stroke_color", "#000000");
      setState("fill_on_top", true);
    } else if (actionId === "set_fill_none") {
      setState("fill_color", null);
    } else if (actionId === "set_stroke_none") {
      setState("stroke_color", null);
    } else if (actionId === "toggle_pane") {
      const pane = params.pane;
      if (pane) {
        const key = pane + "_visible";
        setState(key, !state[key]);
        const el = document.getElementById(pane + "_pane");
        if (el) el.style.display = state[key] ? "" : "none";
      }
    } else if (actionId === "toggle_canvas_maximize") {
      setState("canvas_maximized", !state.canvas_maximized);
    } else if (actionId === "toggle_dock_collapse") {
      setState("dock_collapsed", !state.dock_collapsed);
    } else if (actionId === "dismiss_dialog") {
      // Close any open modal
      const modal = document.querySelector(".modal.show");
      if (modal) {
        const bsModal = bootstrap.Modal.getInstance(modal);
        if (bsModal) bsModal.hide();
      }
    }
    // Tier 3 actions: just logged above
  }

  // ── Wire data-action attributes ────────────────────────────

  document.addEventListener("DOMContentLoaded", function () {
    document.addEventListener("click", function (e) {
      const el = e.target.closest("[data-action]");
      if (!el) return;
      e.preventDefault();
      const action = el.getAttribute("data-action");
      const paramsStr = el.getAttribute("data-action-params");
      let params = {};
      if (paramsStr) {
        try { params = JSON.parse(paramsStr); } catch (e) { /* ignore */ }
      }
      dispatch(action, params);
    });
  });

  // ── Keyboard shortcuts ─────────────────────────────────────

  function normalizeKey(keyStr) {
    return keyStr
      .split("+")
      .map(function (k) { return k.trim().toLowerCase(); })
      .sort()
      .join("+");
  }

  function buildKeyString(e) {
    const parts = [];
    if (e.ctrlKey || e.metaKey) parts.push("ctrl");
    if (e.altKey) parts.push("alt");
    if (e.shiftKey) parts.push("shift");
    let key = e.key;
    if (key === " ") key = "space";
    if (key.length === 1) key = key.toLowerCase();
    parts.push(key);
    return parts.sort().join("+");
  }

  document.addEventListener("keydown", function (e) {
    // Ignore if typing in an input
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA" || e.target.isContentEditable) {
      return;
    }
    const pressed = buildKeyString(e);
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

  let dragState = null;

  document.addEventListener("mousedown", function (e) {
    const title = e.target.closest(".jas-pane-title");
    if (!title) return;
    const pane = title.closest(".jas-pane");
    if (!pane) return;
    e.preventDefault();
    dragState = {
      pane: pane,
      offsetX: e.clientX - pane.offsetLeft,
      offsetY: e.clientY - pane.offsetTop,
    };
    // Bring to front
    document.querySelectorAll(".jas-pane").forEach(function (p) {
      p.style.zIndex = p === pane ? "100" : "";
    });
  });

  document.addEventListener("mousemove", function (e) {
    if (!dragState) return;
    const pane = dragState.pane;
    pane.style.left = (e.clientX - dragState.offsetX) + "px";
    pane.style.top = (e.clientY - dragState.offsetY) + "px";
  });

  document.addEventListener("mouseup", function () {
    dragState = null;
  });

  // ── Edge resize ────────────────────────────────────────────

  let resizeState = null;

  document.addEventListener("mousedown", function (e) {
    const handle = e.target.closest(".jas-edge-handle");
    if (!handle) return;
    const pane = handle.closest(".jas-pane");
    if (!pane) return;
    e.preventDefault();
    e.stopPropagation();
    const isLeft = handle.classList.contains("left");
    const isRight = handle.classList.contains("right");
    const isTop = handle.classList.contains("top");
    const isBottom = handle.classList.contains("bottom");
    resizeState = {
      pane: pane,
      startX: e.clientX,
      startY: e.clientY,
      startLeft: pane.offsetLeft,
      startTop: pane.offsetTop,
      startW: pane.offsetWidth,
      startH: pane.offsetHeight,
      isLeft: isLeft,
      isRight: isRight,
      isTop: isTop,
      isBottom: isBottom,
    };
  });

  document.addEventListener("mousemove", function (e) {
    if (!resizeState) return;
    const r = resizeState;
    const dx = e.clientX - r.startX;
    const dy = e.clientY - r.startY;
    if (r.isRight) {
      r.pane.style.width = Math.max(50, r.startW + dx) + "px";
    } else if (r.isLeft) {
      const newW = Math.max(50, r.startW - dx);
      r.pane.style.width = newW + "px";
      r.pane.style.left = (r.startLeft + r.startW - newW) + "px";
    }
    if (r.isBottom) {
      r.pane.style.height = Math.max(50, r.startH + dy) + "px";
    } else if (r.isTop) {
      const newH = Math.max(50, r.startH - dy);
      r.pane.style.height = newH + "px";
      r.pane.style.top = (r.startTop + r.startH - newH) + "px";
    }
  });

  document.addEventListener("mouseup", function () {
    resizeState = null;
  });

})();
