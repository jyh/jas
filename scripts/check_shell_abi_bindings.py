#!/usr/bin/env python3
"""Every C# `DllImport` of the jas ABI must match the C header it calls through.

WHY THIS EXISTS
---------------
P/Invoke is UNCHECKED. `[DllImport] extern int jas_selection_len(IntPtr e)` and
`extern nuint jas_selection_len(IntPtr e)` both compile, both link, and both
run; one of them reads the wrong half of a register. Nothing in this repository
could tell them apart:

  * the C# compiler cannot -- it never sees the callee;
  * `dotnet build` in CI cannot, for the same reason;
  * the Rust suite cannot -- it does not know a C# consumer exists;
  * `check_cbindgen_freshness.py` keeps `jas_dioxus/include/jas_ffi.h` CURRENT
    with the Rust, and stops there. Nothing reads the header back.

Measured before this gate was written, with a positive control (`check_` hits
59 files under `scripts/`, so the one-line answer is a reading and not a broken
query):

    grep -rln 'jas_ffi.h' scripts/ .github/workflows/  ->  check_cbindgen_freshness.py

⛔ THAT COMMAND NOW RETURNS **TWO** FILES, AND THE SECOND IS THIS ONE. Written
out because a measurement quoted in prose is exactly the kind of claim that goes
stale the moment its own repair lands, and then reads as a defect in the
sentence rather than as its subject. The finding was: ONE file named the header,
and `check_cbindgen_freshness.py:57` says of itself that it compares the header
to the RUST -- "it does not check that the header is CORRECT, only that it is
CURRENT". Nothing read it back against a caller.

`prototypes/sb_winui/JasCore.cs` already carries the defect class in PROSE, in
the `JasBytes` doc comment:

    "THE LAYOUT IS THE CONTRACT: `#[repr(C)] { *const u8, usize }`. `usize` is
     `nuint` here and NOT `int` -- on x64 a 4-byte field would misalign the
     pointer's neighbour and read length from the wrong half of the struct,
     which is the class of bug that shows up as a plausible-looking wrong number
     rather than as a crash."

A comment that names a defect class is not a gate. This is the gate, and it
arrives with wave 1's four new bindings (`jas_document_svg`, `jas_menu_state`,
`jas_dispatch_event`, `jas_last_error_json`) because those are four fresh
chances to spell `nuint` as `int` in a file nothing checks.

WHAT IT ASSERTS
---------------
Over EVERY `prototypes/**/*.cs` that carries a `DllImport` (the population is
DERIVED by that glob, never pinned -- a fourth consumer is covered the day it is
written), with comments and string-literal contents blanked by
`scripts/csharp_source.py`:

(a) Every bound name is DECLARED in `jas_dioxus/include/jas_ffi.h`. A binding
    the header does not declare is a call into nothing -- `EntryPointNotFound`
    at the first invocation, in a window, on another machine.
(b) ARITY matches, positionally.
(c) Every parameter type and the return type are COMPATIBLE, by the table in
    `C_CANON` / `CS_CANON` below. Compatible is not "equal": the header's
    `const uint8_t *` is legitimately bound as `IntPtr`, `byte[]` or `byte*`,
    and only that one C type accepts more than one canonical form.
(d) An UNKNOWN type on either side is a REFUSAL, never a skip. A resolver that
    returns "no finding" for what it could not parse reports a clean tree from a
    broken parser -- this seat has paid for that twice (a null-on-miss resolver
    makes every defect read as false; a count has no failure mode).
(e) ANTI-VACUITY, three floors, because a gate over an empty population is green
    for the wrong reason: at least `MIN_FILES` files carry bindings, at least
    `MIN_BINDINGS` bindings are found in total, and at least `MIN_HEADER_DECLS`
    declarations are parsed out of the header.
(f) The per-file TYPE ALIASES below are NAMED with their reason, and an alias
    whose file no longer declares that type is reported STALE -- an exemption
    that outlives its subject is how a hole becomes permanent.

WHAT IT DOES NOT COVER
----------------------
* SEMANTICS. It compares shapes. A binding that passes a panel id where the
  header wants a scene stays green, because both are `const uint8_t *`.
* OWNERSHIP (BL4). Nothing here can see that a returned `JasBytes` was copied
  and freed. `TakeString` holds that discipline in one place; no gate does.
* THREAD AFFINITY (BL2). Whether a bound function is called on the engine's own
  thread is a control-flow question this text gate cannot answer. The
  `jas-render` queue is what holds it, and `check_shell_interaction_path.py`'s
  own "WHAT IT DOES NOT COVER" already names the drain as beyond a text gate.
* CALLING CONVENTION and `SetLastError`. Every binding in this repo takes the
  defaults and the ABI is `extern "C"`; a gate asserting the default would red
  the day someone legitimately needed `Cdecl` spelled out.
* THE HEADER'S OWN TRUTH. If cbindgen mis-translates a signature, this gate is
  satisfied by the mis-translation -- exactly as `check_cbindgen_freshness.py`
  says of itself. The two gates chain: Rust -> header (freshness) -> C# (here),
  and neither link proves the other's subject.
* `#if` regions in the header. Declarations behind `JAS_WITH_D2D` are read as
  ordinary declarations, so a binding to a function the shipped cdylib does not
  export would pass here. The cdylib is built with those features on
  (`--features d2d,ffi`); the day it is not, this is where the hole is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `.as_posix()`, not `str()`: check_path_keying.py bans rendering a Path to text
# with `str()` because it yields "/" here and "\\" on Windows, and this gate
# runs on both families. It caught this line the first time the file was staged.
sys.path.insert(0, Path(__file__).resolve().parent.as_posix())

import csharp_source  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HEADER = ROOT / "jas_dioxus" / "include" / "jas_ffi.h"
SEARCH_ROOT = ROOT / "prototypes"

# ---------------------------------------------------------------------------
# ANTI-VACUITY FLOORS
#
# Floors, not equalities: this gate must not have to be edited by the PR that
# adds a binding, or its green becomes a statement about the editor. Each is
# well below today's reading and each reds if a whole file or the header stops
# being scanned. MEASURED TODAY, not recalled: 3 files, 40 bindings, 29 header
# declarations (2026-09-08, at `1e6f8125` plus this wave's four).
#
# ⛔ AND THE REASON A FLOOR IS WRITTEN DOWN AT ALL, from this seat's own record:
#    a floor's arm tests its ARITHMETIC and never its VALUE, so two floors in
#    this repo sat 42 and 45 files below reality with green self-tests. These
#    three are therefore stated WITH the reading they were taken against, so a
#    reader can see the slack rather than infer it.
# ---------------------------------------------------------------------------
MIN_FILES = 3
MIN_BINDINGS = 30
MIN_HEADER_DECLS = 25

# ---------------------------------------------------------------------------
# PER-FILE TYPE ALIASES -- NAMED, WITH THEIR REASON (clause (f))
#
# Two consumers spell the ABI's two by-value types with their own local names.
# That is legal C# and it is not a defect, so the gate resolves them rather than
# refusing them -- but it resolves them BY NAME, so a third spelling appearing
# tomorrow is a REFUSAL and not a silent pass.
#
# Each entry names the file, the local spelling, and the ABI type it stands for.
# `alias_is_stale()` reds an entry whose file no longer declares that type.
# ---------------------------------------------------------------------------
ALIASES: dict[str, dict[str, str]] = {
    # The S-A spike predates `JasCore.cs` and named the struct for its own
    # namespace; `Status` is its local mirror of the `JasStatus` enum, which the
    # header emits as `int32_t` under C99.
    "prototypes/ffi_spike/Program.cs": {"Bytes": "JasBytes", "Status": "JasStatus"},
}

# ---------------------------------------------------------------------------
# THE TYPE TABLE
#
# Canonical tokens are the shapes the ABI actually has. Everything else on
# either side is UNKNOWN and reds (clause (d)).
# ---------------------------------------------------------------------------

# C spelling (normalised: collapsed whitespace, `struct ` dropped) -> canonical
C_CANON = {
    "JasEngine *": "ptr",
    "void *": "ptr",
    "const uint8_t *": "bytes-in",
    "uint8_t *": "bytes-in",
    "uintptr_t": "usize",
    "uintptr_t *": "usize-out",
    "uint32_t": "u32",
    "int32_t": "i32",
    "JasStatus": "i32",
    "float": "f32",
    "double": "f64",
    "void": "void",
    "JasBytes": "JasBytes",
}

# C# spelling (normalised) -> canonical
CS_CANON = {
    "IntPtr": "ptr",
    "nint": "ptr",
    "byte[]": "bytes-in",
    "byte[]?": "bytes-in",
    "byte*": "bytes-in",
    "nuint": "usize",
    "UIntPtr": "usize",
    "out nuint": "usize-out",
    "out UIntPtr": "usize-out",
    "uint": "u32",
    "int": "i32",
    "float": "f32",
    "double": "f64",
    "void": "void",
    "JasBytes": "JasBytes",
}

# The ONE C type that legitimately accepts more than one C# shape. A pointer to
# bytes may be marshalled as a raw pointer (the caller does the pinning) or as a
# managed array (the marshaller does). Both are correct; nothing else here is
# many-to-one, and a second entry in this table should have to argue for itself.
COMPATIBLE = {
    "bytes-in": {"bytes-in", "ptr"},
}


class Refuse(Exception):
    """The gate could not measure its subject. Never a pass."""


# ---------------------------------------------------------------------------
# The header
# ---------------------------------------------------------------------------

_C_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_C_LINE_COMMENT = re.compile(r"//[^\n]*")
# A declaration ends at the first `;`. Returns may be `struct X *`, `const T *`,
# a bare type, or a typedef'd name; the NAME is the last identifier before `(`.
_C_DECL = re.compile(
    r"(?P<ret>[A-Za-z_][A-Za-z0-9_ \*]*?)\s*(?P<name>jas_[a-z0-9_]+)\s*\((?P<args>[^;]*?)\)\s*;",
    re.S,
)


def _strip_c_comments(src: str) -> str:
    return _C_LINE_COMMENT.sub("", _C_COMMENT.sub("", src))


def _norm_c_type(text: str) -> str:
    """Collapse a C type to the spelling `C_CANON` is keyed by."""
    t = " ".join(text.split())
    t = re.sub(r"\bstruct\s+", "", t)
    t = re.sub(r"\s*\*", " *", t)          # `X*` and `X *` are one type
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _split_c_args(args: str) -> list[str]:
    """`void` is zero parameters, not one named `void`."""
    inner = " ".join(args.split())
    if inner in ("", "void"):
        return []
    return [a.strip() for a in inner.split(",")]


def _c_param_type(param: str) -> str:
    """Drop the parameter NAME, keep the type.

    A parameter is `<type> <name>` or `<type> *<name>` or an unnamed type. The
    name, when present, is the trailing identifier -- and only when the token
    before it is not itself the whole type.
    """
    p = " ".join(param.split())
    m = re.match(r"^(?P<type>.*?[\s\*])(?P<name>[A-Za-z_][A-Za-z0-9_]*)$", p)
    if m:
        candidate = _norm_c_type(m.group("type"))
        if candidate:
            return candidate
    return _norm_c_type(p)


def parse_header(src: str) -> dict[str, tuple[str, list[str]]]:
    """name -> (return type, [parameter types]), all normalised."""
    out: dict[str, tuple[str, list[str]]] = {}
    for m in _C_DECL.finditer(_strip_c_comments(src)):
        name = m.group("name")
        ret = _norm_c_type(m.group("ret"))
        params = [_c_param_type(a) for a in _split_c_args(m.group("args"))]
        out[name] = (ret, params)
    return out


# ---------------------------------------------------------------------------
# The C# side
# ---------------------------------------------------------------------------

_CS_EXTERN = re.compile(
    r"\bextern\s+(?P<ret>[A-Za-z_][A-Za-z0-9_\.\[\]\?\* ]*?)\s+"
    r"(?P<name>jas_[a-z0-9_]+)\s*\((?P<args>[^)]*)\)\s*;",
    re.S,
)


def _norm_cs_type(text: str) -> str:
    t = " ".join(text.split())
    t = re.sub(r"\s*\[\s*\]", "[]", t)
    t = re.sub(r"\s*\*", "*", t)
    return t.strip()


def _cs_param_type(param: str) -> str:
    """Drop the parameter NAME and any attributes, keep type and `out`/`ref`.

    ⛔ ATTRIBUTES ARE STRIPPED ONLY AT THE HEAD, AND THAT IS A MEASURED REPAIR.
    The first cut stripped any `[...]` followed by an identifier, which is also
    the shape of an ARRAY: `byte[] opJson` became `byteopJson`, and the gate
    reported nine REFUSALs against a tree with no mismatch in it. Caught by
    running the instrument on the real artifact before writing a fixture -- a
    fixture written first would have carried the same assumption.
    """
    p = " ".join(param.split())
    p = re.sub(r"^(?:\[[^\]]+\]\s*)+", "", p)   # [In], [MarshalAs(...)] -- leading only
    parts = p.split()
    if len(parts) >= 2:
        p = " ".join(parts[:-1])
    return _norm_cs_type(p)


def parse_cs(src: str) -> list[tuple[str, str, list[str], int]]:
    """[(name, return type, [parameter types], offset)] from `extern` decls."""
    out = []
    for m in _CS_EXTERN.finditer(src):
        args = [a for a in m.group("args").split(",") if a.strip()]
        out.append((
            m.group("name"),
            _norm_cs_type(m.group("ret")),
            [_cs_param_type(a) for a in args],
            m.start(),
        ))
    return out


def canon_cs(spelling: str, aliases: dict[str, str]) -> str | None:
    """Canonical token for a C# type, or None -- which is a REFUSAL upstream."""
    resolved = aliases.get(spelling, spelling)
    if resolved != spelling:
        resolved = C_CANON.get(resolved, resolved)
        if resolved in ("ptr", "usize", "i32", "u32", "f32", "f64", "void",
                        "JasBytes", "bytes-in", "usize-out"):
            return resolved
    return CS_CANON.get(spelling)


