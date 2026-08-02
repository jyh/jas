#!/usr/bin/env python3
"""Per-family non-default variance: a corpus of defaults cannot see a dropped field.

WHY THIS EXISTS
---------------
A read-only census on 2026-08-02 measured 446 fixture files / 1,751 vectors and
found SEVEN dimensions frozen corpus-wide. `opacity` is 1.0 in 2016 of 2113
observations and in 334 of 334 under `actions/`. 90.6% of elements carry no
transform, and NO transform anywhere has a negative determinant -- there is no
mirror and no flip in the entire corpus. `selected_layer` is 0 in all 268
observations. `stroke` is null in 753 of 758 slots.

Every one of those frozen constants is EXACTLY the struct default, verified
field-by-field against `CommonProps::default()`. That is not a coincidence, it
is the mechanism: fixtures are authored by CONSTRUCTING a document, so they
inherit the constructor.

    A CORPUS WHOSE EVERY VALUE **IS** THE DEFAULT CANNOT DISTINGUISH A DROPPED
    FIELD FROM A PRESERVED ONE.

That is the banked Swift copy-site omission class -- "a copy site constructs
instead of clones, so every new element field is silently dropped"
(scripts/check_swift_copy_sites.py) -- seen from the other end. The defect and
the blindness share a cause: a constructor. One writes the default in, the
other cannot tell that it was written in.

AND THE VARIANCE THAT DOES EXIST IS CAMPAIGN RESIDUE. The family x field
cross-tab is near-DIAGONAL: `transform` is non-default in 11 of 18 `transform_*`
fixtures and 0 of the other 172; `locked` only under `lock_*`; `stroke` only
under `set_*`. The two fields varied everywhere are `name` and `fill` --
precisely the two that had dedicated campaigns. The corpus varies where we once
looked, which predicts the next blind spot exactly: ANY FIELD THAT NEVER HAD A
CAMPAIGN.

WHAT DOES NOT WORK, AND WAS MEASURED BEFORE THIS WAS BUILT
----------------------------------------------------------
"Assert field F takes at least N distinct values corpus-wide." `opacity` takes
NINE distinct values across the corpus and clears any sane floor while
`actions/` sits at 334 of 334 default. AGGREGATION DILUTES EXACTLY WHAT HIDES
THE PROBLEM, so the primitive here is PER-FAMILY and nothing is pooled.

`min_witnesses` (R7) is also weaker than its docs claimed: it was proven GREEN
on twelve identical copies of one `gradient_remap` vector, with
`min_discriminating` RISING to 12 against a floor of 11, because it counts over
a predicate -- it sees the absence of a separation but never its CONCENTRATION.
docs/CHECKERS.md was narrowed in the same change that added this file.

THE PRIMITIVE (P1)
------------------
For each (family F, field P): how many DOCUMENTS of F carry a value of P that
is not P's struct default, counted over the elements to which P applies.

  * A FAMILY is `<fixture-subdirectory>/<leading token of the file name>`, with
    a trailing `_expected` stripped -- `operations/transform`, `actions/align`.
    That is the same grouping the census's own sentences use ("11 of 18
    `transform_*` fixtures").
  * A DOCUMENT is one canonical test JSON: an object carrying `layers`.
  * P APPLIES to an element of type T when P is declared on `CommonProps`
    (every element) or on T's own `*Elem` struct (that type only). A `fill` slot
    does not exist on a layer, so a layer can never satisfy a `fill` obligation.
  * A MISSING KEY IS THE DEFAULT. That is the canonical writer's stated
    identity-omission convention (`extended_element_fields` in
    jas_dioxus/src/geometry/test_json.rs: "every key is emitted CONDITIONALLY on
    being non-default"). It is also the conservative reading -- it can only
    LOWER a carrier count, never raise one, so it cannot turn a red green.

DEFAULTS ARE DERIVED FROM THE SOURCE, NEVER TYPED HERE
-------------------------------------------------------
There is no table of defaults in this file. They are read out of
`jas_dioxus/src/geometry/element.rs` (`impl Default for CommonProps`, the
`Option<...>` fields of each `*Elem`), `jas_dioxus/src/document/document.rs`
(`impl Default for Document`), and -- for enum-valued defaults -- the canonical
writer's own `X::Variant => "string"` arms, so that `Visibility::Preview`
resolves to the byte `"preview"` that actually appears in a fixture.

A HAND-TYPED DEFAULT WOULD SILENTLY MOVE THE FLOOR. If someone changed
`CommonProps::default().opacity` to 0.9, a hand-typed 1.0 here would start
counting 1.0-valued elements as carriers and the gate would report variance
that does not exist. Derivation makes that change reclassify the corpus
instead, which is the honest answer.

THE PARSE FAILS CLOSED. If `impl Default for CommonProps` cannot be found, an
initializer holds an expression this file cannot resolve, or an `Element`
variant's payload type resolves to no struct, it RAISES. An empty default map
would make every value non-default and paint the corpus green.

That last clause was added after the gate was attacked. The first cut resolved a
variant's payload with `struct_opts.get(name, {})`, and
`Element::Live(super::live::LiveVariant)` is not declared in element.rs -- so it
resolved to nothing, and all 46 live elements across 20 families contributed
ZERO `fill` and `stroke` slots. It failed OPEN, in the one place the rest of the
file was careful to fail closed, and it reported the gap as a confident wrong
sentence: an obligation on a live-only family said "`fill` is declared on a
struct none of this family's element types use", when `fill` is declared on
`GeneratedElem` in the file the parser did not read.

ITERATE THE OBLIGATION, NOT THE EVIDENCE
-----------------------------------------
`scripts/default_variance_ledger.json` is the subject of this gate. It is
walked; the corpus is only measured. Walking the fields you happen to FIND
would miss the field nobody varied -- which is the entire defect. This is the
same inversion that made `scripts/checker_lane_registry.json` work, and it is
here for the same reason: a rule phrased over what it finds cannot notice an
absence.

  * `obligations` are FLOORS. Each says a (family, field) pair must carry at
    least `min` non-default documents, and each carries a `reason` naming the
    consequence. Below the floor is red.
  * `declared_debt` is EXACT, in both directions. The thin-cell finding is
    unpayable today, so it is recorded with its measurement rather than
    forgotten. If reality moves toward health, someone paid part of the debt
    and the row must be promoted or restated; if it moves away, the corpus
    thinned where we already knew it was thin. Either way the number is a red,
    not a stale comment. Each row declares WHICH WAY health lies (`improves`),
    because the first cut assumed "up is better" and duly reported a corpus
    that had just lost a lock family as progress.

WHY OBLIGATIONS ARE FLOORS AND DEBT IS EXACT -- the slack question, answered
rather than dodged. This house's rule is "a floor with slack is a floor with a
hole exactly the size of the slack", and it is right for a floor that encodes a
DECISION (MIN_DECLARED_LANES: adding a lane should force a ruling). It is wrong
here for obligations, whose whole purpose is to make ADDING A CARRIER CHEAP: an
exact obligation would red on every unrelated fixture that happened to vary the
field, which is the behaviour we are trying to encourage. The ratchet lives on
the DEBT side instead, where exactness costs nothing and buys the promotion
signal. Headroom on every obligation is printed on the green path so the slack
is visible rather than implied.

BOTH DIRECTIONS. Besides the floors, the ledger itself is policed: a row naming
a family the corpus no longer has, a field with no derived default, a pair with
ZERO applicable slots (an obligation ranging over nothing), a `min` below 1, or
an empty `reason` are all red. A stale row is not a harmless row --
`swift:dropdown` asserted for months that JasSwift lacked a feature it had
shipped, and a seat read that row, believed it, and set out to rebuild it.

WHAT THIS GATE CANNOT SEE -- stated on the GREEN path as well as the red
------------------------------------------------------------------------
  * It counts fields PRESENT IN FIXTURE JSON. A field the canonical writer
    never emits is invisible here no matter how badly it is dropped.
  * THE VOCABULARY IS 16 FIELD NAMES, AND 73 ELEMENT-STRUCT SLOTS SIT OUTSIDE
    IT. A field enters only by being on `CommonProps` or by being
    `Option`-typed. `PathElem::fill_rule`, `GroupElem::isolated_blending` and
    `knockout_group`, `width_points`, and the whole 21-field TextElem
    typography block are plain-typed on structs with no `Default` impl, so
    there is no default to read and they are outside the primitive entirely.
    That set skews hard toward exactly the never-had-a-campaign fields this
    file predicts as the next blind spot -- the gate's own thesis pointed at
    the gate. Pinning the COUNT (`UNWATCHED_ELEMENT_FIELDS`) is the cheap part
    and is done, so a new one arrives with a ruling instead of in silence;
    giving them defaults to measure against is not, and is not attempted here.
  * It counts a document as a carrier when ANY applicable element in it holds a
    non-default value, so it sees a family's breadth and never its DEPTH.
  * It reads the RUST defaults. A port whose default differs (Swift's
    `CommonProps` init, the Python reference interpreter) is not consulted, so
    a per-port default divergence reads as agreement.
  * It counts a value being non-default, not the value MEANING anything. A
    transform of `scale(1,1)` is non-default and semantically inert, and this
    gate scores it as a carrier. In particular it cannot see the census's
    "no negative determinant anywhere" finding, which is a claim about the
    VALUES of a non-default field, not about how many carry one.
  * Dimensions that are not struct defaults at all -- "646 of 771 boxes are
    square", "638 of 686 rx/ry pairs are equal", "colour space rgb 707 to cmyk
    1" -- are outside the primitive by construction. `rx` has no derivable
    default because `RectElem` has no `Default` impl, and squareness is a
    relation between two fields rather than a field. They are recorded in the
    ledger's `out_of_reach` section so the omission is visible.
  * A family whose documents all come from one setup SVG can satisfy a floor
    with N copies of one situation. This is a POPULATION count, exactly like
    `min_rulable_vectors`; it cannot see collinearity.

Usage:
    python3 scripts/check_default_variance.py
    python3 scripts/check_default_variance.py --self-test
    python3 scripts/check_default_variance.py --report
"""

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "test_fixtures")
SCRIPTS = os.path.join(REPO, "scripts")
LEDGER = os.path.join(SCRIPTS, "default_variance_ledger.json")

