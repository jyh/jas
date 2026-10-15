"""The compiled workspace carries the brand logo's SVG TEXT, so a port with
no file system access to `assets/` (the engine, a WinUI shell) draws
`brand_logo` from the bundle alone. `app.yaml` names each asset by path
(`app.brand.logo_small: assets/brand/logo-small.svg`); the reference renderer
(jas_flask/app.py) resolved those paths at runtime into `<key>_svg`. The
loader now does it once, at compile time, for every port.
"""

import os

from workspace_interpreter.loader import load_workspace

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def test_every_brand_path_is_inlined_as_its_file_text():
    brand = load_workspace(os.path.join(ROOT, "workspace"))["app"]["brand"]
    paths = {k: v for k, v in brand.items() if isinstance(v, str) and v.endswith(".svg")}
    assert set(paths) >= {"logo", "logo_small"}, "the control: the spec names its logos"
    for key, rel in paths.items():
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            assert brand[f"{key}_svg"] == f.read(), key
        assert brand[f"{key}_svg"].lstrip().startswith("<"), key


def test_the_compiled_bundle_carries_it():
    import json
    with open(os.path.join(ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        brand = json.load(f)["app"]["brand"]
    assert "<svg" in brand.get("logo_small_svg", ""), "workspace.json is regenerated"
