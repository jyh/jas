"""Knuth-Plass every-line line-breaking composer.

Pure-Python port of the Rust / Swift / OCaml KP composers from
``jas_dioxus/src/algorithms/knuth_plass.rs`` etc. Phase 10.

Items are tuples in the form ``("box", width, char_idx)``,
``("glue", width, stretch, shrink, char_idx)``, or
``("penalty", width, value, flagged, char_idx)``. Callers tokenise
their text into items, run :func:`compose`, and re-render lines with
the per-line adjustment ratio applied to glue widths.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


PENALTY_INFINITY = 10000.0


@dataclass(frozen=True)
class KPBox:
    width: float
    char_idx: int


@dataclass(frozen=True)
class KPGlue:
    width: float
    stretch: float
    shrink: float
    char_idx: int


@dataclass(frozen=True)
class KPPenalty:
    width: float
    value: float
    flagged: bool
    char_idx: int


KPItem = KPBox | KPGlue | KPPenalty


def item_width(it: KPItem) -> float:
    if isinstance(it, KPPenalty):
        return 0.0  # contributes only on break
    return it.width


def item_char_idx(it: KPItem) -> int:
    return it.char_idx


@dataclass
class KPOpts:
    line_penalty: float = 10.0
    flagged_demerit: float = 3000.0
    max_ratio: float = 10.0


@dataclass(frozen=True)
class KPBreak:
    item_idx: int
    ratio: float
    flagged: bool


def compose(items: list[KPItem], line_widths: list[float],
            opts: KPOpts | None = None) -> Optional[list[KPBreak]]:
    """Run the Knuth-Plass DP composer.

    ``line_widths`` reuses its last element when the paragraph wants
    more lines than the list provides. Returns ``None`` when no
    feasible composition exists (caller falls back to greedy
    first-fit).

    The returned breaks always end at the final item, which the
    caller must terminate with a forced penalty
    (``value = -PENALTY_INFINITY``).
    """
    if not items or not line_widths:
        return []
    if opts is None:
        opts = KPOpts()
    n = len(items)

    # Prefix sums of width / stretch / shrink for O(1) line eval.
    sum_w = [0.0] * (n + 1)
    sum_y = [0.0] * (n + 1)
    sum_z = [0.0] * (n + 1)
    for i, it in enumerate(items):
        sum_w[i + 1] = sum_w[i] + item_width(it)
        if isinstance(it, KPGlue):
            sum_y[i + 1] = sum_y[i] + it.stretch
            sum_z[i + 1] = sum_z[i] + it.shrink
        else:
            sum_y[i + 1] = sum_y[i]
            sum_z[i + 1] = sum_z[i]

    # DP node: (item_idx, line, total_demerits, ratio, flagged, prev_idx)
    nodes: list[tuple[int, int, float, float, bool, Optional[int]]] = [
        (0, 0, 0.0, 0.0, False, None)
    ]

    def nat_width(from_: int, to_: int) -> tuple[float, float, float]:
        w = sum_w[to_ + 1] - sum_w[from_]
        y = sum_y[to_ + 1] - sum_y[from_]
        z = sum_z[to_ + 1] - sum_z[from_]
        last = items[to_]
        if isinstance(last, KPGlue):
            w -= last.width
            y -= last.stretch
            z -= last.shrink
        elif isinstance(last, KPPenalty):
            w += last.width
        return (w, y, z)

    def line_width_for(line: int) -> float:
        return line_widths[line] if line < len(line_widths) else line_widths[-1]

    for j in range(n):
        item_j = items[j]
        if isinstance(item_j, KPGlue):
            legal = j > 0 and isinstance(items[j - 1], KPBox)
        elif isinstance(item_j, KPPenalty):
            legal = item_j.value < PENALTY_INFINITY
        else:
            legal = False
        if not legal:
            continue

        best: tuple[int, float, float] | None = None
        for ni, n_node in enumerate(nodes):
            n_item_idx, n_line, n_total_d, _, n_flagged, n_prev = n_node
            from_ = 0 if (n_prev is None and ni == 0) else n_item_idx + 1
            if from_ > j:
                continue
            nat, stretch, shrink = nat_width(from_, j)
            line_w = line_width_for(n_line)
            if abs(nat - line_w) < 1e-9:
                ratio = 0.0
            elif nat < line_w:
                ratio = (line_w - nat) / stretch if stretch > 0 else float("inf")
            else:
                ratio = (line_w - nat) / shrink if shrink > 0 else float("-inf")
            if ratio < -1.0 or ratio > opts.max_ratio:
                continue
            badness = 100.0 * abs(ratio) ** 3
            if isinstance(item_j, KPPenalty):
                pen_value, pen_flagged = item_j.value, item_j.flagged
            else:
                pen_value, pen_flagged = 0.0, False
            if pen_value >= 0:
                line_demerit = (opts.line_penalty + badness + pen_value) ** 2
            elif pen_value > -PENALTY_INFINITY:
                line_demerit = (opts.line_penalty + badness) ** 2 - pen_value ** 2
            else:
                line_demerit = (opts.line_penalty + badness) ** 2
            demerits = n_total_d + line_demerit
            if n_flagged and pen_flagged:
                demerits += opts.flagged_demerit
            if best is None or demerits < best[1]:
                best = (ni, demerits, ratio)
        if best is not None:
            prev, d, r = best
            pen_flagged = isinstance(item_j, KPPenalty) and item_j.flagged
            nodes.append((j, nodes[prev][1] + 1, d, r, pen_flagged, prev))

    # Find lowest-demerit node ending at item n-1.
    best_d = float("inf")
    best_idx: Optional[int] = None
    for ni, node in enumerate(nodes):
        if node[0] == n - 1 and node[2] < best_d:
            best_d = node[2]
            best_idx = ni
    if best_idx is None:
        return None
    out: list[KPBreak] = []
    cur = best_idx
    while True:
        node = nodes[cur]
        if node[5] is None and cur == 0:
            break
        out.append(KPBreak(item_idx=node[0], ratio=node[3], flagged=node[4]))
        if node[5] is None:
            break
        cur = node[5]
    out.reverse()
    return out
