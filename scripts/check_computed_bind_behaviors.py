"""A widget whose bind is COMPUTED must not sit on a web renderer that drops its behavior.

The web's renderers classify a widget's bind (`classify_bind`): `panel.<f>` and
`dialog.<f>` write back, anything else is `BindTarget::None`. Three web
renderers ran NOTHING on None, so a widget with a computed bind lost its
declared behavior with the write-back: the Gradient Location combo (row 268,
four days of red on the web) and Artboard Options' Fill and Size selects
(row 270). Those two kinds are routed now. This gate keeps the class closed:

  * the DROPPING kinds are DERIVED from the renderer source: every
    `fn render_<kind>(` whose body has a `BindTarget::None => {}` or
    `BindTarget::None => { return; }` arm;
  * a shipped widget (workspace/**/*.yaml) of a dropping kind whose
    `bind.value` / `bind.checked` names no `panel.`/`dialog.` field AND that
    declares a `behavior` is refused by name.

    python3 scripts/check_computed_bind_behaviors.py [--self-test]

It does not read the Mac or Windows shells (both route a widget's commit through
their generic doors) and does not judge whether a behavior is right, only
whether the web can run it.
"""
import glob
import os
import re
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDERER = os.path.join(REPO, "jas_dioxus", "src", "interpreter", "renderer.rs")
DROP_ARM = re.compile(r"BindTarget::None\s*=>\s*\{\s*(return;\s*)?\}")
BIND_KEYS = ("value", "checked")


def dropping_kinds(src):
    """{kind: True if its render fn drops on None}, for every render_<kind> fn
    that has a BindTarget::None arm at all."""
    out = {}
    starts = [(m.start(), m.group(1)) for m in re.finditer(r"\nfn render_([a-z_]+)\(", src)]
    for i, (at, kind) in enumerate(starts):
        # A top-level fn ends at its own closing brace in column 0, NOT at the
        # next render fn: a helper between them (and its None arm) is not this
        # fn's (the first run blamed render_placeholder for a helper's arm).
        end = src.find("\n}", at + 1)
        body = src[at:end if end >= 0 else len(src)]
        if "BindTarget::None" in body:
            out[kind] = bool(DROP_ARM.search(body))
    return out


def computed_bind(w):
    b = w.get("bind")
    if not isinstance(b, dict):
        return None  # a string or list `bind` is not a widget's bind map
    for k in BIND_KEYS:
        v = b.get(k)
        if isinstance(v, str) and not v.startswith(("panel.", "dialog.")):
            return k, v
    return None


def widgets(tree, path):
    if isinstance(tree, dict):
        if isinstance(tree.get("type"), str):
            yield path, tree
        for v in tree.values():
            yield from widgets(v, path)
    elif isinstance(tree, list):
        for v in tree:
            yield from widgets(v, path)


def findings(docs, kinds):
    """docs: [(path, parsed yaml)]; kinds: dropping_kinds' map. -> (findings, census)"""
    out, census = [], []
    for path, doc in docs:
        for _, w in widgets(doc, path):
            cb = computed_bind(w)
            if not cb or not w.get("behavior"):
                continue
            census.append((path, w.get("id"), w["type"]))
            if kinds.get(w["type"]):
                out.append(f"{os.path.relpath(path, REPO)} {w.get('id')!r}: a {w['type']} with a computed "
                           f"bind.{cb[0]} ({cb[1][:50]!r}) and a declared behavior; the web's render_{w['type']} "
                           f"drops it on BindTarget::None. Route that arm as render_combo_box/render_select do "
                           f"(commit_computed_bind, apply_dialog_behavior).")
    return out, census


def load_docs():
    return [(p, yaml.safe_load(open(p, encoding="utf-8"))) for p in sorted(glob.glob(
        os.path.join(REPO, "workspace", "**", "*.yaml"), recursive=True))]


def self_test():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)
    src = ("\nfn render_toggle(el) {\n  match t { BindTarget::None => {} }\n}\n"
           "\nfn render_select(el) {\n  match t { BindTarget::None => { apply(); } }\n}\n"
           "\nfn render_icon_select(el) {\n  match t { BindTarget::None => { return; } }\n}\n"
           "\nfn render_button(el) {\n}\n"
           "\nfn render_placeholder(el) {\n  click(el)\n}\n"
           "\nfn helper_after_it(t) {\n  match t { BindTarget::None => {} }\n}\n")
    k = dropping_kinds(src)
    check(k == {"toggle": True, "select": False, "icon_select": True},
          f"the dropping kinds derive from the source, and a helper's None arm is not the render fn before it: {k}")
    w = lambda t, bind, beh=True: {"type": t, "id": "x", "bind": bind, **({"behavior": [{"event": "change"}]} if beh else {})}
    docs = [("/r/workspace/a.yaml", {"children": [w("toggle", {"checked": "a and b"})]})]
    f, c = findings(docs, k)
    check(len(f) == 1 and "render_toggle drops it" in f[0], "a computed-bind toggle with a behavior is refused by name")
    check(not findings([("/r/a.yaml", {"c": [w("toggle", {"checked": "panel.x"})]})], k)[0], "a panel. bind passes")
    check(not findings([("/r/a.yaml", {"c": [w("toggle", {"checked": "a"}, beh=False)]})], k)[0], "no behavior passes")
    check(not findings([("/r/a.yaml", {"c": [w("select", {"value": "if a then b else c"})]})], k)[0],
          "a routed kind passes")
    check(not findings([("/r/a.yaml", {"c": [{"type": "toggle", "bind": "panel.x", "behavior": [{}]}]})], k)[0],
          "a non-mapping bind is no bind, never a crash")
    real = dropping_kinds(open(RENDERER, encoding="utf-8").read())
    check(len(real) >= 3, f"the real renderer has render fns with a None arm (vacuity floor): {real}")
    check(real.get("combo_box") is False and real.get("select") is False,
          f"combo_box and select are routed in the real renderer (rows 268, 270): {real}")
    print(f"check_computed_bind_behaviors --self-test: {8 - len(fails)} of 8 arms")
    for x in fails:
        print("  FAIL:", x)
    return 1 if fails else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    kinds = dropping_kinds(open(RENDERER, encoding="utf-8").read())
    f, census = findings(load_docs(), kinds)
    drop = sorted(k for k, d in kinds.items() if d)
    print(f"check_computed_bind_behaviors: {len(census)} shipped widget(s) with a computed bind and a behavior; "
          f"dropping kinds on the web (derived): {drop or 'none'}; {len(f)} finding(s)")
    for x in f:
        print("  " + x)
    return 1 if f else 0


if __name__ == "__main__":
    sys.exit(main())
