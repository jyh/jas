"""Knuth-Liang hyphenation algorithm.

Pure-Python implementation of the Knuth-Liang word hyphenation
algorithm as used in TeX. Given a word and a TeX-style pattern
list (e.g. ``2'2``, ``1ad``, ``2bc1d``), returns the set of valid
break points (1-based char indices, where breaks[i] means a break
is allowed between chars i-1 and i).

The pattern format follows TeX hyphenation patterns: each pattern
is a string of letters interleaved with digits. A ``.`` at the
start means word start; a ``.`` at the end means word end. Digits
between letters are priorities; the highest priority at each
inter-character position wins. Odd priorities mark break points;
even priorities suppress them.

Phase 9: ships with a small en-US pattern subset for testing. Full
TeX dictionary is a follow-up packaging task. The algorithm itself
works with any pattern list a caller loads.
"""


def split_pattern(pat: str) -> tuple[str, list[int]]:
    """Split a TeX hyphenation pattern into its letter sequence and
    per-position digit list. ``2'2`` -> letters="'", digits=[2,2]
    (digit at position 0, between, after). The digit list has length
    ``len(letters) + 1``; positions with no digit get 0."""
    letters: list[str] = []
    digits: list[int] = []
    pending: int | None = None
    for c in pat:
        if "0" <= c <= "9":
            pending = ord(c) - ord("0")
        else:
            digits.append(pending if pending is not None else 0)
            pending = None
            letters.append(c)
    digits.append(pending if pending is not None else 0)
    return ("".join(letters), digits)


def hyphenate(word: str, patterns: list[str], min_before: int, min_after: int) -> list[bool]:
    """Compute valid break positions in ``word`` per the given
    patterns. Returns a ``list[bool]`` of length ``len(word) + 1``
    where ``breaks[i] = True`` means a break is permitted between
    chars i-1 and i. Indices 0 and ``len(word)`` are always False
    (no break before first or after last char). Patterns are case-
    folded; the input word is lowercased for matching.

    ``min_before`` and ``min_after`` enforce the dialog "After First
    N letters" / "Before Last N letters" constraints — break points
    within the first ``min_before`` or last ``min_after`` characters
    are suppressed."""
    n = len(word)
    if n == 0:
        return []
    levels = [0] * (n + 1)
    lower = word.lower()
    padded = "." + lower + "."
    plen = len(padded)
    for pat in patterns:
        letters, digits = split_pattern(pat)
        pn = len(letters)
        if pn == 0 or pn > plen:
            continue
        for start in range(plen - pn + 1):
            if padded[start:start + pn] == letters:
                for i, lvl in enumerate(digits):
                    if lvl == 0:
                        continue
                    padded_pos = start + i
                    if padded_pos == 0 or padded_pos > n:
                        continue
                    unpadded_pos = padded_pos - 1
                    if unpadded_pos > n:
                        continue
                    if levels[unpadded_pos] < lvl:
                        levels[unpadded_pos] = lvl
    breaks = [False] * (n + 1)
    upper = max(0, n - min_after)
    for i in range(n + 1):
        if i < min_before or i > upper:
            continue
        if levels[i] % 2 == 1:
            breaks[i] = True
    return breaks


# A small en-US pattern set sufficient for unit tests and a rough
# demonstration. Sourced from a tiny subset of the TeX hyphen.tex
# patterns. A full dictionary (~4500 patterns) landing as a packaged
# resource is tracked separately — production callers should load the
# full set instead of this.
EN_US_PATTERNS_SAMPLE: list[str] = [
    "1ti", "2tion", "1men", "2ment", "1ness", "2ness",
    "3able", "1able",
    ".un1", ".re1", ".dis1", ".pre1", ".pro1",
    "2bl", "2br", "2cl", "2cr", "2dr", "2fl", "2fr", "2gl",
    "2gr", "2pl", "2pr", "2sc", "2sl", "2sm", "2sn", "2sp",
    "2st", "2sw", "2tr", "2tw", "2wr",
    "1ba", "1be", "1bi", "1bo", "1bu",
    "1ca", "1ce", "1ci", "1co", "1cu",
    "1da", "1de", "1di", "1do", "1du",
    "1fa", "1fe", "1fi", "1fo", "1fu",
    "1ga", "1ge", "1gi", "1go", "1gu",
    "1ha", "1he", "1hi", "1ho", "1hu",
    "1la", "1le", "1li", "1lo", "1lu",
    "1ma", "1me", "1mi", "1mo", "1mu",
    "1na", "1ne", "1ni", "1no", "1nu",
    "1pa", "1pe", "1pi", "1po", "1pu",
    "1ra", "1re", "1ri", "1ro", "1ru",
    "1sa", "1se", "1si", "1so", "1su",
    "1ta", "1te", "1ti", "1to", "1tu",
    "1va", "1ve", "1vi", "1vo", "1vu",
]
