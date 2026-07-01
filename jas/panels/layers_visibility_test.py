"""Layers-panel eye-button visibility cycle.

The tree-row eye button cycles an element's visibility
Preview -> Outline -> Invisible -> Preview (panels.yaml_renderer._cycle_visibility).
Cross-app equivalent: Rust cycle_element_visibility, Swift cycleVisibility,
OCaml Element.cycle_visibility.
"""

from geometry.element import Visibility
from panels.yaml_renderer import _cycle_visibility, _cycle_element_visibility_at


def test_cycle_order():
    assert _cycle_visibility(Visibility.PREVIEW) == Visibility.OUTLINE
    assert _cycle_visibility(Visibility.OUTLINE) == Visibility.INVISIBLE
    assert _cycle_visibility(Visibility.INVISIBLE) == Visibility.PREVIEW


def test_full_loop():
    v = Visibility.PREVIEW
    for _ in range(3):
        v = _cycle_visibility(v)
    assert v == Visibility.PREVIEW


def test_cycle_element_visibility_at_deselects_on_invisible():
    # The eye handler cycles the element at `path` and drops it from the
    # selection when it becomes Invisible. Mirrors Rust/OCaml/Swift.
    from geometry.element import Rect, Layer
    from document.document import Document, ElementSelection
    layer = Layer(children=(Rect(x=0, y=0, width=10, height=10),))
    path = (0, 0)
    doc = Document(layers=(layer,), selection=frozenset({ElementSelection.all(path)}))
    assert any(es.path == path for es in doc.selection)
    # Preview -> Outline: still selected.
    d1 = _cycle_element_visibility_at(doc, path)
    assert d1.get_element(path).visibility == Visibility.OUTLINE
    assert any(es.path == path for es in d1.selection)
    # Outline -> Invisible: deselected.
    d2 = _cycle_element_visibility_at(d1, path)
    assert d2.get_element(path).visibility == Visibility.INVISIBLE
    assert not any(es.path == path for es in d2.selection)
