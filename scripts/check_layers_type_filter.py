#!/usr/bin/env python3
"""The Layers type filter: one vocabulary, spoken the same by the YAML and both
active ports, and derived from the ELEMENT rather than from its label.

WHY THIS EXISTS
---------------
`workspace/panels/layers.yaml` (`lp_filter_button`) says: "Unchecking a type
hides all elements of that type from the tree." ALL of that type.

jas_dioxus recovered each row's type by PARSING THE ROW LABEL -- it matched
`<Rectangle>` apart and let everything else fall through to `""`:

    let type_hint = if r.is_layer { "layer" } else {
        let n = &r.display_name;
        if n.starts_with('<') && n.ends_with('>') { type_value(&n[1..n.len()-1]) }
        else { "" }        // "Named layer already checked"
    };

That was CORRECT BY CONSTRUCTION on the day it was written, because only a
Layer could carry a name and `is_layer` caught those. Then a later commit let
every element carry one ("Tree row reads common.name; drop the is_layer rename
gate"), and from that moment a NAMED element's label was its name, the hint came
out `""`, `""` matched nothing hidden -- and NAMING AN ELEMENT EXEMPTED IT FROM
THE FILTER. Nothing failed. JasSwift's `layersTypeValue` had matched on the
element all along, so the two active ports quietly disagreed in the panel an
artist reads most.

The general shape is worth more than the instance:

    A display name is a PRESENTATION of an element; its type is a FACT about
    it. Recovering the fact from the presentation is lossy the moment
    presentation gains a second form -- and the commit that adds the second
    form is never the commit that looks suspicious.

`layers.yaml` is precise about this exactly where it means names: search matches
"whose name (or auto-generated type name like `<Path>`)". The filter clause says
only *type*, and *all*.

The gate that would have caught it was DEFERRED for a reason that expired.
`transcripts/LAYERS_TESTS.md` LYR-091: "only Layers are renameable in the
current UI, so we can't construct a named non-layer descendant... Revisit when
Group/element names land." They landed. Nobody revisited. So this gate also
exists as the standing answer to a deferral whose precondition changed.

WHAT THIS GATE ASSERTS
----------------------
1. Both ports answer the SAME SET of type tokens. This is the prime directive
   at its narrowest: one vocabulary, byte-identical, `text_path` included.
2. Every value the filter MENU offers is answerable by some element in both
   ports -- a menu entry no element can ever match is a control that does
   nothing.
3. Every token a port answers that the menu CANNOT offer is declared in
   UNOFFERABLE. Today that is `live` alone, deliberately spelled the same on
   both sides so a shared gap stays a shared gap. Growing this set requires
   saying so here, in the same commit.
4. Neither port's filter site reads a DISPLAY NAME. This is the regression
   guard for the defect class rather than the instance: it fails if either
   filter block mentions a label/display-name identifier again.

WHAT IT DOES NOT COVER
----------------------
* It reads source text, not behaviour. The per-port value tests
  (`the_type_filter_reads_the_element_not_its_label` in
  jas_dioxus/src/interpreter/renderer.rs, `LayersTypeFilterTests` in
  JasSwift/Tests/Panels/) are what pin what the functions DO; this pins that
  their vocabularies agree with each other and with the shipping YAML.
* It says nothing about whether hiding a CONTAINER type ought to remove it.
  Both ports keep an ancestor of any surviving row -- a tree cannot draw a
  child without its parent -- so hiding "group" is inoperative whenever a
  descendant survives. That is a SHARED reading of the spec, deliberately
  identical, and it is a question for council, not a divergence.
* The frozen ports are out of scope by POLICY.md §1.
"""

import pathlib
import re
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
# The TOKENS live in the ungated algorithms layer (moved there 2026-07-29 so the
# shared corpus reader can drive them in a native build -- see
# check_native_core_tests.py, which insisted and was right). The FILTER BLOCK
# that consumes them is still in the web-gated renderer, so this gate reads two
# Rust files. The split is deliberate: the label-reading regression this gate
# forbids can only appear at the CONSUMING site.
RUST_TOKENS = REPO / "jas_dioxus" / "src" / "algorithms" / "layers_filter.rs"
RUST_FILTER = REPO / "jas_dioxus" / "src" / "interpreter" / "renderer.rs"
SWIFT = REPO / "JasSwift" / "Sources" / "Interpreter" / "YamlPanelBodyView.swift"
LAYERS_YAML = REPO / "workspace" / "panels" / "layers.yaml"

