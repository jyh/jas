#!/usr/bin/env python3
"""A small, honest C# reader for the shell text gates.

WHY THIS EXISTS
---------------
`check_shell_interaction_path.py` (O2b) and `check_shell_knobs.py` (O7) both
scan `prototypes/sb_winui/*.cs`. Both must answer questions about CODE, not
about prose or payload:

  * a `Math.Max` sitting inside a `//` comment that explains why the clamp was
    DELETED must not red the ban that deleted it;
  * a `GetEnvironmentVariable("SB_FRAMES")` printed inside a diagnostic STRING
    must not be counted as a read of the knob, or a receipt row could spoof the
    census that decides which knobs are documented.

Both are the same defect one level down: a text gate that scans bytes answers a
question about bytes, and then its finding is reported as a question about
behaviour. So the two gates share one reader, and the reader's job is to say
which byte ranges are code, which are comment, and which are literal payload.

WHAT IT PROVIDES
----------------
`lex(src)` -> `Lexed`, carrying three views of the SAME index space (every
transform replaces characters in place, never shifts them, so an offset means
the same thing in all three and `line_of()` is exact in all three):

    decommented   comments blanked; string/char literal CONTENTS intact
    code          the above, with literal contents blanked too
    string_spans  (start, end) of every literal's contents

and `blocks(code)` -> the brace structure: every `{...}` with the text that
opened it, and which of those are METHOD bodies.

WHAT IT DOES NOT COVER
----------------------
* Interpolated strings (`$"...{expr}..."`) are treated as OPAQUE payload for
  their whole extent. Code inside the holes is therefore invisible to both
  gates. That is the SAFE direction for a ban (a clamp hidden in an
  interpolation hole would be missed) and the UNSAFE direction is not reachable:
  neither gate's positive assertions are satisfiable from inside a literal.
  Named, not hidden -- if a shell ever computes a surface size inside an
  interpolation hole, this reader is why the gate did not see it.
* Preprocessor directives (`#if`, `#region`) are ordinary text. The shell has
  none today; a `#if` that comments out a clamp would still be read as a clamp,
  which is the conservative direction.
* The method-signature recogniser is textual, not a parser. It rejects the C#
  keywords that wear a call's shape (`if (...) {`), and it rejects object
  initialisers (`new T(...) {`) and lambdas (`(...) => {`). A novel shape is
  reported as NOT a method, so the gates' anti-vacuity floors (which count the
  methods they expect to find) are what turn a parser miss into a RED rather
  than into a silent pass. That direction is deliberate.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# C# keywords that can precede `(...) {` and are NOT method declarations. A
# method recogniser without this list calls every `if` and every `catch` a
# method, and the gates' "inside a method named X" clauses become noise.
NOT_A_METHOD = frozenset(
    """if else for foreach while switch catch do try finally using lock fixed
    unsafe checked unchecked return new yield await throw case default
    when where select from""".split()
)


@dataclass
class Lexed:
    src: str
    decommented: str
    code: str
    string_spans: list[tuple[int, int]] = field(default_factory=list)

    def line_of(self, offset: int) -> int:
        """1-based line number of `offset`. Exact in all three views."""
        return self.src.count("\n", 0, offset) + 1

    def in_string(self, offset: int) -> bool:
        return any(a <= offset < b for a, b in self.string_spans)


def _blank(text: str) -> str:
    """Same length, newlines kept -- so every offset survives the transform."""
    return "".join("\n" if c == "\n" else " " for c in text)


def lex(src: str) -> Lexed:
    """Split `src` into code / comment / literal, preserving every offset."""
    n = len(src)
    out = list(src)          # comments -> blanks
    spans: list[tuple[int, int]] = []
    i = 0
    while i < n:
        c = src[i]
        # ---- comments -----------------------------------------------------
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = list(_blank(src[i:j]))
            i = j
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out[i:j] = list(_blank(src[i:j]))
            i = j
            continue
        # ---- verbatim / interpolated-verbatim strings ----------------------
        if c in "@$" and i + 1 < n:
            m = re.match(r'(?:@\$?|\$@)"', src[i:])
            if m:
                start = i + m.end()          # first content char
                j = start
                while j < n:
                    if src[j] == '"':
                        if j + 1 < n and src[j + 1] == '"':
                            j += 2
                            continue
                        break
                    j += 1
                spans.append((start, min(j, n)))
                i = min(j + 1, n)
                continue
        # ---- regular / interpolated strings, and char literals -------------
        if c == "$" and i + 1 < n and src[i + 1] == '"':
            i += 1
            c = '"'
        if c in "\"'":
            quote = c
            start = i + 1
            j = start
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == quote:
                    break
                if src[j] == "\n" and quote == '"':
                    break               # unterminated; do not run off the file
                j += 1
            spans.append((start, min(j, n)))
            i = min(j + 1, n)
            continue
        i += 1

    decommented = "".join(out)
    code_chars = list(decommented)
    for a, b in spans:
        code_chars[a:b] = list(_blank(decommented[a:b]))
    return Lexed(src=src, decommented=decommented, code="".join(code_chars),
                 string_spans=spans)


@dataclass(frozen=True)
class Block:
    """One `{...}` region of the code view."""
    head: str        # text between the previous ;{} and the opening brace
    head_start: int
    body_start: int  # index of `{`
    body_end: int    # index of the matching `}` (== len(code) if unbalanced)
    method: str | None      # method name, or None if this is not a method body
    sig_start: int | None   # index of the method-name identifier

    def contains(self, offset: int) -> bool:
        return self.body_start <= offset <= self.body_end


_SIG_TAIL = re.compile(r"([A-Za-z_]\w*)\s*(?:<[^<>()]*>)?\s*$")


def _method_name(head: str, head_start: int):
    """(name, offset) if `head` reads as a method declaration, else (None, None).

    `head` is the code text since the previous `;`, `{` or `}`. A method
    declaration ends in a parameter list; a lambda ends in `=>`; an object
    initialiser is preceded by `new`.
    """
    t = head.rstrip()
    if not t.endswith(")"):
        return None, None
    depth = 0
    for k in range(len(t) - 1, -1, -1):
        if t[k] == ")":
            depth += 1
        elif t[k] == "(":
            depth -= 1
            if depth == 0:
                break
    else:
        return None, None
    if depth != 0:
        return None, None
    before = t[:k]
    m = _SIG_TAIL.search(before)
    if not m:
        return None, None
    name = m.group(1)
    if name in NOT_A_METHOD:
        return None, None
    # `new Foo(...) { ... }` is an initialiser, not a declaration.
    if re.search(r"\bnew\s*$", before[: m.start(1)]):
        return None, None
    return name, head_start + m.start(1)


def blocks(code: str) -> list[Block]:
    """Every brace block in the code view, innermost-last within a nesting."""
    found: list[Block] = []
    stack: list[int] = []
    last_break = -1
    opens: dict[int, tuple[str, int]] = {}
    for i, ch in enumerate(code):
        if ch in ";}":
            last_break = i
        if ch == "{":
            head_start = last_break + 1
            opens[i] = (code[head_start:i], head_start)
            stack.append(i)
            last_break = i
        elif ch == "}":
            if not stack:
                continue
            start = stack.pop()
            head, head_start = opens.pop(start, ("", start))
            name, sig = _method_name(head, head_start)
            found.append(Block(head=head, head_start=head_start, body_start=start,
                               body_end=i, method=name, sig_start=sig))
    for start in stack:                       # unbalanced: run to end of file
        head, head_start = opens.get(start, ("", start))
        name, sig = _method_name(head, head_start)
        found.append(Block(head=head, head_start=head_start, body_start=start,
                           body_end=len(code), method=name, sig_start=sig))
    found.sort(key=lambda b: b.body_start)
    return found


def enclosing_method(bs: list[Block], offset: int) -> Block | None:
    """The innermost METHOD block containing `offset`."""
    best = None
    for b in bs:
        if b.method and b.contains(offset):
            if best is None or b.body_start > best.body_start:
                best = b
    return best


def enclosing_blocks(bs: list[Block], offset: int) -> list[Block]:
    """Every block containing `offset`, innermost first."""
    hits = [b for b in bs if b.contains(offset)]
    hits.sort(key=lambda b: b.body_start, reverse=True)
    return hits
