"""Pure key-chord -> action resolution (TESTING_STRATEGY.md §5 rec 3).

A keyboard shortcut becomes an application command in two steps:
  1. BINDING — the framework key event (Qt ``QKeyEvent``, and its peers
     in the other apps) is normalized into a framework-neutral chord. This
     is platform-specific and stays on the MANUAL floor.
  2. RESOLUTION — the chord is looked up against the compiled bundle
     ``shortcuts`` table (workspace/shortcuts.yaml) to yield an action verb
     and its params. This step is PURE and framework-free, and is the
     refactor target of §5 rec 3: it is pinned cross-language by the key
     corpus in ``cross_language_test.py`` so all four apps resolve a chord
     to byte-identical ``{action, params}``.

``shortcuts`` is the single authoritative key->action table; it carries both
menu actions (``Ctrl+N`` -> ``new_document``) and tool selections (``V`` ->
``select_tool {tool: selection}``), already disambiguated (no duplicate
chords). Resolution is therefore a first-match lookup — the list order is a
deterministic tie-break that the present table never exercises.

This module is the Python mirror of the reference
``jas_dioxus/src/workspace/resolve_key.rs``. The pure functions here are
exercised today by the key-resolution corpus and get wired into this app's
live keyboard path in Phase 2 of §5 rec 3.
"""

from __future__ import annotations

from typing import Optional


def canon_key(key: str) -> str:
    """Canonicalize a key token.

    A single ASCII letter is uppercased (``"v"`` -> ``"V"``); every other
    token (digit, symbol, named key) is returned verbatim. This makes the
    chord comparison case-insensitive for letters while leaving ``"Delete"``,
    ``"="``, ``"\\\\"`` untouched.
    """
    if len(key) == 1 and key.isascii() and key.isalpha():
        return key.upper()
    return key


def make_chord(
    key: str,
    ctrl: bool = False,
    shift: bool = False,
    alt: bool = False,
    meta: bool = False,
) -> dict:
    """Build a normalized chord dict, canonicalizing the key token.

    ``shift`` is carried as a SEPARATE flag and is never folded into the
    character. Missing modifiers default to ``False``.
    """
    return {
        "key": canon_key(key),
        "ctrl": bool(ctrl),
        "shift": bool(shift),
        "alt": bool(alt),
        "meta": bool(meta),
    }


def parse_shortcut(s: str) -> Optional[dict]:
    """Parse a bundle shortcut string into a normalized chord dict.

    Examples: ``"Ctrl+Shift+S"``, ``"V"``, ``"Shift+E"``, ``"Delete"``,
    ``"\\\\"``. Tokens are split on ``+``; all but the last are modifiers
    (matched case-insensitively: ``Ctrl``/``Control``, ``Shift``,
    ``Alt``/``Option``, ``Meta``/``Cmd``/``Command``/``Super``), and the last
    token is the key. Returns ``None`` for an empty string. (No shortcut in
    the table uses ``+`` as its key, so splitting on ``+`` is unambiguous
    here.)
    """
    if not s:
        return None
    tokens = s.split("+")
    key_tok = tokens[-1]
    mod_toks = tokens[:-1]
    ctrl = shift = alt = meta = False
    for m in mod_toks:
        low = m.lower()
        if low in ("ctrl", "control"):
            ctrl = True
        elif low == "shift":
            shift = True
        elif low in ("alt", "option"):
            alt = True
        elif low in ("meta", "cmd", "command", "super"):
            meta = True
        # Unknown modifier token: ignore (keeps parsing total).
    return make_chord(key_tok, ctrl, shift, alt, meta)


def _chord_eq(a: dict, b: dict) -> bool:
    """Structural equality over the five chord fields."""
    return (
        a["key"] == b["key"]
        and a["ctrl"] == b["ctrl"]
        and a["shift"] == b["shift"]
        and a["alt"] == b["alt"]
        and a["meta"] == b["meta"]
    )


def resolve_key_in(chord: dict, shortcuts: list) -> Optional[dict]:
    """Resolve a chord against an explicit ``shortcuts`` array (the testable
    core, so the corpus can resolve every case against one loaded bundle).

    Returns the first entry whose parsed chord equals ``chord`` as
    ``{"action": str, "params": dict}`` (``params`` defaults to ``{}`` when
    absent), or ``None`` if unmapped.
    """
    for entry in shortcuts:
        if not isinstance(entry, dict):
            continue
        key = entry.get("key")
        if not isinstance(key, str):
            continue
        parsed = parse_shortcut(key)
        if parsed is None:
            continue
        if _chord_eq(parsed, chord):
            action = entry.get("action")
            if not isinstance(action, str):
                action = ""
            params = entry.get("params")
            if not isinstance(params, dict):
                params = {}
            return {"action": action, "params": params}
    return None


def _load_shortcuts() -> list:
    """Load the compiled bundle ``shortcuts`` array via the SAME accessor the
    menu uses to read ``menubar`` (panels.yaml_menu.get_workspace_data).
    Returns an empty list if the bundle is missing/corrupt.
    """
    from panels.yaml_menu import get_workspace_data

    ws = get_workspace_data()
    if not ws:
        return []
    shortcuts = ws.get("shortcuts")
    if not isinstance(shortcuts, list):
        return []
    return shortcuts


def resolve_key(chord: dict) -> Optional[dict]:
    """Resolve a chord against the compiled bundle ``shortcuts`` table.

    Returns the first entry whose parsed chord equals ``chord`` as
    ``{"action", "params"}``, or ``None`` if unmapped. The bundle is loaded
    through the same path the menu uses for ``menubar``.
    """
    return resolve_key_in(chord, _load_shortcuts())