ELEMENT_RS = os.path.join(REPO, "jas_dioxus", "src", "geometry", "element.rs")
DOCUMENT_RS = os.path.join(REPO, "jas_dioxus", "src", "document", "document.rs")
TEST_JSON_RS = os.path.join(REPO, "jas_dioxus", "src", "geometry", "test_json.rs")
# `Element::Live` carries `super::live::LiveVariant`, whose member structs live
# here rather than in element.rs. Read because a variant this file cannot
# resolve used to contribute ZERO element fields SILENTLY -- see
# `resolve_payload`.
LIVE_RS = os.path.join(REPO, "jas_dioxus", "src", "geometry", "live.rs")

# Keys whose value is a subtree of further elements. The walk descends these
# and nothing else -- deliberately NOT `mask`, whose subtree is artwork owned by
# its host rather than a document element (the same rule
# check_preservation_corpus.py's walk follows).
CHILD_KEYS = ("layers", "children", "symbols")

# A family needs at least this many documents before a "fewer than three
# carriers" verdict on it means anything: a two-document family cannot reach
# three carriers however varied it is, so counting its cells as thin would
# inflate the debt with arithmetic rather than blindness.
MIN_FAMILY_DOCS = 3

# The debt headline counts cells below this many carriers. Three, because two
# carriers cannot separate "this family varies the field" from "one fixture
# happens to".
THIN = 3

# Anti-vacuity: how few derived defaults means the Rust parse has degraded.
# A PARSE floor, so it is hand-typed on purpose -- there is no independent
# oracle for "how many fields CommonProps has" that is not another parse of the
# same file, and a floor that agrees with any breakage is worse than none.
# 9 common + 6 element-Option + selected_layer = 16 today.
MIN_DERIVED_DEFAULTS = 16

# How many `<struct>.<field>` slots on the structs an Element can actually BE
# are OUTSIDE the vocabulary, because they are neither on CommonProps nor
# Option-typed and so have no derivable default. EXACT, and hand-typed for the
# same reason as the floor above: there is no oracle for it but another parse.
# It is pinned because MIN_DERIVED_DEFAULTS only notices the vocabulary
# SHRINKING, and adding a plain-typed field to an Elem struct moves neither
# number -- so without this the third way to add a field arrives in silence.
# 73 today over 14 payload structs; see the self-test for what lives in there.
UNWATCHED_ELEMENT_FIELDS = 73


class SourceParseError(RuntimeError):
    """The Rust source could not be read for its defaults.

    Raised rather than defaulted to an empty map. With no defaults every value
    counts as non-default, so the corpus would score as maximally varied --
    the gate would paint the exact condition it exists to detect as healthy.
    """


# ---------------------------------------------------------------------------
# defaults, derived from the Rust source
# ---------------------------------------------------------------------------

ABSENT = object()          # a key the fixture does not carry


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise SourceParseError(
            f"cannot read {os.path.relpath(path, REPO)} ({e}). Defaults are "
            f"DERIVED from this file; an unreadable source cannot be treated "
            f"as 'no defaults', because that scores every value as non-default."
        ) from e


def split_top_level(body):
    """Split a Rust struct-literal body on commas at brace/paren depth 0."""
    out, depth, cur = [], 0, []
    for ch in body:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append("".join(cur))
    return out


def enum_strings(test_json_src):
    """`{(Enum, Variant): "json string"}` as the canonical writer spells them.

    Derived from the writer rather than assumed, so `Visibility::Preview`
    resolves to the byte sequence a fixture actually holds. A variant spelled
    two different ways in two writers is ambiguous and is refused at lookup.
    """
    tbl = {}
    for m in re.finditer(r'\b([A-Z]\w*)::([A-Z]\w*)\s*=>\s*"([^"]*)"', test_json_src):
        tbl.setdefault((m.group(1), m.group(2)), set()).add(m.group(3))
    return tbl


def rust_literal_to_json(expr, enums, where):
    """One Rust initializer expression as the JSON value a fixture would hold."""
    e = expr.strip()
    if e == "None":
        return None
    if e == "true":
        return True
    if e == "false":
        return False
    if re.fullmatch(r"-?\d+\.\d+", e):
        return float(e)
    if re.fullmatch(r"-?\d+", e):
        return int(e)
    m = re.fullmatch(r"([A-Z]\w*)::([A-Z]\w*)", e)
    if m:
        spellings = enums.get((m.group(1), m.group(2)))
        if not spellings:
            raise SourceParseError(
                f"{where}: default is {e}, but the canonical writer has no "
                f"`{e} => \"...\"` arm, so this gate cannot know what byte the "
                f"default takes in a fixture. Teach enum_strings() where the "
                f"spelling lives rather than guessing one."
            )
        if len(spellings) > 1:
            raise SourceParseError(
                f"{where}: {e} is written {sorted(spellings)} in different "
                f"places; an ambiguous default cannot classify a fixture value."
            )
        return next(iter(spellings))
    raise SourceParseError(
        f"{where}: cannot resolve the default expression {e!r} to a JSON "
        f"value. Refusing rather than skipping the field: a field silently "
        f"dropped from the vocabulary is a field nothing can obligate."
    )


