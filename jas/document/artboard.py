"""Artboards: print-page regions attached to the document root.

See transcripts/ARTBOARDS.md for the full specification. Every
document has at least one artboard; ``Artboard`` carries position,
size, fill, display toggles, and a stable 8-char base36 ``id``.
The 1-based ``number`` shown in the panel is derived from list
position, not stored.

Serialization format matches Python workspace_interpreter + Rust
+ Swift + OCaml exactly (cross-app contract, ART-441).
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field
from typing import Callable, Optional, Union


# ``fill`` is a sum type: either the sentinel string ``"transparent"`` or
# a hex color literal ``"#rrggbb"``. The Python port keeps the data-layer
# representation simple (plain string) so round-trip through JSON is
# identity; readers use :func:`fill_is_transparent` when they need the
# distinction.
ArtboardFill = str


def fill_is_transparent(fill: ArtboardFill) -> bool:
    return fill == "transparent"


def fill_as_canonical(fill: ArtboardFill) -> str:
    return fill


def fill_from_canonical(s: str) -> ArtboardFill:
    return s


@dataclass(frozen=True)
class Artboard:
    """Per-artboard stored state."""

    id: str
    name: str = "Artboard 1"
    x: float = 0.0
    y: float = 0.0
    width: float = 612.0
    height: float = 792.0
    fill: ArtboardFill = "transparent"
    show_center_mark: bool = False
    show_cross_hairs: bool = False
    show_video_safe_areas: bool = False
    video_ruler_pixel_aspect_ratio: float = 1.0

    @staticmethod
    def default_with_id(id: str) -> "Artboard":
        """Canonical default: Letter 612x792 at origin, transparent
        fill, all display toggles off."""
        return Artboard(id=id)


@dataclass(frozen=True)
class ArtboardOptions:
    """Document-global artboard toggles. Both default to on."""
    fade_region_outside_artboard: bool = True
    update_while_dragging: bool = True


DEFAULT_ARTBOARD_OPTIONS = ArtboardOptions()


# ── Id generation ──────────────────────────────────────────────────

_ARTBOARD_ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
_ARTBOARD_ID_LENGTH = 8


def generate_artboard_id(rng: Optional[Callable[[], int]] = None) -> str:
    """Mint a fresh 8-char base36 id. Pass a zero-arg callable returning
    a non-negative integer for deterministic tests; default uses
    ``secrets.randbelow``."""
    if rng is None:
        rng = lambda: secrets.randbelow(1 << 30)
    alphabet_len = len(_ARTBOARD_ID_ALPHABET)
    return "".join(
        _ARTBOARD_ID_ALPHABET[rng() % alphabet_len]
        for _ in range(_ARTBOARD_ID_LENGTH)
    )


# ── Default-name rule ─────────────────────────────────────────────

_DEFAULT_NAME_RE = re.compile(r"^Artboard (\d+)$")


def parse_default_name(name: str) -> Optional[int]:
    """Return N on match of ``^Artboard \\d+$`` (case-sensitive,
    exactly one space)."""
    m = _DEFAULT_NAME_RE.match(name)
    if m:
        return int(m.group(1))
    return None


def next_artboard_name(artboards) -> str:
    """Smallest unused N such that no artboard is named ``Artboard N``."""
    used: set[int] = set()
    for a in artboards:
        n = parse_default_name(a.name)
        if n is not None:
            used.add(n)
    n = 1
    while n in used:
        n += 1
    return f"Artboard {n}"


# ── At-least-one-artboard invariant ────────────────────────────────

def ensure_artboards_invariant(
    artboards,
    id_generator: Optional[Callable[[], str]] = None,
) -> tuple[tuple[Artboard, ...], bool]:
    """Return a (tuple, did_repair) pair. ``did_repair`` is True when a
    default artboard was seeded because the input was empty."""
    if len(artboards) > 0:
        return (tuple(artboards), False)
    gen = id_generator if id_generator is not None else generate_artboard_id
    return ((Artboard.default_with_id(gen()),), True)
