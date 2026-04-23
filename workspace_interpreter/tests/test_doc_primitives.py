"""Phase 3 of PYTHON_TOOL_RUNTIME.md — doc-aware primitives +
buffers + math primitives."""

from __future__ import annotations

import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from workspace_interpreter import anchor_buffers, doc_primitives, point_buffers
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import Value, ValueType


# ── Math primitives ──────────────────────────────────────


class TestMath:
    def test_min_max_abs(self):
        assert evaluate("min(3, 1, 2)", {}).value == 1.0
        assert evaluate("max(3, 1, 2)", {}).value == 3.0
        assert evaluate("abs(-5)", {}).value == 5.0

    def test_sqrt_and_hypot(self):
        assert evaluate("sqrt(9)", {}).value == 3.0
        assert evaluate("hypot(3, 4)", {}).value == 5.0

    def test_sqrt_rejects_negative(self):
        assert evaluate("sqrt(-1)", {}).type == ValueType.NULL


# ── Doc primitives ───────────────────────────────────────


def _doc_with_rect():
    from document.document import Document
    from geometry.element import Layer, Rect as RectElem
    layer = Layer(name="L", children=(
        RectElem(x=10.0, y=10.0, width=20.0, height=20.0),
    ))
    return Document(layers=(layer,))


class TestDocPrimitives:
    def teardown_method(self, method):
        # Ensure the current-doc slot is reset between tests to
        # avoid order-dependency on the module-local ref.
        doc_primitives._current = None

    def test_hit_test_without_doc_returns_null(self):
        doc_primitives._current = None
        v = evaluate("hit_test(15, 15)", {})
        assert v.type == ValueType.NULL

    def test_hit_test_hits_inside(self):
        with doc_primitives.with_doc(_doc_with_rect()):
            v = evaluate("hit_test(15, 15)", {})
            assert v.type == ValueType.PATH
            assert tuple(v.value) == (0, 0)

    def test_hit_test_misses_outside(self):
        with doc_primitives.with_doc(_doc_with_rect()):
            v = evaluate("hit_test(100, 100)", {})
            assert v.type == ValueType.NULL

    def test_doc_guard_restores_prior(self):
        outer = _doc_with_rect()
        with doc_primitives.with_doc(outer):
            assert evaluate("hit_test(15, 15)", {}).type == ValueType.PATH
            from document.document import Document
            inner = Document(layers=())
            with doc_primitives.with_doc(inner):
                assert evaluate("hit_test(15, 15)", {}).type == ValueType.NULL
            # Outer restored after inner exit.
            assert evaluate("hit_test(15, 15)", {}).type == ValueType.PATH
        # After outer exit, no doc.
        assert evaluate("hit_test(15, 15)", {}).type == ValueType.NULL

    def test_selection_empty_with_and_without_doc(self):
        doc_primitives._current = None
        assert evaluate("selection_empty()", {}).value is True
        from document.document import Document
        with doc_primitives.with_doc(Document(layers=())):
            assert evaluate("selection_empty()", {}).value is True


# ── Point buffers ────────────────────────────────────────


class TestPointBuffers:
    def test_push_and_length(self):
        point_buffers.clear("test_buf_a")
        assert point_buffers.length("test_buf_a") == 0
        point_buffers.push("test_buf_a", 1.0, 2.0)
        point_buffers.push("test_buf_a", 3.0, 4.0)
        assert point_buffers.length("test_buf_a") == 2
        pts = point_buffers.points("test_buf_a")
        assert pts == [(1.0, 2.0), (3.0, 4.0)]
        point_buffers.clear("test_buf_a")
        assert point_buffers.length("test_buf_a") == 0

    def test_buffer_length_primitive(self):
        point_buffers.clear("test_buf_b")
        for x in (1, 2, 3):
            point_buffers.push("test_buf_b", float(x), 0.0)
        v = evaluate("buffer_length('test_buf_b')", {})
        assert v.value == 3.0
        point_buffers.clear("test_buf_b")


# ── Anchor buffers ───────────────────────────────────────


class TestAnchorBuffers:
    def test_push_creates_corner(self):
        anchor_buffers.clear("test_anc_a")
        anchor_buffers.push("test_anc_a", 10.0, 20.0)
        a = anchor_buffers.first("test_anc_a")
        assert a is not None
        assert a.x == 10.0 and a.y == 20.0
        assert a.hx_in == 10.0 and a.hy_in == 20.0
        assert a.hx_out == 10.0 and a.hy_out == 20.0
        assert not a.smooth
        anchor_buffers.clear("test_anc_a")

    def test_set_last_out_mirrors_in(self):
        anchor_buffers.clear("test_anc_b")
        anchor_buffers.push("test_anc_b", 50.0, 50.0)
        anchor_buffers.set_last_out_handle("test_anc_b", 60.0, 50.0)
        a = anchor_buffers.first("test_anc_b")
        assert a is not None
        assert a.hx_out == 60.0 and a.hy_out == 50.0
        # Mirrored: (2*50 - 60, 2*50 - 50) = (40, 50)
        assert a.hx_in == 40.0 and a.hy_in == 50.0
        assert a.smooth
        anchor_buffers.clear("test_anc_b")

    def test_pop(self):
        anchor_buffers.clear("test_anc_c")
        anchor_buffers.push("test_anc_c", 1.0, 2.0)
        anchor_buffers.push("test_anc_c", 3.0, 4.0)
        assert anchor_buffers.length("test_anc_c") == 2
        anchor_buffers.pop("test_anc_c")
        assert anchor_buffers.length("test_anc_c") == 1
        a = anchor_buffers.first("test_anc_c")
        assert a is not None and a.x == 1.0
        anchor_buffers.clear("test_anc_c")

    def test_close_hit_primitive(self):
        anchor_buffers.clear("test_anc_d")
        anchor_buffers.push("test_anc_d", 0.0, 0.0)
        anchor_buffers.push("test_anc_d", 100.0, 0.0)
        # Cursor at (3, 4) — hypot = 5, within r = 8.
        v = evaluate("anchor_buffer_close_hit('test_anc_d', 3, 4, 8)", {})
        assert v.value is True
        # Too far.
        v2 = evaluate("anchor_buffer_close_hit('test_anc_d', 20, 0, 8)", {})
        assert v2.value is False
        anchor_buffers.clear("test_anc_d")

    def test_close_hit_rejects_short_buffer(self):
        anchor_buffers.clear("test_anc_e")
        anchor_buffers.push("test_anc_e", 0.0, 0.0)
        # Only 1 anchor — close-hit requires >= 2.
        v = evaluate("anchor_buffer_close_hit('test_anc_e', 1, 1, 10)", {})
        assert v.value is False
        anchor_buffers.clear("test_anc_e")
