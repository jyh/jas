"""Reactive state store for the workspace interpreter.

Pure Python, no Qt dependency. Uses callback-based notifications.
Platform-specific bindings (Qt signals, Dioxus signals, etc.) connect
to the subscribe mechanism.
"""

from __future__ import annotations
import copy
import logging
from typing import Callable

# ── Artboard invariants (ARTBOARDS.md §At-least-one-artboard invariant) ──

_ARTBOARD_ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
_ARTBOARD_ID_LENGTH = 8


def _generate_artboard_id(rng=None) -> str:
    """Mint an 8-char base36 id. Pass a seeded ``random.Random`` for
    deterministic tests; default is cryptographically random."""
    import random
    import secrets
    if rng is None:
        rng = random.Random(secrets.randbits(128))
    return "".join(rng.choices(_ARTBOARD_ID_ALPHABET, k=_ARTBOARD_ID_LENGTH))


def _default_artboard(artboard_id: str, name: str = "Artboard 1") -> dict:
    """Return the canonical default artboard: Letter 612x792 at origin,
    transparent fill, all display toggles off."""
    return {
        "id": artboard_id,
        "name": name,
        "x": 0,
        "y": 0,
        "width": 612,
        "height": 792,
        "fill": "transparent",
        "show_center_mark": False,
        "show_cross_hairs": False,
        "show_video_safe_areas": False,
        "video_ruler_pixel_aspect_ratio": 1.0,
    }


def next_artboard_name(artboards: list) -> str:
    """Pick ``Artboard N`` with the smallest N not currently used as a
    default-pattern name. Case-sensitive match on ``^Artboard \\d+$``
    with exactly one space (ARTBOARDS.md §Numbering and naming)."""
    import re
    used: set[int] = set()
    for a in artboards:
        if not isinstance(a, dict):
            continue
        name = a.get("name", "")
        if isinstance(name, str):
            m = re.match(r'^Artboard (\d+)$', name)
            if m:
                used.add(int(m.group(1)))
    n = 1
    while n in used:
        n += 1
    return f"Artboard {n}"


def ensure_artboards_invariant(document: dict, id_generator=None) -> bool:
    """Mutate ``document`` in-place to enforce ``artboards.length >= 1``
    and populate ``artboard_options`` defaults. Returns True when a
    default artboard was inserted — callers emit the log line.

    ``id_generator`` is a zero-arg callable returning a fresh id string;
    tests pass a seeded generator for determinism."""
    gen = id_generator if id_generator is not None else _generate_artboard_id
    repaired = False
    artboards = document.get("artboards")
    if not isinstance(artboards, list) or len(artboards) == 0:
        document["artboards"] = [_default_artboard(gen())]
        repaired = True
    options = document.get("artboard_options")
    if not isinstance(options, dict):
        options = {}
        document["artboard_options"] = options
    options.setdefault("fade_region_outside_artboard", True)
    options.setdefault("update_while_dragging", True)
    return repaired