def struct_options(src):
    """`{struct name: {Option field: None}}` for every `pub struct X { .. }`.

    NOT restricted to `*Elem`. The Element enum's payload types are not all
    named that way and not all declared in element.rs -- `Live` carries
    `super::live::LiveVariant`, whose members are `CompoundShape`,
    `ReferenceElem`, `RecordedElem`, `GeneratedElem`.
    """
    out = {}
    for sm in re.finditer(r"pub struct (\w+)\s*\{(.*?)\n\}", src, re.S):
        opts = {}
        for f, t in re.findall(r"^\s*pub (\w+):\s*([^,\n]+),", sm.group(2), re.M):
            if t.strip().startswith("Option<"):
                opts[f] = None
        out[sm.group(1)] = opts
    return out


def non_option_fields(src):
    """`{struct name: [non-Option, non-`common` field]}` -- the UNWATCHED set.

    These have no derivable default (no `Default` impl on any `*Elem`), so they
    are outside the vocabulary entirely. Counted so the size of that blind spot
    is a pinned number rather than an impression; see the self-test.
    """
    out = {}
    for sm in re.finditer(r"pub struct (\w+)\s*\{(.*?)\n\}", src, re.S):
        out[sm.group(1)] = [
            f for f, t in re.findall(r"^\s*pub (\w+):\s*([^,\n]+),", sm.group(2), re.M)
            if not t.strip().startswith("Option<") and f != "common"]
    return out


def enum_payloads(src):
    """`{enum name: [payload type names]}`, module paths stripped."""
    out = {}
    for em in re.finditer(r"pub enum (\w+) \{(.*?)\n\}", src, re.S):
        out[em.group(1)] = [
            p.strip().rpartition("::")[2]
            for _v, p in re.findall(r"^\s*([A-Z]\w*)\((.*?)\),", em.group(2), re.M)]
    return out


def element_payload_structs(element_src, live_src):
    """Every struct an `Element` can actually BE, following enum payloads.

    Scoped deliberately: `pub struct Transform`, `Fill` and `ConceptDef` are
    also in these files but nothing is an instance of them, so counting their
    fields would inflate the blind spot with types no fixture element has.
    """
    payloads = enum_payloads(element_src)
    payloads.update(enum_payloads(live_src))
    known = set(struct_options(element_src)) | set(struct_options(live_src))
    out = set()
    for p in payloads.get("Element", []):
        if p in known:
            out.add(p)
        else:
            out |= {m for m in payloads.get(p, []) if m in known}
    return out


def resolve_payload(type_name, structs, payloads, where):
    """The Option fields an `Element` variant's payload contributes.

    FAILS CLOSED, and that is the point. Until 2026-08-02 this was
    `structs.get(name, {})`: `Element::Live(super::live::LiveVariant)` resolved
    to NOTHING, so all 46 live elements in 20 families contributed zero `fill`
    and zero `stroke` slots and the gate could not see a live element's paint at
    all. Worse, the miss came back as a CONFIDENT WRONG SENTENCE -- an
    obligation on a live-only family reported "`fill` is declared on a struct
    none of this family's element types use", which is false: `fill` is declared
    on `GeneratedElem`, in the file this parser did not read.

    An enum payload contributes the UNION of its members' Option fields. Union,
    not intersection, because the question a slot answers is "could an element
    of this type carry this field" -- one member declaring it is enough to
    defeat "ranges over nothing" -- and a slot can never invent a carrier, since
    an absent key reads as the default.
    """
    bare = type_name.strip().rpartition("::")[2]
    if bare in structs:
        return dict(structs[bare])
    if bare in payloads:
        merged = {}
        for member in payloads[bare]:
            if member not in structs:
                raise SourceParseError(
                    f"{where}: `{bare}::{member}` names a struct this gate "
                    f"cannot find, so that member would contribute no fields "
                    f"and its paint would be invisible.")
            merged.update(structs[member])
        return merged
    raise SourceParseError(
        f"{where}: the payload type `{type_name}` resolves to no struct and no "
        f"enum this gate can read. Refusing rather than treating it as a type "
        f"with no fields: that is how `Element::Live` went unseen for 46 "
        f"elements, and it reported the gap as 'the field applies to no element "
        f"type this family uses'. Add the declaring source next to LIVE_RS.")


def derive_defaults(element_src=None, document_src=None, test_json_src=None,
                    live_src=None, min_defaults=None):
    """`(common, per_type, doc)` defaults, read out of the Rust source.

    common   -- {field: json value}, applicable to EVERY element
    per_type -- {json type string: {field: json value}}, that type only
    doc      -- {field: json value}, at the document level

    `min_defaults` is the anti-vacuity floor on the SIZE of the derived
    vocabulary; it defaults to MIN_DERIVED_DEFAULTS, which is calibrated for the
    real source. The self-test's miniature sources pass their own, and case (k)
    pins the real floor against the real source.
    """
    if min_defaults is None:
        min_defaults = MIN_DERIVED_DEFAULTS
    element_src = _read(ELEMENT_RS) if element_src is None else element_src
    document_src = _read(DOCUMENT_RS) if document_src is None else document_src
    test_json_src = _read(TEST_JSON_RS) if test_json_src is None else test_json_src
    live_src = _read(LIVE_RS) if live_src is None else live_src

    enums = enum_strings(test_json_src)

    # (a) CommonProps -- the explicit Default impl.
    m = re.search(
        r"impl\s+Default\s+for\s+CommonProps\s*\{.*?fn\s+default\s*\(\s*\)"
        r"\s*->\s*Self\s*\{\s*Self\s*\{(.*?)\n\s*\}\s*\n\s*\}\s*\n\}",
        element_src, re.S)
    if not m:
        raise SourceParseError(
            "`impl Default for CommonProps` not found in "
            f"{os.path.relpath(ELEMENT_RS, REPO)}. Every common-field default "
            "comes from there; without it this gate has no idea what a default "
            "is and would score the whole corpus as varied.")
    common = {}
    for part in split_top_level(m.group(1)):
        f = re.match(r"\s*(\w+)\s*:\s*(.+)", part, re.S)
        if f:
            common[f.group(1)] = rust_literal_to_json(
                f.group(2), enums, f"CommonProps::default().{f.group(1)}")

    # (b) each element struct's Option fields -- absent/null is the only value
    #     they can take when nothing sets them, which is `Option::default()`
    #     and equally the serde default. Both sources, because the Element
    #     enum's payloads are not all declared in element.rs.
    struct_opts = struct_options(element_src)
    struct_opts.update(struct_options(live_src))
    payloads = enum_payloads(element_src)
    payloads.update(enum_payloads(live_src))

    # (c) Element variant -> struct, and variant -> the writer's type string.
    em = re.search(r"pub enum Element \{(.*?)\n\}", element_src, re.S)
    if not em:
        raise SourceParseError("`pub enum Element` not found; cannot map a "
                               "fixture's `type` string to a struct.")
    variant_struct = dict(re.findall(r"^\s*([A-Z]\w*)\((.*?)\),", em.group(1), re.M))

    ej = re.search(r"fn element_json\(elem: &Element\) -> String \{(.*?)\n\}\n",
                   test_json_src, re.S)
    if not ej:
        raise SourceParseError("`fn element_json` not found; cannot learn which "
                               "`type` string each Element variant writes.")
    variant_type = {}
    for vm in re.finditer(r"Element::(\w+)\(", ej.group(1)):
        tail = ej.group(1)[vm.end():]
        t = re.search(r'o\.str_val\("type",\s*"([a-z_]+)"\)', tail)
        if t:
            variant_type.setdefault(vm.group(1), t.group(1))

    per_type = {}
    for variant, tname in variant_type.items():
        if variant not in variant_struct:
            raise SourceParseError(
                f"`Element::{variant}` is written as type \"{tname}\" by the "
                f"canonical writer but carries no payload this gate could read "
                f"from `pub enum Element`; it would contribute no fields.")
        per_type.setdefault(tname, {}).update(
            resolve_payload(variant_struct[variant], struct_opts, payloads,
                            f"Element::{variant}"))

    # (d) the document level.
    dm = re.search(
        r"impl Default for Document \{.*?fn default\(\) -> Self \{(.*?)\n    \}\n\}",
        document_src, re.S)
    if not dm:
        raise SourceParseError("`impl Default for Document` not found; "
                               "`selected_layer` would have no default.")
    sm = re.search(r"Self \{(.*)\n        \}", dm.group(1), re.S)
    doc = {}
    if sm:
        for part in split_top_level(sm.group(1)):
            f = re.match(r"\s*(\w+)\s*:\s*(.+)", part, re.S)
            if f and f.group(1) == "selected_layer":
                doc[f.group(1)] = rust_literal_to_json(
                    f.group(2), enums, "Document::default().selected_layer")
    if "selected_layer" not in doc:
        raise SourceParseError(
            "`Document::default()` does not state `selected_layer`; the census "
            "measured it at 0 in ALL 268 observations, so losing its default "
            "would silently retire the frozen dimension it names.")

    # The DISTINCT vocabulary, not the sum of the three maps. An element-level
    # Option field may share a CommonProps name -- `ReferenceElem::transform`
    # does -- and summing counted it twice, so the floor drifted upward on a
    # change that added no watched field at all.
    n = len(field_vocabulary(common, per_type, doc))
    if n < min_defaults:
        raise SourceParseError(
            f"derived only {n} distinct field defaults, below the parse floor "
            f"of {min_defaults}. A shrunken vocabulary is not a smaller "
            f"job, it is a blind gate: an obligation on a field that fell out "
            f"of the vocabulary reds as 'unknown field', but a field nobody "
            f"obligated just stops being counted.")
    return common, per_type, doc


