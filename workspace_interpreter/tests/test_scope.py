"""Tests for the immutable lexical scope."""

import pytest
from types import MappingProxyType

from workspace_interpreter.scope import Scope


class TestCreate:
    def test_empty_scope(self):
        s = Scope()
        assert s.get("x") is None

    def test_from_bindings(self):
        s = Scope({"x": 1, "y": 2})
        assert s.get("x") == 1
        assert s.get("y") == 2

    def test_bindings_are_frozen(self):
        s = Scope({"x": 1})
        with pytest.raises(TypeError):
            s._bindings["x"] = 2


class TestLookup:
    def test_missing_returns_none(self):
        s = Scope({"x": 1})
        assert s.get("missing") is None

    def test_contains(self):
        s = Scope({"x": 1})
        assert "x" in s
        assert "y" not in s

    def test_parent_lookup(self):
        parent = Scope({"x": 1})
        child = Scope({"y": 2}, parent=parent)
        assert child.get("x") == 1
        assert child.get("y") == 2

    def test_shadowing(self):
        parent = Scope({"x": 1})
        child = Scope({"x": 99}, parent=parent)
        assert child.get("x") == 99
        assert parent.get("x") == 1  # parent unchanged


class TestExtend:
    def test_extend_creates_child(self):
        root = Scope({"state": {"fill": "#ff0000"}})
        child = root.extend(lib={"id": "web_colors"})
        assert child.get("lib") == {"id": "web_colors"}
        assert child.get("state") == {"fill": "#ff0000"}

    def test_extend_shadows_parent(self):
        root = Scope({"x": 1})
        child = root.extend(x=99)
        assert child.get("x") == 99
        assert root.get("x") == 1

    def test_extend_does_not_mutate_parent(self):
        root = Scope({"a": 1})
        child = root.extend(b=2)
        assert root.get("b") is None

    def test_nested_extend(self):
        root = Scope({"data": {"libs": {}}})
        lib_scope = root.extend(lib={"id": "web"})
        swatch_scope = lib_scope.extend(swatch={"color": "#ff0000"})
        assert swatch_scope.get("data") == {"libs": {}}
        assert swatch_scope.get("lib") == {"id": "web"}
        assert swatch_scope.get("swatch") == {"color": "#ff0000"}

    def test_sibling_scopes_independent(self):
        root = Scope({"x": 0})
        a = root.extend(item={"val": "a"})
        b = root.extend(item={"val": "b"})
        assert a.get("item") == {"val": "a"}
        assert b.get("item") == {"val": "b"}
        assert root.get("item") is None


class TestMerge:
    def test_merge_adds_bindings(self):
        s = Scope({"state": {"x": 1}})
        s2 = s | {"data": {"libs": {}}}
        assert s2.get("state") == {"x": 1}
        assert s2.get("data") == {"libs": {}}

    def test_merge_overrides(self):
        s = Scope({"x": 1, "y": 2})
        s2 = s | {"x": 99}
        assert s2.get("x") == 99
        assert s2.get("y") == 2

    def test_merge_does_not_mutate_original(self):
        s = Scope({"x": 1})
        s2 = s | {"x": 99}
        assert s.get("x") == 1

    def test_merge_preserves_parent(self):
        parent = Scope({"a": 1})
        child = Scope({"b": 2}, parent=parent)
        merged = child | {"c": 3}
        assert merged.get("a") == 1  # from parent
        assert merged.get("b") == 2  # from original child
        assert merged.get("c") == 3  # from merge


class TestToDict:
    def test_flat(self):
        s = Scope({"x": 1, "y": 2})
        assert s.to_dict() == {"x": 1, "y": 2}

    def test_chain(self):
        root = Scope({"state": {"fill": "#ff0000"}})
        child = root.extend(lib={"id": "web"})
        d = child.to_dict()
        assert d["state"] == {"fill": "#ff0000"}
        assert d["lib"] == {"id": "web"}

    def test_shadowing_in_dict(self):
        root = Scope({"x": 1})
        child = root.extend(x=99)
        assert child.to_dict() == {"x": 99}

    def test_deep_chain(self):
        s = Scope({"a": 1})
        s = s.extend(b=2)
        s = s.extend(c=3)
        assert s.to_dict() == {"a": 1, "b": 2, "c": 3}

    def test_to_dict_does_not_mutate_scope(self):
        s = Scope({"x": 1})
        d = s.to_dict()
        d["x"] = 99
        assert s.get("x") == 1


class TestRepr:
    def test_repr(self):
        s = Scope({"x": 1, "y": 2})
        assert "Scope(" in repr(s)
        assert "depth=0" in repr(s)

    def test_repr_with_parent(self):
        parent = Scope({"a": 1})
        child = parent.extend(b=2)
        assert "depth=1" in repr(child)