def compatible(c_token: str, cs_token: str) -> bool:
    return cs_token in COMPATIBLE.get(c_token, {c_token})


# ---------------------------------------------------------------------------
# The scan
# ---------------------------------------------------------------------------

def alias_is_stale(rel: str, spelling: str, code: str) -> bool:
    """An alias naming a type the file no longer declares (clause (f))."""
    return re.search(rf"\b(struct|enum|class)\s+{re.escape(spelling)}\b", code) is None


def scan(files: dict[str, str], header: dict[str, tuple[str, list[str]]]) -> tuple[list[str], int]:
    findings: list[str] = []
    total = 0

    for rel in sorted(files):
        lexed = csharp_source.lex(files[rel])
        code = lexed.code
        aliases = ALIASES.get(rel, {})

        for spelling in sorted(aliases):
            if alias_is_stale(rel, spelling, code):
                findings.append(
                    f"{rel}: STALE ALIAS '{spelling}' -- ALIASES claims this file "
                    f"declares it and no struct/enum/class of that name is here. "
                    f"Remove the entry or restore the type; an exemption that "
                    f"outlives its subject is a permanent hole")

        for name, ret, params, offset in parse_cs(code):
            total += 1
            line = csharp_source.line_of(code, offset) if hasattr(csharp_source, "line_of") \
                else code[:offset].count("\n") + 1
            where = f"{rel}:{line} {name}"

            if name not in header:
                findings.append(
                    f"{where}: bound, but {HEADER.name} declares no such function. "
                    f"This is EntryPointNotFoundException at the first call, on "
                    f"another machine")
                continue

            c_ret, c_params = header[name]

            c_ret_token = C_CANON.get(c_ret)
            if c_ret_token is None:
                findings.append(
                    f"{where}: REFUSING -- the header's return type '{c_ret}' is not "
                    f"in C_CANON. Add it with its C# counterpart; an unparsed type "
                    f"must never read as agreement")
                continue
            cs_ret_token = canon_cs(ret, aliases)
            if cs_ret_token is None:
                findings.append(
                    f"{where}: REFUSING -- the C# return type '{ret}' is not in "
                    f"CS_CANON and is not an ALIASES entry for this file")
                continue
            if not compatible(c_ret_token, cs_ret_token):
                findings.append(
                    f"{where}: RETURN TYPE -- header says '{c_ret}' ({c_ret_token}), "
                    f"binding says '{ret}' ({cs_ret_token})")

            if len(params) != len(c_params):
                findings.append(
                    f"{where}: ARITY -- header takes {len(c_params)} "
                    f"({', '.join(c_params) or 'void'}), binding takes {len(params)} "
                    f"({', '.join(params) or 'none'})")
                continue

            for i, (c_p, cs_p) in enumerate(zip(c_params, params)):
                c_token = C_CANON.get(c_p)
                if c_token is None:
                    findings.append(
                        f"{where}: REFUSING -- parameter {i} type '{c_p}' from the "
                        f"header is not in C_CANON")
                    continue
                cs_token = canon_cs(cs_p, aliases)
                if cs_token is None:
                    findings.append(
                        f"{where}: REFUSING -- parameter {i} type '{cs_p}' is not in "
                        f"CS_CANON and is not an ALIASES entry for this file")
                    continue
                if not compatible(c_token, cs_token):
                    findings.append(
                        f"{where}: PARAMETER {i} -- header says '{c_p}' ({c_token}), "
                        f"binding says '{cs_p}' ({cs_token})")

    return findings, total