def field_vocabulary(common, per_type, doc):
    return sorted(set(common) | {f for d in per_type.values() for f in d} | set(doc))


# ---------------------------------------------------------------------------
# the corpus
# ---------------------------------------------------------------------------

def family_of(rel_path):
    """`<subdir>/<leading name token>` -- the grouping the census speaks in.

    SEPARATOR-CLEAN BY CONSTRUCTION. A family name is an IDENTITY: the ledger's
    rows are keyed on it, so if it rendered `operations\\lock` on Windows and
    `operations/lock` elsewhere, every obligation would read STALE on one
    platform and hold on the others -- each platform agreeing with itself and
    nothing failing, which is precisely the class check_path_keying.py was
    written for after it had been found three times. Backslashes are folded
    unconditionally rather than via `os.sep`, so the behaviour does not depend
    on where the gate happens to be running.
    """
    norm = rel_path.replace("\\", "/")
    d, _, base = norm.rpartition("/")
    if base.endswith(".json"):
        base = base[:-5]
    if base.endswith("_expected"):
        base = base[: -len("_expected")]
    return f"{d}/{base.split('_')[0]}"


def walk_elements(node, out):
    if isinstance(node, list):
        for item in node:
            walk_elements(item, out)
        return
    if not isinstance(node, dict):
        return
    if "type" in node:
        out.append(node)
    for key in CHILD_KEYS:
        if key in node:
            walk_elements(node[key], out)


def load_documents(root=None):
    """[(family, document)] for every canonical test JSON under test_fixtures."""
    root = FIXTURES if root is None else root
    docs = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".json"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as f:
                    j = json.load(f)
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(j, dict) and isinstance(j.get("layers"), list):
                docs.append((family_of(os.path.relpath(path, root)), j))
    return docs


def default_variance(docs, common, per_type, doc_defaults):
    """P1. `(carriers, slots, family_docs)`.

    carriers[(family, field)] -- documents of that family in which at least one
                                 applicable element holds a non-default value
    slots[(family, field)]    -- applicable element observations, so a cell with
                                 no slots can be told from a cell with no
                                 carriers. An obligation over zero slots is
                                 vacuous and must red rather than merely fail.
    """
    carriers, slots, family_docs = {}, {}, {}
    for family, document in docs:
        family_docs[family] = family_docs.get(family, 0) + 1
        elements = []
        walk_elements(document.get("layers", []), elements)
        walk_elements(document.get("symbols", []), elements)

        seen = set()
        for elem in elements:
            applicable = dict(common)
            applicable.update(per_type.get(elem.get("type"), {}))
            for field, default in applicable.items():
                slots[(family, field)] = slots.get((family, field), 0) + 1
                value = elem.get(field, ABSENT)
                if value is ABSENT:
                    continue          # writer omits identity values
                if value != default:
                    seen.add(field)

        for field in doc_defaults:
            slots[(family, field)] = slots.get((family, field), 0) + 1
            if document.get(field, ABSENT) not in (ABSENT, doc_defaults[field]):
                seen.add(field)

        for field in seen:
            carriers[(family, field)] = carriers.get((family, field), 0) + 1
    return carriers, slots, family_docs


def thin_cells(carriers, slots, family_docs, vocabulary, below=THIN):
    """(thin, total) over families large enough for the verdict to mean anything."""
    thin = total = 0
    for family, n in family_docs.items():
        if n < MIN_FAMILY_DOCS:
            continue
        for field in vocabulary:
            if not slots.get((family, field), 0):
                continue
            total += 1
            if carriers.get((family, field), 0) < below:
                thin += 1
    return thin, total


# ---------------------------------------------------------------------------
# the ledger
# ---------------------------------------------------------------------------

def load_ledger(path=None):
    path = LEDGER if path is None else path
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def split_key(key):
    """`"operations/lock|locked"` -> `("operations/lock", "locked")`."""
    if "|" not in key:
        return None, None
    fam, _, field = key.partition("|")
    return fam, field


