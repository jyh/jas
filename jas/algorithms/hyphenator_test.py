"""Tests for the Knuth-Liang hyphenation algorithm."""
from algorithms.hyphenator import (
    EN_US_PATTERNS_SAMPLE, hyphenate, split_pattern,
)


def test_split_pattern_simple():
    letters, digits = split_pattern("2'2")
    assert letters == "'"
    assert digits == [2, 2]


def test_split_pattern_no_digits():
    letters, digits = split_pattern("abc")
    assert letters == "abc"
    assert digits == [0, 0, 0, 0]


def test_split_pattern_with_word_anchors():
    letters, digits = split_pattern(".un1")
    assert letters == ".un"
    assert digits == [0, 0, 0, 1]


def test_empty_word_returns_empty_breaks():
    breaks = hyphenate("", [".un1"], 1, 1)
    assert breaks == []


def test_no_patterns_no_breaks():
    breaks = hyphenate("hello", [], 1, 1)
    assert len(breaks) == 6
    assert all(not b for b in breaks)


def test_min_before_suppresses_early_breaks():
    breaks = hyphenate("hello", ["1ello"], 2, 1)
    assert breaks[1] is False


def test_min_after_suppresses_late_breaks():
    breaks = hyphenate("hello", ["hell1o"], 1, 2)
    assert breaks[4] is False


def test_en_us_sample_breaks_repeat():
    breaks = hyphenate("repeat", EN_US_PATTERNS_SAMPLE, 1, 1)
    assert breaks[2] is True