class StateStore:
    """Manages global state, panel-scoped state, and reactive subscriptions."""

    def __init__(self, defaults: dict | None = None, document: dict | None = None,
                 artboard_id_generator=None):
        self._state: dict = dict(defaults) if defaults else {}
        self._panels: dict[str, dict] = {}
        self._active_panel: str | None = None
        self._dialog: dict = {}
        self._dialog_id: str | None = None
        self._dialog_params: dict | None = None
        self._dialog_props: dict = {}  # {key: {"get": expr, "set": expr}}
        # Captured original values of state keys named in the open
        # dialog's preview_targets. Restored on close_dialog (via the
        # close_dialog effect) unless first cleared by the
        # clear_dialog_snapshot effect (used by OK actions).
        self._dialog_snapshot: dict | None = None
        self._subscribers: list[tuple[set | None, Callable]] = []
        self._panel_subscribers: dict[str, list[Callable]] = {}
        # Phase 3: optional document tree for doc.set / snapshot effects.
        # Shape: {"layers": [<element>, ...], "artboards": [<artboard>, ...],
        # "artboard_options": {...}}. Real apps use a native Model; tests
        # use plain dicts.
        self._document: dict | None = document
        # Random-like rng (has .choices()) used for artboard id generation.
        # ensure_artboards_invariant expects a zero-arg callable, so wrap.
        self._artboard_id_rng = artboard_id_generator
        if self._document is not None:
            id_fn = lambda: _generate_artboard_id(self._artboard_id_rng)
            repaired = ensure_artboards_invariant(
                self._document, id_generator=id_fn,
            )
            if repaired:
                logging.getLogger("workspace_interpreter").info(
                    "Document had no artboards; inserted default."
                )
        self._snapshots: list[dict] = []

    # ── Global state ─────────────────────────────────────────

    def get(self, key: str):
        return self._state.get(key)

    def set(self, key: str, value):
        old = self._state.get(key)
        if old is value or old == value:
            return
        self._state[key] = value
        self._notify(key, value)

    def get_all(self) -> dict:
        return dict(self._state)

    # ── Panel state ──────────────────────────────────────────

    def init_panel(self, panel_id: str, defaults: dict):
        """Initialize a panel's state scope with defaults."""
        self._panels[panel_id] = dict(defaults)

    def get_panel(self, panel_id: str, key: str):
        scope = self._panels.get(panel_id)
        if scope is None:
            return None
        return scope.get(key)

    def set_panel(self, panel_id: str, key: str, value):
        scope = self._panels.get(panel_id)
        if scope is None:
            return
        old = scope.get(key)
        if old is value or old == value:
            return
        scope[key] = value
        self._notify_panel(panel_id, key, value)

    def get_panel_state(self, panel_id: str) -> dict:
        return dict(self._panels.get(panel_id, {}))

    def set_active_panel(self, panel_id: str | None):
        self._active_panel = panel_id

    def get_active_panel_id(self) -> str | None:
        return self._active_panel

    def get_active_panel_state(self) -> dict:
        if self._active_panel is None:
            return {}
        return dict(self._panels.get(self._active_panel, {}))

    def destroy_panel(self, panel_id: str):
        self._panels.pop(panel_id, None)
        self._panel_subscribers.pop(panel_id, None)
        if self._active_panel == panel_id:
            self._active_panel = None

    # ── Dialog state ───────────────────────────────────────────

    def init_dialog(self, dialog_id: str, defaults: dict,
                    params: dict | None = None,
                    props: dict | None = None):
        """Initialize dialog-local state. Replaces any previous dialog.

        Args:
            defaults: Initial stored values for plain variables.
            params: Parameters passed when opening the dialog.
            props: Property definitions {key: {"get": expr, "set": expr}}.
                   Variables with "get" are computed on read from sibling state.
                   Variables with "set" run a lambda on write to update targets.
        """
        self._dialog_id = dialog_id
        self._dialog = dict(defaults)
        self._dialog_params = dict(params) if params else None
        self._dialog_props = dict(props) if props else {}

    def get_dialog(self, key: str):
        if self._dialog_id is None:
            return None
        prop = self._dialog_props.get(key)
        if prop and "get" in prop:
            from workspace_interpreter.expr import evaluate
            # Build local scope: all sibling state vars by bare name
            local = dict(self._dialog)
            result = evaluate(prop["get"], local)
            return result.value
        return self._dialog.get(key)

    def set_dialog(self, key: str, value):
        if self._dialog_id is None:
            return
        prop = self._dialog_props.get(key)
        if prop and "set" in prop:
            from workspace_interpreter.expr import evaluate
            from workspace_interpreter.expr_types import Value, ValueType
            # Parse the setter as a lambda and apply with the value
            local = dict(self._dialog)
            # Store callback: assignments in the setter write to dialog state
            def store_cb(target, val):
                self._dialog[target] = val.value
            local["__store_cb__"] = store_cb
            # Evaluate the setter lambda
            setter_val = evaluate(prop["set"], local)
            if setter_val.type == ValueType.CLOSURE:
                params, body, captured = setter_val.value
                if len(params) == 1:
                    from workspace_interpreter.expr_eval import eval_node
                    call_ctx = dict(captured)
                    call_ctx.update(local)
                    call_ctx[params[0]] = value
                    eval_node(body, call_ctx)
            return
        if prop and "get" in prop and "set" not in prop:
            return  # read-only — ignore writes
        self._dialog[key] = value

    def get_dialog_state(self) -> dict:
        return dict(self._dialog)

    def get_dialog_id(self) -> str | None:
        return self._dialog_id

    def get_dialog_params(self) -> dict | None:
        return self._dialog_params

    def close_dialog(self):
        self._dialog_id = None
        self._dialog = {}
        self._dialog_params = None
        self._dialog_props = {}

    # ── Dialog preview snapshot/restore (Phase 0) ──────────────

    def capture_dialog_snapshot(self, targets: dict):
        """Capture the current value of every state key referenced by
        a dialog's preview_targets. Phase 0 supports only top-level
        state keys (no dots in the path); deep paths are silently
        skipped and will land alongside their first real consumer in
        Phase 8/9. `targets` maps dialog_state_key -> state_key."""
        snap = {}
        for state_key in targets.values():
            if "." not in state_key:
                snap[state_key] = self._state.get(state_key)
        self._dialog_snapshot = snap

    def get_dialog_snapshot(self) -> dict | None:
        return self._dialog_snapshot

    def clear_dialog_snapshot(self):
        self._dialog_snapshot = None

    def has_dialog_snapshot(self) -> bool:
        return self._dialog_snapshot is not None

    # ── List operations ──────────────────────────────────────

    def list_push(self, panel_id: str, key: str, value,
                  unique: bool = False, max_length: int | None = None):
        """Push a value to the front of a list in panel state."""
        scope = self._panels.get(panel_id)
        if scope is None:
            return
        lst = scope.get(key)
        if not isinstance(lst, list):
            lst = []
        lst = list(lst)  # copy
        if unique and value in lst:
            lst.remove(value)
        lst.insert(0, value)
        if max_length is not None and len(lst) > max_length:
            lst = lst[:max_length]
        scope[key] = lst
        self._notify_panel(panel_id, key, lst)

    # ── Subscriptions ────────────────────────────────────────

    def subscribe(self, keys: list[str] | None, callback: Callable):
        """Subscribe to global state changes.

        If keys is None, callback fires for any key change.
        callback receives (key, new_value).
        """
        key_set = set(keys) if keys is not None else None
        self._subscribers.append((key_set, callback))

    def subscribe_panel(self, panel_id: str, callback: Callable):
        """Subscribe to panel state changes. callback receives (key, new_value)."""
        self._panel_subscribers.setdefault(panel_id, []).append(callback)

    def _notify(self, key: str, value):
        for key_set, callback in self._subscribers:
            if key_set is None or key in key_set:
                callback(key, value)

    def _notify_panel(self, panel_id: str, key: str, value):
        for callback in self._panel_subscribers.get(panel_id, []):
            callback(key, value)

    # ── Document (Phase 3) ───────────────────────────────────

    def document(self) -> dict | None:
        """Return the live document tree, or None."""
        return self._document

    def snapshot(self) -> None:
        """Deep-copy the current document into the snapshots stack.
        No-op when there is no document."""
        if self._document is not None:
            self._snapshots.append(copy.deepcopy(self._document))

    def snapshots(self) -> list[dict]:
        """Return the snapshots list (for tests / inspection)."""
        return self._snapshots

    def get_element(self, path: tuple[int, ...]) -> dict | None:
        """Resolve a path tuple to an element dict. None if invalid."""
        if self._document is None:
            return None
        layers = self._document.get("layers")
        if not isinstance(layers, list):
            return None
        if len(path) == 0:
            # Root path refers to the document itself
            return self._document
        if path[0] < 0 or path[0] >= len(layers):
            return None
        elem = layers[path[0]]
        for idx in path[1:]:
            children = elem.get("children") if isinstance(elem, dict) else None
            if not isinstance(children, list) or idx < 0 or idx >= len(children):
                return None
            elem = children[idx]
        return elem

    def clone_element_at(self, path: tuple[int, ...]):
        """Deep-copy the element at path. Returns the clone, or None."""
        elem = self.get_element(path)
        if elem is None:
            return None
        return copy.deepcopy(elem)

    def insert_after(self, path: tuple[int, ...], element) -> bool:
        """Insert element at index path[-1]+1 under the parent of path."""
        if self._document is None or len(path) == 0:
            return False
        if len(path) == 1:
            layers = self._document.get("layers")
            if not isinstance(layers, list):
                return False
            insert_idx = min(path[0] + 1, len(layers))
            layers.insert(insert_idx, element)
            return True
        parent = self.get_element(path[:-1])
        if parent is None or not isinstance(parent, dict):
            return False
        children = parent.setdefault("children", [])
        if not isinstance(children, list):
            return False
        insert_idx = min(path[-1] + 1, len(children))
        children.insert(insert_idx, element)
        return True

    def insert_at(self, parent_path: tuple[int, ...], index: int, element) -> bool:
        """Insert element at parent_path[index]."""
        if self._document is None:
            return False
        if len(parent_path) == 0:
            # Parent is the document root; insert into top-level layers
            layers = self._document.setdefault("layers", [])
            if not isinstance(layers, list):
                return False
            index = max(0, min(index, len(layers)))
            layers.insert(index, element)
            return True
        parent = self.get_element(parent_path)
        if parent is None or not isinstance(parent, dict):
            return False
        children = parent.setdefault("children", [])
        if not isinstance(children, list):
            return False
        index = max(0, min(index, len(children)))
        children.insert(index, element)
        return True

    def delete_element_at(self, path: tuple[int, ...]):
        """Delete the element at path. Returns the deleted element, or None."""
        if self._document is None or len(path) == 0:
            return None
        layers = self._document.get("layers")
        if not isinstance(layers, list):
            return None
        if len(path) == 1:
            idx = path[0]
            if idx < 0 or idx >= len(layers):
                return None
            return layers.pop(idx)
        # Nested: walk to parent, then pop child
        parent = self.get_element(path[:-1])
        if parent is None or not isinstance(parent, dict):
            return None
        children = parent.get("children")
        if not isinstance(children, list):
            return None
        last = path[-1]
        if last < 0 or last >= len(children):
            return None
        return children.pop(last)

    # ── Artboards ────────────────────────────────────────────

    def create_artboard(self, overrides: dict | None = None) -> dict | None:
        """Append a new artboard to ``document.artboards``.

        A fresh 8-char base36 id is minted; on (astronomically unlikely)
        collision the id generator is retried up to 100 times. Name
        defaults to the next unused ``Artboard N`` if not supplied in
        overrides. Field overrides map 1:1 onto artboard fields (``x``,
        ``y``, ``width``, ``height``, ``fill``, display toggles).

        Returns the new artboard dict (live reference inside the
        document), or None when there is no document."""
        if self._document is None:
            return None
        artboards = self._document.setdefault("artboards", [])
        if not isinstance(artboards, list):
            return None
        existing_ids = {a.get("id") for a in artboards if isinstance(a, dict)}
        aid = None
        for _ in range(100):
            candidate = _generate_artboard_id(self._artboard_id_rng)
            if candidate not in existing_ids:
                aid = candidate
                break
        if aid is None:
            return None
        overrides = overrides or {}
        name = overrides.get("name")
        if not isinstance(name, str) or not name.strip():
            name = next_artboard_name(artboards)
        artboard = _default_artboard(aid, name)
        for k, v in overrides.items():
            if k == "name":
                continue
            if k in artboard:
                artboard[k] = v
        artboards.append(artboard)
        return artboard

    def find_artboard_by_id(self, artboard_id: str) -> dict | None:
        """Return the live artboard dict with this id, or None."""
        if self._document is None:
            return None
        artboards = self._document.get("artboards")
        if not isinstance(artboards, list):
            return None
        for a in artboards:
            if isinstance(a, dict) and a.get("id") == artboard_id:
                return a
        return None

    def delete_artboard_by_id(self, artboard_id: str) -> dict | None:
        """Remove the artboard with this id from the list. Returns
        the deleted dict, or None if not found. Callers enforce the
        at-least-one-artboard invariant (via enabled_when predicates
        in the panel yaml)."""
        if self._document is None:
            return None
        artboards = self._document.get("artboards")
        if not isinstance(artboards, list):
            return None
        for i, a in enumerate(artboards):
            if isinstance(a, dict) and a.get("id") == artboard_id:
                return artboards.pop(i)
        return None

    def set_artboard_field(self, artboard_id: str, field: str, value) -> bool:
        """Write value to the named field of the artboard with this id.
        Returns True on success, False if the artboard wasn't found."""
        ab = self.find_artboard_by_id(artboard_id)
        if ab is None:
            return False
        ab[field] = value
        return True

    def move_artboards_up(self, selected_ids: list) -> bool:
        """Apply the swap-with-neighbor-skipping-selected rule for
        Move Up (ARTBOARDS.md §Reordering). Iterate top-to-bottom;
        each selected row swaps with the row above it, skipping rows
        whose upper neighbor is itself selected or which are already
        at position 1. Returns True if any swap occurred."""
        if self._document is None:
            return False
        artboards = self._document.get("artboards")
        if not isinstance(artboards, list):
            return False
        selected_set = {s for s in selected_ids if isinstance(s, str)}
        changed = False
        for i in range(len(artboards)):
            elem = artboards[i]
            if not isinstance(elem, dict):
                continue
            if elem.get("id") not in selected_set:
                continue
            if i == 0:
                continue
            above = artboards[i - 1]
            if not isinstance(above, dict):
                continue
            if above.get("id") in selected_set:
                continue
            artboards[i - 1], artboards[i] = artboards[i], artboards[i - 1]
            changed = True
        return changed

    def move_artboards_down(self, selected_ids: list) -> bool:
        """Symmetric to Move Up. Iterate bottom-to-top; each selected
        row swaps with the row below it, skipping rows whose lower
        neighbor is itself selected or which are already at the
        bottom. Returns True if any swap occurred."""
        if self._document is None:
            return False
        artboards = self._document.get("artboards")
        if not isinstance(artboards, list):
            return False
        selected_set = {s for s in selected_ids if isinstance(s, str)}
        changed = False
        for i in range(len(artboards) - 1, -1, -1):
            elem = artboards[i]
            if not isinstance(elem, dict):
                continue
            if elem.get("id") not in selected_set:
                continue
            if i == len(artboards) - 1:
                continue
            below = artboards[i + 1]
            if not isinstance(below, dict):
                continue
            if below.get("id") in selected_set:
                continue
            artboards[i], artboards[i + 1] = artboards[i + 1], artboards[i]
            changed = True
        return changed

    def duplicate_artboard(
        self, artboard_id: str, offset_x: float = 20, offset_y: float = 20
    ) -> dict | None:
        """Deep-copy the artboard with this id, mint a fresh id, pick
        the next unused ``Artboard N`` name, offset position by
        ``(offset_x, offset_y)`` pt, and append to
        ``document.artboards``. Returns the new artboard, or None if
        the source wasn't found or there is no document.

        Contained-element copying is not implemented here — the
        artboard-only copy is correct for the Flask phase-1 surface,
        which has no element model. Native ports that carry elements
        can override this method."""
        source = self.find_artboard_by_id(artboard_id)
        if source is None or self._document is None:
            return None
        artboards = self._document.setdefault("artboards", [])
        if not isinstance(artboards, list):
            return None
        existing_ids = {a.get("id") for a in artboards if isinstance(a, dict)}
        aid: str | None = None
        for _ in range(100):
            candidate = _generate_artboard_id(self._artboard_id_rng)
            if candidate not in existing_ids:
                aid = candidate
                break
        if aid is None:
            return None
        dup = copy.deepcopy(source)
        dup["id"] = aid
        dup["name"] = next_artboard_name(artboards)
        dup["x"] = dup.get("x", 0) + offset_x
        dup["y"] = dup.get("y", 0) + offset_y
        artboards.append(dup)
        return dup

    def set_element_field(self, path: tuple[int, ...], dotted_field: str, value) -> bool:
        """Write value to the element at path under dotted_field.
        Creates intermediate dicts as needed. Returns True on success."""
        elem = self.get_element(path)
        if elem is None or not isinstance(elem, dict):
            return False
        keys = dotted_field.split(".")
        for k in keys[:-1]:
            if k not in elem or not isinstance(elem[k], dict):
                elem[k] = {}
            elem = elem[k]
        elem[keys[-1]] = value
        return True

    # ── Context for expression evaluation ────────────────────

    def eval_context(self, extra: dict | None = None) -> dict:
        """Build an evaluation context dict for the expression evaluator.

        Returns {"state": {...}, "panel": {...}, "active_document": {...}, ...}.
        When a dialog is open, also includes "dialog" and "param" keys.
        """
        ctx = {"state": dict(self._state)}
        if self._active_panel and self._active_panel in self._panels:
            ctx["panel"] = dict(self._panels[self._active_panel])
        else:
            ctx["panel"] = {}
        if self._dialog_id is not None:
            ctx["dialog"] = dict(self._dialog)
            if self._dialog_params is not None:
                ctx["param"] = dict(self._dialog_params)
        ctx["active_document"] = self._active_document_view()
        if extra:
            ctx.update(extra)
        return ctx

    def _active_document_view(self) -> dict:
        """Build the active_document namespace from the document tree.
        Includes top_level_layers and top_level_layer_paths (Phase 3 §7.2).
        Also exposes computed properties for new_layer: next_layer_name and
        new_layer_insert_index — derived from current layers + panel state.
        Artboard fields (ARTBOARDS.md): artboards, artboard_options,
        artboards_count, next_artboard_name, current_artboard_id,
        artboards_panel_selection_ids.
        """
        from workspace_interpreter.expr_types import Value
        canvas_sel = self._canvas_selection_paths()
        has_selection = len(canvas_sel) > 0
        selection_count = len(canvas_sel)
        element_selection = [Value.path(p) for p in canvas_sel]
        # Artboard-view computation (works whether document is None or not)
        if self._document is None:
            raw_artboards: list = []
            raw_options: dict = {}
        else:
            raw_ab = self._document.get("artboards")
            raw_artboards = raw_ab if isinstance(raw_ab, list) else []
            raw_opt = self._document.get("artboard_options")
            raw_options = raw_opt if isinstance(raw_opt, dict) else {}
        artboards_view: list = []
        for i, a in enumerate(raw_artboards):
            if isinstance(a, dict):
                v = dict(a)
                v["number"] = i + 1
                artboards_view.append(v)
        artboards_count = len(artboards_view)
        next_ab_name = next_artboard_name(raw_artboards)
        ab_panel = self._panels.get("artboards", {})
        ab_sel = ab_panel.get("artboards_panel_selection", [])
        artboards_panel_selection_ids = (
            [s for s in ab_sel if isinstance(s, str)]
            if isinstance(ab_sel, list) else []
        )
        current_artboard_id: str | None = None
        current_artboard: dict | None = None
        selected_set = set(artboards_panel_selection_ids)
        if selected_set:
            for a in raw_artboards:
                if isinstance(a, dict) and a.get("id") in selected_set:
                    current_artboard_id = a["id"]
                    current_artboard = dict(a)
                    break
        if current_artboard is None and raw_artboards:
            first = raw_artboards[0]
            if isinstance(first, dict):
                current_artboard_id = first.get("id")
                current_artboard = dict(first)
        # When there are no artboards at all (document is None),
        # current_artboard is {} rather than None so expressions like
        # current_artboard.width don't null-deref.
        if current_artboard is None:
            current_artboard = {}
        artboards_common = {
            "artboards": artboards_view,
            "artboard_options": dict(raw_options),
            "artboards_count": artboards_count,
            "next_artboard_name": next_ab_name,
            "current_artboard_id": current_artboard_id,
            "current_artboard": current_artboard,
            "artboards_panel_selection_ids": artboards_panel_selection_ids,
        }
        if self._document is None:
            sel_count = 0
            if self._active_panel == "layers":
                panel = self._panels.get("layers", {})
                sel = panel.get("layers_panel_selection", [])
                if isinstance(sel, list):
                    sel_count = len(sel)
            return {
                "top_level_layers": [],
                "top_level_layer_paths": [],
                "next_layer_name": "Layer 1",
                "new_layer_insert_index": 0,
                "layers_panel_selection_count": sel_count,
                "has_selection": has_selection,
                "selection_count": selection_count,
                "element_selection": element_selection,
                **artboards_common,
            }
        layers = self._document.get("layers", [])
        top_level_layers = []
        top_level_layer_paths = []
        layer_names = set()
        for i, elem in enumerate(layers):
            if isinstance(elem, dict) and elem.get("kind") == "Layer":
                # Expose layer with its path for HOF predicates
                view = dict(elem)
                view["path"] = Value.path((i,))
                top_level_layers.append(view)
                top_level_layer_paths.append(Value.path((i,)))
                name = elem.get("name")
                if isinstance(name, str):
                    layer_names.add(name)
        # Next unused "Layer N" name
        n = 1
        while f"Layer {n}" in layer_names:
            n += 1
        next_layer_name = f"Layer {n}"
        # Insertion index: min of selected top-level indices + 1, else end.
        # Selection lives on the layers panel; read if active.
        insert_idx = len(layers)
        if self._active_panel == "layers":
            panel = self._panels.get("layers", {})
            sel = panel.get("layers_panel_selection", [])
            if isinstance(sel, list):
                top_level_indices = []
                for p in sel:
                    # Path might be a Value.path, a __path__ marker dict, or
                    # a list of ints. Handle all three.
                    if isinstance(p, Value) and p.type.name == "PATH":
                        idx = p.value
                    elif isinstance(p, dict) and "__path__" in p:
                        idx = tuple(p["__path__"])
                    elif isinstance(p, (list, tuple)):
                        idx = tuple(p)
                    else:
                        continue
                    if len(idx) == 1:
                        top_level_indices.append(idx[0])
                if top_level_indices:
                    insert_idx = min(top_level_indices) + 1
        # Panel-selection rollup for enabled_when predicates and fallback
        # logic in actions like enter_isolation_mode.
        sel_count = 0
        if self._active_panel == "layers":
            panel = self._panels.get("layers", {})
            sel = panel.get("layers_panel_selection", [])
            if isinstance(sel, list):
                sel_count = len(sel)
        return {
            "top_level_layers": top_level_layers,
            "top_level_layer_paths": top_level_layer_paths,
            "next_layer_name": next_layer_name,
            "new_layer_insert_index": insert_idx,
            "layers_panel_selection_count": sel_count,
            "has_selection": has_selection,
            "selection_count": selection_count,
            "element_selection": element_selection,
            **artboards_common,
        }

    def _canvas_selection_paths(self) -> list[tuple[int, ...]]:
        """Extract canvas selection from the document as a list of path
        tuples. Accepts entries that are tuples, lists, dicts with a
        "path" field, or ``__path__`` markers. Missing / malformed
        entries are skipped silently."""
        if self._document is None:
            return []
        sel = self._document.get("selection")
        if not isinstance(sel, list):
            return []
        out: list[tuple[int, ...]] = []
        for entry in sel:
            if isinstance(entry, tuple):
                out.append(entry)
            elif isinstance(entry, list):
                out.append(tuple(entry))
            elif isinstance(entry, dict):
                if "__path__" in entry:
                    out.append(tuple(entry["__path__"]))
                elif "path" in entry:
                    p = entry["path"]
                    if isinstance(p, (list, tuple)):
                        out.append(tuple(p))
        return out
