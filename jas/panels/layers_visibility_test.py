"""Layers-panel eye-button visibility cycle.

The tree-row eye button cycles an element's visibility
Preview -> Outline -> Invisible -> Preview (panels.yaml_renderer._cycle_visibility).
Cross-app equivalent: Rust cycle_element_visibility, Swift cycleVisibility,
OCaml Element.cycle_visibility.
"""

from geometry.element import Visibility
from panels.yaml_renderer import _cycle_visibility


def test_cycle_order():
    assert _cycle_visibility(Visibility.PREVIEW) == Visibility.OUTLINE
    assert _cycle_visibility(Visibility.OUTLINE) == Visibility.INVISIBLE
    assert _cycle_visibility(Visibility.INVISIBLE) == Visibility.PREVIEW


def test_full_loop():
    v = Visibility.PREVIEW
    for _ in range(3):
        v = _cycle_visibility(v)
    assert v == Visibility.PREVIEW
