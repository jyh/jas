#!/usr/bin/env python3
"""Write one level-2 certificate from a prove_e2e `E2E-CERT v1` line.

The writer half of §203 (a): a CERTIFIED live run of the Windows app becomes
a committed file, `prototypes/sb_winui/l2_certs/<class>/<id>.<observable>.json`,
that `yaml_coverage_census.py`'s reader checks (and FAILS on when refused).
The census names the row; this script never guesses it: `--row` is required.

    python scripts/write_l2_cert.py --row tools/rect/state --line "E2E-CERT v1 spec=... verdict=CERTIFIED ..."

⛔ IT REFUSES, BY NAME, EVERYTHING THE READER WOULD REFUSE AND THREE THINGS IT
CANNOT SEE. A refusal writes nothing and exits 2.
  - the line's verdict is not CERTIFIED, or any arm is neither PASS nor
    NOT APPLICABLE;
  - the build was `+dirty` (the run's shell or core differed from its commit);
  - the line's whole-spec sha is not the CURRENT `workspace.json`'s: the run
    certified another spec, so the per-item sha computed now would vouch for
    an item the run never saw;
  - the row is not a census row, or (for `tools`) the script drives another tool;
  - the script or its frozen baseline is not in the tree.

The per-item `spec_sha` is the census's own `item_spec_sha` (imported, never
re-derived here), so writer and reader cannot disagree on the hash.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import yaml_coverage_census as census  # noqa: E402

# The keys prove_e2e writes, in its order. A value may hold spaces
# ("PASS(move=1 delta=(36,24))", "NOT APPLICABLE(tool=rect: ...)"), so the
# line splits only before one of THESE keys, never at every space. `spec`
# appears TWICE: first the whole-spec sha, then the selection arm.
LINE_KEYS = ("spec", "build", "platform", "item", "drive", "script", "readback",
             "core", "tree", "pixels", "screenshot", "foreign-input", "verdict", "date")
HEAD = "E2E-CERT v1 "
ARM_KEYS = ("drive", "spec", "readback", "core", "tree", "pixels")


class Refused(Exception):
    pass


def parse_line(line):
    """The line's fields: {key: value}, with the two `spec=` as `spec_sha`
    (the first) and `spec` (the second, the arm)."""
    line = line.strip()
    if not line.startswith(HEAD):
        raise Refused(f"not an E2E-CERT v1 line: {line[:40]!r}")
    keys = "|".join(re.escape(k) for k in LINE_KEYS)
    parts = re.split(rf" (?=(?:{keys})=)", line[len(HEAD):])
    out = {}
    for part in parts:
        key, sep, value = part.partition("=")
        if not sep or key not in LINE_KEYS:
            raise Refused(f"unreadable field {part[:40]!r}")
        if key == "spec" and "spec_sha" not in out:
            key = "spec_sha"
        if key in out:
            raise Refused(f"field {key!r} appears twice")
        out[key] = value
    return out


def arm_verdict(value):
    """An arm's head verdict: PASS, NOT APPLICABLE, or what it says instead."""
    m = re.match(r"SendInput\([^)]*\):(.*)$", value)
    if m:
        value = m.group(1)
    return re.match(r"[A-Z][A-Z ]*[A-Z]", value).group(0) if re.match(r"[A-Z]", value) else value


def whole_spec_sha(root):
    """prove_e2e's `spec=`: sha256 of workspace.json's BYTES, first 16 hex."""
    with open(os.path.join(root, "workspace", "workspace.json"), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]


def build_cert(root, spec, row, line):
    """The certificate dict for census row `row` = (class, id, observable)."""
    cls, iid, obs = row
    f = parse_line(line)
    missing = [k for k in ("spec_sha", "build", "platform", "item", "script", "verdict", "date")
               + ARM_KEYS if k not in f]
    if missing:
        raise Refused(f"the line has no {missing}")
    if f["verdict"] != census.L2_CERTIFIED:
        raise Refused(f"verdict {f['verdict']!r} is not {census.L2_CERTIFIED}")
    arms = {k: arm_verdict(f[k]) for k in ARM_KEYS}
    bad = {k: v for k, v in arms.items() if v not in census.L2_ARM_OK}
    if bad:
        raise Refused(f"arm(s) neither PASS nor NOT APPLICABLE: {bad}")
    if f["build"].endswith("+dirty"):
        raise Refused(f"build {f['build']} was dirty: the run's code was not its commit's")
    now = whole_spec_sha(root)
    if f["spec_sha"] != now:
        raise Refused(f"the run certified spec {f['spec_sha']}, but workspace.json is now {now}")
    sha = census.item_spec_sha(spec, cls, iid)
    known = {(r["class"], r["id"], r["observable"])
             for r in census.census(spec, census.gather_evidence(root))}
    if sha is None or row not in known:
        raise Refused(f"row {cls}/{iid}/{obs} is not a census row")
    # prove_e2e echoes `script=` as the person typed it (`../../test_fixtures/...`
    # from the shell's folder), so the certificate names the ITEM's script and
    # only checks that the typed path ends in it.
    script = f"test_fixtures/input_scripts/{f['item']}.json"
    if not f["script"].replace("\\", "/").endswith(script):
        raise Refused(f"script= {f['script']} is not item {f['item']}'s script ({script})")
    try:
        with open(os.path.join(root, script), encoding="utf-8") as fh:
            sdoc = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refused(f"script {script} is not readable: {e}") from None
    if cls == "tools" and sdoc.get("tool") != iid:
        raise Refused(f"script {script} drives tool {sdoc.get('tool')!r}, not {iid!r}")
    baseline = f"prototypes/sb_winui/e2e_baselines/{f['item']}"
    if not os.path.isdir(os.path.join(root, baseline)):
        raise Refused(f"no frozen baseline at {baseline}")
    return {"schema": census.L2_SCHEMA, "platform": "windows",
            "row": {"class": cls, "id": iid, "observable": obs},
            "spec_sha": sha, "evidence": "e2e", "script": script, "baseline": baseline,
            "arms": arms, "verdict": census.L2_CERTIFIED, "build": f["build"],
            "platform_detail": f["platform"], "date": f["date"]}