def _load() -> tuple[dict[str, str], dict[str, tuple[str, list[str]]]]:
    if not HEADER.is_file():
        raise Refuse(f"{HEADER} is missing; there is no oracle to compare against")
    header = parse_header(HEADER.read_text(encoding="utf-8"))
    if len(header) < MIN_HEADER_DECLS:
        raise Refuse(
            f"only {len(header)} declaration(s) parsed out of {HEADER.name} "
            f"(floor {MIN_HEADER_DECLS}). Either the header shrank or this gate's "
            f"declaration pattern stopped matching it -- both are the gate's "
            f"problem and neither is a pass")

    files: dict[str, str] = {}
    for path in sorted(SEARCH_ROOT.rglob("*.cs")):
        if "/obj/" in path.as_posix() or "/bin/" in path.as_posix():
            continue
        text = path.read_text(encoding="utf-8")
        # ⛔ THE POPULATION IS DECIDED ON CODE, NOT ON PROSE, AND THAT IS A
        #    MEASURED REPAIR. The first cut tested the RAW text, so the moment a
        #    doc comment in `Canvas.cs` used the word `DllImport` the file joined
        #    the population and the OK line read "4 file(s)" while three carry
        #    bindings. Nothing was hidden by it -- over-inclusion is the safe
        #    direction -- but the number printed beside the verdict is a claim,
        #    and it was wrong. A count carries its scope; the sentence does not.
        if "DllImport" not in text:
            continue
        if "DllImport" in csharp_source.lex(text).code:
            files[path.relative_to(ROOT).as_posix()] = text
    if len(files) < MIN_FILES:
        raise Refuse(
            f"only {len(files)} C# file(s) under {SEARCH_ROOT.name}/ carry a "
            f"DllImport (floor {MIN_FILES}); a scan that found nothing is not a "
            f"clean tree")
    return files, header


