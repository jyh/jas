"""Every golden ``scripts/gen_panel_layout_fixture.py`` writes is FRESH
against the reference (STATUS-jas row 67).

The ports replay these goldens, so a reference change that forgets to re-run
the generator leaves a golden both ports still agree with, and nothing reds.
Only ``panel_bind_values.json`` had a reference staleness arm
(``test_bind_values.py``). This one runs the generator with its writer
replaced by a collector and compares every payload, byte for byte, with the
file on disk.
"""

import importlib.util
import json
import os

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_GEN = os.path.join(_ROOT, "scripts", "gen_panel_layout_fixture.py")

# The layout goldens the row is about. A floor, not the population: the
# generator may write more, and every one it writes is compared.
_LAYOUT = {"panel_layout.json", "pane_layout.json", "dialog_layout.json"}


def _would_write():
    spec = importlib.util.spec_from_file_location("gen_panel_layout_fixture", _GEN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    collected = {}

    def collect(path, cases):
        assert path not in collected, f"the generator writes {path} twice"
        collected[path] = json.dumps(cases, indent=2) + "\n"

    mod._write = collect
    mod.print = lambda *a, **k: None
    assert mod.main() in (0, None)
    return collected


def test_every_generated_golden_matches_the_file_on_disk():
    collected = _would_write()
    names = {os.path.basename(p) for p in collected}
    assert _LAYOUT <= names, sorted(names)
    stale = []
    for path, text in sorted(collected.items()):
        with open(path, encoding="utf-8", newline="") as f:
            if f.read() != text:
                stale.append(os.path.relpath(path, _ROOT))
    assert not stale, (
        f"stale against the reference: {stale} "
        "(re-run scripts/gen_panel_layout_fixture.py and commit)")
