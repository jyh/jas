"""Tspan primitives tests, fixture-driven against
``test_fixtures/algorithms/tspan_*.json`` — the same vectors Rust /
Swift / OCaml run. Plus a handful of hand-written sanity cases.
Mirrors ``jas_dioxus/src/geometry/tspan.rs``,
``JasSwift/Tests/Geometry/TspanPrimitivesTests.swift``, and
``jas_ocaml/test/geometry/tspan_test.ml``.
"""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path
from typing import Any

from geometry.tspan import (
    Tspan, concat_content, default_tspan, merge, resolve_id,
    split, split_range,
)


# ── Fixture plumbing ────────────────────────────────────────────

def _fixtures_root() -> Path:
    """Walk up from this file until a ``test_fixtures`` sibling is
    found. Robust against the working directory pytest runs from."""
    here = Path(__file__).resolve().parent
    for parent in [here, *here.parents]:
        candidate = parent / "test_fixtures"
        if candidate.is_dir():
            return candidate
    raise RuntimeError("test_fixtures not found above " + str(here))


def _load(rel: str) -> dict[str, Any]:
    return json.loads((_fixtures_root() / rel).read_text())


def _tspan_from_json(d: dict[str, Any]) -> Tspan:
    """Decode a single tspan JSON object. Missing fields default to
    ``None``/``""``/``0`` per the fixture convention. Transforms aren't
    exercised by the algorithm vectors so the field is ignored."""
    decor = d.get("text_decoration")
    text_decoration: tuple[str, ...] | None = (
        tuple(decor) if isinstance(decor, list) else None
    )
    return Tspan(
        id=int(d.get("id", 0)),
        content=d.get("content", ""),
        baseline_shift=d.get("baseline_shift"),
        dx=d.get("dx"),
        font_family=d.get("font_family"),
        font_size=d.get("font_size"),
        font_style=d.get("font_style"),
        font_variant=d.get("font_variant"),
        font_weight=d.get("font_weight"),
        jas_aa_mode=d.get("jas_aa_mode"),
        jas_fractional_widths=d.get("jas_fractional_widths"),
        jas_kerning_mode=d.get("jas_kerning_mode"),
        jas_no_break=d.get("jas_no_break"),
        letter_spacing=d.get("letter_spacing"),
        line_height=d.get("line_height"),
        rotate=d.get("rotate"),
        style_name=d.get("style_name"),
        text_decoration=text_decoration,
        text_rendering=d.get("text_rendering"),
        text_transform=d.get("text_transform"),
        transform=None,
        xml_lang=d.get("xml_lang"),
    )


def _parse_tspans(value: Any) -> list[Tspan]:
    tspans = value.get("tspans") if isinstance(value, dict) else value
    if not isinstance(tspans, list):
        return []
    return [_tspan_from_json(t) for t in tspans]


# ── Shared-fixture tests ────────────────────────────────────────

class TestDefaultFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_default.json")
        for v in file["vectors"]:
            expected = _tspan_from_json(v["expected"])
            got = default_tspan()
            assert got == expected, f"vector {v['name']}"
            assert got.id == 0
            assert got.content == ""
            assert got.has_no_overrides()


class TestConcatContentFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_concat_content.json")
        for v in file["vectors"]:
            tspans = _parse_tspans(v)
            expected = v["expected"]
            assert concat_content(tspans) == expected, f"vector {v['name']}"


class TestResolveIdFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_resolve_id.json")
        for v in file["vectors"]:
            tspans = _parse_tspans(v["input"])
            tspan_id = v["input"]["id"]
            expected = v["expected"]
            assert resolve_id(tspans, tspan_id) == expected, \
                f"vector {v['name']}"


class TestSplitFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_split.json")
        for v in file["vectors"]:
            tspans = _parse_tspans(v["input"])
            idx = v["input"]["tspan_idx"]
            offset = v["input"]["offset"]
            got, got_left, got_right = split(tspans, idx, offset)
            expected_tspans = _parse_tspans(v["expected"])
            expected_left = v["expected"]["left_idx"]
            expected_right = v["expected"]["right_idx"]
            assert got == expected_tspans, f"vector {v['name']} tspans"
            assert got_left == expected_left, f"vector {v['name']} left_idx"
            assert got_right == expected_right, f"vector {v['name']} right_idx"


class TestSplitRangeFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_split_range.json")
        for v in file["vectors"]:
            tspans = _parse_tspans(v["input"])
            start = v["input"]["char_start"]
            end = v["input"]["char_end"]
            got, got_first, got_last = split_range(tspans, start, end)
            expected_tspans = _parse_tspans(v["expected"])
            expected_first = v["expected"]["first_idx"]
            expected_last = v["expected"]["last_idx"]
            assert got == expected_tspans, f"vector {v['name']} tspans"
            assert got_first == expected_first, f"vector {v['name']} first_idx"
            assert got_last == expected_last, f"vector {v['name']} last_idx"


class TestMergeFixtures:
    def test_matches(self):
        file = _load("algorithms/tspan_merge.json")
        for v in file["vectors"]:
            input_tspans = _parse_tspans(v["input"])
            expected_tspans = _parse_tspans(v["expected"])
            assert merge(input_tspans) == expected_tspans, f"vector {v['name']}"


# ── Hand-written sanity tests ───────────────────────────────────

class TestHandWritten:
    def test_split_preserves_attribute_overrides_on_both_sides(self):
        original = Tspan(id=0, content="Hello", font_weight="bold")
        got, _, _ = split([original], 0, 2)
        assert len(got) == 2
        assert got[0].font_weight == "bold"
        assert got[1].font_weight == "bold"
        assert got[0].content == "He"
        assert got[1].content == "llo"
        assert got[0].id == 0
        assert got[1].id == 1

    def test_merge_preserves_attribute_overrides(self):
        a = Tspan(id=0, content="A", font_weight="bold")
        b = Tspan(id=1, content="B", font_weight="bold")
        got = merge([a, b])
        assert len(got) == 1
        assert got[0].content == "AB"
        assert got[0].font_weight == "bold"
        assert got[0].id == 0

    def test_merge_does_not_combine_different_overrides(self):
        a = Tspan(id=0, content="A", font_weight="bold")
        b = Tspan(id=1, content="B", font_weight="normal")
        assert len(merge([a, b])) == 2

    def test_resolve_id_after_merge_loses_right_id(self):
        a = Tspan(id=0, content="A")
        b = Tspan(id=3, content="B")
        m = merge([a, b])
        assert resolve_id(m, 0) == 0
        assert resolve_id(m, 3) is None

    def test_merge_of_all_empty_returns_single_default(self):
        got = merge([Tspan(id=5, content=""), Tspan(id=7, content="")])
        assert len(got) == 1
        assert got[0].content == ""
        assert got[0].id == 0
        assert got[0].has_no_overrides()

    def test_dataclass_is_frozen(self):
        """Per the dataclass(frozen=True) invariant — attempts to
        mutate an existing tspan raise, and `replace` is the only
        copy-on-modify path."""
        t = Tspan(id=1, content="hi")
        try:
            t.content = "bye"  # type: ignore[misc]
        except Exception:
            pass
        else:
            raise AssertionError("Tspan should be immutable")
        updated = replace(t, content="bye")
        assert updated.content == "bye"
        assert t.content == "hi"  # original unchanged