def check_ledger(ledger, carriers, slots, family_docs, vocabulary):
    """Every failure the ledger can hold, as `[(kind, message)]`.

    The LEDGER is iterated, not the corpus. A pair nobody wrote a row for is
    unwatched here by construction -- that is what `declared_debt` is for.
    """
    problems = []

    obligations = ledger.get("obligations")
    if not isinstance(obligations, dict):
        return [("shape", "ledger has no `obligations` object")]

    floor = ledger.get("min_obligations")
    if not isinstance(floor, int) or isinstance(floor, bool) or floor < 1:
        problems.append(("shape",
                         f"`min_obligations` must be an integer >= 1, got "
                         f"{floor!r} -- a floor of zero is not a floor, and an "
                         f"emptied registry would pass every corpus"))
    elif len(obligations) < floor:
        problems.append(("vacuity",
                         f"the registry declares min_obligations={floor} but "
                         f"carries {len(obligations)} row(s): rows were deleted "
                         f"without anyone lowering the floor the file states "
                         f"about itself"))

    for key in sorted(obligations):
        row = obligations[key]
        family, field = split_key(key)
        if family is None:
            problems.append(("shape", f"{key!r}: keys are 'family|field'"))
            continue
        if not isinstance(row, dict):
            problems.append(("shape", f"{key}: row is not an object"))
            continue
        reason = str(row.get("reason", "")).strip()
        if not reason:
            problems.append((
                "shape",
                f"{key}: no `reason`. A row without an argument is a number "
                f"nobody can judge, and it is how an exemption outlives its "
                f"condition."))
        want = row.get("min")
        if not isinstance(want, int) or isinstance(want, bool) or want < 1:
            problems.append(("shape",
                             f"{key}: `min` must be an integer >= 1, got {want!r}"))
            continue

        # STALENESS, first direction: does the row still range over anything?
        if field not in vocabulary:
            problems.append((
                "stale",
                f"{key}: `{field}` has no derived default, so nothing can be "
                f"classified as non-default for it. Either the field left the "
                f"Rust source or the row was always misspelled; a row that "
                f"cannot fire is a claim nobody rechecks."))
            continue
        if family not in family_docs:
            problems.append((
                "stale",
                f"{key}: no fixture family `{family}` exists. Delete the row or "
                f"point it at the family that replaced it -- an obligation on a "
                f"family nothing populates asserts nothing."))
            continue
        if not slots.get((family, field), 0):
            problems.append((
                "stale",
                f"{key}: `{family}` has {family_docs[family]} document(s) but "
                f"ZERO elements to which `{field}` applies, so the obligation "
                f"ranges over nothing. `{field}` is declared on a struct none of "
                f"this family's element types use."))
            continue

        got = carriers.get((family, field), 0)
        if got < want:
            problems.append((
                "floor",
                f"{key}: {got} non-default document(s), floor {want}. {reason}"))

    problems.extend(check_debt(ledger, carriers, slots, family_docs, vocabulary))
    return problems


def measure_debt(carriers, slots, family_docs, vocabulary):
    """The debt's own measurements, recomputed. `{row key: value}`."""
    out = {}
    for field in vocabulary:
        n = sum(1 for (fam, f) in carriers if f == field)
        out[f"families_varying:{field}"] = n
    thin, total = thin_cells(carriers, slots, family_docs, vocabulary)
    out["thin_cells"] = thin
    # THE DENOMINATOR IS DECLARED TOO. `thin_cells` is an absolute count over a
    # population that moves, so DELETING evidence lowers it: removing one
    # fixture from a three-document family drops that family below
    # MIN_FAMILY_DOCS and takes all of its cells out of the count. Measured
    # 2026-08-02 -- deleting a single gestures/select fixture moved thin_cells
    # 310 -> 298 and the gate's ONLY red read "PAID DOWN -- promote it to an
    # obligation". `improves` fixes the polarity of the COMPARISON; it cannot
    # fix a quantity whose denominator moves. Pairing the two makes the shape
    # legible: both up = the corpus grew, both down = it SHRANK, thin down with
    # the total steady = somebody actually paid.
    out["populated_cells"] = total
    return out


def check_debt(ledger, carriers, slots, family_docs, vocabulary):
    """DECLARED DEBT is exact, in BOTH directions.

    An obligation is a floor because adding a carrier must stay cheap. Debt is
    the opposite: its whole job is to keep an unpaid number visible, so a
    measurement that has MOVED must be restated by hand. Movement toward health
    is the interesting one -- it means someone paid part of this debt without
    noticing, and the row should be promoted to an obligation instead of quietly
    continuing to describe a corpus that no longer exists.

    WHICH WAY IS HEALTH IS DECLARED, NOT ASSUMED, and that is not pedantry: the
    first cut of this hard-coded "up is better", which is right for
    `families_varying:*` (more families varying a field is progress) and exactly
    backwards for `thin_cells` (a count of BLIND cells). It reported a corpus
    that had just LOST a lock family as "PAID DOWN -- promote it". A gate that
    misnames the direction of a regression is worse than one that stays silent,
    because someone acts on it.
    """
    problems = []
    debt = ledger.get("declared_debt")
    if not isinstance(debt, dict):
        return [("shape", "ledger has no `declared_debt` object")]
    rows = debt.get("measured")
    if not isinstance(rows, dict) or not rows:
        return [("shape", "`declared_debt.measured` must be a non-empty object")]
    reach = debt.get("out_of_reach")
    if not isinstance(reach, dict) or len([k for k in reach if not k.startswith("_")]) < 1:
        problems.append((
            "shape",
            "`declared_debt.out_of_reach` must name at least one census finding "
            "this gate's primitive cannot express. A gate whose blind spots are "
            "undeclared is the defect it exists to prevent, one level up -- and "
            "an emptied section reads exactly like a gate with none."))

    actual = measure_debt(carriers, slots, family_docs, vocabulary)
    for key in sorted(rows):
        row = rows[key]
        if not isinstance(row, dict) or "value" not in row:
            problems.append(("shape", f"debt {key!r}: row needs a `value`"))
            continue
        if not str(row.get("why_not_closed", "")).strip():
            problems.append((
                "shape",
                f"debt {key!r}: no `why_not_closed`. Debt without an argument "
                f"is not declared debt, it is a number that was forgotten in "
                f"public."))
        better = row.get("improves")
        if better not in ("up", "down"):
            problems.append((
                "shape",
                f"debt {key!r}: `improves` must be 'up' or 'down' -- which way "
                f"this number moves when the debt is being PAID. Assuming it "
                f"made the gate report a lost lock family as progress."))
        if key not in actual:
            problems.append((
                "stale",
                f"debt {key!r}: this gate no longer measures that quantity, so "
                f"the row asserts nothing. Delete it, or restore whatever "
                f"stopped being measured."))
            continue
        if actual[key] != row["value"]:
            rose = actual[key] > row["value"]
            paid = (rose and better == "up") or (not rose and better == "down")
            direction = ("PAID DOWN -- promote it to an obligation or restate it"
                         if paid else
                         "GOT WORSE -- the corpus thinned where it was already thin")
            problems.append((
                "debt",
                f"debt {key!r}: declared {row['value']}, measured "
                f"{actual[key]}. The debt {direction}."))

    unrecorded = sorted(set(actual) - set(rows))
    if unrecorded:
        problems.append((
            "stale",
            f"{len(unrecorded)} measured quantity/quantities carry no debt row: "
            f"{unrecorded[:6]}{'...' if len(unrecorded) > 6 else ''}. A "
            f"measurement nobody declared is the forgotten number this section "
            f"exists to prevent."))
    return problems


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

def report(carriers, slots, family_docs, vocabulary):
    print("family x field non-default DOCUMENT counts "
          f"(families with >= {MIN_FAMILY_DOCS} documents)")
    fams = sorted((f for f, n in family_docs.items() if n >= MIN_FAMILY_DOCS),
                  key=lambda f: (-family_docs[f], f))
    w = max([len(f) for f in fams] + [6])
    print("family".ljust(w) + "  n  " + " ".join(v[:7].rjust(7) for v in vocabulary))
    for fam in fams:
        cells = []
        for field in vocabulary:
            if not slots.get((fam, field), 0):
                cells.append("      -")
            else:
                cells.append(str(carriers.get((fam, field), 0)).rjust(7))
        print(fam.ljust(w) + f" {family_docs[fam]:>3} " + " ".join(cells))
    thin, total = thin_cells(carriers, slots, family_docs, vocabulary)
    print()
    print(f"{thin} of {total} populated cells hold fewer than {THIN} "
          f"non-default carriers")
    print("legend: '-' = the field applies to no element type this family uses")


def scope_note():
    return (
        "SCOPE: counts fields PRESENT in fixture JSON, against defaults derived "
        "from the RUST source. Blind to a field the writer omits, to a default "
        "that differs per port, and to a value that is non-default but "
        "semantically inert (scale(1,1) scores as a carrier). Blind to REPLICAS: "
        "a floor of N is satisfied by N identical copies of one document, "
        "proven on this corpus. 73 plain-typed element fields have no derivable "
        "default and are outside the vocabulary; square boxes, rx==ry and "
        "colour space are out of reach by construction. See the ledger's "
        "`out_of_reach` -- all of it, not just the first line.")


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

