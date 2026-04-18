"""Tests for TextEditSession."""

from geometry.element import RgbColor, Fill, Text
from geometry.tspan import Tspan
from tools.text_edit import EditTarget, TextEditSession


def session(content):
    return TextEditSession(path=(0, 0), target=EditTarget.TEXT,
                           content=content, insertion=0)


def test_new_session_caret():
    s = TextEditSession(path=(0, 0), target=EditTarget.TEXT,
                        content="abc", insertion=2)
    assert s.insertion == 2
    assert s.anchor == 2
    assert not s.has_selection()


def test_insert_advances():
    s = session("hello")
    s.set_insertion(5, False)
    s.insert(" world")
    assert s.content == "hello world"
    assert s.insertion == 11


def test_insert_replaces_selection():
    s = session("hello")
    s.set_insertion(0, False)
    s.set_insertion(5, True)
    s.insert("hi")
    assert s.content == "hi"
    assert s.insertion == 2


def test_backspace():
    s = session("hello")
    s.set_insertion(5, False)
    s.backspace()
    assert s.content == "hell"
    assert s.insertion == 4


def test_backspace_at_start_noop():
    s = session("hi")
    s.set_insertion(0, False)
    s.backspace()
    assert s.content == "hi"


def test_backspace_with_selection():
    s = session("hello")
    s.set_insertion(1, False)
    s.set_insertion(4, True)
    s.backspace()
    assert s.content == "ho"
    assert s.insertion == 1


def test_delete_forward():
    s = session("hello")
    s.set_insertion(0, False)
    s.delete_forward()
    assert s.content == "ello"


def test_delete_forward_end_noop():
    s = session("hi")
    s.set_insertion(2, False)
    s.delete_forward()
    assert s.content == "hi"


def test_select_all():
    s = session("hello")
    s.select_all()
    assert s.selection_range() == (0, 5)


def test_copy_selection():
    s = session("hello")
    s.set_insertion(1, False)
    s.set_insertion(4, True)
    assert s.copy_selection() == "ell"


def test_copy_no_selection_returns_none():
    assert session("hello").copy_selection() is None


def test_undo_redo():
    s = session("")
    s.insert("a")
    s.insert("b")
    assert s.content == "ab"
    s.undo()
    assert s.content == "a"
    s.undo()
    assert s.content == ""
    s.redo()
    assert s.content == "a"


def test_new_edit_clears_redo():
    s = session("")
    s.insert("a")
    s.undo()
    s.insert("b")
    s.redo()
    assert s.content == "b"


def test_set_insertion_clamps():
    s = session("hi")
    s.set_insertion(99, False)
    assert s.insertion == 2


def test_extend_selection_keeps_anchor():
    s = session("hello")
    s.set_insertion(2, False)
    s.set_insertion(4, True)
    assert s.anchor == 2
    assert s.insertion == 4
    assert s.selection_range() == (2, 4)


def test_reverse_selection_orders():
    s = session("hello")
    s.set_insertion(4, False)
    s.set_insertion(1, True)
    assert s.selection_range() == (1, 4)


def test_select_all_then_insert_replaces():
    s = session("hello")
    s.select_all()
    s.insert("X")
    assert s.content == "X"
    assert s.insertion == 1


# Session-scoped tspan clipboard — mirrors Swift/OCaml/Rust coverage.


def test_copy_selection_with_tspans_captures_and_returns_flat():
    element_tspans = (
        Tspan(id=0, content="foo"),
        Tspan(id=1, content="bar", font_weight="bold"),
    )
    s = TextEditSession(path=(0, 0), target=EditTarget.TEXT,
                        content="foobar", insertion=0)
    s.set_insertion(1, False)
    s.set_insertion(5, True)  # select "ooba"
    flat = s.copy_selection_with_tspans(element_tspans)
    assert flat == "ooba"
    assert s.tspan_clipboard is not None
    saved_flat, saved = s.tspan_clipboard
    assert saved_flat == "ooba"
    assert len(saved) == 2
    assert saved[0].content == "oo"
    assert saved[0].font_weight is None
    assert saved[1].content == "ba"
    assert saved[1].font_weight == "bold"


def test_try_paste_tspans_matches_and_splices():
    element_tspans = (Tspan(id=0, content="foo"),)
    s = TextEditSession(path=(0, 0), target=EditTarget.TEXT,
                        content="foo", insertion=0)
    s.tspan_clipboard = (
        "X",
        (Tspan(id=0, content="X", font_weight="bold"),),
    )
    s.set_insertion(1, False)
    result = s.try_paste_tspans(element_tspans, "X")
    assert result is not None
    assert len(result) == 3
    assert result[0].content == "f"
    assert result[1].content == "X"
    assert result[1].font_weight == "bold"
    assert result[2].content == "oo"


def test_try_paste_tspans_returns_none_when_text_doesnt_match():
    element_tspans = (Tspan(id=0, content="foo"),)
    s = TextEditSession(path=(0, 0), target=EditTarget.TEXT,
                        content="foo", insertion=0)
    s.tspan_clipboard = ("X", ())
    assert s.try_paste_tspans(element_tspans, "DIFFERENT") is None
