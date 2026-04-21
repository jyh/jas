"""Unit tests for the native-Python Artboard module."""

from document.artboard import (
    Artboard,
    ArtboardOptions,
    DEFAULT_ARTBOARD_OPTIONS,
    ensure_artboards_invariant,
    fill_as_canonical,
    fill_from_canonical,
    fill_is_transparent,
    generate_artboard_id,
    next_artboard_name,
    parse_default_name,
)


# ── Fill canonical round-trip ─────────────────────────────────────


def test_fill_transparent():
    assert fill_is_transparent("transparent")
    assert not fill_is_transparent("#ff0000")
    assert fill_as_canonical("transparent") == "transparent"
    assert fill_from_canonical("transparent") == "transparent"


def test_fill_color():
    assert fill_as_canonical("#ff0000") == "#ff0000"
    assert fill_from_canonical("#ff0000") == "#ff0000"


# ── Artboard defaults ─────────────────────────────────────────────


def test_default_with_id_canonical_fields():
    ab = Artboard.default_with_id("seedfeed")
    assert ab.id == "seedfeed"
    assert ab.name == "Artboard 1"
    assert ab.x == 0.0
    assert ab.y == 0.0
    assert ab.width == 612.0
    assert ab.height == 792.0
    assert ab.fill == "transparent"
    assert ab.show_center_mark is False
    assert ab.show_cross_hairs is False
    assert ab.show_video_safe_areas is False
    assert ab.video_ruler_pixel_aspect_ratio == 1.0


def test_artboard_options_defaults():
    opts = ArtboardOptions()
    assert opts.fade_region_outside_artboard is True
    assert opts.update_while_dragging is True
    assert DEFAULT_ARTBOARD_OPTIONS == opts


# ── Id generation ─────────────────────────────────────────────────


def test_id_is_8_chars_base36_seeded():
    counter = [0]
    def rng():
        counter[0] += 1
        return counter[0]
    aid = generate_artboard_id(rng=rng)
    assert len(aid) == 8
    assert all(c in "0123456789abcdefghijklmnopqrstuvwxyz" for c in aid)


def test_id_deterministic_with_same_seed():
    def make_rng():
        counter = [42]
        def rng():
            counter[0] = (counter[0] * 1103515245 + 12345) & 0x7FFFFFFF
            return counter[0]
        return rng
    a = generate_artboard_id(rng=make_rng())
    b = generate_artboard_id(rng=make_rng())
    assert a == b


# ── Name rule ─────────────────────────────────────────────────────


def test_parse_default_name_valid():
    assert parse_default_name("Artboard 1") == 1
    assert parse_default_name("Artboard 42") == 42


def test_parse_default_name_edge_cases():
    assert parse_default_name("artboard 1") is None      # lowercase
    assert parse_default_name("Artboard  1") is None     # two spaces
    assert parse_default_name("Artboard 1 ") is None     # trailing space
    assert parse_default_name("Artboard") is None
    assert parse_default_name("Artboard abc") is None


def test_next_artboard_name_empty():
    assert next_artboard_name([]) == "Artboard 1"


def test_next_artboard_name_skips_used():
    abs_ = (
        Artboard.default_with_id("a")._replace() if hasattr(Artboard.default_with_id("a"), "_replace")
        else Artboard(id="a", name="Artboard 1"),
        Artboard(id="b", name="Artboard 2"),
    )
    # dataclass is frozen, can't _replace; build directly.
    abs_ = (
        Artboard(id="a", name="Artboard 1"),
        Artboard(id="b", name="Artboard 2"),
    )
    assert next_artboard_name(abs_) == "Artboard 3"


def test_next_artboard_name_fills_gaps():
    abs_ = (
        Artboard(id="a", name="Artboard 1"),
        Artboard(id="b", name="Artboard 3"),
    )
    assert next_artboard_name(abs_) == "Artboard 2"


def test_next_artboard_name_case_sensitive():
    abs_ = (
        Artboard(id="a", name="artboard 1"),      # lowercase
        Artboard(id="b", name="Artboard  1"),     # two spaces
    )
    assert next_artboard_name(abs_) == "Artboard 1"


# ── Invariant ─────────────────────────────────────────────────────


def test_ensure_invariant_seeds_default_on_empty():
    seq = [0]
    def gen():
        seq[0] += 1
        return f"seed{seq[0]:04d}"
    out, repaired = ensure_artboards_invariant((), id_generator=gen)
    assert repaired is True
    assert len(out) == 1
    assert out[0].name == "Artboard 1"
    assert out[0].id == "seed0001"


def test_ensure_invariant_noop_when_nonempty():
    existing = (Artboard(id="existing"),)
    out, repaired = ensure_artboards_invariant(existing)
    assert repaired is False
    assert out == existing