def cert_path(root, row):
    cls, iid, obs = row
    return os.path.join(root, census.L2_DIR, cls, f"{iid}.{obs}.json")


def self_test():
    import shutil
    import tempfile
    ok = fail = 0

    def case(name, got, want):
        nonlocal ok, fail
        if got == want:
            ok += 1
        else:
            fail += 1
            print(f"  FAIL: {name} -- want {want!r}, got {got!r}")

    def refusal(fn):
        try:
            fn()
        except Refused as e:
            return str(e)
        except Exception as e:  # noqa: BLE001 -- a crash is not a refusal
            return f"THREW {type(e).__name__}: {e}"
        return None

    # A scratch root: the real workspace.json and census, a fake script + baseline.
    tmp = tempfile.mkdtemp(prefix="l2w-")
    try:
        os.makedirs(os.path.join(tmp, "workspace"))
        shutil.copy(os.path.join(ROOT, "workspace", "workspace.json"), os.path.join(tmp, "workspace"))
        os.makedirs(os.path.join(tmp, "test_fixtures", "input_scripts"))
        for item, tool in (("rect.draw", "rect"), ("selection.drag", "selection")):
            with open(os.path.join(tmp, "test_fixtures", "input_scripts", f"{item}.json"), "w", encoding="utf-8", newline="") as f:
                json.dump({"item": item, "tool": tool}, f)
            os.makedirs(os.path.join(tmp, "prototypes", "sb_winui", "e2e_baselines", item))
        spec = census._load(os.path.join(tmp, "workspace", "workspace.json"))
        sha = whole_spec_sha(tmp)

        def line(item="rect.draw", verdict="CERTIFIED", build="4d665f73", spec_sha=sha,
                 moved="NOT APPLICABLE(tool=rect: the moved-by-delta arm is the selection tool's)",
                 core="PASS", pixels="PASS@2379x1369"):
            return (f"E2E-CERT v1 spec={spec_sha} build={build} platform=windows-winui-10.0.26200 "
                    f"item={item} drive=SendInput(session=1,pid=1,moves=1):PASS(move=1 delta=(36,24)) "
                    f"spec={moved} script=test_fixtures\\input_scripts\\{item}.json "
                    f"readback=PASS(bytes=2468) core={core} tree=PASS pixels={pixels} "
                    f"screenshot=748b6f623bcdfd5b(archived,not compared) "
                    f"foreign-input=none-reached-the-gesture verdict={verdict} "
                    f"date=2026-10-12T03:42:31-07:00")

        rect = ("tools", "rect", "state")

        # parse: the two spec= keys, a value with spaces, the drive's own verdict.
        p = parse_line(line())
        case("parse: the FIRST spec= is the whole-spec sha", p.get("spec_sha"), sha)
        case("parse: the SECOND spec= is the arm, spaces and all", p.get("spec"),
             "NOT APPLICABLE(tool=rect: the moved-by-delta arm is the selection tool's)")
        case("parse: a value with spaces is one value", p.get("drive"),
             "SendInput(session=1,pid=1,moves=1):PASS(move=1 delta=(36,24))")
        case("parse: the last key", p.get("date"), "2026-10-12T03:42:31-07:00")
        case("parse: a line that is not E2E-CERT v1 is refused",
             refusal(lambda: parse_line("PROBE item=rect.draw")) is not None, True)

        case("arm: PASS(...) is PASS", arm_verdict("PASS(bytes=2468)"), "PASS")
        case("arm: PASS@surface is PASS", arm_verdict("PASS@2379x1369"), "PASS")
        case("arm: the drive's verdict is after the SendInput(...): head",
             arm_verdict("SendInput(session=1,pid=1,moves=1):PASS(move=1 delta=(36,24))"), "PASS")
        case("arm: NOT APPLICABLE(...) is NOT APPLICABLE",
             arm_verdict("NOT APPLICABLE(tool=rect: x)"), "NOT APPLICABLE")
        case("arm: FAIL(...) is FAIL", arm_verdict("FAIL(readback=x)"), "FAIL")
        case("arm: NOT COMPARABLE(...) is NOT COMPARABLE",
             arm_verdict("NOT COMPARABLE(surface=1x1 baseline=2x2)"), "NOT COMPARABLE")

        # build: the shape §225 proposed and #370 reads.
        c = build_cert(tmp, spec, rect, line())
        case("cert: the per-item sha is the census's own item_spec_sha",
             c.get("spec_sha"), census.item_spec_sha(spec, "tools", "rect"))
        case("cert: the row", c.get("row"), {"class": "tools", "id": "rect", "observable": "state"})
        case("cert: arms read by verdict", c.get("arms"),
             {"drive": "PASS", "spec": "NOT APPLICABLE", "readback": "PASS", "core": "PASS",
              "tree": "PASS", "pixels": "PASS"})
        case("cert: the script and baseline, with forward slashes",
             (c.get("script"), c.get("baseline")),
             ("test_fixtures/input_scripts/rect.draw.json", "prototypes/sb_winui/e2e_baselines/rect.draw"))
        case("cert: a script= path as typed at the prompt names the canonical script",
             build_cert(tmp, spec, rect, line().replace(
                 "script=test_fixtures\\input_scripts", "script=..\\..\\test_fixtures\\input_scripts")
             ).get("script"), "test_fixtures/input_scripts/rect.draw.json")
        case("refuse: a script= path that is not the item's script",
             "item" in (refusal(lambda: build_cert(tmp, spec, rect, line().replace(
                 "input_scripts\\rect.draw.json", "input_scripts\\other.json"))) or ""), True)
        case("cert: the rest", (c.get("schema"), c.get("platform"), c.get("evidence"), c.get("verdict"),
                                c.get("build"), c.get("platform_detail"), c.get("date")),
             (census.L2_SCHEMA, "windows", "e2e", "CERTIFIED", "4d665f73", "windows-winui-10.0.26200",
              "2026-10-12T03:42:31-07:00"))
        # The reader's own verdict on what the writer wrote: CERTIFIED, not refused.
        rows = census.census(spec, census.gather_evidence(ROOT))
        os.makedirs(os.path.dirname(cert_path(tmp, rect)))
        with open(cert_path(tmp, rect), "w", encoding="utf-8", newline="") as f:
            json.dump(c, f)
        got, refused = census.read_l2_certs(tmp, spec, rows)
        case("cert: the census READER certifies what the writer wrote",
             (got.get(("windows", rect), ("absent",))[0], refused), ("CERTIFIED", []))
        os.remove(cert_path(tmp, rect))

        # refusals, each by name; and their CONTROL is the case above.
        def why(**kw):
            return refusal(lambda: build_cert(tmp, spec, kw.pop("row", rect), line(**kw)))
        case("refuse: NOT CERTIFIED", "verdict" in (why(verdict="NOT") or ""), True)
        case("refuse: a FAIL arm even under a CERTIFIED verdict",
             "core" in (why(core="FAIL(readback=x)") or ""), True)
        case("refuse: a NOT COMPARABLE pixel arm",
             "pixels" in (why(pixels="NOT COMPARABLE(surface=1x1 baseline=2x2)") or ""), True)
        case("refuse: a +dirty build", "dirty" in (why(build="4d665f73+dirty") or ""), True)
        case("refuse: another spec than the current workspace.json",
             "workspace.json" in (why(spec_sha="0123456789abcdef") or ""), True)
        case("refuse: a row the census does not have",
             "census" in (why(row=("tools", "no_such_tool", "state")) or ""), True)
        case("refuse: a tools row whose script drives another tool",
             "selection" in (why(row=("tools", "selection", "state")) or ""), True)
        case("CONTROL: the selection row with ITS script is not refused",
             why(row=("tools", "selection", "state"), item="selection.drag",
                 moved="PASS(path=[0,0] coords=2 by (36,24))"), None)
        shutil.rmtree(os.path.join(tmp, "prototypes", "sb_winui", "e2e_baselines", "rect.draw"))
        case("refuse: no frozen baseline in the tree", "baseline" in (why() or ""), True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"--- write_l2_cert self-test: {ok} passed, {fail} failed ---")
    return 1 if fail else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--row", help="<class>/<id>/<observable>, a census row")
    ap.add_argument("--line", help="the run's `E2E-CERT v1` line, verbatim")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not (args.row and args.line):
        ap.error("--row and --line are both required")
    row = tuple(args.row.split("/"))
    if len(row) != 3:
        print(f"write_l2_cert: REFUSED: --row {args.row!r} is not <class>/<id>/<observable>")
        return 2
    spec = census._load(os.path.join(args.root, "workspace", "workspace.json"))
    try:
        cert = build_cert(args.root, spec, row, args.line)
    except Refused as e:
        print(f"write_l2_cert: REFUSED: {e}")
        return 2
    path = cert_path(args.root, row)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cert, f, indent=2, sort_keys=False, ensure_ascii=False)
        f.write("\n")
    print(f"write_l2_cert: WROTE {os.path.relpath(path, args.root).replace(os.sep, '/')} "
          f"spec_sha={cert['spec_sha']} build={cert['build']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