# ---------------------------------------------------------------------------
# Self-test -- fixtures only, green on any tree
# ---------------------------------------------------------------------------

_HDR = """
struct JasBytes { const uint8_t *ptr; uintptr_t len; };
typedef struct JasEngine JasEngine;
struct JasEngine *jas_engine_new(void);
void jas_engine_free(struct JasEngine *e);
struct JasBytes jas_document_svg(struct JasEngine *e);
struct JasBytes jas_menu_state(struct JasEngine *e, const uint8_t *ctx_json, uintptr_t ctx_len);
JasStatus jas_dispatch_event(struct JasEngine *e, const uint8_t *op_json, uintptr_t len);
struct JasBytes jas_last_error_json(struct JasEngine *e);
uintptr_t jas_selection_len(struct JasEngine *e);
const uint8_t *jas_tool_name(uintptr_t index, uintptr_t *out_len);
"""

_GOOD = """
internal static unsafe class JasCore {
    [DllImport(Lib)] internal static extern IntPtr jas_engine_new();
    [DllImport(Lib)] internal static extern void jas_engine_free(IntPtr e);
    [DllImport(Lib)] internal static extern JasBytes jas_document_svg(IntPtr e);
    [DllImport(Lib)] internal static extern JasBytes jas_menu_state(IntPtr e, byte[] ctx, nuint len);
    [DllImport(Lib)] internal static extern int jas_dispatch_event(IntPtr e, byte[] op, nuint len);
    [DllImport(Lib)] internal static extern JasBytes jas_last_error_json(IntPtr e);
    [DllImport(Lib)] internal static extern nuint jas_selection_len(IntPtr e);
    [DllImport(Lib)] internal static extern IntPtr jas_tool_name(nuint index, out nuint len);
}
"""


