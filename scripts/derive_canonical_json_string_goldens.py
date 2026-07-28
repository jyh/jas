#!/usr/bin/env python3
"""Generate test_fixtures/algorithms/canonical_json_string.json.

The `canonical` field of every vector is produced by the adjudicator itself --
Python's json.dumps(s, ensure_ascii=False) -- so the fixture cannot encode a
hand-typed mistake, and `reparses` is MEASURED (json.loads round trip), not
asserted.
"""
import json, os, sys

DOC = [
    "The canonical Test-JSON STRING escaping rule, pinned byte-for-byte.",
    "",
    "Every string a canonical Test-JSON writer emits -- an element name, a tspan's",
    "content, a recipe op name, a recorded input id, a text-decoration member, a",
    "concept param -- passes through ONE escaper per port: `json_escape_string` in",
    "jas_dioxus/src/geometry/test_json.rs and `jsonEscapeString` in",
    "JasSwift/Sources/Geometry/TestJson.swift. This file is that escaper's whole",
    "contract, and it is the only place the rule is written down.",
    "",
    "WHY IT EXISTS. Before 2026-07-27 there were three different string writers per",
    "port at three different escaping levels, and the byte oracle behind the codec",
    "gates could not express a control character at all (coverage gap",
    "`codec-no-control-chars`, CORPUS_CENSUS.md 5.5). Measured on that commit:",
    "  (a) `JsonObj::str_val` / `JsonObj.str` applied exactly two replacements",
    "      (backslash, quote), so a text content of 'a<LF>b' serialised to a raw LF",
    "      inside a JSON string -- which serde_json AND JSONSerialization both",
    "      REJECT. A loud ceiling, not a silent divergence.",
    "  (b) Rust's `canonical_value` (recipe params, recorded ops) used Rust's `{:?}`",
    "      Debug, which spells U+0000 as \\\\0 and U+0001 as \\\\u{1} -- neither is JSON",
    "      -- and also escapes any scalar Rust calls non-printable, so a combining",
    "      mark, a ZWJ, NBSP or a soft hyphen became \\\\u{301} and friends. Swift's",
    "      mirror `canonicalRecordedValue` emitted every one of those RAW. The two",
    "      ports therefore disagreed byte-for-byte on the params path, and no",
    "      fixture reached it. That was a LIVE divergence, not a ceiling.",
    "  (c) `opt_str_vec`, `text_decoration_json` and the recipe `targets` list",
    "      quoted with no escaping at all, in both ports.",
    "",
    "THE RULE, and who adjudicates it. Python's json.dumps(s, ensure_ascii=False),",
    "per the house adjudication hierarchy (absent a guiding principle, the Python",
    "reference decides): the two-character escapes for backslash, quote, U+0008,",
    "U+000C, U+000A, U+000D and U+0009; \\\\u00xx with LOWER-CASE hex for every other",
    "scalar below U+0020; every scalar at U+0020 and above emitted literally --",
    "including U+007F DEL, which JSON does not require escaping and which no vector",
    "in this corpus had carried before this file. Solidus is NOT escaped.",
    "",
    "Every `canonical` below was produced BY that json.dumps call rather than typed,",
    "and every `reparses` was measured by feeding `canonical` back through",
    "json.loads and comparing with `input`.",
    "",
    "Each vector's `input` and `canonical` are ordinary JSON strings, so the FIXTURE",
    "format never had this ceiling -- only the document codec did. The corpus already",
    "carried multi-line text in text_layout.json's `hard_newline` vector, which the",
    "algorithms harness feeds to layoutText directly, never through the document",
    "writer.",
    "",
    "Driven in Rust by geometry::test_json::tests::canonical_json_string_corpus and",
    "in Swift by CanonicalJsonStringTests.canonicalJsonStringCorpus.",
]