# Tokens a port answers that the filter menu does not offer, each with a
# reason. A row here is a claim that the gap is INTENDED and SHARED.
UNOFFERABLE: dict[str, str] = {
    # EMPTY, and that is a result. `live` sat here from 2026-07-29, declared as
    # a shared gap: no menu item offered it, so a live element could not be
    # hidden in either port. Council Q1.2 added the Compound Shape entry, this
    # gate's stale-row arm red on its own declaration, and the row was deleted.
    #
    # It mattered more than a tidy-up. Under the CHECKED semantics JYH ruled,
    # a type the menu cannot offer can never be CHECKED -- so a gap that was
    # merely benign under unchecked semantics would have made every live
    # element vanish the instant any filter was applied.
}

# Anti-vacuity floors, EXACT rather than slack. Flask's law, proved by
# mutation on 2026-07-29: "A floor with slack is a floor with a hole exactly
# the size of the slack, and the hole admits precisely the move the assertion
# exists to forbid." A count that must be edited when a type is added is the
# feature -- adding an element kind should force the menu decision, not slip
# past a `>=`.
EXPECTED_TOKENS = 12   # the eleven menu types plus `live`
EXPECTED_MENU = 12   # eleven leaf/container types plus `live`

# Identifiers that mean "the row's label" in either port. Their presence
# anywhere in a filter block is the defect returning.
LABEL_IDENTS = ("display_name", "displayName", "elementDisplayName",
                "tree_elem_display_name", "row_label", "rowLabel")


class ParseFailure(Exception):
    """The source did not have the shape this gate reads.

    Raised rather than returning empty, because an empty parse is
    indistinguishable from a clean result and that is how the original defect
    survived every green suite.
    """


