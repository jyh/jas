"""Tests for the Knuth-Plass composer."""
from algorithms.knuth_plass import (
    PENALTY_INFINITY, KPBox, KPGlue, KPOpts, KPPenalty, compose,
)


def b(width: float, idx: int) -> KPBox:
    return KPBox(width=width, char_idx=idx)


def g(width: float, idx: int) -> KPGlue:
    return KPGlue(width=width, stretch=width * 0.5, shrink=width * 0.33,
                   char_idx=idx)


def g_wide(width: float, idx: int) -> KPGlue:
    return KPGlue(width=width, stretch=20.0, shrink=5.0, char_idx=idx)


def fil_glue(idx: int) -> KPGlue:
    return KPGlue(width=0.0, stretch=1e9, shrink=0.0, char_idx=idx)


def forced(idx: int) -> KPPenalty:
    return KPPenalty(width=0.0, value=-PENALTY_INFINITY, flagged=False,
                      char_idx=idx)


def test_empty_returns_empty():
    assert compose([], [100.0]) == []


def test_three_words_one_line_when_wide_enough():
    items = [b(30, 0), g(10, 3), b(30, 4), g(10, 7), b(30, 8),
             fil_glue(11), forced(11)]
    breaks = compose(items, [200.0])
    assert breaks is not None
    assert len(breaks) == 1
    assert breaks[0].item_idx == len(items) - 1


def test_three_words_two_lines_when_narrow():
    items = [b(30, 0), g(10, 3), b(30, 4), g(10, 7), b(30, 8),
             fil_glue(11), forced(11)]
    breaks = compose(items, [70.0])
    assert breaks is not None
    assert len(breaks) == 2
    assert breaks[0].item_idx == 3


def _hyphen_corpus(penalty: float):
    return [
        b(35, 0), g_wide(5, 2), b(50, 3), g(5, 8), b(10, 9),
        KPPenalty(width=5, value=penalty, flagged=True, char_idx=11),
        b(10, 11), fil_glue(13), forced(13),
    ]


def test_hyphen_penalty_discourages_high():
    items = _hyphen_corpus(1000.0)
    breaks = compose(items, [110.0])
    assert breaks is not None
    used_hyphen = any(br.item_idx == 5 for br in breaks)
    assert not used_hyphen


def test_hyphen_penalty_taken_low():
    items = _hyphen_corpus(10.0)
    breaks = compose(items, [110.0])
    assert breaks is not None
    used_hyphen = any(br.item_idx == 5 for br in breaks)
    assert used_hyphen