def self_test() -> int:
    failures: list[str] = []
    header = parse_header(_HDR)

    def run(src: str, rel: str = "prototypes/fixture/JasCore.cs"):
        return scan({rel: src}, header)

    def green(label: str, src: str, rel: str = "prototypes/fixture/JasCore.cs"):
        findings, total = run(src, rel)
        if findings:
            failures.append(f"{label}: expected clean, got {findings}")
        if total == 0:
            failures.append(f"{label}: scanned ZERO bindings -- the fixture is not a control")

    def red(label: str, src: str, needle: str, rel: str = "prototypes/fixture/JasCore.cs"):
        findings, _ = run(src, rel)
        if not any(needle in f for f in findings):
            failures.append(f"{label}: expected a finding containing '{needle}', got {findings}")

    # (1) THE INSTRUMENT BEFORE THE SUBJECT. The header fixture must parse into
    #     the shapes every later arm is compared against; an arm driven by an
    #     empty header would be green for the wrong reason in BOTH directions.
    if len(header) != 8:
        failures.append(f"1 header fixture parsed {len(header)} decls, expected 8")
    if header.get("jas_menu_state") != ("JasBytes", ["JasEngine *", "const uint8_t *", "uintptr_t"]):
        failures.append(f"1 header fixture mis-parsed jas_menu_state: {header.get('jas_menu_state')}")
    if header.get("jas_engine_new") != ("JasEngine *", []):
        failures.append(f"1 `(void)` must parse as ZERO params: {header.get('jas_engine_new')}")
    if header.get("jas_tool_name") != ("const uint8_t *", ["uintptr_t", "uintptr_t *"]):
        failures.append(f"1 out-pointer mis-parsed: {header.get('jas_tool_name')}")

    # (2) The green control, and it is proven non-empty by `green` itself.
    green("2 the real shapes", _GOOD)

    # (3) `nuint` -> `int` on a LENGTH. The defect JasCore.cs's own comment names.
    red("3 usize bound as int", _GOOD.replace(
        "jas_menu_state(IntPtr e, byte[] ctx, nuint len)",
        "jas_menu_state(IntPtr e, byte[] ctx, int len)"), "PARAMETER 2")

    # (4) ...and the same defect on a RETURN, which is a different code path.
    red("4 usize returned as int", _GOOD.replace(
        "extern nuint jas_selection_len", "extern int jas_selection_len"), "RETURN TYPE")

    # (5) Arity, in both directions.
    red("5a a parameter dropped", _GOOD.replace(
        "jas_menu_state(IntPtr e, byte[] ctx, nuint len)",
        "jas_menu_state(IntPtr e, byte[] ctx)"), "ARITY")
    red("5b a parameter invented", _GOOD.replace(
        "jas_last_error_json(IntPtr e)",
        "jas_last_error_json(IntPtr e, nuint extra)"), "ARITY")

    # (6) A by-value struct bound as a pointer -- 16 bytes read as 8.
    red("6 JasBytes bound as IntPtr", _GOOD.replace(
        "extern JasBytes jas_document_svg", "extern IntPtr jas_document_svg"), "RETURN TYPE")

    # (7) A name the header does not declare.
    red("7 unknown entry point", _GOOD.replace(
        "jas_document_svg(IntPtr e)", "jas_document_svgg(IntPtr e)"), "declares no such function")

    # (8) AN UNKNOWN C# TYPE IS A REFUSAL, NOT AN EXCLUSION. This is the arm that
    #     separates this gate from a null-on-miss resolver: a type it cannot map
    #     must RED, never quietly count as agreement.
    red("8 unknown C# type refuses", _GOOD.replace(
        "extern nuint jas_selection_len", "extern SomeStruct jas_selection_len"), "REFUSING")

    # (9) ...and the same on the header side, in BOTH POSITIONS.
    #
    # ⛔ 9b EXISTS BECAUSE 9a ALONE LEFT A LIVE MUTANT. `C_CANON.get(c_p, "usize")`
    #    -- an unknown header PARAMETER type silently defaulting -- SURVIVED a
    #    self-test that already had 9a, because 9a mutates a RETURN type and the
    #    two lookups are two code paths. A census of the return positions does
    #    not cover the parameter positions, and the reverse: this seat's own card
    #    (a census of parameters does not cover the function that reads them),
    #    arriving inside the gate written to apply it.
    hdr_odd_ret = parse_header(_HDR.replace(
        "uintptr_t jas_selection_len", "wchar_t jas_selection_len"))
    findings, _ = scan({"prototypes/fixture/JasCore.cs": _GOOD}, hdr_odd_ret)
    if not any("REFUSING" in f and "C_CANON" in f and "return type" in f for f in findings):
        failures.append(f"9a unknown C RETURN type must refuse, got {findings}")

    hdr_odd_param = parse_header(_HDR.replace(
        "jas_menu_state(struct JasEngine *e, const uint8_t *ctx_json, uintptr_t ctx_len)",
        "jas_menu_state(struct JasEngine *e, const uint8_t *ctx_json, wchar_t ctx_len)"))
    if hdr_odd_param.get("jas_menu_state", ("", []))[1][-1] != "wchar_t":
        failures.append("9b the header mutation did not take -- the arm proves nothing")
    findings, _ = scan({"prototypes/fixture/JasCore.cs": _GOOD}, hdr_odd_param)
    if not any("REFUSING" in f and "C_CANON" in f and "parameter 2" in f for f in findings):
        failures.append(f"9b unknown C PARAMETER type must refuse, got {findings}")

    # (10) `const uint8_t *` is the ONE many-to-one row: three spellings, all green.
    for spell in ("byte[]", "IntPtr", "byte*"):
        green(f"10 bytes-in as {spell}", _GOOD.replace("byte[] ctx", f"{spell} ctx"))

    # (11) ...and that latitude does not leak to the OTHER pointer kinds. An
    #      engine handle bound as a managed array is a defect, and `COMPATIBLE`
    #      having exactly one row is what makes that true.
    red("11 engine handle as byte[]", _GOOD.replace(
        "jas_last_error_json(IntPtr e)", "jas_last_error_json(byte[] e)"), "PARAMETER 0")

    # (12) A BINDING IN A COMMENT IS NOT A BINDING, and one in a string is not
    #      either -- the gate reads `lexed.code`, so both are blanked. Without
    #      this a doc comment quoting a superseded signature would red the tree.
    green("12 a wrong signature in a comment", _GOOD.replace(
        "internal static unsafe class JasCore {",
        "internal static unsafe class JasCore {\n"
        "    // [DllImport(Lib)] internal static extern int jas_selection_len(IntPtr e);"))
    green("12b a wrong signature in a string", _GOOD.replace(
        "internal static unsafe class JasCore {",
        'internal static unsafe class JasCore {\n'
        '    const string Doc = "extern int jas_selection_len(IntPtr e);";'))

    # (13) THE ALIAS ROW, both directions. A file whose entry is in ALIASES may
    #      spell the struct locally; a file WITHOUT an entry may not.
    alias_src = _GOOD.replace("JasBytes", "Bytes").replace(
        "internal static unsafe class JasCore {",
        "internal struct Bytes { }\ninternal static unsafe class JasCore {")
    saved = dict(ALIASES)
    try:
        ALIASES["prototypes/aliased/Program.cs"] = {"Bytes": "JasBytes"}
        green("13a aliased struct name", alias_src, "prototypes/aliased/Program.cs")
        red("13b the same file without an alias entry", alias_src,
            "REFUSING", "prototypes/unaliased/Program.cs")
        # (14) A STALE ALIAS -- the entry stands, the type is gone.
        ALIASES["prototypes/stale/Program.cs"] = {"Bytes": "JasBytes", "Gone": "JasStatus"}
        red("14 stale alias reported", alias_src, "STALE ALIAS", "prototypes/stale/Program.cs")
    finally:
        ALIASES.clear()
        ALIASES.update(saved)

    # (15) THE VACUITY ARMS, driven rather than asserted. Each floor must be the
    #      thing that reds -- a floor nobody drives is arithmetic, not a gate.
    class _Tmp:
        pass

    for label, patch, needle in (
        ("15a header floor", {"MIN_HEADER_DECLS": 10_000}, "declaration(s) parsed"),
        ("15b file floor", {"MIN_FILES": 10_000}, "carry a"),
    ):
        original = {k: globals()[k] for k in patch}
        globals().update(patch)
        try:
            _load()
        except Refuse as exc:
            if needle not in str(exc):
                failures.append(f"{label}: refusal did not name its floor: {exc}")
        else:
            failures.append(f"{label}: the floor did not fire")
        finally:
            globals().update(original)

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(
        "check_shell_abi_bindings SELF-TEST: OK (the header fixture is parsed and "
        "checked FIRST, including `(void)` as zero params and an out-pointer; the "
        "green control is proven non-empty; nuint->int reds on a parameter AND on a "
        "return; arity reds in both directions; a by-value JasBytes bound as IntPtr "
        "reds; an undeclared entry point reds; an unknown type REFUSES on the C# "
        "side and on the header side, in BOTH the return and the parameter position; "
        "`const uint8_t *` accepts all three spellings "
        "while an engine handle accepts only a pointer; a wrong signature in a "
        "comment and in a string stay green; an alias resolves only for its own "
        "file and goes STALE when its type leaves; both vacuity floors are DRIVEN)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        files, header = _load()
    except Refuse as exc:
        print(f"REFUSING: {exc}")
        return 1
    findings, total = scan(files, header)
    if total < MIN_BINDINGS:
        print(f"REFUSING: only {total} binding(s) found across {len(files)} file(s) "
              f"(floor {MIN_BINDINGS}). A scan that parsed almost nothing reports a "
              f"clean tree from a broken parser")
        return 1
    if findings:
        print("FAIL: a C# DllImport disagrees with the C header it calls through.")
        for f in findings:
            print(f"  {f}")
        print()
        print("P/Invoke is unchecked: every one of these compiles, links and runs.")
        print(f"The header is generated from Rust and kept current by")
        print(f"check_cbindgen_freshness.py; fix the C# side to match it.")
        return 1
    print(f"check_shell_abi_bindings: OK ({total} binding(s) in {len(files)} file(s) "
          f"checked against {len(header)} declaration(s) in {HEADER.name}; name, "
          f"arity, every parameter and every return)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
