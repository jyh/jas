#!/usr/bin/env python3
"""commit-msg hook: strip the session trailer BEFORE it can enter history.

WHY THIS EXISTS
---------------
`scripts/check_commit_trailers.py` enforces the 2026-07-22 scrub on a RANGE.
That is the right shape for CI, but it is a detector: by the time it speaks,
the commit exists and the repair is a rebase. On this box the trailer is not a
mistake anyone makes — the seat's harness appends it to every commit message
automatically — so a detector alone means the rule depends on remembering,
every commit, forever. This removes the trailer at the one moment it is still
free to remove.

It does NOT duplicate the forbidden patterns. It imports them from the gate,
so the two can never drift apart in silence. If the gate cannot be found this
hook REFUSES THE COMMIT rather than passing it through unscrubbed: a scrubber
whose oracle has vanished must refuse, not return zero.

`Co-Authored-By` is preserved deliberately — the scrub kept attribution and
removed only the session URL. That is pinned by a test, so nobody later tidies
the two together.
"""
import os
import subprocess
import sys


def _repo_root() -> str:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, encoding="utf-8")
    if out.returncode != 0:
        return ""
    return out.stdout.strip()


GATE_PATH = "scripts/check_commit_trailers.py"

# Refs consulted when the working tree does not carry the gate. A feature
# branch cut before the gate landed still has it in its history's reach, and
# refusing every commit on such a branch would be a correct rule enforced at a
# useless moment. These are read-only lookups of the SAME file -- the patterns
# still have exactly one source.
FALLBACK_REFS = ("origin/main", "main")


def _exec_source(src: str, origin: str):
    import types
    mod = types.ModuleType("_ct_gate")
    mod.__file__ = origin
    try:
        exec(compile(src, origin, "exec"), mod.__dict__)
    except Exception:
        return None
    if not hasattr(mod, "FORBIDDEN") or not hasattr(mod, "PRESERVED"):
        return None
    return mod


def _load_gate(root: str):
    """Load FORBIDDEN/PRESERVED from the gate. Returns (module, where) or None.

    Working tree first, then git refs. Never a local copy of the patterns.
    """
    path = os.path.join(root, *GATE_PATH.split("/"))
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as fh:
            mod = _exec_source(fh.read(), path)
        if mod is not None:
            return mod, GATE_PATH

    for ref in FALLBACK_REFS:
        # ⛔ encoding="utf-8" IS LOAD-BEARING HERE, not lint. This reads the
        # GATE'S OWN SOURCE out of a git ref and execs it, and that file is full
        # of non-ASCII (⛔, em-dashes). `text=True` alone decodes with the LOCALE
        # codec — cp1252 on Windows, which is the platform this hook was written
        # for — so the read raises UnicodeDecodeError, the hook dies, and every
        # commit on that box is refused. Fail-closed, and still broken.
        out = subprocess.run(["git", "show", f"{ref}:{GATE_PATH}"],
                             capture_output=True, text=True, encoding="utf-8",
                             cwd=root)
        if out.returncode == 0 and out.stdout:
            mod = _exec_source(out.stdout, f"{ref}:{GATE_PATH}")
            if mod is not None:
                return mod, f"{ref}:{GATE_PATH}"
    return None


def scrub(body: str, forbidden, preserved: str) -> str:
    """Drop every line matching a forbidden shape; never drop a preserved one."""
    kept = []
    for line in body.splitlines(keepends=True):
        if preserved.lower() in line.lower():
            kept.append(line)
            continue
        if any(p.search(line) for p, _ in forbidden):
            continue
        kept.append(line)
    return "".join(kept)


def main(argv) -> int:
    if len(argv) < 2:
        print("commit-msg scrub: no message file given", file=sys.stderr)
        return 1
    path = argv[1]

    root = _repo_root()
    found = _load_gate(root) if root else None
    if found is None:
        print(f"REFUSED: commit-msg scrub cannot find {GATE_PATH}", file=sys.stderr)
        print("         Looked in the working tree and in "
              f"{', '.join(FALLBACK_REFS)}.", file=sys.stderr)
        print("         The hook derives its patterns from that gate and will not",
              file=sys.stderr)
        print("         guess them. Restore the gate, or remove this hook knowingly.",
              file=sys.stderr)
        return 1
    gate, _where = found

    with open(path, "r", encoding="utf-8") as fh:
        before = fh.read()

    after = scrub(before, gate.FORBIDDEN, gate.PRESERVED)

    if after != before:
        # Trailing blank lines left behind by the removal are cosmetic; git
        # strips them itself via cleanup. Do not otherwise reflow the message.
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(after)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