FAKE_ELEMENT_RS = '''
pub enum Element {
    Rect(RectElem),
    Layer(LayerElem),
    Live(super::live::LiveVariant),
}
pub struct RectElem {
    pub x: f64,
    pub fill: Option<Fill>,
    pub common: CommonProps,
}
pub struct LayerElem {
    pub children: Vec<Rc<Element>>,
    pub common: CommonProps,
}
impl Default for CommonProps {
    fn default() -> Self {
        Self {
            opacity: 1.0,
            transform: None,
            locked: false,
            visibility: Visibility::Preview,
        }
    }
}
'''

# The payload of `Element::Live` is an enum, declared in ANOTHER FILE, whose
# members carry the paint fields. Modelled here because resolving it is what
# the first cut of this gate got wrong -- silently, and in the direction that
# hides evidence.
FAKE_LIVE_RS = '''
pub struct CompoundShape {
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub operands: Vec<Element>,
}
pub struct GeneratedElem {
    pub fill: Option<Fill>,
    pub recipe: String,
}
pub enum LiveVariant {
    CompoundShape(CompoundShape),
    Generated(GeneratedElem),
}
'''

FAKE_DOCUMENT_RS = '''
impl Default for Document {
    fn default() -> Self {
        Self {
            layers: vec![],
            selected_layer: 0,
            selection: Vec::new(),
        }
    }
}
'''

FAKE_TEST_JSON_RS = '''
fn visibility_str(v: Visibility) -> &'static str {
    match v {
        Visibility::Invisible => "invisible",
        Visibility::Preview => "preview",
    }
}
fn element_json(elem: &Element) -> String {
    let mut o = JsonObj::new();
    match elem {
        Element::Rect(e) => {
            o.str_val("type", "rect");
        }
        Element::Layer(e) => {
            o.str_val("type", "layer");
        }
        Element::Live(e) => {
            o.str_val("type", "live");
        }
    }
}
'''

# Which way each measured quantity moves when the debt is being PAID. Both are
# counts of cells, and they point OPPOSITE ways: fewer blind cells is progress,
# fewer measured cells is lost evidence.
_DEBT_POLARITY = {"thin_cells": "down", "populated_cells": "up"}


def _debt(measured):
    """A well-formed `declared_debt` around a measurement map."""
    return {"measured": {
                k: {"value": v, "why_not_closed": "w",
                    "improves": _DEBT_POLARITY.get(k, "up")}
                for k, v in measured.items()},
            "out_of_reach": {"semantically_inert_values": "scale(1,1)"}}


def _doc(*elements, selected_layer=0):
    return {"layers": list(elements), "selected_layer": selected_layer,
            "selection": []}


def _rect(**kw):
    e = {"type": "rect", "opacity": 1.0, "transform": None, "locked": False,
         "visibility": "preview", "fill": None}
    e.update(kw)
    return e


def _layer(children, **kw):
    e = {"type": "layer", "opacity": 1.0, "transform": None, "locked": False,
         "visibility": "preview", "children": children}
    e.update(kw)
    return e


