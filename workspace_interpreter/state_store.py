"""Reactive state store for the workspace interpreter.

Pure Python, no Qt dependency. Uses callback-based notifications.
Platform-specific bindings (Qt signals, Dioxus signals, etc.) connect
to the subscribe mechanism.
"""

from __future__ import annotations
import copy
from typing import Callable


class StateStore:
    """Manages global state, panel-scoped state, and reactive subscriptions."""

    def __init__(self, defaults: dict | None = None, document: dict | None = None):
        self._state: dict = dict(defaults) if defaults else {}
        self._panels: dict[str, dict] = {}
        self._active_panel: str | None = None
        self._dialog: dict = {}
        self._dialog_id: str | None = None
        self._dialog_params: dict | None = None
        self._dialog_props: dict = {}  # {key: {"get": expr, "set": expr}}
        self._subscribers: list[tuple[set | None, Callable]] = []
        self._panel_subscribers: dict[str, list[Callable]] = {}
        # Phase 3: optional document tree for doc.set / snapshot effects.
        # Shape: {"layers": [<element>, ...]} where <element> is a dict
        # with at least {"kind": str, "name": str}. Real apps use a
        # native Model; tests use plain dicts.
        self._document: dict | None = document
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
        Includes top_level_layers and top_level_layer_paths (Phase 3 §7.2)."""
        from workspace_interpreter.expr_types import Value
        if self._document is None:
            return {
                "top_level_layers": [],
                "top_level_layer_paths": [],
            }
        layers = self._document.get("layers", [])
        top_level_layers = []
        top_level_layer_paths = []
        for i, elem in enumerate(layers):
            if isinstance(elem, dict) and elem.get("kind") == "Layer":
                # Expose layer with its path for HOF predicates
                view = dict(elem)
                view["path"] = Value.path((i,))
                top_level_layers.append(view)
                top_level_layer_paths.append(Value.path((i,)))
        return {
            "top_level_layers": top_level_layers,
            "top_level_layer_paths": top_level_layer_paths,
        }