def _brace_block(src: str, header: str) -> str:
    """The `{...}` block introduced by the first line containing `header`.

    Brace-counted, so a nested `match`/`switch` does not truncate it. String
    literals in both languages here are simple enough that counting braces
    outside them is exact; a literal containing a brace would need more, and
    ParseFailure is preferable to a guess.
    """
    at = src.find(header)
    if at < 0:
        raise ParseFailure(f"no {header!r} in source")
    open_at = src.find("{", at)
    if open_at < 0:
        raise ParseFailure(f"{header!r} has no opening brace")
    depth = 0
    for i in range(open_at, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[open_at:i + 1]
    raise ParseFailure(f"{header!r} block never closes")


def type_tokens(src: str, header: str) -> set[str]:
    """The set of string literals a type-token function returns.

    Deliberately shape-blind: it reads the literals out of the function body
    rather than modelling `match` or `switch`, so it works on both languages
    and does not need updating when either port restyles its arms.
    """
    body = _brace_block(src, header)
    toks = set(re.findall(r'"([a-z_]+)"', body))
    if not toks:
        raise ParseFailure(f"{header!r} returns no string literals")
    return toks


def menu_values(doc: object) -> list[str]:
    """The `lp_filter_button` widget's item values, in declaration order."""
    found: list[list[str]] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            if node.get("id") == "lp_filter_button":
                items = node.get("items")
                if not isinstance(items, list):
                    raise ParseFailure("lp_filter_button has no `items` list")
                # Only `type: toggle` items name an element TYPE. The "All"
                # item is an action that resets the filter -- counting it as a
                # type would demand that some element answer "__all__".
                found.append([str(i["value"]) for i in items
                              if "value" in i and i.get("type") == "toggle"])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(doc)
    if len(found) != 1:
        raise ParseFailure(
            f"expected exactly one lp_filter_button, found {len(found)}")
    return found[0]


def label_reads(block: str) -> list[str]:
    """Label identifiers appearing in a filter block, if any."""
    return sorted({ident for ident in LABEL_IDENTS if ident in block})


def scan(rust_src: str, swift_src: str, yaml_doc: object,
         rust_filter_src: str | None = None) -> dict:
    """All four claims, as data, so the self-test can drive them directly.

    `rust_filter_src` defaults to `rust_src`, so a self-test case that supplies
    one Rust string still exercises both halves.
    """
    rust_filter_src = rust_src if rust_filter_src is None else rust_filter_src
    rust = type_tokens(rust_src, "pub fn type_value")
    swift = type_tokens(swift_src, "func layersTypeValue")
    menu = menu_values(yaml_doc)
    return {
        "rust": rust,
        "swift": swift,
        "menu": menu,
        "rust_only": sorted(rust - swift),
        "swift_only": sorted(swift - rust),
        "menu_unanswered": sorted(set(menu) - (rust & swift)),
        "undeclared_unofferable": sorted((rust | swift) - set(menu) - set(UNOFFERABLE)),
        "stale_unofferable": sorted(set(UNOFFERABLE) & set(menu)),
        "rust_labels": label_reads(
            _brace_block(rust_filter_src, "if !hidden_types.is_empty()")),
        "swift_labels": label_reads(
            _brace_block(swift_src, "if !hiddenTypes.isEmpty")),
    }


def failures(r: dict) -> list[str]:
    out = []
    if r["rust_only"] or r["swift_only"]:
        out.append(
            f"the ports answer different vocabularies: only jas_dioxus "
            f"{r['rust_only']}, only JasSwift {r['swift_only']}")
    if r["menu_unanswered"]:
        out.append(
            f"the filter menu offers {r['menu_unanswered']}, which no element "
            f"answers in both ports -- those entries hide nothing")
    if r["undeclared_unofferable"]:
        out.append(
            f"the ports answer {r['undeclared_unofferable']}, which the menu "
            f"cannot offer and UNOFFERABLE does not declare -- either add the "
            f"menu item or record why the gap is intended")
    if r["stale_unofferable"]:
        out.append(
            f"UNOFFERABLE still lists {r['stale_unofferable']}, but the menu "
            f"now offers it -- delete the row")
    for port, key in (("jas_dioxus", "rust_labels"), ("JasSwift", "swift_labels")):
        if r[key]:
            out.append(
                f"{port}'s type-filter block reads {r[key]} -- the type must "
                f"come from the ELEMENT, never from its label. This is the "
                f"2026-07-29 defect returning; see this file's header")
    # Floors last: a shape failure above is more informative than a count.
    if len(r["rust"]) != EXPECTED_TOKENS or len(r["swift"]) != EXPECTED_TOKENS:
        out.append(
            f"expected {EXPECTED_TOKENS} type tokens per port, read "
            f"{len(r['rust'])} (jas_dioxus) and {len(r['swift'])} (JasSwift). "
            f"If an element kind was added, decide whether the menu offers it "
            f"and raise this number in the same commit")
    if len(r["menu"]) != EXPECTED_MENU:
        out.append(
            f"expected {EXPECTED_MENU} menu values, read {len(r['menu'])}")
    if len(set(r["menu"])) != len(r["menu"]):
        out.append(f"the menu offers a duplicate value: {r['menu']}")
    return out


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

RUST_OK = '''
pub fn type_value(elem: &Element) -> &'static str {
    match elem {
        Element::Line(_) => "line",
        Element::Rect(_) => "rectangle",
        Element::Circle(_) => "circle",
        Element::Ellipse(_) => "ellipse",
        Element::Polyline(_) => "polyline",
        Element::Polygon(_) => "polygon",
        Element::Path(_) => "path",
        Element::Text(_) => "text",
        Element::TextPath(_) => "text_path",
        Element::Group(_) => "group",
        Element::Layer(_) => "layer",
        Element::Live(_) => "live",
    }
}
fn caller() {
    if !hidden_types.is_empty() {
        let keep = tree_type_filter_keep(
            rows.iter().map(|r| (r.path.as_slice(), r.type_value)), &hidden_types);
        rows.retain(|r| keep.contains(&r.path));
    }
}
'''

SWIFT_OK = '''
func layersTypeValue(_ elem: Element) -> String {
    switch elem {
    case .line: return "line"
    case .rect: return "rectangle"
    case .circle: return "circle"
    case .ellipse: return "ellipse"
    case .polyline: return "polyline"
    case .polygon: return "polygon"
    case .path: return "path"
    case .text: return "text"
    case .textPath: return "text_path"
    case .group: return "group"
    case .layer: return "layer"
    case .live: return "live"
    }
}
func caller() {
    if !hiddenTypes.isEmpty {
        let keep = layersTypeFilterKeep(
            result.map { (path: $0.path, typeValue: layersTypeValue($0.elem)) },
            hidden: hiddenTypes)
    }
}
'''

MENU_OK = {"body": [{"id": "lp_filter_button", "items": [
    {"label": "Layer", "value": "layer", "type": "toggle"}, {"label": "Group", "value": "group", "type": "toggle"},
    {"label": "Path", "value": "path", "type": "toggle"}, {"label": "Rectangle", "value": "rectangle", "type": "toggle"},
    {"label": "Circle", "value": "circle", "type": "toggle"}, {"label": "Ellipse", "value": "ellipse", "type": "toggle"},
    {"label": "Polyline", "value": "polyline", "type": "toggle"}, {"label": "Polygon", "value": "polygon", "type": "toggle"},
    {"label": "Text", "value": "text", "type": "toggle"}, {"label": "Text Path", "value": "text_path", "type": "toggle"},
    {"label": "Line", "value": "line", "type": "toggle"},
    {"label": "Compound Shape", "value": "live", "type": "toggle"},
]}]}


def self_test() -> int:
    """Prove the gate goes RED on each class it claims to cover."""
    bad = []

    def check(name, rust, swift, menu, want_red):
        try:
            got = failures(scan(rust, swift, menu))
        except ParseFailure as e:
            got = [f"parse: {e}"]
        if bool(got) != want_red:
            verb = "RED" if want_red else "GREEN"
            bad.append(f"  {name}: expected {verb}, got {got or 'GREEN'}")
        return got

    # (a) The shipping shape is green.
    check("a/clean", RUST_OK, SWIFT_OK, MENU_OK, False)

    # (b) THE DEFECT ITSELF -- a filter block that reads the row label. The
    #     historical spelling, verbatim in shape.
    rust_label = RUST_OK.replace(
        "(r.path.as_slice(), r.type_value)",
        '(r.path.as_slice(), if r.display_name.starts_with(\'<\') { "x" } else { "" })')
    got = check("b/rust reads label", rust_label, SWIFT_OK, MENU_OK, True)
    if not any("display_name" in g for g in got):
        bad.append(f"  b: message should name the identifier, got {got}")

    # (c) The same defect on the other side, so the guard is not one-port.
    swift_label = SWIFT_OK.replace(
        "typeValue: layersTypeValue($0.elem)",
        "typeValue: elementDisplayName($0.elem).0")
    check("c/swift reads label", RUST_OK, swift_label, MENU_OK, True)

    # (d) DIVERGENT VOCABULARIES -- the prime directive at its narrowest. The
    #     realistic spelling slip, not a nonsense token.
    check("d/spelling", RUST_OK, SWIFT_OK.replace('"text_path"', '"textPath"'),
          MENU_OK, True)

    # (e) A menu entry no element answers: a control that hides nothing.
    menu_ghost = {"body": [{"id": "lp_filter_button",
                            "items": MENU_OK["body"][0]["items"] + [
                                {"label": "Mesh", "value": "mesh", "type": "toggle"}]}]}
    check("e/ghost menu item", RUST_OK, SWIFT_OK, menu_ghost, True)

    # (f) A new token the menu cannot offer and UNOFFERABLE does not declare.
    #     This is the arm that forces a DECISION when an element kind is added,
    #     rather than letting it become silently unfilterable the way `live`
    #     did before anyone wrote it down.
    check("f/undeclared gap",
          RUST_OK.replace('Element::Live(_) => "live",',
                          'Element::Live(_) => "live",\n        Element::Mesh(_) => "mesh",'),
          SWIFT_OK.replace('case .live: return "live"',
                           'case .live: return "live"\n    case .mesh: return "mesh"'),
          MENU_OK, True)

    # (g) A DECLARED-UNOFFERABLE token that the menu now offers must red until
    #     the row is deleted. This arm fired for real on 2026-07-30: `live` sat
    #     in UNOFFERABLE as a declared shared gap, council Q1.2 added the
    #     Compound Shape entry, and the gate refused its own stale declaration.
    #     Driven here with a synthetic row, since UNOFFERABLE is empty now.
    saved = dict(UNOFFERABLE)
    UNOFFERABLE["line"] = "synthetic: pretend `line` is unofferable"
    try:
        check("g/stale UNOFFERABLE", RUST_OK, SWIFT_OK, MENU_OK, True)
    finally:
        UNOFFERABLE.clear()
        UNOFFERABLE.update(saved)

    # (h) REFUSE rather than pass when the shape is gone. A rename that this
    #     gate cannot follow must not read as a clean tree.
    check("h/renamed away", RUST_OK.replace("pub fn type_value", "pub fn kind_token"),
          SWIFT_OK, MENU_OK, True)
    check("i/no filter block", RUST_OK.replace("if !hidden_types.is_empty()",
                                               "if !hidden.is_empty()"),
          SWIFT_OK, MENU_OK, True)
    check("j/two filter buttons",
          RUST_OK, SWIFT_OK,
          {"body": MENU_OK["body"] + MENU_OK["body"]}, True)

    # (k) The floors, which are the only guard on a parse that silently
    #     shrinks. Drop ONE arm from each port and the vocabularies still
    #     agree -- nothing above would notice.
    check("k/floor", RUST_OK.replace('        Element::Line(_) => "line",\n', ""),
          SWIFT_OK.replace('    case .line: return "line"\n', ""),
          {"body": [{"id": "lp_filter_button", "items": [
              i for i in MENU_OK["body"][0]["items"] if i["value"] != "line"]}]},
          True)

    if bad:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(bad))
        return 1
    print("self-test: 11 classes checked -- a filter block reading the row "
          "label (BOTH ports), divergent spellings, a menu entry no element "
          "answers, an undeclared new gap, a declared gap gone stale, three "
          "shapes of vanished-anchor REFUSAL, and the exact floor that a "
          "silently shrinking parse would otherwise slip past.")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    try:
        result = scan(
            RUST_TOKENS.read_text(encoding="utf-8"),
            SWIFT.read_text(encoding="utf-8"),
            yaml.safe_load(LAYERS_YAML.read_text(encoding="utf-8")),
            RUST_FILTER.read_text(encoding="utf-8"),
        )
    except (OSError, ParseFailure, yaml.YAMLError) as e:
        print(f"ERROR: cannot read the type-filter vocabulary: {e}",
              file=sys.stderr)
        print(file=sys.stderr)
        print("This gate REFUSES rather than passing when the shape it reads "
              "is gone. If a function was renamed, update this gate in the "
              "same commit -- a gate that cannot find its subject reports a "
              "clean tree, which is how the defect it watches for survived "
              "every green suite it ever ran under.", file=sys.stderr)
        return 1

    problems = failures(result)
    if not problems:
        print(f"layers type filter: {len(result['rust'])} type tokens spoken "
              f"identically by both active ports, all {len(result['menu'])} "
              f"menu values answerable, {len(UNOFFERABLE)} declared "
              f"unofferable ({', '.join(sorted(UNOFFERABLE))}), neither "
              f"filter block reads a row label.")
        return 0

    print("ERROR: the Layers type filter's vocabulary does not hold.",
          file=sys.stderr)
    print(file=sys.stderr)
    for p in problems:
        print(f"  * {p}", file=sys.stderr)
    print(file=sys.stderr)
    print("layers.yaml, in the CHECKED semantics ruled 2026-07-30: \"a checked "
          "type lists all its elements, plus their ancestors; nothing checked "
          "is the same as checking everything.\" The filter reads the ELEMENT, "
          "never its label -- a circle the artist named \"<Rectangle>\" is "
          "still a circle.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