def self_test():
    """Prove the gate reds on each class it claims, including the two the naive
    version could not see."""
    failures = []

    def check(cond, label):
        if cond:
            print(f"  ok: {label}")
        else:
            failures.append(label)
            print(f"  FAIL: {label}")

    common, per_type, doc_defaults = derive_defaults(
        FAKE_ELEMENT_RS, FAKE_DOCUMENT_RS, FAKE_TEST_JSON_RS, FAKE_LIVE_RS,
        min_defaults=1)
    vocab = field_vocabulary(common, per_type, doc_defaults)

    # (a) The defaults really are READ, including the enum spelling. If any of
    #     these were hand-typed the fake source could not move them.
    check(common == {"opacity": 1.0, "transform": None, "locked": False,
                     "visibility": "preview"},
          f"CommonProps defaults derived from source: {common}")
    check(doc_defaults == {"selected_layer": 0},
          "Document::default().selected_layer derived from source")
    check(per_type == {"rect": {"fill": None}, "layer": {},
                       "live": {"fill": None, "stroke": None}},
          "Option fields are per-STRUCT: rect has a fill slot, layer has none, "
          "and an ENUM PAYLOAD DECLARED IN ANOTHER FILE resolves to the union "
          "of its members rather than to nothing")

    # (b) A CHANGED DEFAULT RECLASSIFIES THE CORPUS. This is the whole argument
    #     for deriving rather than typing: with the default moved to 0.5, the
    #     1.0-valued elements below become carriers.
    moved = FAKE_ELEMENT_RS.replace("opacity: 1.0", "opacity: 0.5")
    mv_common, mv_types, mv_doc = derive_defaults(
        moved, FAKE_DOCUMENT_RS, FAKE_TEST_JSON_RS, FAKE_LIVE_RS,
        min_defaults=1)
    docs = [("f/a", _doc(_layer([_rect()])))]
    c0, _, _ = default_variance(docs, common, per_type, doc_defaults)
    c1, _, _ = default_variance(docs, mv_common, mv_types, mv_doc)
    check(c0.get(("f/a", "opacity"), 0) == 0 and c1.get(("f/a", "opacity"), 0) == 1,
          "a changed struct default reclassifies the corpus rather than moving "
          "the floor silently")

    # (c) THE AGGREGATION TRAP, which is the measured reason this primitive is
    #     per-family. `opacity` takes many distinct values corpus-wide while one
    #     whole family sits at 334-of-334 default. Any "at least N distinct
    #     values" floor passes this corpus; P1 must not.
    trap = [("varied/x", _doc(_layer([_rect(opacity=v)])))
            for v in (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)]
    trap += [("frozen/y", _doc(_layer([_rect()]))) for _ in range(20)]
    tc, ts, tf = default_variance(trap, common, per_type, doc_defaults)
    distinct = {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9}
    check(len(distinct) >= 9 and tc.get(("frozen/y", "opacity"), 0) == 0
          and tc.get(("varied/x", "opacity"), 0) == 9,
          "the aggregation trap: 9 distinct values corpus-wide, and the frozen "
          "family still scores 0 -- a pooled floor would call this healthy")
    led = {"min_obligations": 1,
           "obligations": {"frozen/y|opacity": {"min": 3, "reason": "r"}},
           "declared_debt": _debt(measure_debt(tc, ts, tf, vocab))}
    kinds = [k for k, _ in check_ledger(led, tc, ts, tf, vocab)]
    check(kinds == ["floor"],
          "and the per-family obligation on the frozen family goes RED")

    # (d) A satisfied obligation is silent.
    led["obligations"] = {"varied/x|opacity": {"min": 3, "reason": "r"}}
    check(not check_ledger(led, tc, ts, tf, vocab),
          "a satisfied obligation is silent")

    # (e) STALENESS. A row that cannot fire is not a harmless row: it reads as
    #     a guarantee to the next person, and `swift:dropdown` cost a seat an
    #     evening on exactly that. The third case is the control -- a live row
    #     must NOT be called stale, which is the false positive the coarse
    #     version of this idea produced against check_element_dispatch.py.
    for key, kind, label in [
        ("nosuch/family|opacity", "stale", "a family the corpus no longer has"),
        ("varied/x|no_such_field", "stale", "a field with no derived default"),
        ("varied/x|fill", None, "a field that DOES apply is not stale"),
    ]:
        led["obligations"] = {key: {"min": 1, "reason": "r"}}
        got = [k for k, _ in check_ledger(led, tc, ts, tf, vocab)]
        if kind is None:
            check(got in ([], ["floor"]), label)
        else:
            check(got == [kind], label)

    # (f) An obligation over ZERO applicable slots is vacuous. `fill` is
    #     declared on RectElem only, so a layer-only family can never satisfy
    #     it -- and must say so rather than reading as an unmet floor.
    layers_only = [("only/layers", _doc(_layer([]))) for _ in range(4)]
    lc, ls, lf = default_variance(layers_only, common, per_type, doc_defaults)
    led2 = {"min_obligations": 1,
            "obligations": {"only/layers|fill": {"min": 1, "reason": "r"}},
            "declared_debt": _debt(measure_debt(lc, ls, lf, vocab))}
    probs = check_ledger(led2, lc, ls, lf, vocab)
    check([k for k, _ in probs] == ["stale"]
          and "ranges over nothing" in probs[0][1],
          "an obligation over a field no element of the family carries is "
          "VACUOUS, and says so instead of reading as an unmet floor")

    # (g) Shape rules: a row must argue for itself, and a floor must be a floor.
    for row, needle, label in [
        ({"min": 3}, "no `reason`", "a row with no reason is refused"),
        ({"min": 0, "reason": "r"}, "`min` must be", "min 0 is refused"),
        ({"reason": "r"}, "`min` must be", "a row with no min is refused"),
    ]:
        led["obligations"] = {"varied/x|opacity": row}
        msgs = [m for _, m in check_ledger(led, tc, ts, tf, vocab)]
        check(any(needle in m for m in msgs), label)

    # (h) ANTI-VACUITY: an emptied registry must not pass. This is the shape
    #     that turned four other gates green on `[]` in this repo.
    led["obligations"] = {}
    led["min_obligations"] = 4
    msgs = [m for _, m in check_ledger(led, tc, ts, tf, vocab)]
    check(any("without anyone lowering the floor" in m for m in msgs),
          "an emptied registry is refused against its own declared floor")
    led["min_obligations"] = 1
    led["obligations"] = {"varied/x|opacity": {"min": 3, "reason": "r"}}

    # (i) DEBT IS EXACT IN BOTH DIRECTIONS -- and the direction is READ from the
    #     row, not assumed. `thin_cells` counts BLIND cells, so it improves
    #     DOWNWARD; `families_varying:*` improves upward. Hard-coding "up is
    #     better" made the first cut report a corpus that had just lost a lock
    #     family as "PAID DOWN -- promote it", which is a red pointing the wrong
    #     way. Both polarities are pinned here, both ways.
    for key, delta, needle, label in [
        ("thin_cells", -1, "GOT WORSE",
         "thin_cells RISING above its declaration is a regression, not progress"),
        ("thin_cells", +1, "PAID DOWN",
         "thin_cells FALLING below its declaration is progress to be promoted"),
        ("families_varying:opacity", -1, "PAID DOWN",
         "a families-varying count rising above its declaration is progress"),
        ("families_varying:opacity", +1, "GOT WORSE",
         "a families-varying count falling below its declaration is a regression"),
    ]:
        bad = json.loads(json.dumps(led))
        bad["declared_debt"]["measured"][key]["value"] += delta
        msgs = [m for _, m in check_ledger(bad, tc, ts, tf, vocab)]
        check(any(needle in m and key in m for m in msgs), label)
    bad = json.loads(json.dumps(led))
    del bad["declared_debt"]["measured"]["thin_cells"]["improves"]
    msgs = [m for _, m in check_ledger(bad, tc, ts, tf, vocab)]
    check(any("`improves` must be" in m for m in msgs),
          "a debt row that does not say which way health lies is refused")
    bad = json.loads(json.dumps(led))
    del bad["declared_debt"]["measured"]["thin_cells"]
    msgs = [m for _, m in check_ledger(bad, tc, ts, tf, vocab)]
    check(any("carry no debt row" in m for m in msgs),
          "a measured quantity with no debt row reds -- the forgotten number")
    bad = json.loads(json.dumps(led))
    bad["declared_debt"]["measured"]["thin_cells"]["why_not_closed"] = ""
    msgs = [m for _, m in check_ledger(bad, tc, ts, tf, vocab)]
    check(any("why_not_closed" in m for m in msgs),
          "debt without an argument is refused")

    # (j) THE PARSE FAILS CLOSED. An empty default map scores every value as
    #     non-default, which paints the exact condition this gate detects as
    #     health -- so each of these must RAISE, not return {}.
    for src, label in [
        (FAKE_ELEMENT_RS.replace("impl Default for CommonProps", "impl Nope"),
         "a missing CommonProps Default"),
        (FAKE_ELEMENT_RS.replace("visibility: Visibility::Preview",
                                 "visibility: Visibility::Nonesuch"),
         "an enum default the writer has no spelling for"),
        (FAKE_ELEMENT_RS.replace("opacity: 1.0", "opacity: compute_it()"),
         "an initializer that is not a literal"),
        (FAKE_ELEMENT_RS.replace("pub enum Element", "pub enum Elephant"),
         "a vanished Element enum"),
    ]:
        try:
            derive_defaults(src, FAKE_DOCUMENT_RS, FAKE_TEST_JSON_RS,
                            FAKE_LIVE_RS, min_defaults=1)
            check(False, f"{label} must RAISE rather than yield empty defaults")
        except SourceParseError:
            check(True, f"{label} raises rather than yielding empty defaults")
    try:
        derive_defaults(FAKE_ELEMENT_RS,
                        FAKE_DOCUMENT_RS.replace("selected_layer: 0", "x: 0"),
                        FAKE_TEST_JSON_RS, FAKE_LIVE_RS, min_defaults=1)
        check(False, "a lost selected_layer default must RAISE")
    except SourceParseError:
        check(True, "a lost selected_layer default raises")

    # (j2) AN UNRESOLVABLE PAYLOAD FAILS CLOSED TOO. This is the mutation the
    #      first cut of the gate did NOT survive: it answered `{}` and carried
    #      on, so `Element::Live` contributed no fields for 46 elements in 20
    #      families and the miss surfaced as "the field applies to no element
    #      type this family uses" -- a wrong sentence, stated confidently. The
    #      whole point of failing closed is that an unreadable source is not the
    #      same as a source with nothing in it.
    for elem_mut, live_mut, label in [
        (FAKE_ELEMENT_RS.replace("super::live::LiveVariant", "somewhere::Ghost"),
         FAKE_LIVE_RS, "a variant payload naming a type in no readable source"),
        (FAKE_ELEMENT_RS, FAKE_LIVE_RS.replace("pub enum LiveVariant", "pub enum Gone"),
         "a payload enum that left the source"),
        (FAKE_ELEMENT_RS,
         FAKE_LIVE_RS.replace("pub struct GeneratedElem", "pub struct RenamedElem"),
         "a payload enum member whose struct was renamed out from under it"),
    ]:
        try:
            derive_defaults(elem_mut, FAKE_DOCUMENT_RS, FAKE_TEST_JSON_RS,
                            live_mut, min_defaults=1)
            check(False, f"{label} must RAISE rather than resolve to no fields")
        except SourceParseError:
            check(True, f"{label} raises rather than resolving to no fields")

    # (j3) ...and it is a REAL gap being closed, not a hypothetical: against the
    #      live tree, `live` must carry paint slots. If this ever reads {} again
    #      the parser has silently stopped following the payload.
    live_slots = derive_defaults()[1].get("live", {})
    check("fill" in live_slots and "stroke" in live_slots,
          f"on the REAL source, `live` resolves to paint slots {sorted(live_slots)} "
          f"-- 46 elements in 20 families that used to have none")

    # (k) The MIN_DERIVED_DEFAULTS floor fires on a shrunken vocabulary, using
    #     the REAL source, so the floor is pinned against reality rather than
    #     against the fake.
    real_e, real_d, real_t = _read(ELEMENT_RS), _read(DOCUMENT_RS), _read(TEST_JSON_RS)
    real_l = _read(LIVE_RS)
    try:
        derive_defaults(real_e, real_d, real_t, real_l,
                        min_defaults=MIN_DERIVED_DEFAULTS + 1)
        check(False, "the derived-vocabulary floor must fire when the parse shrinks")
    except SourceParseError:
        check(True, "the derived-vocabulary floor fires when the parse shrinks")
    # ...and the REAL source clears the REAL floor exactly, so the constant is
    # pinned against reality rather than left slack. 9 common + 6 element-Option
    # + selected_layer, counted as a SET: `ReferenceElem::transform` shares the
    # CommonProps name and must not be counted twice.
    rc, rt, rd = derive_defaults(real_e, real_d, real_t, real_l)
    n_real = len(field_vocabulary(rc, rt, rd))
    check(n_real == MIN_DERIVED_DEFAULTS,
          f"the real source derives exactly {MIN_DERIVED_DEFAULTS} field "
          f"defaults (measured {n_real}) -- the floor is exact, not slack")

    # (k2) THE SIZE OF THE BLIND SPOT IS PINNED, because the floor above only
    #      notices the vocabulary SHRINKING. A field enters the vocabulary by
    #      being on CommonProps or by being Option-typed; a plain
    #      `pub fill_rule: FillRule` on an Elem struct has no Default impl to
    #      read, so it enters NOTHING -- no obligation, no debt row, no red, and
    #      n_real does not move either. That is two of the three ways to add a
    #      field forcing a ruling and the third arriving in silence, and the
    #      silent third is where the never-had-a-campaign fields live:
    #      fill_rule, isolated_blending, knockout_group, width_points and the
    #      21-field TextElem typography block. Exact on purpose: when it moves,
    #      restate it in one line and say whether the new field needs watching.
    reachable = element_payload_structs(real_e, real_l)
    all_non_opt = non_option_fields(real_e)
    all_non_opt.update(non_option_fields(real_l))
    unwatched = {f"{s}.{f}" for s in reachable for f in all_non_opt.get(s, ())}
    check(len(unwatched) == UNWATCHED_ELEMENT_FIELDS,
          f"{UNWATCHED_ELEMENT_FIELDS} element-struct fields are OUTSIDE the "
          f"vocabulary by construction (measured {len(unwatched)}); the count is "
          f"pinned so a new one arrives with a ruling instead of in silence")

    # (l) A MISSING KEY IS THE DEFAULT, and it is the CONSERVATIVE reading: it
    #     can only lower a count, so it cannot turn a red green.
    sparse = [("s/a", _doc(_layer([{"type": "rect"}])))]
    sc, ss, _sf = default_variance(sparse, common, per_type, doc_defaults)
    check(not any(k[0] == "s/a" for k in sc) and ss.get(("s/a", "fill"), 0) == 1,
          "an element carrying no keys is all-default, and still occupies its "
          "slots")

    # (n) THE FAMILY NAME IS AN IDENTITY, so it must render the same text on
    #     every platform. A Windows relpath keyed as-is would make every
    #     obligation read STALE there and hold everywhere else -- the separator
    #     class, three sightings deep in this repo (check_path_keying.py).
    for raw, want in [
        ("operations/lock_selection_expected.json", "operations/lock"),
        ("operations\\lock_selection_expected.json", "operations/lock"),
        ("gestures\\blob_brush_seam.json", "gestures/blob"),
    ]:
        got = family_of(raw)
        check(got == want, f"family_of({raw!r}) -> {got!r} (want {want!r})")

    # (m) THE LIVE TREE. Production must be green here, not in CI for the first
    #     time -- and the live corpus must be big enough for that to mean
    #     something.
    r_common, r_types, r_doc = derive_defaults()
    r_vocab = field_vocabulary(r_common, r_types, r_doc)
    live_docs = load_documents()
    check(len(live_docs) >= 200,
          f"the live corpus walk finds {len(live_docs)} documents (a walk that "
          f"found nothing would satisfy every floor vacuously)")
    lc, ls, lf = default_variance(live_docs, r_common, r_types, r_doc)
    live_problems = check_ledger(load_ledger(), lc, ls, lf, r_vocab)
    check(not live_problems,
          "the shipped ledger is clean against the shipped corpus"
          + ("" if not live_problems else f": {live_problems}"))

    if failures:
        print(f"SELF-TEST FAILED -- {len(failures)} case(s) the gate does not "
              f"detect as claimed")
        return 1
    print("self-test: defaults are read from source (and a changed default "
          "reclassifies rather than moving the floor); the aggregation trap "
          "that defeats a pooled distinct-value floor is caught per-family; "
          "stale, vacuous, unargued and floor-breaching rows all red; debt is "
          "exact in both directions and its denominator is declared beside it; "
          "the parse fails closed on eight mutations INCLUDING an unresolvable "
          "Element payload; and the shipped ledger is clean against the shipped "
          "corpus.")
    print(scope_note())
    return 0


