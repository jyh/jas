/**
 * Generic effects engine for WORKSPACE.yaml-driven UI.
 * All action logic is interpreted from the effects lists in APP_ACTIONS.
 * No app-specific hardcoding — the engine is purely data-driven.
 */

(function () {
  "use strict";

  // ── State store ────────────────────────────────────────────

  const state = Object.assign({}, typeof APP_STATE !== "undefined" ? APP_STATE : {});
  const actions = typeof APP_ACTIONS !== "undefined" ? APP_ACTIONS : {};
  const shortcuts = typeof APP_SHORTCUTS !== "undefined" ? APP_SHORTCUTS : [];
  const timers = {};  // named timers for long-press etc.
  var STORAGE_KEY = "workspace_layouts";  // localStorage key for saved layouts
  var APPEARANCE_STORAGE_KEY = "app_appearances";  // localStorage key for user appearances
  var activeWorkspaceName = null;         // currently active workspace name
  var activeAppearanceName = typeof APP_ACTIVE_APPEARANCE !== "undefined" ? APP_ACTIVE_APPEARANCE : "dark_gray";

  // ── Runtime contexts ──────────────────────────────────────
  // active_document.* — properties of the active tab's document
  var activeDocumentCtx = {
    is_modified: false, has_filename: false, filename: "",
    any_modified: false, has_selection: false, selection_count: 0,
    can_undo: false, can_redo: false, zoom_level: 1.0
  };
  // workspace.* — properties of the workspace layout system
  var workspaceCtx = { has_saved_layout: false, active_layout_name: "" };
  // Initialize from runtime_contexts defaults if provided
  (function () {
    var rc = typeof APP_RUNTIME_CONTEXTS !== "undefined" ? APP_RUNTIME_CONTEXTS : {};
    if (rc.active_document && rc.active_document.defaults) {
      Object.assign(activeDocumentCtx, rc.active_document.defaults);
    }
    if (rc.workspace && rc.workspace.defaults) {
      Object.assign(workspaceCtx, rc.workspace.defaults);
    }
  })();

  // ── Dialog-local state ──────────────────────────────────���─
  var dialogState = null;         // non-null only while a dialog with state is open
  var dialogParams = null;        // params passed to open_dialog
  var dialogProps = null;         // {key: {get: expr, set: expr}} from YAML state defs
  var dialogSnapshot = null;      // {target_path: original_value} captured on open
                                  // when YAML declares preview_targets; restored on
                                  // close_dialog unless first cleared by an OK action.

  // ── Dialog property evaluation ─────────────────────────────
  // Evaluates get expressions against dialogState using colorFunctions.
  function dialogEvalExpr(expr, localScope) {
    if (!expr || typeof expr !== "string") return null;
    // Simple expression evaluator for property get/set expressions.
    // Handles: functionName(arg), functionName(arg1, arg2, arg3),
    // variable references, string concat with +, string literals
    var trimmed = expr.trim();

    // String literal
    if (trimmed.charAt(0) === '"' && trimmed.charAt(trimmed.length - 1) === '"') {
      return trimmed.slice(1, -1);
    }

    // String concat: expr + expr
    var plusIdx = findTopLevelPlus(trimmed);
    if (plusIdx > 0) {
      var left = dialogEvalExpr(trimmed.substring(0, plusIdx), localScope);
      var right = dialogEvalExpr(trimmed.substring(plusIdx + 1), localScope);
      return String(left != null ? left : "") + String(right != null ? right : "");
    }

    // Function call: name(args)
    var funcMatch = trimmed.match(/^(\w+)\((.+)\)$/);
    if (funcMatch) {
      var fname = funcMatch[1];
      var argsStr = funcMatch[2];
      var args = splitArgs(argsStr);
      var evalArgs = args.map(function (a) { return dialogEvalExpr(a.trim(), localScope); });
      // Built-in color functions
      if (colorFunctions[fname] && evalArgs.length === 1) {
        return colorFunctions[fname](evalArgs[0]);
      }
      // Multi-arg: hsb(h,s,b), rgb(r,g,b)
      if (fname === "hsb" && evalArgs.length === 3) {
        var rgb = hsbToRgb(Number(evalArgs[0]), Number(evalArgs[1]), Number(evalArgs[2]));
        return "#" + rgbToHexStr(rgb.r, rgb.g, rgb.b);
      }
      if (fname === "rgb" && evalArgs.length === 3) {
        return "#" + rgbToHexStr(Number(evalArgs[0]), Number(evalArgs[1]), Number(evalArgs[2]));
      }
      return null;
    }

    // Number literal
    if (/^-?\d+(\.\d+)?$/.test(trimmed)) {
      return Number(trimmed);
    }

    // Variable reference (bare name from local scope)
    if (/^\w+$/.test(trimmed) && localScope && trimmed in localScope) {
      return localScope[trimmed];
    }

    return null;
  }

  function findTopLevelPlus(s) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] === '(') depth++;
      else if (s[i] === ')') depth--;
      else if (s[i] === '+' && depth === 0 && i > 0) return i;
    }
    return -1;
  }

  function splitArgs(s) {
    var args = [], depth = 0, start = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] === '(') depth++;
      else if (s[i] === ')') depth--;
      else if (s[i] === ',' && depth === 0) { args.push(s.substring(start, i)); start = i + 1; }
    }
    args.push(s.substring(start));
    return args;
  }

  // Get a dialog value, evaluating getter if the variable has one.
  function dialogGetValue(key) {
    if (!dialogState) return null;
    if (dialogProps && dialogProps[key] && dialogProps[key].get) {
      return dialogEvalExpr(dialogProps[key].get, dialogState);
    }
    return dialogState[key];
  }

  // Set a dialog value, running setter if the variable has one.
  function dialogSetValue(key, value) {
    if (!dialogState) return;
    if (dialogProps && dialogProps[key] && dialogProps[key].set) {
      var setExpr = dialogProps[key].set;
      // Parse: "fun PARAM -> BODY" where BODY is "TARGET <- EXPR"
      var m = setExpr.match(/^fun\s+(\w+)\s*->\s*(.+)$/);
      if (!m) { m = setExpr.match(/^fun\s*\((\w+)\)\s*->\s*(.+)$/); }
      if (m) {
        var param = m[1], body = m[2].trim();
        // Build local scope with param bound
        var local = {};
        for (var k in dialogState) { if (dialogState.hasOwnProperty(k)) local[k] = dialogState[k]; }
        local[param] = value;
        // Handle sequenced assignments: body1; body2
        var parts = body.split(";");
        for (var i = 0; i < parts.length; i++) {
          var part = parts[i].trim();
          var assignMatch = part.match(/^(\w+)\s*<-\s*(.+)$/);
          if (assignMatch) {
            var target = assignMatch[1];
            var valExpr = assignMatch[2].trim();
            var result = dialogEvalExpr(valExpr, local);
            if (result != null) {
              dialogState[target] = result;
              local[target] = result;
            }
          }
        }
      }
      return;
    }
    // Read-only check
    if (dialogProps && dialogProps[key] && dialogProps[key].get && !dialogProps[key].set) {
      return; // ignore writes to read-only
    }
    dialogState[key] = value;
  }

  // ── Panel-local state ──────────────────────────────────────
  var panelState = {};            // keyed by field name for the active panel

  var panelColorSyncLocked = false;   // prevents circular update during slider drag

  function panelStateToColor() {
    var mode = panelState.mode || "hsb";
    var rgb;
    if (mode === "hsb") {
      rgb = hsbToRgb(Number(panelState.h) || 0, Number(panelState.s) || 0, Number(panelState.b) || 100);
    } else if (mode === "rgb" || mode === "web_safe_rgb") {
      rgb = { r: Number(panelState.r) || 0, g: Number(panelState.g) || 0, b: Number(panelState.bl) || 0 };
    } else if (mode === "grayscale") {
      var v = Math.round(255 * (1 - (Number(panelState.k) || 0) / 100));
      rgb = { r: v, g: v, b: v };
    } else if (mode === "cmyk") {
      rgb = cmykToRgb(Number(panelState.c) || 0, Number(panelState.m) || 0,
                      Number(panelState.y) || 0, Number(panelState.k) || 0);
    } else {
      rgb = { r: 0, g: 0, b: 0 };
    }
    return "#" + rgbToHexStr(rgb.r, rgb.g, rgb.b);
  }

  function syncPanelColorState() {
    if (panelColorSyncLocked) return;
    var activeColor = state.fill_on_top ? state.fill_color : state.stroke_color;
    if (!activeColor || activeColor === "null" || activeColor === "none") return;
    panelState.h  = colorFunctions.hsb_h(activeColor);
    panelState.s  = colorFunctions.hsb_s(activeColor);
    panelState.b  = colorFunctions.hsb_b(activeColor);
    panelState.r  = colorFunctions.rgb_r(activeColor);
    panelState.g  = colorFunctions.rgb_g(activeColor);
    panelState.bl = colorFunctions.rgb_b(activeColor);
    panelState.c  = colorFunctions.cmyk_c(activeColor);
    panelState.m  = colorFunctions.cmyk_m(activeColor);
    panelState.y  = colorFunctions.cmyk_y(activeColor);
    panelState.k  = colorFunctions.cmyk_k(activeColor);
    panelState.hex = colorFunctions.hex(activeColor);
  }

  // ── Color conversion functions ──────────────────────────────

  function parseColor(c) {
    if (!c || c === "null" || c === "none") return { r: 0, g: 0, b: 0 };
    var hex = String(c).replace(/^#/, "");
    if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
    return {
      r: parseInt(hex.substring(0, 2), 16) || 0,
      g: parseInt(hex.substring(2, 4), 16) || 0,
      b: parseInt(hex.substring(4, 6), 16) || 0
    };
  }

  function rgbToHsb(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    var h = 0, s = max === 0 ? 0 : d / max, v = max;
    if (d > 0) {
      if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
      else if (max === g) h = ((b - r) / d + 2) / 6;
      else h = ((r - g) / d + 4) / 6;
    }
    return { h: Math.round(h * 360), s: Math.round(s * 100), b: Math.round(v * 100) };
  }

  function hsbToRgb(h, s, b) {
    s /= 100; b /= 100;
    var c = b * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = b - c;
    var r, g, bl;
    if      (h < 60)  { r = c; g = x; bl = 0; }
    else if (h < 120) { r = x; g = c; bl = 0; }
    else if (h < 180) { r = 0; g = c; bl = x; }
    else if (h < 240) { r = 0; g = x; bl = c; }
    else if (h < 300) { r = x; g = 0; bl = c; }
    else              { r = c; g = 0; bl = x; }
    return { r: Math.round((r + m) * 255), g: Math.round((g + m) * 255), b: Math.round((bl + m) * 255) };
  }

  function cmykToRgb(c, m, y, k) {
    c /= 100; m /= 100; y /= 100; k /= 100;
    return {
      r: Math.round(255 * (1 - c) * (1 - k)),
      g: Math.round(255 * (1 - m) * (1 - k)),
      b: Math.round(255 * (1 - y) * (1 - k))
    };
  }

  function rgbToHexStr(r, g, b) {
    return ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
  }

  function rgbToCmyk(r, g, b) {
    if (r === 0 && g === 0 && b === 0) return { c: 0, m: 0, y: 0, k: 100 };
    var c = 1 - r / 255, m = 1 - g / 255, y = 1 - b / 255;
    var k = Math.min(c, m, y);
    return {
      c: Math.round((c - k) / (1 - k) * 100),
      m: Math.round((m - k) / (1 - k) * 100),
      y: Math.round((y - k) / (1 - k) * 100),
      k: Math.round(k * 100)
    };
  }

  var colorFunctions = {
    hsb_h: function (c) { var rgb = parseColor(c); return rgbToHsb(rgb.r, rgb.g, rgb.b).h; },
    hsb_s: function (c) { var rgb = parseColor(c); return rgbToHsb(rgb.r, rgb.g, rgb.b).s; },
    hsb_b: function (c) { var rgb = parseColor(c); return rgbToHsb(rgb.r, rgb.g, rgb.b).b; },
    rgb_r: function (c) { return parseColor(c).r; },
    rgb_g: function (c) { return parseColor(c).g; },
    rgb_b: function (c) { return parseColor(c).b; },
    cmyk_c: function (c) { var rgb = parseColor(c); return rgbToCmyk(rgb.r, rgb.g, rgb.b).c; },
    cmyk_m: function (c) { var rgb = parseColor(c); return rgbToCmyk(rgb.r, rgb.g, rgb.b).m; },
    cmyk_y: function (c) { var rgb = parseColor(c); return rgbToCmyk(rgb.r, rgb.g, rgb.b).y; },
    cmyk_k: function (c) { var rgb = parseColor(c); return rgbToCmyk(rgb.r, rgb.g, rgb.b).k; },
    hex: function (c) { var rgb = parseColor(c); return ((1<<24)+(rgb.r<<16)+(rgb.g<<8)+rgb.b).toString(16).slice(1); },
  };

  // ── Interpolation engine ───────────────────────────────────

  // Known namespace prefixes for expression-context detection
  var _NAMESPACES = ["state", "panel", "dialog", "param", "prop", "event",
                     "self", "active_document", "document", "workspace", "theme", "data"];

  // Coerce a resolved value to a comparison-safe string. Treats null
  // and undefined as "" but preserves 0 / false as "0" / "false".
  function _toCmpStr(v) {
    if (v === null || v === undefined) return "";
    return String(v);
  }

  function resolve(template, ctx) {
    if (template === null || template === undefined) return null;
    if (typeof template === "number" || typeof template === "boolean") return template;
    var s = String(template);
    // Text context: has {{expr}} — interpolate each region
    if (s.indexOf("{{") !== -1) {
      return s.replace(/\{\{(.+?)\}\}/g, function (_, expr) {
        return evalExpr(expr.trim(), ctx);
      });
    }
    // Ternary: if COND then TRUE else FALSE
    var ternMatch = s.match(/^if\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)$/);
    if (ternMatch) {
      var cond = resolve(ternMatch[1].trim(), ctx);
      var condBool = (cond === true || cond === "true" || (cond && cond !== "false" && cond !== "0" && cond !== "null" && cond !== ""));
      return condBool ? resolve(ternMatch[2].trim(), ctx) : resolve(ternMatch[3].trim(), ctx);
    }
    // Comparison operators: resolve each side separately
    var compMatch = s.match(/^(.+?)\s*(==|!=)\s*(.+)$/);
    if (compMatch) {
      // Use _toCmpStr instead of `String(x || "")` — `|| ""` collapses
      // 0 and false to the empty string, which silently broke
      // numeric comparisons like `state.active_tab == 0`.
      var lhs = _toCmpStr(resolve(compMatch[1].trim(), ctx));
      var rhs = compMatch[3].trim();
      if (rhs.length >= 2 && rhs.charAt(0) === '"' && rhs.charAt(rhs.length - 1) === '"') {
        rhs = rhs.substring(1, rhs.length - 1);
      } else {
        rhs = _toCmpStr(resolve(rhs, ctx));
      }
      return compMatch[2] === "==" ? lhs === rhs : lhs !== rhs;
    }
    // Expression context: bare expression without {{}}
    // Check if it starts with a known namespace or is a function call
    var firstDot = s.indexOf(".");
    var prefix = firstDot > 0 ? s.substring(0, firstDot) : s;
    var isFuncCall = /^\w+\(/.test(s);
    if (isFuncCall || _NAMESPACES.indexOf(prefix) >= 0) {
      return evalExpr(s, ctx);
    }
    // String literal: "foo" or 'foo' — strip the surrounding
    // quotes so expressions like `set: { active_tool: '"rect"' }`
    // store the unquoted value `rect`. Matches the rhs-quote
    // stripping in the comparison handler above and the OCaml /
    // Python expression-language semantics.
    if (s.length >= 2 &&
        ((s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') ||
         (s.charAt(0) === "'" && s.charAt(s.length - 1) === "'"))) {
      return s.substring(1, s.length - 1);
    }
    // Literal string (CSS values, plain text, etc.)
    return s;
  }

  function evalExpr(expr, ctx) {
    // Simple expression evaluator for interpolation
    ctx = ctx || {};
    // Check for function call syntax: fn_name(arg)
    // Use a balanced-paren match to handle fn(if a then b else c) correctly
    var fnMatch = expr.match(/^(\w+)\((.+)\)$/);
    if (fnMatch && colorFunctions[fnMatch[1]]) {
      var argStr = fnMatch[2].trim();
      // If the argument contains an if/then/else, evaluate it first
      var ternaryMatch = argStr.match(/^if\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)$/);
      if (ternaryMatch) {
        var cond = resolve(ternaryMatch[1].trim(), ctx);
        var arg = evalCondition(String(cond), ctx)
          ? resolve(ternaryMatch[2].trim(), ctx)
          : resolve(ternaryMatch[3].trim(), ctx);
        return colorFunctions[fnMatch[1]](arg);
      }
      var arg = resolve(argStr, ctx);
      return colorFunctions[fnMatch[1]](arg);
    }
    // Built-in `mem(needle, haystack)` — true iff `needle` is in
    // `haystack`. `haystack` is a list literal like ["a", "b"].
    // Used by toolbar slots to drive `bind.checked` for tools that
    // share a long-press slot with alternates. Mirrors the same-name
    // primitive in the OCaml / Python expression interpreters.
    //
    // Without this branch the evaluator falls through and returns
    // "" for the whole expression; `evalCondition("")` then returns
    // true via its empty-string-is-no-condition fallback, leaving
    // every alternate-bearing slot button stuck with the `.active`
    // class.
    if (fnMatch && fnMatch[1] === "mem") {
      var memArgStr = fnMatch[2];
      var memDepth = 0, memSplit = -1;
      for (var mi = 0; mi < memArgStr.length; mi++) {
        var mch = memArgStr.charAt(mi);
        if (mch === "[" || mch === "(") memDepth++;
        else if (mch === "]" || mch === ")") memDepth--;
        else if (mch === "," && memDepth === 0) { memSplit = mi; break; }
      }
      if (memSplit === -1) return false;
      var needleExpr = memArgStr.substring(0, memSplit).trim();
      var haystackExpr = memArgStr.substring(memSplit + 1).trim();
      var needle = resolve(needleExpr, ctx);
      var needleStr = needle === null || needle === undefined
        ? "" : String(needle);
      try {
        var haystack = JSON.parse(haystackExpr.replace(/'/g, '"'));
        if (Array.isArray(haystack)) {
          return haystack.indexOf(needleStr) >= 0;
        }
      } catch (e) {}
      return false;
    }
    var parts = expr.split(".");
    if (parts[0] === "state") return state[parts[1]];
    if (parts[0] === "param" && ctx.params) return ctx.params[parts[1]];
    if (parts[0] === "prop" && ctx.props) return ctx.props[parts[1]];
    if (parts[0] === "panel") {
      if (parts.length === 3 && parts[1] === "recent_colors") {
        var rcArr = panelState.recent_colors || [];
        return rcArr[parseInt(parts[2])] || null;
      }
      return panelState[parts[1]];
    }
    if (parts[0] === "dialog" && dialogState) return dialogGetValue(parts[1]);
    if (parts[0] === "event" && ctx.event) return ctx.event[parts[1]];
    if (parts[0] === "self" && ctx.self) return ctx.self[parts[1]];
    if (parts[0] === "active_document" || parts[0] === "document") return activeDocumentCtx[parts[1]];
    if (parts[0] === "workspace") return workspaceCtx[parts[1]];
    if (parts[0] === "theme") {
      var themeData = typeof APP_THEME !== "undefined" ? APP_THEME : {};
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
    if (condStr === false) return false;
    if (!condStr) return true;
    // Resolve the expression (handles both {{}} and bare expressions)
    var resolved = resolve(condStr, ctx);
    // Simple boolean evaluation
    if (resolved === "true" || resolved === true) return true;
    if (resolved === "false" || resolved === false || resolved === "" || resolved === "null" || resolved === null) return false;
    // Handle ternary: "if COND then TRUE else FALSE"
    var ternaryMatch = typeof resolved === "string"
      ? resolved.match(/^if\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)$/) : null;
    if (ternaryMatch) {
      return evalCondition(ternaryMatch[1].trim(), ctx)
        ? evalCondition(ternaryMatch[2].trim(), ctx)
        : evalCondition(ternaryMatch[3].trim(), ctx);
    }
    // Handle "not X"
    if (typeof resolved === "string" && resolved.startsWith("not ")) {
      return !evalCondition(resolved.substring(4), ctx);
    }
    // Handle "X == Y" (strip quotes from string literals for comparison)
    var eqMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*==\s*(.+)$/) : null;
    if (eqMatch) {
      var lhs = eqMatch[1].trim();
      var rhs = eqMatch[2].trim();
      // Strip surrounding quotes from string literals
      if (rhs.length >= 2 && rhs.charAt(0) === '"' && rhs.charAt(rhs.length - 1) === '"') {
        rhs = rhs.substring(1, rhs.length - 1);
      }
      if (lhs.length >= 2 && lhs.charAt(0) === '"' && lhs.charAt(lhs.length - 1) === '"') {
        lhs = lhs.substring(1, lhs.length - 1);
      }
      return lhs === rhs;
    }
    var neqMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*!=\s*(.+)$/) : null;
    if (neqMatch) {
      var lhs2 = neqMatch[1].trim();
      var rhs2 = neqMatch[2].trim();
      if (rhs2.length >= 2 && rhs2.charAt(0) === '"' && rhs2.charAt(rhs2.length - 1) === '"') {
        rhs2 = rhs2.substring(1, rhs2.length - 1);
      }
      return lhs2 !== rhs2;
    }
    // Handle "X > Y", "X < Y", "X >= Y", "X <= Y"
    var gtMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*>\s*(.+)$/) : null;
    if (gtMatch && gtMatch[2].indexOf(">") === -1 && gtMatch[2].indexOf("=") === -1) {
      var a = parseFloat(gtMatch[1].trim());
      var b = parseFloat(gtMatch[2].trim());
      if (!isNaN(a) && !isNaN(b)) return a > b;
    }
    var ltMatch = typeof resolved === "string" ? resolved.match(/^(.+?)\s*<\s*(.+)$/) : null;
    if (ltMatch) {
      var a2 = parseFloat(ltMatch[1].trim());
      var b2 = parseFloat(ltMatch[2].trim());
      if (!isNaN(a2) && !isNaN(b2)) return a2 < b2;
    }
    // Truthy
    return !!resolved;
  }

  // ── State mutation + reactive update ───────────────────────

  function setState(key, value) {
    var old = state[key];
    state[key] = value;
    if (old !== value) {
      // Mirror to the engine store (canvas_bootstrap.mjs publishes
      // it on globalThis.JAS.mirrorState) so canvas tool dispatch
      // reads the right active_tool / fill_color / etc. App.js
      // remains the canonical state holder for panels.
      var mirror = (globalThis.JAS && globalThis.JAS.mirrorState);
      if (typeof mirror === "function") mirror(key, value);
      updateBindings(key, value);
    }
  }

  function updateBindings(key, value) {
    // Recompute panel color state when active color or focus changes
    if (key === "fill_color" || key === "stroke_color" || key === "fill_on_top") {
      syncPanelColorState();
    }
    // Generic data-bind-value: set input value
    document.querySelectorAll("[data-bind-value]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-value");
      var val = resolve(expr, {});
      if (val !== null && val !== undefined) el.value = val;
    });
    // Generic data-bind-disabled: enable/disable input
    document.querySelectorAll("[data-bind-disabled]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-disabled");
      el.disabled = evalCondition(resolve(expr, {}), {});
    });
    // Generic data-bind-visible: show/hide using d-none class (overrides Bootstrap !important)
    document.querySelectorAll("[data-bind-visible]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-visible");
      var result = evalCondition(resolve(expr, {}), {});
      if (result) {
        el.classList.remove("d-none");
      } else {
        el.classList.add("d-none");
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
    // Generic data-bind-color: set background (fill swatch) or border (hollow/stroke swatch)
    document.querySelectorAll("[data-bind-color]").forEach(function (el) {
      var ref = el.getAttribute("data-bind-color");
      var color = resolve(ref, {});
      var hasColor = color && color !== "null" && color !== "undefined";
      var isHollow = el.getAttribute("data-hollow") === "true";
      if (isHollow) {
        el.style.borderColor = hasColor ? color : "transparent";
      } else if (hasColor) {
        el.classList.remove("app-color-swatch-empty");
        el.style.background = color;
        el.style.border = "1px solid #666";
        el.style.cursor = "pointer";
      } else {
        el.classList.add("app-color-swatch-empty");
        el.style.background = "transparent";
        el.style.border = "";
        el.style.cursor = "default";
      }
    });
    // Generic data-bind-icon: swap SVG content via if/then/else expression
    document.querySelectorAll("[data-bind-icon]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-icon");
      var resolved = resolve(expr, {});
      if (typeof resolved !== "string") return;
      var ternary = resolved.match(/^if\s+(.+?)\s+then\s+(\S+)\s+else\s+(\S+)$/);
      if (ternary) {
        var cond = evalCondition(ternary[1], {});
        var iconName = cond ? ternary[2] : ternary[3];
        var iconDef = (typeof APP_ICONS !== "undefined") ? APP_ICONS[iconName] : null;
        if (iconDef) {
          var svg = el.querySelector("svg");
          if (svg) {
            svg.setAttribute("viewBox", iconDef.viewbox || "0 0 16 16");
            svg.innerHTML = iconDef.svg || "";
          }
        }
      }
    });
    // data-alternate-icons: toolbar slot buttons whose displayed
    // icon should track which alternate is active. The attribute
    // is a JSON map {tool_id: icon_name}; when state.active_tool
    // matches a key, swap the slot's <svg> to that icon's content.
    // Otherwise leave the default icon untouched (e.g. when an
    // unrelated tool is active for some other slot).
    //
    // We mirror the original SVG (the first <svg> child of the
    // button — not the alternate-triangle <svg> which has class
    // "alternate-triangle") so the triangle indicator survives
    // the swap.
    document.querySelectorAll("[data-alternate-icons]").forEach(function (el) {
      var raw = el.getAttribute("data-alternate-icons");
      var map;
      try { map = JSON.parse(raw); } catch (ex) { return; }
      if (!map || typeof map !== "object") return;
      var tool = state.active_tool;
      var iconName = map[tool];
      if (!iconName) return;
      var iconDef = (typeof APP_ICONS !== "undefined") ? APP_ICONS[iconName] : null;
      if (!iconDef) return;
      // Find the icon SVG — first <svg> that isn't the triangle.
      var svgs = el.querySelectorAll("svg");
      var iconSvg = null;
      for (var i = 0; i < svgs.length; i++) {
        if (!svgs[i].classList.contains("alternate-triangle")) {
          iconSvg = svgs[i];
          break;
        }
      }
      if (!iconSvg) return;
      iconSvg.setAttribute("viewBox", iconDef.viewbox || "0 0 16 16");
      iconSvg.innerHTML = iconDef.svg || "";
    });
    // Generic data-bind-z_index: set z-index via if/then/else expression
    document.querySelectorAll("[data-bind-z_index]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-z_index");
      var resolved = resolve(expr, {});
      if (typeof resolved !== "string") return;
      var ternary = resolved.match(/^if\s+(.+?)\s+then\s+(\S+)\s+else\s+(\S+)$/);
      if (ternary) {
        var cond = evalCondition(ternary[1], {});
        el.style.zIndex = cond ? ternary[2] : ternary[3];
      } else {
        el.style.zIndex = resolved;
      }
    });
    // Generic data-bind-collapsed: set pane to collapsed_width, content visibility
    // is handled by data-bind-visible on individual children
    document.querySelectorAll("[data-bind-collapsed]").forEach(function (el) {
      var expr = el.getAttribute("data-bind-collapsed");
      var result = evalCondition(resolve(expr, {}), {});
      var cw = el.getAttribute("data-collapsed-width");
      if (result && cw) {
        el.style.width = cw + "px";
      } else if (!result && cw) {
        el.style.width = "";
      }
    });
    // Redraw color bar canvases
    drawColorBars();
  }

  function drawColorBars() {
    document.querySelectorAll("canvas[data-type='color-bar']").forEach(function (canvas) {
      if (canvas.offsetParent === null) return; // skip hidden canvases
      var w = canvas.clientWidth || 300;
      var h = canvas.clientHeight || 64;
      canvas.width  = w;
      canvas.height = h;
      var ctx = canvas.getContext("2d");
      var midY = h / 2;
      var imageData = ctx.createImageData(w, h);
      for (var y = 0; y < h; y++) {
        var s, b;
        if (y <= midY) {
          // Top half: s 0→100, b 100→80  (top=white, middle=full-sat)
          var t = y / midY;
          s = t * 100;
          b = 100 - t * 20;
        } else {
          // Bottom half: s=100, b 80→0  (middle=full-sat, bottom=black)
          var t = (y - midY) / (h - midY);
          s = 100;
          b = 80 * (1 - t);
        }
        for (var x = 0; x < w; x++) {
          var hue = 360 * x / (w - 1);
          var rgb = hsbToRgb(hue, s, b);
          var idx = (y * w + x) * 4;
          imageData.data[idx]     = rgb.r;
          imageData.data[idx + 1] = rgb.g;
          imageData.data[idx + 2] = rgb.b;
          imageData.data[idx + 3] = 255;
        }
      }
      ctx.putImageData(imageData, 0, 0);
    });
  }

  // ── Popover dialog show/hide ───────────────────────────────
  //
  // Tool-alternate flyouts (declared in dialog yaml as
  // `modal: false`) anchor next to the triggering toolbar slot
  // instead of centering with a backdrop. Skip the Bootstrap
  // Modal API entirely; manage `display` + position inline.

  function showPopover(el, ctx) {
    // Resolve the triggering element. ctx.self is the slot button
    // when fired by wireBehaviors; ctx.event.target_id is a fallback.
    var triggerId =
      (ctx && ctx.self && ctx.self.id) ||
      (ctx && ctx.event && ctx.event.target_id) ||
      null;
    var trigger = triggerId ? document.getElementById(triggerId) : null;
    el.classList.add("show");
    el.style.display = "block";
    el.removeAttribute("aria-hidden");
    el.setAttribute("aria-modal", "false");
    var inner = el.querySelector(".modal-dialog");
    if (inner) {
      inner.style.position = "fixed";
      inner.style.margin = "0";
      inner.style.maxWidth = "none";
      if (trigger) {
        var r = trigger.getBoundingClientRect();
        // Anchor 4 px to the right of the trigger, top-aligned.
        // The popover is measured by the browser after .show, so
        // a second-pass clamp keeps it on-screen.
        inner.style.left = (r.right + 4) + "px";
        inner.style.top = r.top + "px";
        // Clamp to viewport once layout settles.
        requestAnimationFrame(function () {
          var pop = inner.getBoundingClientRect();
          var vw = window.innerWidth;
          var vh = window.innerHeight;
          if (pop.right > vw - 4) {
            inner.style.left = Math.max(4, vw - pop.width - 4) + "px";
          }
          if (pop.bottom > vh - 4) {
            inner.style.top = Math.max(4, vh - pop.height - 4) + "px";
          }
        });
      } else {
        // No trigger known — fall back to centred.
        inner.style.left = "50%";
        inner.style.top = "20%";
        inner.style.transform = "translateX(-50%)";
      }
    }
    // Click-outside handler. Use mousedown so a click-inside event
    // doesn't fire the dismiss before the inside button's click
    // handler runs. Capture phase to win over inner buttons that
    // stopPropagation. Single-shot.
    var dismiss = function (evt) {
      if (!el.contains(evt.target) && (!trigger || !trigger.contains(evt.target))) {
        hidePopover(el);
      }
    };
    el._popoverDismiss = dismiss;
    setTimeout(function () {
      document.addEventListener("mousedown", dismiss, true);
    }, 0);
  }

  function hidePopover(el) {
    el.classList.remove("show");
    el.style.display = "none";
    el.setAttribute("aria-hidden", "true");
    var inner = el.querySelector(".modal-dialog");
    if (inner) {
      inner.style.position = "";
      inner.style.left = "";
      inner.style.top = "";
      inner.style.margin = "";
      inner.style.maxWidth = "";
      inner.style.transform = "";
    }
    if (el._popoverDismiss) {
      document.removeEventListener("mousedown", el._popoverDismiss, true);
      delete el._popoverDismiss;
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
      var defaults = typeof APP_STATE !== "undefined" ? APP_STATE : {};
      effect.reset.forEach(function (rk) {
        setState(rk, defaults[rk]);
      });
      return;
    }

    // set_panel_state: { panel, key, value }
    if (effect.set_panel_state) {
      var psKey = resolve(effect.set_panel_state.key, ctx);
      var psVal = resolve(effect.set_panel_state.value, ctx);
      panelState[psKey] = psVal;
      updateBindings(null, null);
      return;
    }

    // list_push: { target, value, unique, max_length }
    if (effect.list_push) {
      var lp = effect.list_push;
      var lpTarget = lp.target || "";
      var lpValue = resolve(lp.value, ctx);
      var lpParts = lpTarget.split(".");
      var lpList;
      if (lpParts[0] === "panel" && lpParts.length === 2) {
        lpList = panelState[lpParts[1]] || [];
        lpList = lpList.slice(); // copy
      } else {
        return;
      }
      if (lp.unique) {
        var idx = lpList.indexOf(lpValue);
        if (idx >= 0) lpList.splice(idx, 1);
      }
      lpList.unshift(lpValue);
      if (lp.max_length && lpList.length > lp.max_length) {
        lpList.length = lp.max_length;
      }
      if (lpParts[0] === "panel") panelState[lpParts[1]] = lpList;
      updateBindings(null, null);
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

    // maximize: { target } — fill viewport, hide title bar, remove border, z-index 0
    if (effect.maximize) {
      var maxTarget = resolve(effect.maximize.target, ctx);
      var maxEl = document.getElementById(maxTarget);
      console.log("[maximize]", maxTarget, maxEl ? "found" : "MISSING");
      if (maxEl) {
        var parent = maxEl.parentElement;
        var pw = parent ? parent.clientWidth : window.innerWidth;
        var ph = parent ? parent.clientHeight : window.innerHeight;
        console.log("[maximize] size:", pw, "x", ph);
        maxEl.setAttribute("data-saved-style", maxEl.getAttribute("style") || "");
        maxEl.style.left = "0px";
        maxEl.style.top = "0px";
        maxEl.style.width = pw + "px";
        maxEl.style.height = ph + "px";
        maxEl.style.zIndex = "1";
        maxEl.style.border = "none";
        var title = maxEl.querySelector(".app-pane-title");
        if (title) title.classList.add("d-none");
        // Ensure other panes float above the maximized one
        var siblings = maxEl.parentElement ? maxEl.parentElement.querySelectorAll(".app-pane") : [];
        siblings.forEach(function (p) {
          if (p !== maxEl) p.style.zIndex = "10";
        });
      }
      return;
    }

    // restore: { target } — restore saved style, show title bar
    if (effect.restore) {
      var restEl = document.getElementById(resolve(effect.restore.target, ctx));
      if (restEl) {
        var saved = restEl.getAttribute("data-saved-style");
        if (saved) restEl.setAttribute("style", saved);
        restEl.removeAttribute("data-saved-style");
        var title = restEl.querySelector(".app-pane-title");
        if (title) title.classList.remove("d-none");
      }
      return;
    }

    // show: element_id (use d-none class to override Bootstrap's !important)
    if (effect.show) {
      var showEl = document.getElementById(resolve(effect.show, ctx));
      if (showEl) showEl.classList.remove("d-none");
      return;
    }

    // hide: element_id
    if (effect.hide) {
      var hideEl = document.getElementById(resolve(effect.hide, ctx));
      if (hideEl) hideEl.classList.add("d-none");
      return;
    }

    // create_child: { parent, props, element }
    if (effect.create_child) {
      var parentId = resolve(effect.create_child.parent, ctx);
      var parentEl = document.getElementById(parentId);
      if (parentEl && effect.create_child.element) {
        // Resolve props from current state, then make them available as prop.*
        var childCtx = Object.assign({}, ctx);
        if (effect.create_child.props) {
          var resolvedProps = {};
          for (var pk in effect.create_child.props) {
            if (effect.create_child.props.hasOwnProperty(pk)) {
              resolvedProps[pk] = resolve(effect.create_child.props[pk], ctx);
            }
          }
          childCtx.props = resolvedProps;
        }
        var spec = effect.create_child.element;
        var child = createElementFromSpec(spec, childCtx);
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
            var val = resolve(effect.set_style[prop], ctx);
            // Only append px if the value is a plain number
            if (/^\d+(\.\d+)?$/.test(val)) val += "px";
            // Map snake_case to camelCase for CSS
            var cssProp = prop.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); });
            ssEl.style[cssProp] = val;
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
      var configs = typeof APP_PANE_CONFIGS !== "undefined" ? APP_PANE_CONFIGS : {};
      var container = document.getElementById(resolve(effect.tile.container, ctx));
      if (!container) return;

      // Phase 1: unhide all panes by setting any bound visible state to true
      var paneEls = Array.from(container.querySelectorAll(".app-pane"));
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
      var configs = typeof APP_PANE_CONFIGS !== "undefined" ? APP_PANE_CONFIGS : {};
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
      var defaults = typeof APP_STATE !== "undefined" ? APP_STATE : {};
      for (var dk in defaults) {
        if (defaults.hasOwnProperty(dk)) {
          setState(dk, defaults[dk]);
        }
      }
      // Reset appearance to YAML default
      applyAppearance(typeof APP_ACTIVE_APPEARANCE !== "undefined" ? APP_ACTIVE_APPEARANCE : "dark_gray");
      activeWorkspaceName = null;
      workspaceCtx.has_saved_layout = false;
      workspaceCtx.active_layout_name = "";
      rebuildWorkspaceMenu();
      return;
    }

    // open_dialog: { id, params }
    if (effect.open_dialog) {
      var dlgSpec = effect.open_dialog;
      var dlgId = typeof dlgSpec === "string" ? dlgSpec : resolve(dlgSpec.id, ctx);
      var dlgParams = (typeof dlgSpec === "object" && dlgSpec.params) ? {} : {};
      if (typeof dlgSpec === "object" && dlgSpec.params) {
        for (var dpk in dlgSpec.params) {
          if (dlgSpec.params.hasOwnProperty(dpk)) {
            dlgParams[dpk] = resolve(dlgSpec.params[dpk], ctx);
          }
        }
      }
      dialogParams = dlgParams;
      // Initialize dialog-local state if the dialog defines a state section
      var dlgDef = typeof APP_ACTIONS !== "undefined" ? null : null;
      // Look up dialog definition in the rendered page's data
      var modalEl = document.getElementById("dialog-" + dlgId);
      if (modalEl) {
        var dlgStateDef = modalEl.getAttribute("data-dialog-state");
        // Read property definitions (get/set)
        var dlgPropsStr = modalEl.getAttribute("data-dialog-props");
        dialogProps = null;
        if (dlgPropsStr) {
          try { dialogProps = JSON.parse(dlgPropsStr); } catch (e) {}
        }
        if (dlgStateDef) {
          try {
            var dsDef = JSON.parse(dlgStateDef);
            dialogState = {};
            // Phase 1: set defaults for plain variables (skip get-only)
            for (var dsKey in dsDef) {
              if (dsDef.hasOwnProperty(dsKey)) {
                var hasGet = dialogProps && dialogProps[dsKey] && dialogProps[dsKey].get;
                if (!hasGet) {
                  dialogState[dsKey] = dsDef[dsKey].default !== undefined ? dsDef[dsKey].default : null;
                }
              }
            }
            // Phase 2: run init expressions
            var dlgInit = modalEl.getAttribute("data-dialog-init");
            if (dlgInit) {
              var initMap = JSON.parse(dlgInit);
              var initCtx = { params: dlgParams };
              for (var ik in initMap) {
                if (initMap.hasOwnProperty(ik)) {
                  dialogState[ik] = resolve(initMap[ik], initCtx);
                }
              }
            }
          } catch (ex) { console.warn("[open_dialog] state init error:", ex); }
        }
        // Preview snapshot: if the dialog declares preview_targets, capture
        // the current value of every target path. close_dialog will restore
        // these unless the snapshot is cleared first (typically by an OK
        // action via the clear_dialog_snapshot effect).
        dialogSnapshot = null;
        var dlgPreviewTargets = modalEl.getAttribute("data-dialog-preview-targets");
        if (dlgPreviewTargets) {
          try {
            var ptMap = JSON.parse(dlgPreviewTargets);
            dialogSnapshot = {};
            for (var ptKey in ptMap) {
              if (ptMap.hasOwnProperty(ptKey)) {
                var tpath = ptMap[ptKey];
                dialogSnapshot[tpath] = resolve(tpath, { params: dlgParams });
              }
            }
          } catch (snapEx) {
            console.warn("[open_dialog] preview snapshot error:", snapEx);
            dialogSnapshot = null;
          }
        }
        if (modalEl.getAttribute("data-popover") === "true") {
          // Popover: anchor next to the triggering element (e.g.
          // a toolbar slot button). Skip Bootstrap modal API so
          // there's no backdrop and the dialog isn't forced to the
          // viewport center.
          showPopover(modalEl, ctx);
        } else if (typeof bootstrap !== "undefined") {
          var modal = bootstrap.Modal.getOrCreateInstance(modalEl);
          modal.show();
        }
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
      if (modalToClose && modalToClose.getAttribute("data-popover") === "true") {
        hidePopover(modalToClose);
        return;
      }
      if (modalToClose && typeof bootstrap !== "undefined") {
        var bsModal = bootstrap.Modal.getInstance(modalToClose);
        if (bsModal) bsModal.hide();
      }
      // Preview restore: if a snapshot survived (i.e., no OK action cleared
      // it), revert each target to its captured original value. For Phase 0
      // we only handle simple top-level state keys; deep paths land in
      // Phase 8/9 alongside the actual paragraph dialogs.
      if (dialogSnapshot) {
        for (var rpath in dialogSnapshot) {
          if (dialogSnapshot.hasOwnProperty(rpath)) {
            if (rpath.indexOf(".") === -1) {
              setState(rpath, dialogSnapshot[rpath]);
            } else {
              console.warn("[close_dialog] deep-path restore not yet implemented:", rpath);
            }
          }
        }
      }
      dialogState = null;
      dialogParams = null;
      dialogProps = null;
      dialogSnapshot = null;
      return;
    }

    // clear_dialog_snapshot: drop the preview snapshot so close_dialog
    // does not restore. OK actions use this before close_dialog to commit
    // (see Phase 8/9 paragraph dialogs).
    if (effect.clear_dialog_snapshot !== undefined) {
      dialogSnapshot = null;
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
        flEl.classList.add("app-flash");
        setTimeout(function () { flEl.classList.remove("app-flash"); }, 300);
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

    // save_layout: { container, name_input } — save pane positions + layout_state
    if (effect.save_layout) {
      var container = document.getElementById(resolve(effect.save_layout.container, ctx));
      var nameInput = document.getElementById(resolve(effect.save_layout.name_input, ctx));
      if (container && nameInput) {
        var name = nameInput.value.trim();
        if (!name) { console.warn("[save_layout] empty name"); return; }
        var configs = typeof APP_PANE_CONFIGS !== "undefined" ? APP_PANE_CONFIGS : {};
        var layoutData = { panes: {}, state: {}, dock: {}, floating: [], appearance: activeAppearanceName };
        container.querySelectorAll(".app-pane").forEach(function (p) {
          if (p.id) {
            layoutData.panes[p.id] = {
              left: p.offsetLeft, top: p.offsetTop,
              width: p.offsetWidth, height: p.offsetHeight
            };
            // Save layout_state variables declared by this pane
            var cfg = configs[p.id];
            if (cfg && cfg.layout_state) {
              cfg.layout_state.forEach(function (key) {
                if (state.hasOwnProperty(key)) layoutData.state[key] = state[key];
              });
            }
          }
        });
        // Save dock models
        for (var dockId in dockModels) {
          if (dockId.indexOf("floating_dock_") === 0) {
            var paneId = dockId.replace("_view", "");
            var paneEl = document.getElementById(paneId);
            layoutData.floating.push({
              dockViewId: dockId,
              groups: dockModels[dockId].groups,
              x: paneEl ? paneEl.offsetLeft : 0,
              y: paneEl ? paneEl.offsetTop : 0,
              width: paneEl ? paneEl.offsetWidth : 220,
              height: paneEl ? paneEl.offsetHeight : 300,
            });
          } else {
            layoutData.dock[dockId] = { groups: dockModels[dockId].groups };
          }
        }
        var saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
        saved[name] = layoutData;
        localStorage.setItem(STORAGE_KEY, JSON.stringify(saved));
        activeWorkspaceName = name;
        workspaceCtx.has_saved_layout = true;
        workspaceCtx.active_layout_name = name;
        rebuildWorkspaceMenu();
      }
      return;
    }

    // load_layout: { container, name } — restore pane positions + layout_state
    if (effect.load_layout) {
      var name = resolve(effect.load_layout.name, ctx);
      var container = document.getElementById(resolve(effect.load_layout.container, ctx));
      if (!name || !container) return;
      var layoutData = getLayoutData(name);
      if (!layoutData) { console.warn("[load_layout] not found:", name); return; }
      // Restore pane positions
      var panes = layoutData.panes || layoutData; // backwards compat
      for (var paneId in panes) {
        if (panes.hasOwnProperty(paneId)) {
          var el = document.getElementById(paneId);
          if (el) {
            var pos = panes[paneId];
            el.style.left = pos.left + "px";
            el.style.top = pos.top + "px";
            el.style.width = pos.width + "px";
            el.style.height = pos.height + "px";
            el.classList.remove("d-none");
          }
        }
      }
      // Restore layout_state variables
      if (layoutData.state) {
        for (var key in layoutData.state) {
          if (layoutData.state.hasOwnProperty(key)) {
            setState(key, layoutData.state[key]);
          }
        }
      }
      // Restore dock models
      if (layoutData.dock) {
        for (var dockId in layoutData.dock) {
          if (dockModels[dockId]) {
            dockModels[dockId].groups = layoutData.dock[dockId].groups;
            rerenderDockView(dockId);
          }
        }
      }
      // Remove existing floating docks
      document.querySelectorAll("[id^='floating_dock_']").forEach(function (el) { el.remove(); });
      for (var dk in dockModels) {
        if (dk.indexOf("floating_dock_") === 0) delete dockModels[dk];
      }
      // Restore floating docks
      if (layoutData.floating) {
        layoutData.floating.forEach(function (fd) {
          createFloatingDock(fd.groups, fd.x, fd.y);
        });
      }
      // Restore appearance if saved
      if (layoutData.appearance) {
        applyAppearance(layoutData.appearance);
      }
      activeWorkspaceName = name;
      workspaceCtx.has_saved_layout = true;
      workspaceCtx.active_layout_name = name;
      rebuildWorkspaceMenu();
      return;
    }

    // revert_layout: { container } — reload the active workspace
    if (effect.revert_layout) {
      if (!activeWorkspaceName) return;
      var container = document.getElementById(resolve(effect.revert_layout.container, ctx));
      if (!container) return;
      var layoutData = getLayoutData(activeWorkspaceName);
      if (!layoutData) return;
      var panes = layoutData.panes || layoutData;
      for (var paneId in panes) {
        if (panes.hasOwnProperty(paneId)) {
          var el = document.getElementById(paneId);
          if (el) {
            var pos = panes[paneId];
            el.style.left = pos.left + "px";
            el.style.top = pos.top + "px";
            el.style.width = pos.width + "px";
            el.style.height = pos.height + "px";
            el.classList.remove("d-none");
          }
        }
      }
      if (layoutData.state) {
        for (var key in layoutData.state) {
          if (layoutData.state.hasOwnProperty(key)) setState(key, layoutData.state[key]);
        }
      }
      return;
    }

    // delete_layout: { name } — remove a saved workspace from localStorage
    if (effect.delete_layout) {
      var name = resolve(effect.delete_layout.name, ctx);
      var saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
      delete saved[name];
      localStorage.setItem(STORAGE_KEY, JSON.stringify(saved));
      if (activeWorkspaceName === name) {
        activeWorkspaceName = null;
        workspaceCtx.has_saved_layout = false;
        workspaceCtx.active_layout_name = "";
      }
      rebuildWorkspaceMenu();
      console.log("[delete_layout]", name);
      return;
    }

    // switch_appearance: { name } — switch to a named appearance
    if (effect.switch_appearance) {
      var name = resolve(effect.switch_appearance.name, ctx);
      applyAppearance(name);
      return;
    }

    // save_appearance: { name_input } — save current appearance to localStorage
    if (effect.save_appearance) {
      var nameInput = document.getElementById(resolve(effect.save_appearance.name_input, ctx));
      if (nameInput) {
        var name = nameInput.value.trim();
        if (!name) { console.warn("[save_appearance] empty name"); return; }
        // Save the fully resolved current theme as a self-contained appearance
        var saved = JSON.parse(localStorage.getItem(APPEARANCE_STORAGE_KEY) || "{}");
        saved[name] = {
          label: name,
          colors: APP_THEME.colors || {},
          fonts: APP_THEME.fonts || {},
          sizes: APP_THEME.sizes || {}
        };
        localStorage.setItem(APPEARANCE_STORAGE_KEY, JSON.stringify(saved));
        activeAppearanceName = name;
        rebuildAppearanceMenu();
        console.log("[save_appearance]", name);
      }
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
    if (s.aspect_ratio) styles.push("aspect-ratio:" + s.aspect_ratio);
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
      el.className = "btn btn-sm btn-outline-secondary app-tool-btn p-0";
      if (spec.id) el.id = resolve(spec.id, ctx);
      var ibSz = s.size || 16;
      styles.push("width:" + ibSz + "px", "height:" + ibSz + "px",
                   "display:flex", "align-items:center", "justify-content:center");
      el.style.cssText = styles.join(";");
      var iconName = spec.icon ? resolve(spec.icon, ctx) : "";
      var iconDef = (typeof APP_ICONS !== "undefined") ? APP_ICONS[iconName] : null;
      if (iconDef) {
        var iconSz = Math.floor(ibSz * 0.75);
        el.innerHTML = '<svg viewBox="' + (iconDef.viewbox || "0 0 16 16") + '" width="' + iconSz +
          '" height="' + iconSz + '" fill="currentColor" style="color:#cccccc">' + (iconDef.svg || "") + '</svg>';
      } else {
        el.textContent = iconName;
      }
    } else if (type === "canvas") {
      // Per-tab canvas: emit the 5-layer SVG stack the engine renders
      // into. Mirror of renderer.py::_render_canvas so a runtime-
      // created canvas (via create_child) is structurally identical to
      // a server-rendered one. canvas_bootstrap.mjs binds a Model with
      // a fresh emptyDocument() (one default artboard) to each new
      // app-canvas-stack as it lands in the DOM.
      el.className = "app-canvas-stack";
      var canvasId = el.id || "canvas";
      var bg = (s.background ? resolve(s.background, ctx) : "var(--app-window-bg)");
      styles.push(
        "flex:1", "position:relative", "background:" + bg,
        "min-height:200px", "overflow:hidden"
      );
      el.style.cssText = styles.join(";");
      var layerStyle = "position:absolute;inset:0;width:100%;height:100%;overflow:visible;";
      var pointerless = "pointer-events:none;";
      el.innerHTML =
        '<div class="app-canvas-viewport" data-canvas-id="' + canvasId +
        '" style="position:absolute;inset:0;transform-origin:0 0;">' +
        '<svg data-canvas-layer="artboard-fill"' +
        ' style="' + layerStyle + pointerless + '"></svg>' +
        '<svg data-canvas-layer="doc"' +
        ' style="' + layerStyle + '"></svg>' +
        '<svg data-canvas-layer="artboard-deco"' +
        ' style="' + layerStyle + pointerless + '"></svg>' +
        '<svg data-canvas-layer="selection"' +
        ' style="' + layerStyle + pointerless + '"></svg>' +
        '<svg data-canvas-layer="overlay"' +
        ' style="' + layerStyle + pointerless + '"></svg>' +
        '</div>';
    } else if (type === "placeholder") {
      el.className = "app-placeholder";
      styles.push("border:1px dashed #666", "padding:12px", "color:#888",
                   "text-align:center", "font-size:11px", "min-height:40px");
      el.style.cssText = styles.join(";");
      el.textContent = spec.summary || "Placeholder";
    } else {
      el.style.cssText = styles.join(";");
      el.textContent = label || spec.summary || type;
    }

    // Resolve only prop.* references in an object tree (leaves state.* reactive)
    function resolveProps(obj) {
      if (typeof obj === "string") {
        return obj.replace(/\{\{prop\.(\w+)\}\}/g, function (_, name) {
          return ctx.props ? ctx.props[name] : "";
        });
      }
      if (Array.isArray(obj)) return obj.map(resolveProps);
      if (obj && typeof obj === "object") {
        var out = {};
        for (var k in obj) {
          if (obj.hasOwnProperty(k)) out[k] = resolveProps(obj[k]);
        }
        return out;
      }
      return obj;
    }

    // Apply bind attributes — resolve prop.* only, keep state.* reactive
    if (spec.bind) {
      var resolvedBind = resolveProps(spec.bind);
      for (var prop in resolvedBind) {
        if (resolvedBind.hasOwnProperty(prop)) {
          el.setAttribute("data-bind-" + prop, resolvedBind[prop]);
        }
      }
    }

    // Wire behaviors — resolve prop.* only, keep state.* reactive.
    // Pass through ctx.props (captured at creation time by the
    // create_child effect) so behavior expressions like
    // `set: { active_tab: "prop.index" }` see the right value when
    // the click later fires.
    if (spec.behavior) {
      var resolvedBehavior = resolveProps(spec.behavior);
      el.setAttribute("data-behaviors", JSON.stringify(resolvedBehavior));
      wireBehaviors(el, ctx && ctx.props);
    }

    return el;
  }

  function wireBehaviors(el, props) {
    var behaviors;
    try { behaviors = JSON.parse(el.getAttribute("data-behaviors")); } catch (ex) { return; }
    var capturedProps = props || null;
    // Tag this element so the DOMContentLoaded [data-behaviors] scan
    // doesn't re-wire it. Otherwise dynamically-created elements get
    // both this rich-context wiring (with capturedProps) AND the
    // generic post-load wiring, which fires the action a second
    // time without props — manifested as e.g. close_tab firing once
    // with the right index then again with index="".
    el.setAttribute("data-behaviors-wired", "1");
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
          self: { id: el.id, type: el.getAttribute("data-element-type") || "" },
          props: capturedProps
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
    // File menu actions short-circuit to the engine bootstrap. The
    // yaml definitions today are placeholder log-only stubs gated
    // on `state.tab_count > 0`; rather than threading tab state
    // through every action eval (V1 is single-document), we route
    // the canonical save / save-as / open ids straight to JAS.*.
    if (globalThis.JAS) {
      if ((actionId === "save" || actionId === "save_as")
          && typeof globalThis.JAS.saveAs === "function") {
        globalThis.JAS.saveAs();
        return;
      }
      if (actionId === "open_file"
          && typeof globalThis.JAS.open === "function") {
        globalThis.JAS.open().catch(function (e) {
          console.warn("[open_file] failed:", e && e.message);
        });
        return;
      }
      if (actionId === "undo"
          && typeof globalThis.JAS.undo === "function") {
        globalThis.JAS.undo();
        return;
      }
      if (actionId === "redo"
          && typeof globalThis.JAS.redo === "function") {
        globalThis.JAS.redo();
        return;
      }
    }
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

  // Expose for the engine bootstrap (canvas_bootstrap.mjs) so it
  // can replay actions on startup — specifically, dispatching
  // new_document once per saved tab to rehydrate the workspace.
  globalThis.APP_DISPATCH = dispatch;
  globalThis.APP_SET_STATE = setState;

  // ── Dynamic workspace menu ──────────────────────────────────

  function rebuildWorkspaceMenu() {
    var menu = document.querySelector("#menu_workspace + .dropdown-menu");
    if (!menu) return;
    var defaults = typeof APP_DEFAULT_LAYOUTS !== "undefined" ? APP_DEFAULT_LAYOUTS : {};
    var saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    // Combine default + user layouts, defaults first
    var defaultNames = Object.keys(defaults).sort();
    var userNames = Object.keys(saved).sort();
    // Remove any previously injected items
    menu.querySelectorAll(".app-ws-item").forEach(function (el) { el.remove(); });
    var firstItem = menu.firstElementChild;
    // Insert default layouts (non-deletable)
    defaultNames.forEach(function (name) {
      var li = document.createElement("li");
      li.className = "app-ws-item";
      var check = (activeWorkspaceName === name) ? "\u2713 " : "    ";
      var a = document.createElement("a");
      a.className = "dropdown-item";
      a.href = "#";
      a.textContent = check + name;
      a.setAttribute("data-action", "switch_workspace");
      a.setAttribute("data-action-params", JSON.stringify({name: name}));
      li.appendChild(a);
      menu.insertBefore(li, firstItem);
    });
    // Separator between defaults and user layouts
    if (defaultNames.length > 0 && userNames.length > 0) {
      var sep1 = document.createElement("li");
      sep1.className = "app-ws-item";
      sep1.innerHTML = '<hr class="dropdown-divider">';
      menu.insertBefore(sep1, firstItem);
    }
    // Insert user-saved layouts
    userNames.forEach(function (name) {
      var li = document.createElement("li");
      li.className = "app-ws-item";
      var check = (activeWorkspaceName === name) ? "\u2713 " : "    ";
      var a = document.createElement("a");
      a.className = "dropdown-item";
      a.href = "#";
      a.textContent = check + name;
      a.setAttribute("data-action", "switch_workspace");
      a.setAttribute("data-action-params", JSON.stringify({name: name}));
      li.appendChild(a);
      menu.insertBefore(li, firstItem);
    });
    if (defaultNames.length + userNames.length > 0) {
      var sep2 = document.createElement("li");
      sep2.className = "app-ws-item";
      sep2.innerHTML = '<hr class="dropdown-divider">';
      menu.insertBefore(sep2, firstItem);
    }
    // Update revert enabled state
    var revertItem = menu.querySelector("[data-action='revert_workspace']");
    if (revertItem) {
      revertItem.classList.toggle("disabled", !activeWorkspaceName);
    }
  }

  // Make default layouts available for load_layout
  function getLayoutData(name) {
    var saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    if (saved[name]) return saved[name];
    var defaults = typeof APP_DEFAULT_LAYOUTS !== "undefined" ? APP_DEFAULT_LAYOUTS : {};
    return defaults[name] || null;
  }

  // ── Appearance switching ─────────────────────────────────────

  function applyAppearance(name) {
    var base = typeof APP_BASE_THEME !== "undefined" ? APP_BASE_THEME : {};
    var allApps = typeof APP_ALL_APPEARANCES !== "undefined" ? APP_ALL_APPEARANCES : {};
    // Also check user-saved appearances in localStorage
    var userApps = JSON.parse(localStorage.getItem(APPEARANCE_STORAGE_KEY) || "{}");
    var overrides = allApps[name] || userApps[name] || {};

    // Deep merge: base + overrides for colors, fonts, sizes
    var resolved = {};
    ["colors", "fonts", "sizes"].forEach(function (section) {
      resolved[section] = Object.assign({}, base[section] || {});
      if (overrides[section]) {
        if (section === "fonts") {
          for (var fk in overrides[section]) {
            resolved[section][fk] = Object.assign({}, resolved[section][fk] || {}, overrides[section][fk]);
          }
        } else {
          Object.assign(resolved[section], overrides[section]);
        }
      }
    });

    // Update CSS variables on :root
    var root = document.documentElement;
    for (var k in resolved.colors) {
      if (resolved.colors.hasOwnProperty(k)) {
        root.style.setProperty("--app-" + k.replace(/_/g, "-"), resolved.colors[k]);
      }
    }
    for (var fk in resolved.fonts) {
      if (resolved.fonts.hasOwnProperty(fk)) {
        var font = resolved.fonts[fk];
        var prefix = "--app-font-" + fk.replace(/_/g, "-");
        if (font.family) root.style.setProperty(prefix + "-family", font.family);
        if (font.size) root.style.setProperty(prefix + "-size", font.size + "px");
        if (font.weight) root.style.setProperty(prefix + "-weight", font.weight);
      }
    }
    for (var sk in resolved.sizes) {
      if (resolved.sizes.hasOwnProperty(sk)) {
        root.style.setProperty("--app-size-" + sk.replace(/_/g, "-"), resolved.sizes[sk] + "px");
      }
    }

    // Toggle Bootstrap dark/light based on background luminance
    var bg = resolved.colors.window_bg || "#2e2e2e";
    var lum = hexLuminance(bg);
    root.setAttribute("data-bs-theme", lum > 0.5 ? "light" : "dark");

    // Update APP_THEME for interpolation resolution
    APP_THEME = resolved;
    activeAppearanceName = name;
    rebuildAppearanceMenu();
  }

  function hexLuminance(hex) {
    // Parse #rrggbb to relative luminance (0-1)
    hex = hex.replace("#", "");
    if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
    var r = parseInt(hex.substring(0, 2), 16) / 255;
    var g = parseInt(hex.substring(2, 4), 16) / 255;
    var b = parseInt(hex.substring(4, 6), 16) / 255;
    return 0.299 * r + 0.587 * g + 0.114 * b;
  }

  function rebuildAppearanceMenu() {
    var menu = document.querySelector("#menu_appearance + .dropdown-menu");
    if (!menu) return;
    var appearances = typeof APP_APPEARANCES !== "undefined" ? APP_APPEARANCES : [];
    var userApps = JSON.parse(localStorage.getItem(APPEARANCE_STORAGE_KEY) || "{}");
    // Remove previously injected items
    menu.querySelectorAll(".app-appearance-item").forEach(function (el) { el.remove(); });
    var firstItem = menu.firstElementChild;
    // Insert predefined appearances
    appearances.forEach(function (app) {
      var li = document.createElement("li");
      li.className = "app-appearance-item";
      var check = (activeAppearanceName === app.name) ? "\u2713 " : "    ";
      var a = document.createElement("a");
      a.className = "dropdown-item";
      a.href = "#";
      a.textContent = check + app.label;
      a.setAttribute("data-action", "switch_appearance");
      a.setAttribute("data-action-params", JSON.stringify({name: app.name}));
      li.appendChild(a);
      menu.insertBefore(li, firstItem);
    });
    // Insert user-saved appearances
    var userNames = Object.keys(userApps).sort();
    if (userNames.length > 0 && appearances.length > 0) {
      var sep1 = document.createElement("li");
      sep1.className = "app-appearance-item";
      sep1.innerHTML = '<hr class="dropdown-divider">';
      menu.insertBefore(sep1, firstItem);
    }
    userNames.forEach(function (name) {
      var li = document.createElement("li");
      li.className = "app-appearance-item";
      var check = (activeAppearanceName === name) ? "\u2713 " : "    ";
      var label = userApps[name].label || name;
      var a = document.createElement("a");
      a.className = "dropdown-item";
      a.href = "#";
      a.textContent = check + label;
      a.setAttribute("data-action", "switch_appearance");
      a.setAttribute("data-action-params", JSON.stringify({name: name}));
      li.appendChild(a);
      menu.insertBefore(li, firstItem);
    });
    if (appearances.length + userNames.length > 0) {
      var sep2 = document.createElement("li");
      sep2.className = "app-appearance-item";
      sep2.innerHTML = '<hr class="dropdown-divider">';
      menu.insertBefore(sep2, firstItem);
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

    // Wire behavior data attributes — group by event, first matching condition wins.
    // Skip elements already wired by createElementFromSpec (those carry
    // the data-behaviors-wired marker and were given proper ctx.props
    // in their listener closure).
    document.querySelectorAll("[data-behaviors]:not([data-behaviors-wired])").forEach(function (el) {
      var behaviors;
      try { behaviors = JSON.parse(el.getAttribute("data-behaviors")); } catch (ex) { return; }
      // Group behaviors by event type
      var byEvent = {};
      behaviors.forEach(function (b) {
        var domEvent = eventMap[b.event];
        if (!domEvent) return;
        if (!byEvent[domEvent]) byEvent[domEvent] = [];
        byEvent[domEvent].push(b);
      });
      // Wire one listener per event type
      for (var domEvent in byEvent) {
        (function (evBehaviors) {
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
            // Try each behavior in order, stop at first matching condition
            for (var i = 0; i < evBehaviors.length; i++) {
              var b = evBehaviors[i];
              if (b.condition && !evalCondition(resolve(b.condition, ctx), ctx)) continue;
              e.stopPropagation(); // prevent bubbling to parent elements
              if (b.prevent_default) e.preventDefault();
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
              return; // stop after first match
            }
          });
        })(byEvent[domEvent]);
      }
    });

    // Apply server-side initial hidden state before first binding update
    document.querySelectorAll("[data-initial-hidden]").forEach(function (el) {
      el.classList.add("d-none");
    });

    // Initialize panel-local state from data-panel-state (defaults) and
    // data-panel-init (expressions evaluated against current global state)
    document.querySelectorAll("[data-panel-state]").forEach(function (panelEl) {
      try {
        var defaults = JSON.parse(panelEl.getAttribute("data-panel-state") || "{}");
        Object.assign(panelState, defaults);
      } catch (e) {}
      try {
        var inits = JSON.parse(panelEl.getAttribute("data-panel-init") || "{}");
        for (var pik in inits) {
          if (inits.hasOwnProperty(pik)) {
            // Evaluate init expression (resolve handles bare expressions)
            var resolved = resolve(inits[pik], {});
            if (resolved !== null && resolved !== undefined) panelState[pik] = resolved;
          }
        }
      } catch (e) {}
    });

    // Wire panel slider/input → live color update and commit
    document.addEventListener("input", function (e) {
      var el = e.target;
      var bindVal = el.getAttribute && el.getAttribute("data-bind-value");
      if (!bindVal) return;
      var pm = bindVal.match(/^\{\{panel\.(\w+)\}\}$/) || bindVal.match(/^panel\.(\w+)$/);
      if (!pm) return;
      var field = pm[1];
      panelColorSyncLocked = true;
      panelState[field] = parseFloat(el.value);
      var newColor = panelStateToColor();
      panelState.hex = colorFunctions.hex(newColor);
      setState(state.fill_on_top ? "fill_color" : "stroke_color", newColor);
      panelColorSyncLocked = false;
      updateBindings(null, null);
    });

    document.addEventListener("change", function (e) {
      var el = e.target;
      var bindVal = el.getAttribute && el.getAttribute("data-bind-value");
      if (!bindVal || !(bindVal.match(/^\{\{panel\.\w+\}\}$/) || bindVal.match(/^panel\.\w+$/))) return;
      dispatch("set_active_color", { color: panelStateToColor() });
    });

    // Hex input commit on Enter
    document.addEventListener("keydown", function (e) {
      if (e.key !== "Enter") return;
      var el = e.target;
      if (!el.getAttribute) return;
      var hexBind = el.getAttribute("data-bind-value");
      if (hexBind !== "{{panel.hex}}" && hexBind !== "panel.hex") return;
      var raw = el.value.replace(/^#/, "").trim();
      if (/^[0-9a-fA-F]{6}$/.test(raw)) {
        var newColor = "#" + raw.toLowerCase();
        panelColorSyncLocked = true;
        setState(state.fill_on_top ? "fill_color" : "stroke_color", newColor);
        panelColorSyncLocked = false;
        syncPanelColorState();
        updateBindings(null, null);
        dispatch("set_active_color", { color: newColor });
        el.blur();
      }
    });

    // Color bar click/drag
    var colorBarDragging = false;
    function applyColorBarPoint(canvas, clientX, clientY, commit) {
      var rect = canvas.getBoundingClientRect();
      var x = Math.max(0, Math.min(clientX - rect.left,  rect.width  - 1));
      var y = Math.max(0, Math.min(clientY - rect.top,   rect.height - 1));
      var midY = rect.height / 2;
      panelColorSyncLocked = true;
      panelState.h = Math.round(360 * x / rect.width);
      if (y <= midY) {
        var t = y / midY;
        panelState.s = Math.round(t * 100);
        panelState.b = Math.round(100 - t * 20);
      } else {
        var t = (y - midY) / (rect.height - midY);
        panelState.s = 100;
        panelState.b = Math.round(80 * (1 - t));
      }
      var newColor = panelStateToColor();
      panelState.hex = colorFunctions.hex(newColor);
      setState(state.fill_on_top ? "fill_color" : "stroke_color", newColor);
      panelColorSyncLocked = false;
      updateBindings(null, null);
      if (commit) dispatch("set_active_color", { color: newColor });
    }
    document.addEventListener("pointerdown", function (e) {
      var canvas = e.target.closest("canvas[data-type='color-bar']");
      if (!canvas) return;
      colorBarDragging = true;
      canvas.setPointerCapture(e.pointerId);
      applyColorBarPoint(canvas, e.clientX, e.clientY, false);
    });
    document.addEventListener("pointermove", function (e) {
      if (!colorBarDragging) return;
      var canvas = e.target.closest("canvas[data-type='color-bar']");
      if (!canvas) return;
      applyColorBarPoint(canvas, e.clientX, e.clientY, false);
    });
    document.addEventListener("pointerup", function (e) {
      if (!colorBarDragging) return;
      colorBarDragging = false;
      var canvas = e.target.closest("canvas[data-type='color-bar']");
      if (canvas) applyColorBarPoint(canvas, e.clientX, e.clientY, true);
    });

    // --- Color picker gradient click handler ---
    var gradientDragging = false;
    function applyGradientPoint(el, clientX, clientY) {
      var rect = el.getBoundingClientRect();
      var x = Math.max(0, Math.min(clientX - rect.left, rect.width));
      var y = Math.max(0, Math.min(clientY - rect.top, rect.height));
      var sat = Math.round(x / rect.width * 100);
      var bri = Math.round((1 - y / rect.height) * 100);
      if (dialogState) {
        dialogSetValue("s", sat);
        dialogSetValue("b", bri);
        updateBindings(null, null);
      }
      // Update cursor position
      var cursor = el.querySelector("[data-role='gradient-cursor']");
      if (cursor) {
        cursor.style.left = (x - 5) + "px";
        cursor.style.top = (y - 5) + "px";
      }
    }
    document.addEventListener("pointerdown", function (e) {
      var el = e.target.closest("[data-type='color-gradient']");
      if (!el) return;
      gradientDragging = true;
      el.setPointerCapture(e.pointerId);
      applyGradientPoint(el, e.clientX, e.clientY);
    });
    document.addEventListener("pointermove", function (e) {
      if (!gradientDragging) return;
      var el = e.target.closest("[data-type='color-gradient']");
      if (el) applyGradientPoint(el, e.clientX, e.clientY);
    });
    document.addEventListener("pointerup", function (e) {
      if (!gradientDragging) return;
      gradientDragging = false;
      var el = e.target.closest("[data-type='color-gradient']");
      if (el) applyGradientPoint(el, e.clientX, e.clientY);
    });

    // --- Color picker hue bar click handler ---
    var hueDragging = false;
    function applyHuePoint(el, clientX, clientY) {
      var rect = el.getBoundingClientRect();
      var y = Math.max(0, Math.min(clientY - rect.top, rect.height));
      var hue = Math.round(y / rect.height * 360);
      if (hue >= 360) hue = 359;
      if (dialogState) {
        dialogSetValue("h", hue);
        updateBindings(null, null);
        // Update gradient background for new hue
        var newColor = dialogState.color || "#ff0000";
        var hVal = dialogGetValue("h") || 0;
        var gradEl = document.querySelector("[data-type='color-gradient']");
        if (gradEl) {
          var hRgb = hsbToRgb(Number(hVal), 100, 100);
          gradEl.style.background =
            "linear-gradient(to bottom,transparent,#000)," +
            "linear-gradient(to right,#fff,rgb(" + hRgb.r + "," + hRgb.g + "," + hRgb.b + "))";
        }
      }
      // Update indicator position
      var indicator = el.querySelector("[data-role='hue-indicator']");
      if (indicator) {
        indicator.style.top = (y - 1) + "px";
      }
    }
    document.addEventListener("pointerdown", function (e) {
      var el = e.target.closest("[data-type='color-hue-bar']");
      if (!el) return;
      hueDragging = true;
      el.setPointerCapture(e.pointerId);
      applyHuePoint(el, e.clientX, e.clientY);
    });
    document.addEventListener("pointermove", function (e) {
      if (!hueDragging) return;
      var el = e.target.closest("[data-type='color-hue-bar']");
      if (el) applyHuePoint(el, e.clientX, e.clientY);
    });
    document.addEventListener("pointerup", function (e) {
      if (!hueDragging) return;
      hueDragging = false;
      var el = e.target.closest("[data-type='color-hue-bar']");
      if (el) applyHuePoint(el, e.clientX, e.clientY);
    });

    // --- Gradient slider: stop/midpoint gestures ---
    //
    // Dispatches custom events the panel wiring layer can listen for. No
    // direct state mutation here — Phase 5 wires these events to the
    // gradient action pipeline. Events bubble on the slider element with
    // `detail` carrying the relevant indices / positions.
    //
    // Events:
    //   gradient-slider-stop-click       { stopIndex }
    //   gradient-slider-stop-dblclick    { stopIndex }
    //   gradient-slider-midpoint-click   { midpointIndex }
    //   gradient-slider-bar-click        { location }        — click on empty bar (add-stop)
    //   gradient-slider-stop-drag-start  { stopIndex }
    //   gradient-slider-stop-drag        { stopIndex, location, offBar }
    //   gradient-slider-stop-drag-end    { stopIndex, location, offBar }
    //   gradient-slider-midpoint-drag    { midpointIndex, location }
    //   gradient-slider-midpoint-drag-end{ midpointIndex, location }
    //   gradient-slider-key              { key, shift }      — arrow/delete keys
    var gradSliderDrag = null; // { slider, role, index }
    var GRAD_DRAG_OFF_BAR_PX = 20;

    function _gradSliderRectLoc(slider, clientX) {
      var bar = slider.querySelector("[data-role='bar']");
      if (!bar) return 0;
      var rect = bar.getBoundingClientRect();
      if (rect.width <= 0) return 0;
      var x = Math.max(0, Math.min(clientX - rect.left, rect.width));
      return (x / rect.width) * 100;
    }
    function _gradSliderBarCenterY(slider) {
      var bar = slider.querySelector("[data-role='bar']");
      if (!bar) return 0;
      var rect = bar.getBoundingClientRect();
      return rect.top + rect.height / 2;
    }
    function _gradDispatch(slider, name, detail) {
      slider.dispatchEvent(new CustomEvent(name, { detail: detail, bubbles: true }));
    }

    document.addEventListener("pointerdown", function (e) {
      var slider = e.target.closest("[data-type='gradient-slider']");
      if (!slider) return;
      var stop = e.target.closest("[data-role='stop']");
      var mid = e.target.closest("[data-role='midpoint']");
      if (stop) {
        var si = Number(stop.getAttribute("data-stop-index"));
        gradSliderDrag = { slider: slider, role: "stop", index: si, moved: false };
        slider.setPointerCapture(e.pointerId);
        _gradDispatch(slider, "gradient-slider-stop-click", { stopIndex: si });
        _gradDispatch(slider, "gradient-slider-stop-drag-start", { stopIndex: si });
        e.preventDefault();
      } else if (mid) {
        var mi = Number(mid.getAttribute("data-midpoint-index"));
        gradSliderDrag = { slider: slider, role: "midpoint", index: mi, moved: false };
        slider.setPointerCapture(e.pointerId);
        _gradDispatch(slider, "gradient-slider-midpoint-click", { midpointIndex: mi });
        e.preventDefault();
      } else if (e.target.closest("[data-role='bar']")) {
        var loc = _gradSliderRectLoc(slider, e.clientX);
        _gradDispatch(slider, "gradient-slider-bar-click", { location: loc });
        e.preventDefault();
      }
    });
    document.addEventListener("pointermove", function (e) {
      if (!gradSliderDrag) return;
      var slider = gradSliderDrag.slider;
      var loc = _gradSliderRectLoc(slider, e.clientX);
      gradSliderDrag.moved = true;
      if (gradSliderDrag.role === "stop") {
        var barY = _gradSliderBarCenterY(slider);
        var offBar = Math.abs(e.clientY - barY) > GRAD_DRAG_OFF_BAR_PX;
        _gradDispatch(slider, "gradient-slider-stop-drag", {
          stopIndex: gradSliderDrag.index, location: loc, offBar: offBar,
        });
      } else if (gradSliderDrag.role === "midpoint") {
        _gradDispatch(slider, "gradient-slider-midpoint-drag", {
          midpointIndex: gradSliderDrag.index, location: loc,
        });
      }
    });
    document.addEventListener("pointerup", function (e) {
      if (!gradSliderDrag) return;
      var slider = gradSliderDrag.slider;
      var loc = _gradSliderRectLoc(slider, e.clientX);
      if (gradSliderDrag.role === "stop") {
        var barY = _gradSliderBarCenterY(slider);
        var offBar = Math.abs(e.clientY - barY) > GRAD_DRAG_OFF_BAR_PX;
        _gradDispatch(slider, "gradient-slider-stop-drag-end", {
          stopIndex: gradSliderDrag.index, location: loc, offBar: offBar,
        });
      } else if (gradSliderDrag.role === "midpoint") {
        _gradDispatch(slider, "gradient-slider-midpoint-drag-end", {
          midpointIndex: gradSliderDrag.index, location: loc,
        });
      }
      gradSliderDrag = null;
    });
    document.addEventListener("dblclick", function (e) {
      var slider = e.target.closest("[data-type='gradient-slider']");
      if (!slider) return;
      var stop = e.target.closest("[data-role='stop']");
      if (stop) {
        var si = Number(stop.getAttribute("data-stop-index"));
        _gradDispatch(slider, "gradient-slider-stop-dblclick", { stopIndex: si });
      }
    });
    document.addEventListener("keydown", function (e) {
      var slider = document.activeElement && document.activeElement.closest("[data-type='gradient-slider']");
      if (!slider) return;
      var handled = ["ArrowLeft", "ArrowRight", "Home", "End", "Delete", "Backspace"];
      if (handled.indexOf(e.key) < 0) return;
      _gradDispatch(slider, "gradient-slider-key", { key: e.key, shift: e.shiftKey });
      e.preventDefault();
    });

    // Initialize bindings
    for (var key in state) {
      if (state.hasOwnProperty(key)) {
        updateBindings(key, state[key]);
      }
    }

    // Build dynamic workspace menu on load and when submenu is shown
    rebuildWorkspaceMenu();
    var wsSubmenu = document.getElementById("menu_workspace");
    if (wsSubmenu) {
      wsSubmenu.addEventListener("click", function () {
        setTimeout(rebuildWorkspaceMenu, 0);
      });
    }

    // Build dynamic appearance menu on load and when submenu is shown
    rebuildAppearanceMenu();
    var appSubmenu = document.getElementById("menu_appearance");
    if (appSubmenu) {
      appSubmenu.addEventListener("click", function () {
        setTimeout(rebuildAppearanceMenu, 0);
      });
    }

    // Redraw color bars once the window has fully loaded and laid out.
    window.addEventListener("load", function () { drawColorBars(); });
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
    // ESC toggles wireframe mode
    if (e.key === "Escape") {
      e.preventDefault();
      document.body.classList.toggle("wireframe-active");
      return;
    }
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
    var title = e.target.closest(".app-pane-title");
    if (!title) return;
    // Don't initiate drag if clicking an interactive element within the title bar
    var t = e.target;
    while (t && t !== title) {
      if (t.tagName === "BUTTON" || t.tagName === "A" || t.tagName === "INPUT" || t.tagName === "SELECT"
          || t.hasAttribute("data-action") || t.hasAttribute("data-bs-toggle")) return;
      t = t.parentElement;
    }
    var pane = title.closest(".app-pane");
    if (!pane) return;
    // Don't preventDefault — it suppresses dblclick events on the title bar
    dragState = {
      pane: pane,
      offsetX: e.clientX - pane.offsetLeft,
      offsetY: e.clientY - pane.offsetTop
    };
    document.body.style.cursor = "grabbing";
    document.querySelectorAll(".app-pane").forEach(function (p) {
      p.style.zIndex = p === pane ? "100" : "";
    });
  });

  var SNAP_DISTANCE = 8;

  function getSnapEdges(pane, parent) {
    // Collect snap targets: viewport edges + other pane edges
    var edges = { x: [0], y: [0] };
    if (parent) {
      edges.x.push(parent.clientWidth);
      edges.y.push(parent.clientHeight);
    }
    var panes = parent ? parent.querySelectorAll(".app-pane") : [];
    panes.forEach(function (p) {
      if (p === pane || p.classList.contains("d-none") || p.style.display === "none") return;
      edges.x.push(p.offsetLeft);
      edges.x.push(p.offsetLeft + p.offsetWidth);
      edges.y.push(p.offsetTop);
      edges.y.push(p.offsetTop + p.offsetHeight);
    });
    return edges;
  }

  function snap(val, targets) {
    for (var i = 0; i < targets.length; i++) {
      if (Math.abs(val - targets[i]) < SNAP_DISTANCE) return targets[i];
    }
    return val;
  }

  // Snap preview lines
  var snapLines = [];
  function showSnapLine(orient, pos, parent) {
    var line = document.createElement("div");
    line.className = "app-snap-line";
    if (orient === "x") {
      line.style.cssText = "position:absolute;left:" + pos + "px;top:0;width:1px;height:100%;background:rgba(50,120,220,0.8);z-index:200;pointer-events:none";
    } else {
      line.style.cssText = "position:absolute;left:0;top:" + pos + "px;width:100%;height:1px;background:rgba(50,120,220,0.8);z-index:200;pointer-events:none";
    }
    parent.appendChild(line);
    snapLines.push(line);
  }
  function clearSnapLines() {
    snapLines.forEach(function (l) { l.remove(); });
    snapLines = [];
  }

  document.addEventListener("mousemove", function (e) {
    if (!dragState) return;
    var pane = dragState.pane;
    var rawX = e.clientX - dragState.offsetX;
    var rawY = e.clientY - dragState.offsetY;
    var parent = pane.parentElement;
    var edges = getSnapEdges(pane, parent);
    var w = pane.offsetWidth, h = pane.offsetHeight;
    clearSnapLines();
    // Snap left edge, then right edge
    var sx = snap(rawX, edges.x);
    if (sx !== rawX) { showSnapLine("x", sx, parent); }
    else { sx = snap(rawX + w, edges.x) - w; if (sx + w !== rawX + w) showSnapLine("x", sx + w, parent); }
    // Snap top edge, then bottom edge
    var sy = snap(rawY, edges.y);
    if (sy !== rawY) { showSnapLine("y", sy, parent); }
    else { sy = snap(rawY + h, edges.y) - h; if (sy + h !== rawY + h) showSnapLine("y", sy + h, parent); }
    pane.style.left = sx + "px";
    pane.style.top = sy + "px";
  });

  document.addEventListener("mouseup", function () {
    if (dragState) {
      document.body.style.cursor = "";
      dragState = null;
      clearSnapLines();
    }
  });

  // ── Edge resize ────────────────────────────────────────────

  var resizeState = null;

  function isFixedWidth(pane) {
    var configs = typeof APP_PANE_CONFIGS !== "undefined" ? APP_PANE_CONFIGS : {};
    var cfg = configs[pane.id];
    return cfg && cfg.fixed_width;
  }

  function findAdjacentPane(pane, edge) {
    // Find the pane whose opposite edge is closest to this pane's edge
    var parent = pane.parentElement;
    if (!parent) return null;
    var panes = parent.querySelectorAll(".app-pane");
    var best = null, bestDist = SNAP_DISTANCE * 2;
    var px = pane.offsetLeft, pw = pane.offsetWidth, py = pane.offsetTop, ph = pane.offsetHeight;
    panes.forEach(function (p) {
      if (p === pane || p.classList.contains("d-none")) return;
      var dist;
      if (edge === "right") dist = Math.abs(p.offsetLeft - (px + pw));
      else if (edge === "left") dist = Math.abs((p.offsetLeft + p.offsetWidth) - px);
      else return;
      if (dist < bestDist) { bestDist = dist; best = p; }
    });
    return best;
  }

  document.addEventListener("mousedown", function (e) {
    var handle = e.target.closest(".app-edge-handle");
    if (!handle) return;
    var pane = handle.closest(".app-pane");
    if (!pane) return;
    var handleIsLeft = handle.classList.contains("left");
    var handleIsRight = handle.classList.contains("right");
    var isHoriz = handleIsLeft || handleIsRight;
    var targetPane = pane;
    var resizeLeft = handleIsLeft;
    var resizeRight = handleIsRight;

    // If this pane is fixed-width, redirect horizontal resize to neighbor
    if (isHoriz && isFixedWidth(pane)) {
      var edge = handleIsRight ? "right" : "left";
      var adj = findAdjacentPane(pane, edge);
      if (adj && !isFixedWidth(adj)) {
        targetPane = adj;
        // Flip direction: dragging fixed pane's right handle = resizing neighbor's left edge
        resizeLeft = handleIsRight;
        resizeRight = handleIsLeft;
      } else {
        return;
      }
    }
    e.preventDefault();
    e.stopPropagation();
    resizeState = {
      pane: targetPane,
      startX: e.clientX, startY: e.clientY,
      startLeft: targetPane.offsetLeft, startTop: targetPane.offsetTop,
      startW: targetPane.offsetWidth, startH: targetPane.offsetHeight,
      isLeft: resizeLeft,
      isRight: resizeRight,
      isTop: handle.classList.contains("top"),
      isBottom: handle.classList.contains("bottom")
    };
  });

  document.addEventListener("mousemove", function (e) {
    if (!resizeState) return;
    var r = resizeState, dx = e.clientX - r.startX, dy = e.clientY - r.startY;
    var parent = r.pane.parentElement;
    var edges = getSnapEdges(r.pane, parent);
    clearSnapLines();
    if (r.isRight) {
      var right = snap(r.startLeft + r.startW + dx, edges.x);
      if (right !== r.startLeft + r.startW + dx) showSnapLine("x", right, parent);
      r.pane.style.width = Math.max(50, right - r.startLeft) + "px";
    } else if (r.isLeft) {
      var left = snap(r.startLeft + dx, edges.x);
      if (left !== r.startLeft + dx) showSnapLine("x", left, parent);
      var newW = Math.max(50, r.startLeft + r.startW - left);
      r.pane.style.width = newW + "px";
      r.pane.style.left = (r.startLeft + r.startW - newW) + "px";
    }
    if (r.isBottom) {
      var bottom = snap(r.startTop + r.startH + dy, edges.y);
      if (bottom !== r.startTop + r.startH + dy) showSnapLine("y", bottom, parent);
      r.pane.style.height = Math.max(50, bottom - r.startTop) + "px";
    } else if (r.isTop) {
      var top = snap(r.startTop + dy, edges.y);
      if (top !== r.startTop + dy) showSnapLine("y", top, parent);
      var newH = Math.max(50, r.startTop + r.startH - top);
      r.pane.style.height = newH + "px";
      r.pane.style.top = (r.startTop + r.startH - newH) + "px";
    }
  });

  document.addEventListener("mouseup", function () {
    if (resizeState) clearSnapLines();
    resizeState = null;
  });

  // ── dock_view model + effects engine ────────────────────────

  // Runtime dock model: { dockId: { groups: [...], collapsed: bool } }
  var dockModels = {};
  var floatingDockCounter = 0;
  var hiddenPanels = [];

  // Initialize dock models from rendered dock_view elements
  function initDockModels() {
    document.querySelectorAll(".app-dock-view").forEach(function (el) {
      var id = el.id;
      var groupsAttr = el.getAttribute("data-groups");
      if (groupsAttr) {
        try { dockModels[id] = { groups: JSON.parse(groupsAttr), collapsed: false }; } catch (ex) {}
      }
    });
  }

  // Re-render a dock_view from its model
  function rerenderDockView(dockId) {
    var el = document.getElementById(dockId);
    var model = dockModels[dockId];
    if (!el || !model) return;
    // Update data attribute
    el.setAttribute("data-groups", JSON.stringify(model.groups));
    // Fetch fresh HTML from server would be ideal, but for now rebuild client-side
    rebuildDockViewDOM(el, model);
    // Redraw any color bar canvases that may have just become visible
    drawColorBars();
  }

  function rebuildDockViewDOM(container, model) {
    // Preserve server-rendered panel body elements before clearing
    var savedPanels = {};
    container.querySelectorAll(".app-dock-panel-body[data-panel-name]").forEach(function (el) {
      var name = el.getAttribute("data-panel-name");
      if (name) savedPanels[name] = el;
    });
    container.innerHTML = "";
    var collapsed = state.dock_collapsed;
    var groups = model.groups;

    if (collapsed) {
      var strip = document.createElement("div");
      strip.className = "app-dock-collapsed-strip";
      strip.style.cssText = "display:flex;flex-direction:column;align-items:center;gap:2px;padding:4px 0";
      groups.forEach(function (group, gi) {
        (group.panels || []).forEach(function (panelName, pi) {
          var btn = document.createElement("button");
          btn.className = "btn btn-sm app-dock-icon p-0";
          btn.style.cssText = "width:28px;height:28px;display:flex;align-items:center;justify-content:center;background:#505050;border:none;color:#999";
          btn.title = panelName.charAt(0).toUpperCase() + panelName.slice(1);
          btn.setAttribute("data-dock", container.id);
          btn.setAttribute("data-group", gi);
          btn.setAttribute("data-panel", pi);
          var iconDef = (typeof APP_ICONS !== "undefined") ? APP_ICONS["panel_" + panelName] : null;
          if (iconDef) {
            btn.innerHTML = '<svg viewBox="' + (iconDef.viewbox || "0 0 28 28") + '" width="20" height="20" fill="currentColor">' + (iconDef.svg || "") + '</svg>';
          } else {
            btn.textContent = panelName.charAt(0).toUpperCase();
          }
          btn.addEventListener("click", function () {
            setState("dock_collapsed", false);
            model.groups[gi].active = pi;
            model.groups[gi].collapsed = false;
            rerenderDockView(container.id);
          });
          strip.appendChild(btn);
        });
        if (gi < groups.length - 1) {
          var sep = document.createElement("hr");
          sep.style.cssText = "width:80%;border-color:#555;margin:2px 0";
          strip.appendChild(sep);
        }
      });
      container.appendChild(strip);
      return;
    }

    // Expanded rendering
    groups.forEach(function (group, gi) {
      var panels = group.panels || [];
      var active = group.active || 0;
      var groupCollapsed = group.collapsed || false;

      var groupDiv = document.createElement("div");
      groupDiv.className = "app-dock-group";
      groupDiv.setAttribute("data-dock", container.id);
      groupDiv.setAttribute("data-group-index", gi);

      // Header
      var header = document.createElement("div");
      header.className = "app-dock-group-header";
      header.style.cssText = "display:flex;align-items:center;background:#333;padding:2px 4px;gap:2px";

      // Grip
      var grip = document.createElement("span");
      grip.className = "app-dock-grip";
      grip.style.cssText = "cursor:grab;color:#777;font-size:10px;padding:0 2px";
      grip.textContent = "⠁⠁";
      grip.setAttribute("data-dock", container.id);
      grip.setAttribute("data-group", gi);
      header.appendChild(grip);

      // Tab buttons
      panels.forEach(function (panelName, pi) {
        var label = panelName.charAt(0).toUpperCase() + panelName.slice(1);
        var btn = document.createElement("button");
        btn.className = "btn btn-sm app-dock-tab" + (pi === active ? " active" : "");
        btn.style.cssText = "padding:1px 6px;font-size:11px;color:#ccc;background:" + (pi === active ? "#4a4a4a" : "#353535") + ";border:none;cursor:grab";
        btn.textContent = label;
        btn.setAttribute("data-dock", container.id);
        btn.setAttribute("data-group", gi);
        btn.setAttribute("data-panel-index", pi);
        btn.setAttribute("data-panel-name", panelName);
        btn.addEventListener("click", function () {
          model.groups[gi].active = pi;
          rerenderDockView(container.id);
        });
        header.appendChild(btn);
      });

      // Spacer
      var spacer = document.createElement("span");
      spacer.style.flex = "1";
      header.appendChild(spacer);

      // Chevron
      var chevron = document.createElement("button");
      chevron.className = "btn btn-sm app-dock-chevron p-0";
      chevron.style.cssText = "color:#888;background:transparent;border:none;font-size:18px;line-height:1";
      chevron.textContent = groupCollapsed ? "\u00bb" : "\u00ab";
      chevron.addEventListener("click", function () {
        model.groups[gi].collapsed = !model.groups[gi].collapsed;
        rerenderDockView(container.id);
      });
      header.appendChild(chevron);

      // Hamburger (visible when not collapsed)
      if (!groupCollapsed) {
        var hbDiv = document.createElement("div");
        hbDiv.className = "dropdown d-inline-block";
        var hbBtn = document.createElement("button");
        hbBtn.className = "btn btn-sm p-0 dropdown-toggle";
        hbBtn.setAttribute("data-bs-toggle", "dropdown");
        hbBtn.style.cssText = "color:#888;background:transparent;border:none;font-size:14px";
        hbBtn.textContent = "\u2261";
        var hbMenu = document.createElement("ul");
        hbMenu.className = "dropdown-menu";
        panels.forEach(function (panelName) {
          var li = document.createElement("li");
          var a = document.createElement("a");
          a.className = "dropdown-item";
          a.href = "#";
          a.textContent = "Close " + panelName.charAt(0).toUpperCase() + panelName.slice(1);
          a.addEventListener("click", function (ev) {
            ev.preventDefault();
            dockClosePanel(container.id, panelName);
          });
          li.appendChild(a);
          hbMenu.appendChild(li);
        });
        hbDiv.appendChild(hbBtn);
        hbDiv.appendChild(hbMenu);
        header.appendChild(hbDiv);
      }

      groupDiv.appendChild(header);

      // Body
      if (!groupCollapsed && panels.length > 0) {
        var body = document.createElement("div");
        body.className = "app-dock-group-body";
        body.style.cssText = "flex:1";
        var activeName = panels[Math.min(active, panels.length - 1)];
        panels.forEach(function (pn) {
          var saved = savedPanels[pn];
          if (saved) {
            if (pn === activeName) { saved.classList.remove("d-none"); } else { saved.classList.add("d-none"); }
            body.appendChild(saved);
          } else if (pn === activeName) {
            var label = pn.charAt(0).toUpperCase() + pn.slice(1);
            body.innerHTML += '<div class="app-dock-panel-body" style="padding:12px;color:#aaa;font-size:12px" data-panel-name="' + pn + '">' + label + '</div>';
          }
        });
        groupDiv.appendChild(body);
      }

      container.appendChild(groupDiv);

      // Separator
      if (gi < groups.length - 1) {
        var sep = document.createElement("hr");
        sep.style.cssText = "border-color:#555;margin:0";
        container.appendChild(sep);
      }
    });
  }

  // ── Dock effects ──────────────────────────────────────────

  // Remove a floating dock pane if its model has no groups left
  function removeIfEmptyFloating(dockId) {
    var model = dockModels[dockId];
    if (!model || model.groups.length > 0) return;
    if (dockId.indexOf("floating_dock_") !== 0) return;
    var paneId = dockId.replace("_view", "");
    var pane = document.getElementById(paneId);
    if (pane) pane.remove();
    delete dockModels[dockId];
  }

  function dockClosePanel(dockId, panelName) {
    var model = dockModels[dockId];
    if (!model) return;
    for (var gi = 0; gi < model.groups.length; gi++) {
      var panels = model.groups[gi].panels;
      var idx = panels.indexOf(panelName);
      if (idx >= 0) {
        panels.splice(idx, 1);
        if (model.groups[gi].active >= panels.length) {
          model.groups[gi].active = Math.max(0, panels.length - 1);
        }
        // Remove empty groups
        if (panels.length === 0) {
          model.groups.splice(gi, 1);
        }
        hiddenPanels.push(panelName);
        rerenderDockView(dockId);
        removeIfEmptyFloating(dockId);
        return;
      }
    }
  }

  function dockShowPanel(dockId, panelName) {
    var model = dockModels[dockId];
    if (!model) return;
    // Remove from hidden list
    var hi = hiddenPanels.indexOf(panelName);
    if (hi >= 0) hiddenPanels.splice(hi, 1);
    // Add to last group (or create a new group)
    if (model.groups.length === 0) {
      model.groups.push({ panels: [panelName], active: 0, collapsed: false });
    } else {
      var lastGroup = model.groups[model.groups.length - 1];
      lastGroup.panels.push(panelName);
      lastGroup.active = lastGroup.panels.length - 1;
    }
    rerenderDockView(dockId);
  }

  function dockDetachGroup(dockId, groupIdx, x, y) {
    var model = dockModels[dockId];
    if (!model || groupIdx >= model.groups.length) return;
    var group = model.groups.splice(groupIdx, 1)[0];
    rerenderDockView(dockId);
    removeIfEmptyFloating(dockId);
    // Create floating dock pane
    createFloatingDock([group], x, y);
  }

  function createFloatingDock(groups, x, y) {
    floatingDockCounter++;
    var floatId = "floating_dock_" + floatingDockCounter;
    var dockViewId = floatId + "_view";

    // Register dock model
    dockModels[dockViewId] = { groups: groups, collapsed: false };

    // Create pane element
    var pane = document.createElement("div");
    pane.id = floatId;
    pane.className = "app-pane";
    pane.style.cssText = "position:absolute;left:" + x + "px;top:" + y + "px;width:220px;height:300px;" +
      "background:#3c3c3c;border:1px solid #555;display:flex;flex-direction:column;overflow:hidden;" +
      "box-shadow:4px 4px 12px rgba(0,0,0,0.4);z-index:200";

    // Title bar
    var title = document.createElement("div");
    title.className = "app-pane-title";
    title.style.cssText = "height:20px;background:#2a2a2a;display:flex;align-items:center;padding:0 6px;cursor:grab;font-size:11px;color:#d9d9d9;user-select:none;flex-shrink:0";
    title.innerHTML = '<span style="flex:1">Panels</span>';

    // Redock on double-click
    title.addEventListener("dblclick", function () {
      dockRedock(dockViewId, "dock_main");
    });
    pane.appendChild(title);

    // Content: dock_view
    var content = document.createElement("div");
    content.className = "app-pane-content";
    content.style.cssText = "flex:1;overflow:auto;display:flex;flex-direction:column";
    var dockView = document.createElement("div");
    dockView.id = dockViewId;
    dockView.className = "app-dock-view";
    dockView.style.cssText = "display:flex;flex-direction:column;flex:1";
    content.appendChild(dockView);
    pane.appendChild(content);

    // Edge handles
    ["left", "right", "top", "bottom"].forEach(function (side) {
      var handle = document.createElement("div");
      handle.className = "app-edge-handle " + side;
      pane.appendChild(handle);
    });

    // Add to pane system
    var paneSystem = document.querySelector(".app-pane-system");
    if (paneSystem) paneSystem.appendChild(pane);

    // Render the dock view
    rebuildDockViewDOM(dockView, dockModels[dockViewId]);
  }

  function dockRedock(sourceDockViewId, targetDockViewId) {
    var sourceModel = dockModels[sourceDockViewId];
    var targetModel = dockModels[targetDockViewId];
    if (!sourceModel || !targetModel) return;

    // Move all groups from source to target
    sourceModel.groups.forEach(function (group) {
      targetModel.groups.push(group);
    });
    sourceModel.groups = [];

    // Remove the floating pane
    var pane = document.getElementById(sourceDockViewId.replace("_view", ""));
    if (pane) pane.remove();
    delete dockModels[sourceDockViewId];

    rerenderDockView(targetDockViewId);
  }

  // ── Panel/group drag-and-drop ─────────────────────────────

  var panelDrag = null;
  var dropIndicator = null;

  function getOrCreateDropIndicator() {
    if (!dropIndicator) {
      dropIndicator = document.createElement("div");
      dropIndicator.className = "app-panel-drop-indicator";
      dropIndicator.style.cssText = "position:fixed;z-index:300;pointer-events:none;background:rgba(50,120,220,0.8);display:none";
      document.body.appendChild(dropIndicator);
    }
    return dropIndicator;
  }

  function showIndicator(left, top, width, height) {
    var ind = getOrCreateDropIndicator();
    ind.style.left = left + "px";
    ind.style.top = top + "px";
    ind.style.width = width + "px";
    ind.style.height = height + "px";
    ind.style.display = "block";
  }

  function hideIndicator() {
    if (dropIndicator) dropIndicator.style.display = "none";
  }

  // Find the dock_view and group for a tab/grip element
  function findDockContext(el) {
    var dockId = el.getAttribute("data-dock");
    var groupIdx = parseInt(el.getAttribute("data-group") || el.getAttribute("data-group-index") || "0");
    return { dockId: dockId, groupIdx: groupIdx };
  }

  // Find drop target: a group header tab bar, or an empty area of a dock_view.
  // Returns { dockId, groupIdx, tabIdx, header } for tab drops, or
  // { dockId, newGroup: true, insertAt, dockView } for empty-area drops.
  function findDropTarget(clientX, clientY) {
    // First check group headers (tab bar drops)
    var headers = document.querySelectorAll(".app-dock-group-header");
    for (var i = 0; i < headers.length; i++) {
      var rect = headers[i].getBoundingClientRect();
      if (clientX >= rect.left && clientX <= rect.right &&
          clientY >= rect.top - 8 && clientY <= rect.bottom + 8) {
        var group = headers[i].closest(".app-dock-group");
        var dockId = group ? group.getAttribute("data-dock") : null;
        var groupIdx = group ? parseInt(group.getAttribute("data-group-index") || "0") : 0;
        var tabs = headers[i].querySelectorAll(".app-dock-tab");
        var insertIdx = tabs.length;
        for (var j = 0; j < tabs.length; j++) {
          var tr = tabs[j].getBoundingClientRect();
          if (clientX < tr.left + tr.width / 2) { insertIdx = j; break; }
        }
        return { dockId: dockId, groupIdx: groupIdx, tabIdx: insertIdx, header: headers[i] };
      }
    }
    // Then check dock_view empty areas (between groups or below last group)
    var dockViews = document.querySelectorAll(".app-dock-view");
    for (var d = 0; d < dockViews.length; d++) {
      var dv = dockViews[d];
      var dvRect = dv.getBoundingClientRect();
      if (clientX >= dvRect.left && clientX <= dvRect.right &&
          clientY >= dvRect.top && clientY <= dvRect.bottom) {
        var dockId = dv.id;
        var model = dockModels[dockId];
        if (!model) continue;
        // Find insertion position: check each group's vertical position
        var groups = dv.querySelectorAll(".app-dock-group");
        var insertAt = model.groups.length;
        for (var g = 0; g < groups.length; g++) {
          var gr = groups[g].getBoundingClientRect();
          if (clientY < gr.top + gr.height / 2) { insertAt = g; break; }
        }
        return { dockId: dockId, newGroup: true, insertAt: insertAt, dockView: dv };
      }
    }
    return null;
  }

  // Mousedown on tab buttons or grip handles
  document.addEventListener("mousedown", function (e) {
    var tab = e.target.closest(".app-dock-tab");
    var grip = e.target.closest(".app-dock-grip");
    if (!tab && !grip) return;
    var el = tab || grip;
    panelDrag = {
      type: tab ? "panel" : "group",
      el: el,
      panelName: tab ? tab.getAttribute("data-panel-name") : null,
      context: findDockContext(el),
      ghost: null,
      startX: e.clientX,
      startY: e.clientY,
      started: false
    };
  });

  document.addEventListener("mousemove", function (e) {
    if (!panelDrag) return;
    if (!panelDrag.started && Math.abs(e.clientX - panelDrag.startX) + Math.abs(e.clientY - panelDrag.startY) < 5) return;

    if (!panelDrag.started) {
      panelDrag.started = true;
      var ghost = panelDrag.el.cloneNode(true);
      ghost.style.cssText = "position:fixed;z-index:400;opacity:0.7;pointer-events:none;background:#4a4a4a;color:#ccc;padding:2px 8px;font-size:11px;border:1px solid #666";
      document.body.appendChild(ghost);
      panelDrag.ghost = ghost;
      panelDrag.el.style.opacity = "0.3";
      document.body.style.cursor = "grabbing";
    }

    panelDrag.ghost.style.left = (e.clientX + 8) + "px";
    panelDrag.ghost.style.top = (e.clientY - 10) + "px";

    var target = findDropTarget(e.clientX, e.clientY);
    if (target && target.header) {
      // Tab bar drop: vertical indicator between tabs
      var tabs = target.header.querySelectorAll(".app-dock-tab");
      if (target.tabIdx < tabs.length) {
        var r = tabs[target.tabIdx].getBoundingClientRect();
        showIndicator(r.left - 2, r.top, 3, r.height);
      } else if (tabs.length > 0) {
        var r = tabs[tabs.length - 1].getBoundingClientRect();
        showIndicator(r.right + 1, r.top, 3, r.height);
      }
    } else if (target && target.newGroup) {
      // Empty dock area: horizontal indicator for new group insertion
      var dv = target.dockView;
      var dvRect = dv.getBoundingClientRect();
      var groups = dv.querySelectorAll(".app-dock-group");
      var yPos;
      if (target.insertAt < groups.length) {
        yPos = groups[target.insertAt].getBoundingClientRect().top;
      } else if (groups.length > 0) {
        var lastG = groups[groups.length - 1].getBoundingClientRect();
        yPos = lastG.bottom;
      } else {
        yPos = dvRect.top + 4;
      }
      showIndicator(dvRect.left + 4, yPos - 1, dvRect.width - 8, 3);
    } else {
      hideIndicator();
    }
  });

  document.addEventListener("mouseup", function (e) {
    if (!panelDrag) return;
    var pd = panelDrag;
    panelDrag = null;
    hideIndicator();
    document.body.style.cursor = "";
    if (pd.ghost) { pd.ghost.remove(); pd.el.style.opacity = ""; }
    if (!pd.started) {
      // Click (no drag) on a tab → switch active panel
      if (pd.type === "panel" && pd.context) {
        var m = dockModels[pd.context.dockId];
        if (m && m.groups[pd.context.groupIdx]) {
          var pi = parseInt(pd.el.getAttribute("data-panel-index"), 10);
          if (!isNaN(pi)) {
            m.groups[pd.context.groupIdx].active = pi;
            rerenderDockView(pd.context.dockId);
          }
        }
      }
      return;
    }

    var target = findDropTarget(e.clientX, e.clientY);

    if (!target) {
      // Dropped on empty space → create floating dock
      if (pd.type === "panel" && pd.panelName) {
        var srcModel = dockModels[pd.context.dockId];
        if (srcModel) {
          var srcGroup = srcModel.groups[pd.context.groupIdx];
          if (srcGroup) {
            var idx = srcGroup.panels.indexOf(pd.panelName);
            if (idx >= 0) {
              srcGroup.panels.splice(idx, 1);
              if (srcGroup.active >= srcGroup.panels.length) srcGroup.active = Math.max(0, srcGroup.panels.length - 1);
              if (srcGroup.panels.length === 0) srcModel.groups.splice(pd.context.groupIdx, 1);
              rerenderDockView(pd.context.dockId);
              removeIfEmptyFloating(pd.context.dockId);
              createFloatingDock([{ panels: [pd.panelName], active: 0, collapsed: false }], e.clientX - 110, e.clientY - 10);
            }
          }
        }
      } else if (pd.type === "group") {
        dockDetachGroup(pd.context.dockId, pd.context.groupIdx, e.clientX - 110, e.clientY - 10);
      }
      return;
    }

    // Dropped on a dock target
    if (pd.type === "panel" && pd.panelName) {
      var srcModel = dockModels[pd.context.dockId];
      var tgtModel = dockModels[target.dockId];
      if (!srcModel || !tgtModel) return;

      // Remove from source
      var srcGroup = srcModel.groups[pd.context.groupIdx];
      if (srcGroup) {
        var idx = srcGroup.panels.indexOf(pd.panelName);
        if (idx >= 0) {
          srcGroup.panels.splice(idx, 1);
          if (srcGroup.active >= srcGroup.panels.length) srcGroup.active = Math.max(0, srcGroup.panels.length - 1);
          if (srcGroup.panels.length === 0) srcModel.groups.splice(pd.context.groupIdx, 1);
        }
      }

      if (target.newGroup) {
        // Insert as new panel group at the indicated position
        var newGroup = { panels: [pd.panelName], active: 0, collapsed: false };
        tgtModel.groups.splice(target.insertAt, 0, newGroup);
      } else {
        // Insert into existing group's tab bar
        var tgtGroup = tgtModel.groups[target.groupIdx];
        if (tgtGroup) {
          tgtGroup.panels.splice(target.tabIdx, 0, pd.panelName);
          tgtGroup.active = target.tabIdx;
        }
      }

      rerenderDockView(pd.context.dockId);
      removeIfEmptyFloating(pd.context.dockId);
      if (target.dockId !== pd.context.dockId) rerenderDockView(target.dockId);
    } else if (pd.type === "group" && target.newGroup) {
      // Move entire group to a new position in the target dock
      var srcModel = dockModels[pd.context.dockId];
      var tgtModel = dockModels[target.dockId];
      if (!srcModel || !tgtModel) return;
      if (pd.context.groupIdx < srcModel.groups.length) {
        var group = srcModel.groups.splice(pd.context.groupIdx, 1)[0];
        tgtModel.groups.splice(target.insertAt, 0, group);
        rerenderDockView(pd.context.dockId);
        removeIfEmptyFloating(pd.context.dockId);
        if (target.dockId !== pd.context.dockId) rerenderDockView(target.dockId);
      }
    }
  });

  // ── Wire dock effects into the effects engine ─────────────

  // Patch runEffect to handle dock-specific effects
  var _origRunEffect = runEffect;
  runEffect = function (effect, ctx) {
    if (effect.close_panel) {
      var panel = resolve(effect.close_panel.panel, ctx);
      // Find which dock contains this panel
      for (var dockId in dockModels) {
        var m = dockModels[dockId];
        for (var gi = 0; gi < m.groups.length; gi++) {
          if (m.groups[gi].panels.indexOf(panel) >= 0) {
            dockClosePanel(dockId, panel);
            return;
          }
        }
      }
      return;
    }
    if (effect.show_panel) {
      var panel = resolve(effect.show_panel.panel, ctx);
      var target = resolve(effect.show_panel.target, ctx);
      dockShowPanel(target, panel);
      return;
    }
    if (effect.detach_group) {
      var source = resolve(effect.detach_group.source, ctx);
      var group = parseInt(resolve(effect.detach_group.group, ctx));
      var x = parseFloat(resolve(effect.detach_group.x, ctx));
      var y = parseFloat(resolve(effect.detach_group.y, ctx));
      dockDetachGroup(source, group, x, y);
      return;
    }
    if (effect.redock) {
      var source = resolve(effect.redock.source, ctx);
      var target = resolve(effect.redock.target, ctx);
      dockRedock(source, target);
      return;
    }
    _origRunEffect(effect, ctx);
  };

  // Initialize on DOM ready
  var _origDOMReady = null;
  document.addEventListener("DOMContentLoaded", function () {
    initDockModels();
  });

  // ── Auto-save / restore current workspace ────────────────
  //
  // Persists the live pane layout (positions, dock models, floating
  // docks, layout-state vars, active appearance) to localStorage on
  // every page unload. On the next load, after the dock and pane
  // wiring has finished, apply the snapshot — equivalent to invoking
  // the load_layout effect on a named workspace, except this one is
  // unnamed and tracks the user's working state automatically.
  //
  // Distinct from the explicit "Save Workspace…" feature (which uses
  // STORAGE_KEY = "workspace_layouts") and from the document session
  // save in canvas_bootstrap.mjs (which persists per-tab Models).
  var LIVE_LAYOUT_KEY = "jas_flask_live_layout";

  function snapshotLiveLayout() {
    var configs = typeof APP_PANE_CONFIGS !== "undefined" ? APP_PANE_CONFIGS : {};
    var snapshot = {
      panes: {}, state: {}, dock: {}, floating: [],
      appearance: activeAppearanceName,
    };
    document.querySelectorAll(".app-pane").forEach(function (p) {
      if (!p.id) return;
      snapshot.panes[p.id] = {
        left: p.offsetLeft, top: p.offsetTop,
        width: p.offsetWidth, height: p.offsetHeight,
      };
      var cfg = configs[p.id];
      if (cfg && cfg.layout_state) {
        cfg.layout_state.forEach(function (key) {
          if (state.hasOwnProperty(key)) snapshot.state[key] = state[key];
        });
      }
    });
    for (var dockId in dockModels) {
      if (!dockModels.hasOwnProperty(dockId)) continue;
      if (dockId.indexOf("floating_dock_") === 0) {
        var paneId = dockId.replace("_view", "");
        var paneEl = document.getElementById(paneId);
        snapshot.floating.push({
          dockViewId: dockId,
          groups: dockModels[dockId].groups,
          x: paneEl ? paneEl.offsetLeft : 0,
          y: paneEl ? paneEl.offsetTop : 0,
          width: paneEl ? paneEl.offsetWidth : 220,
          height: paneEl ? paneEl.offsetHeight : 300,
        });
      } else {
        snapshot.dock[dockId] = { groups: dockModels[dockId].groups };
      }
    }
    return snapshot;
  }

  function applyLiveLayout(snapshot) {
    if (!snapshot || typeof snapshot !== "object") return;
    var panes = snapshot.panes || {};
    for (var paneId in panes) {
      if (!panes.hasOwnProperty(paneId)) continue;
      var el = document.getElementById(paneId);
      if (!el) continue;
      var pos = panes[paneId];
      el.style.left = pos.left + "px";
      el.style.top = pos.top + "px";
      el.style.width = pos.width + "px";
      el.style.height = pos.height + "px";
      el.classList.remove("d-none");
    }
    if (snapshot.state) {
      for (var key in snapshot.state) {
        if (snapshot.state.hasOwnProperty(key)) {
          setState(key, snapshot.state[key]);
        }
      }
    }
    if (snapshot.dock) {
      for (var dockId in snapshot.dock) {
        if (!snapshot.dock.hasOwnProperty(dockId)) continue;
        if (dockModels[dockId]) {
          dockModels[dockId].groups = snapshot.dock[dockId].groups;
          rerenderDockView(dockId);
        }
      }
    }
    document.querySelectorAll("[id^='floating_dock_']").forEach(function (el) { el.remove(); });
    for (var dk in dockModels) {
      if (dk.indexOf("floating_dock_") === 0) delete dockModels[dk];
    }
    if (Array.isArray(snapshot.floating)) {
      snapshot.floating.forEach(function (fd) {
        createFloatingDock(fd.groups, fd.x, fd.y);
      });
    }
    if (snapshot.appearance) applyAppearance(snapshot.appearance);
  }

  window.addEventListener("beforeunload", function () {
    try {
      localStorage.setItem(LIVE_LAYOUT_KEY, JSON.stringify(snapshotLiveLayout()));
    } catch (e) { /* QuotaExceededError, security errors — best-effort */ }
  });

  // Defer the restore until after every DOMContentLoaded handler in
  // this IIFE has run (initDockModels populates dockModels, panel
  // bindings get their initial values, etc.). setTimeout 0 hops past
  // the current task — the saved snapshot then lands on a fully-
  // wired DOM.
  document.addEventListener("DOMContentLoaded", function () {
    setTimeout(function () {
      var raw;
      try { raw = localStorage.getItem(LIVE_LAYOUT_KEY); } catch (e) { return; }
      if (!raw) return;
      try { applyLiveLayout(JSON.parse(raw)); }
      catch (e) { console.warn("[live-layout] restore failed:", e); }
    }, 0);
  });

})();


