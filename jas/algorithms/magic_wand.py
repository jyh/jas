"""Magic Wand match predicate.

Pure function: given a seed element, a candidate element, and the
nine ``state.magic_wand_*`` configuration values, decide whether
the candidate is "similar" to the seed under the enabled criteria.

See ``transcripts/MAGIC_WAND_TOOL.md`` §Predicate for the rules.
Cross-language parity is mechanical with the Rust / Swift / OCaml
ports.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from geometry.element import BlendMode, Element, Fill, Stroke


@dataclass(frozen=True)
class MagicWandConfig:
    """The five-criterion configuration mirrors ``state.magic_wand_*``.

    Each criterion has an enabled flag (true = participate in the
    predicate) and, where applicable, a tolerance.
    """

    fill_color: bool = True
    fill_tolerance: float = 32.0  # Euclidean RGB distance, 0..255 scale.

    stroke_color: bool = True
    stroke_tolerance: float = 32.0

    stroke_weight: bool = True
    stroke_weight_tolerance: float = 5.0  # |delta width| in pt.

    opacity: bool = True
    opacity_tolerance: float = 5.0  # |delta opacity| * 100 in pp.

    blending_mode: bool = False  # exact-match — no tolerance.


def _fill_of(e: Element) -> Fill | None:
    return getattr(e, "fill", None)


def _stroke_of(e: Element) -> Stroke | None:
    return getattr(e, "stroke", None)


def _opacity_of(e: Element) -> float:
    return getattr(e, "opacity", 1.0)


def _blend_mode_of(e: Element) -> BlendMode:
    return getattr(e, "blend_mode", BlendMode.NORMAL)


def _rgb_distance(a: tuple[float, float, float, float],
                  b: tuple[float, float, float, float]) -> float:
    """Euclidean RGB distance on the 0..255 scale.

    Inputs are ``Color.to_rgba()`` outputs (R, G, B, A) in
    ``[0.0, 1.0]``; we scale R, G, B to ``[0, 255]`` and ignore
    alpha (``Fill`` / ``Stroke`` carry their own ``opacity`` field).
    """
    dr = (a[0] - b[0]) * 255.0
    dg = (a[1] - b[1]) * 255.0
    db = (a[2] - b[2]) * 255.0
    return math.sqrt(dr * dr + dg * dg + db * db)


def _fill_color_matches(seed: Fill | None, cand: Fill | None,
                        tolerance: float) -> bool:
    if seed is None and cand is None:
        return True
    if seed is None or cand is None:
        return False
    return _rgb_distance(seed.color.to_rgba(), cand.color.to_rgba()) <= tolerance


def _stroke_color_matches(seed: Stroke | None, cand: Stroke | None,
                          tolerance: float) -> bool:
    if seed is None and cand is None:
        return True
    if seed is None or cand is None:
        return False
    return _rgb_distance(seed.color.to_rgba(), cand.color.to_rgba()) <= tolerance


def _stroke_weight_matches(seed: Stroke | None, cand: Stroke | None,
                            tolerance: float) -> bool:
    if seed is None and cand is None:
        return True
    if seed is None or cand is None:
        return False
    return abs(seed.width - cand.width) <= tolerance


def _opacity_matches(seed: float, cand: float, tolerance: float) -> bool:
    return abs(seed - cand) * 100.0 <= tolerance


def _blending_mode_matches(seed: BlendMode, cand: BlendMode) -> bool:
    return seed == cand


def magic_wand_match(seed: Element, candidate: Element,
                     cfg: MagicWandConfig) -> bool:
    """Return ``True`` iff the candidate is similar to the seed.

    AND across all enabled criteria — a single disqualifying
    criterion means no match. When all criteria are disabled the
    function returns ``False``; the click handler treats this case
    as "select only the seed itself", but that is the caller's
    responsibility.
    """
    any_enabled = (cfg.fill_color or cfg.stroke_color
                   or cfg.stroke_weight or cfg.opacity
                   or cfg.blending_mode)
    if not any_enabled:
        return False
    if cfg.fill_color and not _fill_color_matches(
            _fill_of(seed), _fill_of(candidate), cfg.fill_tolerance):
        return False
    if cfg.stroke_color and not _stroke_color_matches(
            _stroke_of(seed), _stroke_of(candidate), cfg.stroke_tolerance):
        return False
    if cfg.stroke_weight and not _stroke_weight_matches(
            _stroke_of(seed), _stroke_of(candidate),
            cfg.stroke_weight_tolerance):
        return False
    if cfg.opacity and not _opacity_matches(
            _opacity_of(seed), _opacity_of(candidate), cfg.opacity_tolerance):
        return False
    if cfg.blending_mode and not _blending_mode_matches(
            _blend_mode_of(seed), _blend_mode_of(candidate)):
        return False
    return True
