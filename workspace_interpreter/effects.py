"""Effects interpreter for the workspace YAML schema.

Executes effect lists from actions and behaviors. Each effect is a
dict with a single key identifying the effect type. Pure Python,
no Qt dependency.
"""

from __future__ import annotations

from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore


def run_effects(effects: list, ctx: dict, store: StateStore,
                actions: dict | None = None,
                platform_effects: dict | None = None,
                dialogs: dict | None = None):
    """Execute a list of effects.

    Args:
        effects: List of effect dicts.
        ctx: Additional evaluation context (params, event, etc.).
        store: The state store to read from and mutate.
        actions: The actions catalog for dispatch effects.
        platform_effects: Registry of platform-specific effect handlers
            keyed by effect name. Each handler receives (effect_data, ctx, store).
        dialogs: Dialog definitions dict for open_dialog effects.
    """
    if not effects:
        return
    for effect in effects:
        if isinstance(effect, dict):
            _run_one(effect, ctx, store, actions, platform_effects, dialogs)


def _eval(expr, store: StateStore, ctx: dict):
    """Evaluate an expression against the store's current state + ctx."""
    eval_ctx = store.eval_context(ctx)
    result = evaluate(str(expr) if expr is not None else "", eval_ctx)
    return result.value


def _run_one(effect: dict, ctx: dict, store: StateStore,
             actions: dict | None, platform_effects: dict | None,
             dialogs: dict | None):

    # set: { key: expr, ... }
    if "set" in effect:
        for key, expr in effect["set"].items():
            value = _eval(expr, store, ctx)
            store.set(key, value)
        return

    # toggle: state_key_name
    if "toggle" in effect:
        key = effect["toggle"]
        # Support text-context interpolation for constructed keys
        if "{{" in str(key):
            from workspace_interpreter.expr import evaluate_text
            key = evaluate_text(str(key), store.eval_context(ctx))
        store.set(key, not store.get(key))
        return

    # swap: [key_a, key_b]
    if "swap" in effect:
        keys = effect["swap"]
        if len(keys) == 2:
            a_val = store.get(keys[0])
            b_val = store.get(keys[1])
            store.set(keys[0], b_val)
            store.set(keys[1], a_val)
        return

    # increment: { key, by }
    if "increment" in effect:
        key = effect["increment"]["key"]
        by = effect["increment"].get("by", 1)
        store.set(key, (store.get(key) or 0) + by)
        return

    # decrement: { key, by }
    if "decrement" in effect:
        key = effect["decrement"]["key"]
        by = effect["decrement"].get("by", 1)
        store.set(key, (store.get(key) or 0) - by)
        return

    # reset: [keys]
    if "reset" in effect:
        # Would need access to original defaults — skip for now
        return

    # if: { condition, then, else }
    if "if" in effect:
        cond = effect["if"]
        cond_expr = cond.get("condition", "false")
        eval_ctx = store.eval_context(ctx)
        result = evaluate(str(cond_expr), eval_ctx)
        if result.to_bool():
            run_effects(cond.get("then", []), ctx, store, actions, platform_effects, dialogs)
        elif "else" in cond:
            run_effects(cond["else"], ctx, store, actions, platform_effects, dialogs)
        return

    # set_panel_state: { key, value, panel? }
    if "set_panel_state" in effect:
        sps = effect["set_panel_state"]
        key = sps.get("key", "")
        value = _eval(sps.get("value", "null"), store, ctx)
        panel_id = sps.get("panel") or store.get_active_panel_id()
        if panel_id:
            store.set_panel(panel_id, key, value)
        return

    # list_push: { target, value, unique, max_length }
    if "list_push" in effect:
        lp = effect["list_push"]
        target = lp.get("target", "")
        parts = target.split(".", 1)
        value = _eval(lp.get("value", "null"), store, ctx)
        unique = lp.get("unique", False)
        max_length = lp.get("max_length")
        if len(parts) == 2 and parts[0] == "panel":
            panel_id = store.get_active_panel_id()
            if panel_id:
                store.list_push(panel_id, parts[1], value,
                               unique=unique, max_length=max_length)
        return

    # dispatch: action_name or { action, params }
    if "dispatch" in effect:
        d = effect["dispatch"]
        if isinstance(d, str):
            action_name = d
            params = {}
        else:
            action_name = d.get("action", "")
            params = d.get("params", {})
        if actions and action_name in actions:
            action_def = actions[action_name]
            action_effects = action_def.get("effects", [])
            dispatch_ctx = dict(ctx)
            if params:
                resolved_params = {}
                for k, v in params.items():
                    resolved_params[k] = _eval(v, store, ctx)
                dispatch_ctx["param"] = resolved_params
            run_effects(action_effects, dispatch_ctx, store, actions, platform_effects, dialogs)
        return

    # open_dialog: { id, params }
    if "open_dialog" in effect:
        od = effect["open_dialog"]
        dlg_id = od.get("id", "") if isinstance(od, dict) else str(od)
        if not dialogs or dlg_id not in dialogs:
            return
        dlg_def = dialogs[dlg_id]
        # Extract state defaults
        defaults = {}
        state_defs = dlg_def.get("state", {})
        if isinstance(state_defs, dict):
            for key, defn in state_defs.items():
                if isinstance(defn, dict):
                    defaults[key] = defn.get("default")
                else:
                    defaults[key] = defn
        # Resolve params
        resolved_params = {}
        raw_params = od.get("params", {}) if isinstance(od, dict) else {}
        for k, v in raw_params.items():
            resolved_params[k] = _eval(v, store, ctx)
        # Init dialog state with defaults and params
        store.init_dialog(dlg_id, defaults, params=resolved_params or None)
        # Evaluate init expressions (order matters — later inits may reference earlier ones)
        init_map = dlg_def.get("init", {})
        if isinstance(init_map, dict):
            for key, expr in init_map.items():
                value = _eval(expr, store, ctx)
                store.set_dialog(key, value)
        return

    # close_dialog: null or dialog_id
    if "close_dialog" in effect:
        store.close_dialog()
        return

    # log: message (no-op in interpreter, just print for debug)
    if "log" in effect:
        return

    # Platform-specific effects — delegate to registered handlers
    if platform_effects:
        for key in effect:
            handler = platform_effects.get(key)
            if handler:
                handler(effect[key], ctx, store)
                return