// ── Tree View (layers panel) ──────────────────────────────────
(function () {
  "use strict";

  // Sample document tree for demonstration
  var SAMPLE_TREE = [
    {
      id: "layer1", name: "Layer 1", type: "layer", type_label: "Layer",
      visibility: "preview", locked: false, element_selected: false,
      ancestor_layer_color: "#4a90d9",
      children: [
        {
          id: "group1", name: "", type: "group", type_label: "Group",
          visibility: "preview", locked: false, element_selected: false,
          ancestor_layer_color: "#4a90d9",
          children: [
            {
              id: "path1", name: "", type: "path", type_label: "Path",
              visibility: "preview", locked: false, element_selected: false,
              ancestor_layer_color: "#4a90d9", children: []
            },
            {
              id: "rect1", name: "Background", type: "rect", type_label: "Rectangle",
              visibility: "preview", locked: true, element_selected: false,
              ancestor_layer_color: "#4a90d9", children: []
            },
            {
              id: "text1", name: "Title", type: "text", type_label: "Text",
              visibility: "outline", locked: false, element_selected: true,
              ancestor_layer_color: "#4a90d9", children: []
            }
          ]
        },
        {
          id: "circle1", name: "", type: "circle", type_label: "Circle",
          visibility: "invisible", locked: false, element_selected: false,
          ancestor_layer_color: "#4a90d9", children: []
        }
      ]
    },
    {
      id: "layer2", name: "Layer 2", type: "layer", type_label: "Layer",
      visibility: "preview", locked: false, element_selected: false,
      ancestor_layer_color: "#d94a4a",
      children: [
        {
          id: "line1", name: "", type: "line", type_label: "Line",
          visibility: "preview", locked: false, element_selected: true,
          ancestor_layer_color: "#d94a4a", children: []
        }
      ]
    }
  ];

  // Icon SVG lookup helper
  function iconSvg(name, size) {
    size = size || 16;
    var def = (typeof APP_ICONS !== "undefined") ? APP_ICONS[name] : null;
    if (!def) return '<span style="width:' + size + 'px;height:' + size + 'px;display:inline-block"></span>';
    var vb = def.viewbox || "0 0 16 16";
    return '<svg viewBox="' + vb + '" width="' + size + '" height="' + size + '" style="display:block">' +
           (def.svg || "") + '</svg>';
  }

  // Visibility icon name from state
  function visIcon(vis) {
    if (vis === "outline") return "eye_outline";
    if (vis === "invisible") return "eye_invisible";
    return "eye_preview";
  }

  // State per tree-view instance
  var treeStates = {};

  function getTreeState(container) {
    var id = container.id || "default";
    if (!treeStates[id]) {
      treeStates[id] = {
        panelSelection: [],
        twirls: {},     // id -> bool (true=expanded); missing = expanded
        data: SAMPLE_TREE
      };
    }
    return treeStates[id];
  }

  function isExpanded(ts, id) {
    return ts.twirls[id] !== false;
  }

  function isPanelSelected(ts, id) {
    return ts.panelSelection.indexOf(id) >= 0;
  }

  // Build flat visible row list from tree
  function flattenVisible(nodes, depth, ts) {
    var rows = [];
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      rows.push({ node: node, depth: depth });
      var isContainer = node.children && node.children.length > 0 ||
                        node.type === "layer" || node.type === "group";
      if (isContainer && isExpanded(ts, node.id) && node.children) {
        rows = rows.concat(flattenVisible(node.children, depth + 1, ts));
      }
    }
    return rows;
  }

  // Render one tree row as HTML
  function renderRow(entry, ts) {
    var node = entry.node;
    var depth = entry.depth;
    var isContainer = node.type === "layer" || node.type === "group";
    var selected = isPanelSelected(ts, node.id);

    var indent = '<span style="width:' + (depth * 16) + 'px;flex-shrink:0;display:inline-block"></span>';

    // Eye button
    var eyeIcon = iconSvg(visIcon(node.visibility), 14);
    var eyeBtn = '<button class="tree-btn" data-tree-action="eye" data-node-id="' +
                 node.id + '" title="Visibility">' + eyeIcon + '</button>';

    // Lock button
    var lockName = node.locked ? "lock_locked" : "lock_unlocked";
    var lockIcon = iconSvg(lockName, 14);
    var lockBtn = '<button class="tree-btn" data-tree-action="lock" data-node-id="' +
                  node.id + '" title="Lock">' + lockIcon + '</button>';

    // Twirl button or gap
    var twirlHtml;
    if (isContainer) {
      var twirlName = isExpanded(ts, node.id) ? "twirl_open" : "twirl_closed";
      var twirlIcon = iconSvg(twirlName, 14);
      twirlHtml = '<button class="tree-btn" data-tree-action="twirl" data-node-id="' +
                  node.id + '" title="Expand/Collapse">' + twirlIcon + '</button>';
    } else {
      twirlHtml = '<span class="tree-gap"></span>';
    }

    // Preview placeholder
    var preview = '<div class="app-element-preview" style="width:24px;height:24px;' +
                  'background:#fff;border:1px solid var(--app-border,#555);' +
                  'border-radius:1px;flex-shrink:0"></div>';

    // Name
    var displayName = node.name || ("<" + node.type_label + ">");
    var nameClass = node.name ? "tree-name" : "tree-name unnamed";
    var nameHtml = '<span class="' + nameClass + '" data-tree-action="name" data-node-id="' +
                   node.id + '">' + displayName + '</span>';

    // Select square
    var sqBg = node.element_selected ? node.ancestor_layer_color : "transparent";
    var selectSq = '<div class="select-square" data-tree-action="select" data-node-id="' +
                   node.id + '" style="background:' + sqBg + '"></div>';

    var rowClass = "app-tree-row" + (selected ? " panel-selected" : "");
    return '<div class="' + rowClass + '" data-node-id="' + node.id + '">' +
           indent + eyeBtn + lockBtn + twirlHtml + preview + nameHtml + selectSq +
           '</div>';
  }

  // Full render of tree into container
  function renderTree(container) {
    var ts = getTreeState(container);
    var rows = flattenVisible(ts.data, 0, ts);
    var html = [];
    for (var i = 0; i < rows.length; i++) {
      html.push(renderRow(rows[i], ts));
    }
    container.innerHTML = html.join("");
  }

  // Find a node in the tree by id
  function findNode(nodes, id) {
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) return nodes[i];
      if (nodes[i].children) {
        var found = findNode(nodes[i].children, id);
        if (found) return found;
      }
    }
    return null;
  }

  // Cycle visibility: preview -> outline -> invisible -> preview
  function cycleVisibility(vis) {
    if (vis === "preview") return "outline";
    if (vis === "outline") return "invisible";
    return "preview";
  }

  // Apply visibility recursively to children
  function setVisibilityRecursive(node, vis) {
    node.visibility = vis;
    if (node.children) {
      for (var i = 0; i < node.children.length; i++) {
        setVisibilityRecursive(node.children[i], vis);
      }
    }
  }

  // Handle tree actions via event delegation
  function wireTreeEvents(container) {
    container.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-tree-action]");
      if (!btn) {
        // Click on the row itself — panel select
        var row = e.target.closest(".app-tree-row");
        if (row) {
          var ts = getTreeState(container);
          var nid = row.getAttribute("data-node-id");
          if (e.metaKey || e.ctrlKey) {
            var idx = ts.panelSelection.indexOf(nid);
            if (idx >= 0) ts.panelSelection.splice(idx, 1);
            else ts.panelSelection.push(nid);
          } else {
            ts.panelSelection = [nid];
          }
          renderTree(container);
        }
        return;
      }
      var action = btn.getAttribute("data-tree-action");
      var nodeId = btn.getAttribute("data-node-id");
      var ts = getTreeState(container);
      var node = findNode(ts.data, nodeId);
      if (!node) return;

      if (action === "eye") {
        var newVis = cycleVisibility(node.visibility);
        setVisibilityRecursive(node, newVis);
        renderTree(container);
      } else if (action === "lock") {
        node.locked = !node.locked;
        renderTree(container);
      } else if (action === "twirl") {
        ts.twirls[nodeId] = !isExpanded(ts, nodeId);
        renderTree(container);
      } else if (action === "select") {
        // Element selection via select square
        node.element_selected = !node.element_selected;
        renderTree(container);
      } else if (action === "name") {
        // Panel select on name click
        if (e.metaKey || e.ctrlKey) {
          var idx = ts.panelSelection.indexOf(nodeId);
          if (idx >= 0) ts.panelSelection.splice(idx, 1);
          else ts.panelSelection.push(nodeId);
        } else {
          ts.panelSelection = [nodeId];
        }
        renderTree(container);
      }
    });

    // Keyboard navigation
    container.setAttribute("tabindex", "0");
    container.addEventListener("keydown", function (e) {
      var ts = getTreeState(container);
      var rows = flattenVisible(ts.data, 0, ts);
      if (rows.length === 0) return;

      // Find current focused row index
      var focusId = ts.panelSelection.length > 0 ? ts.panelSelection[ts.panelSelection.length - 1] : null;
      var focusIdx = -1;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].node.id === focusId) { focusIdx = i; break; }
      }

      if (e.key === "ArrowDown") {
        e.preventDefault();
        if (focusIdx < rows.length - 1) {
          ts.panelSelection = [rows[focusIdx + 1].node.id];
          renderTree(container);
        }
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        if (focusIdx > 0) {
          ts.panelSelection = [rows[focusIdx - 1].node.id];
          renderTree(container);
        }
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        if (focusIdx >= 0) {
          var node = rows[focusIdx].node;
          var isContainer = node.type === "layer" || node.type === "group";
          if (isContainer && !isExpanded(ts, node.id)) {
            ts.twirls[node.id] = true;
            renderTree(container);
          } else if (isContainer && node.children && node.children.length > 0) {
            ts.panelSelection = [node.children[0].id];
            renderTree(container);
          }
        }
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        if (focusIdx >= 0) {
          var node = rows[focusIdx].node;
          var isContainer = node.type === "layer" || node.type === "group";
          if (isContainer && isExpanded(ts, node.id)) {
            ts.twirls[node.id] = false;
            renderTree(container);
          }
          // Move to parent not implemented (would need parent tracking)
        }
      } else if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault();
        // Log only in demo mode
        console.log("Delete panel-selected:", ts.panelSelection);
      }
    });
  }

  // Initialize all tree views on the page
  function initTreeViews() {
    document.querySelectorAll('[data-type="tree-view"]').forEach(function (el) {
      renderTree(el);
      wireTreeEvents(el);
    });
  }

  document.addEventListener("DOMContentLoaded", initTreeViews);
})();
