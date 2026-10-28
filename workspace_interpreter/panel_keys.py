"""Panel-key RESOLUTION: a key chord on a focused panel becomes an action.

A panel declares ``keyboard:`` rows (``{key, action, params?, enabled_when?}``)
on the panel itself (artboards.yaml) or on an element inside it (layers.yaml
puts its rows on the tree_view). Resolution is pure: the chord, the panel's
compiled spec and an evaluation context in, ``{action, params}`` or ``None``
out. The host binds its framework event to a chord and dispatches the result;
neither step lives here. Pinned across languages by
``test_fixtures/panel_keys/panel_key_resolution.json`` (STATUS-jas item 8
class L, step 2).

The chord vocabulary is ``shortcuts.yaml``'s: modifiers ``Ctrl`` ``Shift``
``Alt`` ``Meta``, joined by ``+`` before the key. ``Ctrl`` is the platform
command key (a Mac binding maps Command to it), and a single letter matches
upper-cased.
"""

from workspace_interpreter.expr import evaluate, evaluate_text

_MODIFIERS = ("ctrl", "shift", "alt", "meta")
_MODIFIER_TOKENS = {
    "ctrl": "ctrl", "control": "ctrl",
    "shift": "shift",
    "alt": "alt", "option": "alt",
    "meta": "meta", "cmd": "meta", "command": "meta", "super": "meta",
}


def _canon_key(key: str) -> str:
    return key.upper() if len(key) == 1 and key.isascii() and key.isalpha() else key


def parse_key(s: str):
    """A row's key string (``"Ctrl+A"``, ``"ArrowUp"``) as a chord, or ``None``
    for an empty string. Every token but the last is a modifier, matched
    case-insensitively; an unknown modifier is ignored (Rust's
    ``parse_shortcut``)."""
    if not isinstance(s, str) or not s:
        return None
    *mods, key = s.split("+")
    chord = {"key": _canon_key(key), **{m: False for m in _MODIFIERS}}
    for m in mods:
        name = _MODIFIER_TOKENS.get(m.lower())
        if name:
            chord[name] = True
    return chord


def _chord(c: dict) -> dict:
    return {"key": _canon_key(str(c.get("key", ""))),
            **{m: bool(c.get(m, False)) for m in _MODIFIERS}}


def keyboard_rows(node) -> list:
    """Every ``keyboard:`` row under ``node``, at any depth, in document order
    (the panel's own first, then each element's)."""
    rows = []
    if isinstance(node, dict):
        if isinstance(node.get("keyboard"), list):
            rows.extend(node["keyboard"])
        for k, v in node.items():
            if k != "keyboard":
                rows.extend(keyboard_rows(v))
    elif isinstance(node, list):
        for v in node:
            rows.extend(keyboard_rows(v))
    return rows


def _param(v, ctx: dict):
    """A row param by the ``dispatch`` effect's rule: a non-string is itself; a
    string is an expression, except that a BARE identifier reading null is its
    own name."""
    from workspace_interpreter.effects import _stored
    if not isinstance(v, str):
        return v
    value = _stored(evaluate(v, ctx))
    if value is None and v and all(c.isalnum() or c == "_" for c in v):
        return v
    return value


def resolve_panel_key(panel: dict, chord: dict, ctx: dict):
    """The first row of ``panel`` whose key is ``chord`` and whose
    ``enabled_when`` (if any) holds in ``ctx``, as ``{action, params}``; ``None``
    when no row matches. A ``{{...}}`` action name is evaluated in ``ctx``."""
    want = _chord(chord)
    for row in keyboard_rows(panel):
        if not isinstance(row, dict) or parse_key(row.get("key")) != want:
            continue
        cond = row.get("enabled_when")
        if isinstance(cond, str) and cond and not evaluate(cond, ctx).to_bool():
            continue
        action = row.get("action")
        if not isinstance(action, str) or not action:
            continue
        action = evaluate_text(action, ctx) if "{{" in action else action
        params = {k: _param(v, ctx) for k, v in (row.get("params") or {}).items()}
        return {"action": action, "params": params}
    return None
