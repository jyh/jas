"""Tests for TextEditSession."""

from geometry.element import Color, Fill, Text
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
