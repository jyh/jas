"""The keyboard bindings, pinned as a cross-language golden.

WHY THIS FILE EXISTS. `test_fixtures/expected/shortcut_structure.json` used to
be produced from a hand-transcribed literal list copied into each port
(`workspace/test_json.rs`, `Workspace/WorkspaceTestJson.swift`). Its own header
said it "must match workspace/shortcuts.yaml"; it did not. It pinned
`Ctrl+0 -> fit_in_window` and carried neither `Ctrl+Alt+0` nor `Ctrl+1`, while
`workspace/shortcuts.yaml` says `Ctrl+0 -> fit_active_artboard`,
`Ctrl+Alt+0 -> fit_all_artboards`, `Ctrl+1 -> zoom_to_actual_size`. Because the
fixture only ever pinned the SERIALIZATION SHAPE, nothing was ever wrong at
runtime — and nothing could see the contradiction either. A reader auditing
"what does Ctrl+0 do" found two answers, one of them under
`test_fixtures/expected/`, and NO golden pinned the real bindings at all.

WHAT CHANGED. Both active ports now BUILD that JSON from the compiled bundle's
`shortcuts` array instead of a literal, so the golden is a BINDING golden. This
file is the third implementation of the same canonicalisation — the reference
interpreter's — so the golden is spec-derived rather than captured from either
port, and the fixture cannot silently re-acquire a private opinion about the
key map.

BLIND SPOT, stated. This pins the bundle's `shortcuts` table, i.e. what the
spec DECLARES. It does not prove any port's key handler actually reaches the
declared action; that is what the action corpus and the per-port route tests
are for.
"""

import json
import os

import pytest


REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..")
)
BUNDLE = os.path.join(REPO_ROOT, "workspace", "workspace.json")
FIXTURE = os.path.join(
    REPO_ROOT, "test_fixtures", "expected", "shortcut_structure.json"
)


def _escape(s):
    """The canonical-JSON string escaper the ports' `JsonObj` uses."""
    return json.dumps(s, ensure_ascii=False)


def _fmt_number(v):
    """Canonical float formatting: 4 decimals, trailing zeros trimmed,
    integral values as `N.0` (matches Rust `fmt` / Swift `fmt`)."""
    rounded = round(v * 10000.0) / 10000.0
    if rounded == int(rounded):
        return "%.1f" % rounded
    return ("%.4f" % rounded).rstrip("0")


def _obj(pairs):
    """Serialize {key: raw_json} with SORTED keys, compact separators."""
    body = ",".join(
        '%s:%s' % (_escape(k), pairs[k]) for k in sorted(pairs)
    )
    return "{%s}" % body


def shortcut_structure_json(bundle):
    """Canonical JSON for the bundle's shortcut table, in declaration order."""
    entries = []
    for sc in bundle.get("shortcuts", []):
        fields = {
            "action": _escape(sc.get("action", "")),
            "key": _escape(sc.get("key", "")),
        }
        params = sc.get("params")
        if isinstance(params, dict):
            pfields = {}
            for pk, pv in params.items():
                if isinstance(pv, str):
                    pfields[pk] = _escape(pv)
                elif isinstance(pv, bool):
                    pfields[pk] = "true" if pv else "false"
                elif isinstance(pv, (int, float)):
                    pfields[pk] = _fmt_number(float(pv))
                else:
                    pfields[pk] = "null"
            fields["params"] = _obj(pfields)
        else:
            fields["params"] = "null"
        entries.append(_obj(fields))
    return _obj({
        "count": str(len(entries)),
        "shortcuts": "[%s]" % ",".join(entries),
    })


@pytest.fixture(scope="module")
def bundle():
    with open(BUNDLE, encoding="utf-8") as f:
        return json.load(f)


def test_fixture_matches_the_bundle_byte_for_byte(bundle):
    """The golden IS the bundle's shortcut table, canonicalised."""
    with open(FIXTURE, encoding="utf-8") as f:
        expected = f.read().strip()
    assert shortcut_structure_json(bundle) == expected


def test_ctrl_0_fits_the_active_artboard(bundle):
    """The single answer to "what does Ctrl+0 do", asserted in its own terms.

    Named after the contradiction it retires: the old fixture said
    `fit_in_window` here, and there was no gate that could disagree with it.
    """
    by_key = {sc["key"]: sc["action"] for sc in bundle["shortcuts"]}
    assert by_key["Ctrl+0"] == "fit_active_artboard"
    assert by_key["Ctrl+Alt+0"] == "fit_all_artboards"
    assert by_key["Ctrl+1"] == "zoom_to_actual_size"
    # `fit_in_window` is a real verb — it is simply not bound to Ctrl+0.
    assert "fit_in_window" not in by_key.values()


def test_no_key_is_bound_twice(bundle):
    """Two rows sharing a key make the later one dead: whichever the port's
    lookup happens to reach wins, and the other binding is a lie in the spec.
    """
    seen = {}
    for sc in bundle["shortcuts"]:
        key = sc["key"]
        assert key not in seen, (
            "key %r is bound twice: %r and %r"
            % (key, seen[key], sc["action"])
        )
        seen[key] = sc["action"]


def test_every_bound_action_exists_in_the_actions_catalog(bundle):
    """A shortcut naming an action the catalog does not define is a key that
    does nothing — invisible to any structural fixture, including this one's
    byte comparison."""
    actions = bundle.get("actions", {})
    missing = sorted({
        sc["action"] for sc in bundle["shortcuts"]
        if sc["action"] not in actions
    })
    assert missing == [], "shortcuts bound to undefined actions: %s" % missing