# ---------------------------------------------------------------------------

def main(argv):
    try:
        common, per_type, doc_defaults = derive_defaults()
    except SourceParseError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    vocabulary = field_vocabulary(common, per_type, doc_defaults)
    docs = load_documents()
    carriers, slots, family_docs = default_variance(
        docs, common, per_type, doc_defaults)

    if "--report" in argv:
        report(carriers, slots, family_docs, vocabulary)
        print()
        print(scope_note())
        return 0

    if not docs or not family_docs:
        print("ERROR: the corpus walk found no canonical test JSON under "
              f"{os.path.relpath(FIXTURES, REPO)}. That is not a pass -- every "
              "obligation would range over nothing.", file=sys.stderr)
        return 1

    try:
        ledger = load_ledger()
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read {os.path.relpath(LEDGER, REPO)}: {e}",
              file=sys.stderr)
        return 1

    problems = check_ledger(ledger, carriers, slots, family_docs, vocabulary)
    if problems:
        print(f"ERROR: {len(problems)} problem(s) in the default-variance "
              f"registry.", file=sys.stderr)
        print(file=sys.stderr)
        for kind, msg in problems:
            print(f"  [{kind}] {msg}", file=sys.stderr)
        print(file=sys.stderr)
        print("A corpus whose every value IS the struct default cannot "
              "distinguish a dropped field from a preserved one. Each row here "
              "keeps one (family, field) pair able to tell the difference.",
              file=sys.stderr)
        print(file=sys.stderr)
        print("To ADD an obligation: one row, a `min`, and a sentence saying "
              "what it buys. To DROP one: delete the row and lower "
              "`min_obligations` in the same commit, saying which pair stops "
              "being watched and why that is acceptable.", file=sys.stderr)
        return 1

    n_ob = len(ledger.get("obligations", {}))
    thin, total = thin_cells(carriers, slots, family_docs, vocabulary)
    headroom = min((carriers.get(split_key(k), 0) - row["min"]
                    for k, row in ledger["obligations"].items()),
                   default=0)
    print(f"default variance: {n_ob} obligation(s) hold over {len(docs)} "
          f"documents in {len(family_docs)} families "
          f"({len(vocabulary)} fields derived from source); tightest headroom "
          f"{headroom}; declared debt {thin} of {total} populated cells still "
          f"below {THIN} carriers.")
    print(scope_note())
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(main(sys.argv[1:]))