VECTORS = [
    ("plain_ascii", "abc",
     "The baseline: nothing to escape, and the overwhelming majority of every existing golden."),
    ("mixed_case_is_verbatim", "Aa Zz MiXeD",
     "A literal is copied through byte-for-byte, case included. Added because a mutation that lower-cased the pass-through arm survived the first 22 vectors: every one of them was lower-case, so nothing in the corpus could see it."),
    ("empty", "",
     "An empty string is a pair of quotes, not null -- the null-for-empty rule lives one level up in empty_as_null / emptyAsNull."),
    ("quote", "a\"b",
     "One of the two characters the pre-lift writers already handled; pinned so the lift cannot lose it."),
    ("backslash", "a\\b",
     "The other pre-lift escape."),
    ("backslash_before_quote", "a\\\"b",
     "Escape ORDER, made observable: a pass that replaced the quote before the backslash emits three backslashes here instead of two."),
    ("solidus_is_not_escaped", "a/b",
     "JSON permits \\/ but does not require it, and json.dumps does not emit it. A port that escaped it would still produce valid JSON and would still diverge byte-for-byte."),
    ("newline", "a\nb",
     "THE LIFT. Serialised to a raw LF before 2026-07-27, which both parsers rejected."),
    ("tab", "a\tb",
     "Same class as newline; the short escape is the json.dumps spelling, not \\u0009."),
    ("carriage_return", "a\rb",
     "The third short escape a text content can plausibly carry (a CRLF paste)."),
    ("backspace", "a\bb",
     "U+0008 has a short escape in JSON; a port emitting \\u0008 here is still valid JSON and still a byte divergence."),
    ("form_feed", "a\fb",
     "U+000C, the last of the five short escapes."),
    ("nul", "a\x00b",
     "U+0000 has NO short escape in JSON. Rust's Debug spelled it \\0, which is not JSON."),
    ("unit_separator_lowercase_hex", "ab",
     "U+001F, the top of the escaped range, and the case convention: json.dumps emits lower-case hex, so \\u001f and not \\u001F."),
    ("space_is_the_first_literal", "a b",
     "U+0020 is the boundary itself: the first scalar emitted literally."),
    ("del_is_literal", "ab",
     "U+007F needs no JSON escape and both parsers accept it raw -- measured. It is the one character the format could ALWAYS express and that no fixture had ever carried. Rust's Debug escaped it to \\u{7f}, which is not JSON."),
    ("non_ascii_bmp", "aéb",
     "Non-ASCII is emitted literally (ensure_ascii=False), which existing goldens already rely on."),
    ("astral", "a\U0001F600b",
     "A scalar above the BMP is one Rust char and one Swift unicode scalar but two UTF-16 code units; it must not become a surrogate pair on the wire."),
    ("combining_mark", "aéb",
     "Rust's escape_debug escapes grapheme-extend scalars, so the pre-lift params writer emitted \\u{301} here while Swift emitted the mark raw. This is divergence (b), reduced to one character."),
    ("zero_width_joiner", "\U0001F468‍\U0001F469",
     "U+200D is category Cf, so Rust's Debug escaped it and Swift did not -- the same divergence, on the family-emoji sequence the text corpus already measures."),
    ("no_break_space", "a b",
     "U+00A0 is Zs-other-than-space, the third arm of Rust's non-printable rule."),
    ("multi_line_text", "line one\nline two",
     "The reason the ceiling mattered: text is the largest untested surface in the app, and a fixture format that cannot express a newline cannot gate multi-line text at all."),
    ("every_escape_at_once", "\"\\\b\f\n\r\t z",
     "One string exercising all five short escapes, both literal escapes, the \\u00xx arm and a literal above U+0020, so a port that gets one arm's order wrong cannot pass by getting each arm right in isolation."),
]

out = {"_doc": DOC, "vectors": []}
for name, s, why in VECTORS:
    canonical = json.dumps(s, ensure_ascii=False)
    reparses = json.loads(canonical) == s
    out["vectors"].append({
        "name": name,
        "why": why,
        "input": s,
        "canonical": canonical,
        "reparses": reparses,
    })

names = [v["name"] for v in out["vectors"]]
assert len(names) == len(set(names)), "duplicate vector name"
assert all(v["reparses"] for v in out["vectors"]), "a vector does not round trip"

DEFAULT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "test_fixtures", "algorithms", "canonical_json_string.json",
)

path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
with open(path, "w", encoding="utf-8", newline="") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"wrote {len(out['vectors'])} vectors to {path}")
for v in out["vectors"]:
    print(f"  {v['name']:32} {v['canonical']!r}")
