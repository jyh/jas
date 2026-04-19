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

from geometry.element import Text, TextPath, Rect, sync_tspans_from_content
from geometry.tspan import (
    Tspan, concat_content, copy_range, default_tspan, insert_tspans_at,
    merge, reconcile_content, resolve_id, split, split_range,
    tspans_from_content,
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


# ── Text / TextPath tspans field integration ────────────────────

class TestTextTspansField:
    def test_text_populates_tspans_from_content(self):
        t = Text(0.0, 0.0, "Hello")
        assert len(t.tspans) == 1
        assert t.tspans[0].content == "Hello"
        assert t.tspans[0].id == 0
        assert t.tspans[0].has_no_overrides()
        assert concat_content(list(t.tspans)) == t.content

    def test_text_path_populates_tspans_from_content(self):
        tp = TextPath(d=(), content="path text")
        assert len(tp.tspans) == 1
        assert tp.tspans[0].content == "path text"
        assert tp.tspans[0].has_no_overrides()
        assert concat_content(list(tp.tspans)) == tp.content

    def test_text_accepts_explicit_tspans(self):
        # Caller-supplied tspans override the derive-from-content default.
        explicit = tspans_from_content("Explicit")
        t = Text(0.0, 0.0, "Content", tspans=explicit)
        assert t.tspans == explicit
        # content and tspans can diverge when the caller supplies
        # tspans explicitly; sync_tspans_from_content rebuilds from
        # content if the caller later wants them to agree.
        assert t.content == "Content"

    def test_sync_tspans_from_content_rebuilds(self):
        # replace(text, content="new") leaves tspans stale; the helper
        # rebuilds a fresh single-tspan tuple from the current content.
        t = Text(0.0, 0.0, "old")
        updated = replace(t, content="new")
        synced = sync_tspans_from_content(updated)
        assert synced.content == "new"
        assert len(synced.tspans) == 1
        assert synced.tspans[0].content == "new"

    def test_sync_tspans_on_non_text_is_noop(self):
        r = Rect(0.0, 0.0, 10.0, 10.0)
        assert sync_tspans_from_content(r) is r


# ── reconcile_content ───────────────────────────────────────────

def _plain(s: str, tspan_id: int = 0) -> Tspan:
    return Tspan(id=tspan_id, content=s)

def _bold(s: str, tspan_id: int = 0) -> Tspan:
    return Tspan(id=tspan_id, content=s, font_weight="bold")


class TestReconcileContent:
    def test_identity_passes_through(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        assert reconcile_content(ts, "Hello world") == ts

    def test_append_extends_last_tspan(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        r = reconcile_content(ts, "Hello world!")
        assert len(r) == 2
        assert r[1].content == "world!"
        assert r[1].font_weight == "bold"

    def test_prepend_extends_first_tspan(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        r = reconcile_content(ts, "Say Hello world")
        assert len(r) == 2
        assert r[0].content == "Say Hello "
        assert r[1].font_weight == "bold"

    def test_insert_inside_preserves_neighbour(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        r = reconcile_content(ts, "Hellooo world")
        assert len(r) == 2
        assert r[0].content == "Hellooo "
        assert r[0].font_weight is None
        assert r[1].content == "world"
        assert r[1].font_weight == "bold"

    def test_delete_all_yields_single_default(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        r = reconcile_content(ts, "")
        assert len(r) == 1
        assert r[0].content == ""
        assert r[0].has_no_overrides()

    def test_boundary_replace_absorbs_into_first_overlapping(self):
        ts = [_plain("Hello "), _bold("world", tspan_id=1)]
        r = reconcile_content(ts, "HelloXXworld")
        assert len(r) == 2
        assert r[0].content == "HelloXX"
        assert r[0].font_weight is None
        assert r[1].content == "world"
        assert r[1].font_weight == "bold"

    def test_preserves_utf8_boundaries(self):
        ts = [_plain("café "), _bold("naïve", tspan_id=1)]
        r = reconcile_content(ts, "café plus naïve")
        assert len(r) == 2
        assert r[0].content == "café plus "
        assert r[1].content == "naïve"
        assert r[1].font_weight == "bold"

    def test_runs_merge_cleanup(self):
        ts = [_plain("a"), _plain("b", tspan_id=1), _bold("C", tspan_id=2)]
        r = reconcile_content(ts, "ab")
        assert len(r) == 1
        assert r[0].content == "ab"


class TestCopyRange:
    def test_empty_returns_empty(self):
        ts = [_plain("hello")]
        assert copy_range(ts, 2, 2) == []
        assert copy_range(ts, 3, 1) == []

    def test_inside_single_tspan_preserves_overrides(self):
        ts = [_bold("bold text")]
        r = copy_range(ts, 5, 9)
        assert len(r) == 1
        assert r[0].content == "text"
        assert r[0].font_weight == "bold"

    def test_across_boundary_returns_partial_tspans(self):
        ts = [_plain("foo"), _bold("bar", tspan_id=1)]
        r = copy_range(ts, 1, 5)
        assert len(r) == 2
        assert r[0].content == "oo"
        assert r[0].font_weight is None
        assert r[1].content == "ba"
        assert r[1].font_weight == "bold"

    def test_saturates_to_total(self):
        ts = [_plain("hi")]
        r = copy_range(ts, 0, 999)
        assert len(r) == 1
        assert r[0].content == "hi"


class TestInsertTspansAt:
    def test_at_boundary_between_tspans(self):
        base = [_plain("foo"), _bold("bar", tspan_id=1)]
        ins = [_bold("X")]
        r = insert_tspans_at(base, 3, ins)
        assert len(r) == 2
        assert r[0].content == "foo"
        assert r[1].content == "Xbar"
        assert r[1].font_weight == "bold"

    def test_inside_a_tspan_splits(self):
        base = [_plain("hello")]
        ins = [_bold("X")]
        r = insert_tspans_at(base, 2, ins)
        assert len(r) == 3
        assert r[0].content == "he"
        assert r[0].font_weight is None
        assert r[1].content == "X"
        assert r[1].font_weight == "bold"
        assert r[2].content == "llo"
        assert r[2].font_weight is None

    def test_prepend_at_zero(self):
        base = [_plain("hello")]
        ins = [_bold("Say ")]
        r = insert_tspans_at(base, 0, ins)
        assert len(r) == 2
        assert r[0].content == "Say "
        assert r[0].font_weight == "bold"

    def test_append_at_end(self):
        base = [_plain("hello")]
        ins = [_bold("!")]
        r = insert_tspans_at(base, 5, ins)
        assert len(r) == 2
        assert r[1].content == "!"
        assert r[1].font_weight == "bold"

    def test_reassigns_ids(self):
        base = [Tspan(id=0, content="abc")]
        ins = [Tspan(id=0, content="X", font_weight="bold")]
        r = insert_tspans_at(base, 1, ins)
        ids = [t.id for t in r]
        assert len(set(ids)) == len(ids)

    def test_empty_is_noop(self):
        base = [_plain("hello")]
        assert insert_tspans_at(base, 2, []) == base
        assert insert_tspans_at(base, 2, [_plain("")]) == base

    def test_copy_then_insert_roundtrip(self):
        base = [_plain("foo"), _bold("bar", tspan_id=1)]
        clipboard = copy_range(base, 3, 6)
        r = insert_tspans_at(base, 0, clipboard)
        assert concat_content(r) == "barfoobar"
        assert any(len(t.content) >= 3 and t.font_weight == "bold" for t in r)


# ── rich clipboard: JSON + SVG formats ───────────────────────────────


class TestRichClipboardJson:
    def test_roundtrip_preserves_content_and_overrides(self):
        from geometry.tspan import tspans_to_json_clipboard, tspans_from_json_clipboard
        src = [_plain("foo"), _bold("bar", tspan_id=1)]
        json_str = tspans_to_json_clipboard(src)
        back = tspans_from_json_clipboard(json_str)
        assert back is not None
        assert len(back) == 2
        assert back[0].content == "foo"
        assert back[0].font_weight is None
        assert back[1].content == "bar"
        assert back[1].font_weight == "bold"

    def test_strips_id(self):
        from geometry.tspan import tspans_to_json_clipboard
        src = [Tspan(id=42, content="x")]
        json_str = tspans_to_json_clipboard(src)
        assert '"id":42' not in json_str
        assert '"id": 42' not in json_str

    def test_strips_null_overrides(self):
        from geometry.tspan import tspans_to_json_clipboard
        src = [_plain("foo")]
        json_str = tspans_to_json_clipboard(src)
        assert "null" not in json_str

    def test_from_assigns_fresh_ids(self):
        from geometry.tspan import tspans_from_json_clipboard
        back = tspans_from_json_clipboard(
            '{"tspans":[{"content":"a"},{"content":"b"}]}')
        assert back is not None
        assert back[0].id == 0
        assert back[1].id == 1

    def test_rejects_bad_payload(self):
        from geometry.tspan import tspans_from_json_clipboard
        assert tspans_from_json_clipboard("not json") is None
        assert tspans_from_json_clipboard('{"not_tspans":[]}') is None


class TestRichClipboardSvg:
    def test_roundtrip(self):
        from geometry.tspan import tspans_to_svg_fragment, tspans_from_svg_fragment
        src = [_plain("hello "), _bold("world", tspan_id=1)]
        svg = tspans_to_svg_fragment(src)
        assert '<text xmlns="http://www.w3.org/2000/svg">' in svg
        assert "<tspan>hello </tspan>" in svg
        assert '<tspan font-weight="bold">world</tspan>' in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert back[0].content == "hello "
        assert back[1].content == "world"
        assert back[1].font_weight == "bold"

    def test_escapes_special_chars(self):
        from geometry.tspan import tspans_to_svg_fragment, tspans_from_svg_fragment
        src = [_plain("< & >")]
        svg = tspans_to_svg_fragment(src)
        assert "&lt; &amp; &gt;" in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert back[0].content == "< & >"

    def test_rejects_missing_text_root(self):
        from geometry.tspan import tspans_from_svg_fragment
        assert tspans_from_svg_fragment("<span>hi</span>") is None


class TestJasRolePhase1a:
    """Paragraph wrapper tspans are tagged with jas:role="paragraph".
    Phase 1a only persists the role marker through clipboard SVG
    round-trips; paragraph attribute fields and Enter/Backspace edit
    primitives land in Phase 1b."""

    def test_default_tspan_has_no_role(self):
        from geometry.tspan import default_tspan
        assert default_tspan().jas_role is None

    def test_has_no_overrides_false_when_jas_role_set(self):
        from geometry.tspan import default_tspan
        from dataclasses import replace
        t = replace(default_tspan(), jas_role="paragraph")
        assert not t.has_no_overrides()

    def test_svg_fragment_jas_role_round_trip(self):
        from geometry.tspan import (
            default_tspan, tspans_to_svg_fragment, tspans_from_svg_fragment,
        )
        from dataclasses import replace
        t = replace(default_tspan(), content="", jas_role="paragraph")
        svg = tspans_to_svg_fragment([t])
        assert 'jas:role="paragraph"' in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert len(back) == 1
        assert back[0].jas_role == "paragraph"


class TestPhase3bParagraphAttrs:
    """Phase 3b panel-surface paragraph attrs on Tspan."""

    def test_has_no_overrides_false_when_phase3b_attrs_set(self):
        from geometry.tspan import default_tspan
        from dataclasses import replace
        assert not replace(default_tspan(), jas_left_indent=12.0).has_no_overrides()
        assert not replace(default_tspan(), jas_hyphenate=True).has_no_overrides()
        assert not replace(default_tspan(), jas_list_style="bullet-disc").has_no_overrides()

    def test_svg_fragment_phase3b_attrs_round_trip(self):
        from geometry.tspan import (
            default_tspan, tspans_to_svg_fragment, tspans_from_svg_fragment,
        )
        from dataclasses import replace
        t = replace(default_tspan(),
                    content="", jas_role="paragraph",
                    jas_left_indent=18.0, jas_right_indent=9.0,
                    jas_hyphenate=True, jas_hanging_punctuation=True,
                    jas_list_style="bullet-disc")
        svg = tspans_to_svg_fragment([t])
        assert 'jas:left-indent="18"' in svg
        assert 'jas:right-indent="9"' in svg
        assert 'jas:hyphenate="true"' in svg
        assert 'jas:hanging-punctuation="true"' in svg
        assert 'jas:list-style="bullet-disc"' in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert len(back) == 1
        assert back[0].jas_left_indent == 18.0
        assert back[0].jas_right_indent == 9.0
        assert back[0].jas_hyphenate is True
        assert back[0].jas_hanging_punctuation is True
        assert back[0].jas_list_style == "bullet-disc"


class TestPhase1b1ParagraphAttrs:
    """Phase 1b1 remaining panel-surface paragraph attrs on Tspan
    (text_align / text_align_last / text_indent + space_before /
    space_after)."""

    def test_has_no_overrides_false_when_phase1b1_attrs_set(self):
        from geometry.tspan import default_tspan
        from dataclasses import replace
        assert not replace(default_tspan(), text_align="justify").has_no_overrides()
        assert not replace(default_tspan(), text_align_last="left").has_no_overrides()
        assert not replace(default_tspan(), text_indent=-12.0).has_no_overrides()
        assert not replace(default_tspan(), jas_space_before=6.0).has_no_overrides()
        assert not replace(default_tspan(), jas_space_after=6.0).has_no_overrides()

    def test_svg_fragment_phase1b1_attrs_round_trip(self):
        from geometry.tspan import (
            default_tspan, tspans_to_svg_fragment, tspans_from_svg_fragment,
        )
        from dataclasses import replace
        t = replace(default_tspan(),
                    content="", jas_role="paragraph",
                    text_align="justify", text_align_last="center",
                    text_indent=-18.0,
                    jas_space_before=12.0, jas_space_after=6.0)
        svg = tspans_to_svg_fragment([t])
        assert 'text-align="justify"' in svg
        assert 'text-align-last="center"' in svg
        assert 'text-indent="-18"' in svg
        assert 'jas:space-before="12"' in svg
        assert 'jas:space-after="6"' in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert len(back) == 1
        assert back[0].text_align == "justify"
        assert back[0].text_align_last == "center"
        assert back[0].text_indent == -18.0
        assert back[0].jas_space_before == 12.0
        assert back[0].jas_space_after == 6.0


class TestPhase8JustificationAttrs:
    """Phase 1b2 / Phase 8 Justification dialog attrs round-trip."""

    def test_has_no_overrides_false_when_phase8_attrs_set(self):
        from geometry.tspan import default_tspan
        from dataclasses import replace
        assert not replace(default_tspan(), jas_word_spacing_min=75).has_no_overrides()
        assert not replace(default_tspan(), jas_letter_spacing_desired=5).has_no_overrides()
        assert not replace(default_tspan(), jas_glyph_scaling_max=105).has_no_overrides()
        assert not replace(default_tspan(), jas_auto_leading=140).has_no_overrides()
        assert not replace(default_tspan(), jas_single_word_justify="left").has_no_overrides()

    def test_svg_fragment_phase8_attrs_round_trip(self):
        from geometry.tspan import (
            default_tspan, tspans_to_svg_fragment, tspans_from_svg_fragment,
        )
        from dataclasses import replace
        t = replace(default_tspan(),
                    content="", jas_role="paragraph",
                    jas_word_spacing_min=75, jas_word_spacing_desired=95,
                    jas_word_spacing_max=150,
                    jas_letter_spacing_min=-5, jas_letter_spacing_desired=0,
                    jas_letter_spacing_max=10,
                    jas_glyph_scaling_min=95, jas_glyph_scaling_desired=100,
                    jas_glyph_scaling_max=105,
                    jas_auto_leading=140, jas_single_word_justify="left")
        svg = tspans_to_svg_fragment([t])
        assert 'jas:word-spacing-min="75"' in svg
        assert 'jas:letter-spacing-desired="0"' in svg
        assert 'jas:glyph-scaling-max="105"' in svg
        assert 'jas:auto-leading="140"' in svg
        assert 'jas:single-word-justify="left"' in svg
        back = tspans_from_svg_fragment(svg)
        assert back is not None
        assert len(back) == 1
        assert back[0].jas_word_spacing_min == 75.0
        assert back[0].jas_word_spacing_desired == 95.0
        assert back[0].jas_word_spacing_max == 150.0
        assert back[0].jas_letter_spacing_min == -5.0
        assert back[0].jas_letter_spacing_desired == 0.0
        assert back[0].jas_letter_spacing_max == 10.0
        assert back[0].jas_glyph_scaling_min == 95.0
        assert back[0].jas_glyph_scaling_desired == 100.0
        assert back[0].jas_glyph_scaling_max == 105.0
        assert back[0].jas_auto_leading == 140.0
        assert back[0].jas_single_word_justify == "left"
