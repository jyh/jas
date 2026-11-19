#!/usr/bin/env python3
"""Run every scripts/ invocation that .github/workflows/test.yml runs, before a push.

WHY THIS EXISTS
---------------
CI runs a few hundred `python scripts/...` and `bash scripts/...` lines, spread
over many jobs and inside multi-line `run:` blocks. A grep for `- run:` finds
fewer than half of them: it saw 72 of 189 on 2026-11-17, and it missed
`check_cbindgen_freshness`, so #966 went red after its bytes were public. This
tool PARSES the workflow (every line of every `run:` block) and runs each
invocation from the repo root. On 2026-11-18 it caught two of the author's own
defects before a push: an encoding-hygiene finding, and a frozen-app drift row
the change owed.

WHAT IT DOES
------------
* Lists the distinct invocations (`--list`), or runs them all.
* With `--compare-ref REF` (default `origin/main`), re-runs every failure in a
  clean worktree of REF. A failure there too is ENVIRONMENT or pre-existing (a
  log the CI job produces, a forge call, a toolchain). A failure only on this
  tree is YOURS, and only those make the exit code 1.
* Sets RANGE to `REF..HEAD`, as the CI steps that read a range expect. Run it
  from inside the repo's venv (`source .venv/bin/activate`): the steps resolve
  `python` from PATH, as CI's do.

WHAT IT DOES NOT DO, SAID HERE SO A GREEN IS NOT READ AS CI's
-------------------------------------------------------------
* By default it skips every script that calls a bare `cargo` (named in the
  output). `--cargo` runs them too, and only with CARGO_TARGET_DIR set in the
  environment: a box whose builds must not land in the repo's own `target/`
  names its build directory, or the mode refuses by name (rc 2). Those scripts
  run `cargo run`/`cargo test`, which read CARGO_TARGET_DIR themselves. The
  ref worktree builds into the same directory, so a failure re-run rebuilds.
  `--cargo` raises the per-invocation timeout to 1800 s unless `--timeout`
  says otherwise. Even then it runs only scripts/ lines: CI's own `cargo test`
  steps are not among them.
* It runs nothing that is not a scripts/ invocation: no `cargo`, `swift`,
  `pytest`, `dotnet` or `wasm-pack` line, and no other workflow file.
* A step that reads a log or artifact an earlier CI step writes fails on both
  sides, so it reads as ENVIRONMENT: that is the limit of a local run, not a pass.
* It cannot see platform behaviour (the Windows console, a case-insensitive
  file system).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"
_INVOCATION = re.compile(r"^(python3?|bash) +scripts/(\S+)")


def invocations(workflow_text: str) -> list[str]:
    """Every distinct scripts/ invocation in the workflow's `run:` blocks, in
    first-seen order: each LINE of a block, never only the block's first."""
    import yaml
    doc = yaml.safe_load(workflow_text) or {}
    seen: dict[str, None] = {}
    for job in (doc.get("jobs") or {}).values():
        for step in (job or {}).get("steps") or []:
            for line in str((step or {}).get("run", "")).splitlines():
                s = line.strip()
                if _INVOCATION.match(s):
                    seen.setdefault(s, None)
    return list(seen)


def script_of(cmd: str) -> str:
    return _INVOCATION.match(cmd).group(2)


# A script that BUILDS: its subprocess argv starts with cargo. Not the bare word:
# lane_report.py names "cargo" only to explain an absent toolchain, and this
# file names it in its own needle, so both read as builders and were skipped
# (this tool's own --self-test step never ran here until 2026-11-19).
_CARGO_ARGV = "[" + '"cargo",'  # built, so this file does not spell its own needle


def calls_cargo(script: Path) -> bool:
    try:
        return _CARGO_ARGV in script.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def partition(cmds: list[str], is_cargo, with_cargo: bool) -> tuple[list[str], list[str]]:
    """(to run, skipped), each in first-seen order. Without `--cargo` a script
    that calls a bare cargo is skipped; with it, nothing is."""
    if with_cargo:
        return list(cmds), []
    skipped = [c for c in cmds if is_cargo(c)]
    return [c for c in cmds if c not in skipped], skipped


def cargo_refusal(env: dict, with_cargo: bool) -> str | None:
    """Why `--cargo` cannot run here, or None. A run that builds must name where."""
    if with_cargo and not env.get("CARGO_TARGET_DIR"):
        return ("--cargo needs CARGO_TARGET_DIR set to the build directory this box uses; "
                "without it the cargo scripts would build into jas_dioxus/target")
    return None


def footer(with_cargo: bool, target: str = "") -> str:
    if with_cargo:
        return (f"  (scripts/ steps only, bare-cargo scripts INCLUDED, built in {target}; "
                "CI's own cargo/swift steps are not scripts/ lines: see this file's docstring)")
    return "  (scripts/ steps only, bare-cargo scripts skipped: not CI's green; see this file's docstring)"


def classify(rc_here, rc_ref) -> str:
    """One failure's kind: `rc_ref` None means the ref was not run."""
    if rc_here == 0:
        return "PASS"
    if rc_ref is None:
        return "FAIL"
    return "BOTH" if rc_ref != 0 else "MINE"


def run(cmd: str, cwd: Path, env: dict, log: Path, timeout: int):
    with open(log, "w", encoding="utf-8", newline="") as fh:
        try:
            return subprocess.run(["bash", "-c", cmd], cwd=cwd, env=env, stdout=fh,
                                  stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            return "TIMEOUT"


def self_test() -> int:
    failures: list[str] = []
    ran: list[str] = []

    def check(cond, label):
        ran.append(label)
        if not cond:
            failures.append(label)

    wf = (
        "jobs:\n"
        "  a:\n"
        "    steps:\n"
        "      - run: python scripts/one.py --self-test\n"
        "      - name: a block\n"
        "        run: |\n"
        "          echo hi\n"
        "          python3 scripts/two.py --range \"$RANGE\"\n"
        "          bash scripts/three.sh\n"
        "          cd jas_dioxus && cargo test\n"
        "  b:\n"
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        "      - run: python scripts/one.py --self-test\n"
        "      - run: pythonx scripts/not_one.py\n"
    )
    got = invocations(wf)
    check(got == ["python scripts/one.py --self-test", 'python3 scripts/two.py --range "$RANGE"',
                  "bash scripts/three.sh"], f"a block's every line, deduped, in order: {got}")
    check(script_of('python3 scripts/two.py --range "$RANGE"') == "two.py", "the script name")
    check([classify(0, None), classify(1, None), classify(1, 1), classify(1, 0), classify("TIMEOUT", 0)]
          == ["PASS", "FAIL", "BOTH", "MINE", "MINE"], "the four kinds, a timeout counted as a failure")
    # The live workflow: a real population, and the step a `- run:` grep missed.
    live = invocations(WORKFLOW.read_text(encoding="utf-8"))
    check(len(live) >= 150, f"live invocations found: {len(live)} (a floor, never a target)")
    check(any("check_cbindgen_freshness" in c for c in live),
          "control: the list holds check_cbindgen_freshness (the #966 miss)")
    builders = {script_of(c) for c in live if calls_cargo(ROOT / "scripts" / script_of(c))}
    check("cross_language_algorithms.py" in builders and "check_native_core_tests.py" in builders,
          f"control: the live builders include the cargo-run scripts: {sorted(builders)}")
    check(not builders & {"run_test_yml_steps.py", "lane_report.py"},
          f"a script naming cargo without running it is not skipped: {sorted(builders)}")
    # --cargo: the bare-cargo scripts are included, and only behind a named target dir.
    cmds3 = ["python scripts/a.py", "python scripts/c.py --x", "bash scripts/b.sh"]
    is_c = lambda c: script_of(c) == "c.py"
    check(partition(cmds3, is_c, False) == (["python scripts/a.py", "bash scripts/b.sh"], ["python scripts/c.py --x"]),
          "default: a cargo script is skipped and named")
    check(partition(cmds3, is_c, True) == (cmds3, []), "--cargo: every invocation runs, in order, none skipped")
    r = cargo_refusal({}, True)
    check(r is not None and "CARGO_TARGET_DIR" in r, f"--cargo without CARGO_TARGET_DIR is refused by name: {r!r}")
    check(cargo_refusal({"CARGO_TARGET_DIR": ""}, True) is not None, "an EMPTY CARGO_TARGET_DIR is refused too")
    check(cargo_refusal({"CARGO_TARGET_DIR": "/v/t"}, True) is None, "--cargo with a target dir runs")
    check(cargo_refusal({}, False) is None, "no --cargo: nothing to refuse")
    check("skipped" in footer(False) and "skipped" not in footer(True) and "/v/t" in footer(True, "/v/t"),
          f"the footer names the mode: {footer(False)!r} / {footer(True, '/v/t')!r}")
    arms = len(ran)  # counted as they run, never typed
    for f in failures:
        print(f"  FAIL: {f}")
    print(f"run_test_yml_steps --self-test: {arms} arm(s), {len(failures)} failure(s), {len(live)} live invocations")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--list", action="store_true", help="print the invocations and exit")
    ap.add_argument("--compare-ref", default="origin/main",
                    help="re-run failures on a clean worktree of this ref ('' to skip)")
    ap.add_argument("--cargo", action="store_true",
                    help="also run the scripts that call a bare cargo (needs CARGO_TARGET_DIR)")
    ap.add_argument("--timeout", type=int, default=None,
                    help="seconds per invocation (default 300; 1800 with --cargo)")
    ap.add_argument("--logs", type=Path, help="keep per-invocation logs here (default: a temp dir)")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    cmds = invocations(WORKFLOW.read_text(encoding="utf-8"))
    if args.list:
        print("\n".join(cmds))
        return 0
    refusal = cargo_refusal(dict(os.environ), args.cargo)
    if refusal:
        print(f"run_test_yml_steps: REFUSED: {refusal}", file=sys.stderr)
        return 2
    timeout = args.timeout if args.timeout is not None else (1800 if args.cargo else 300)
    todo, skipped = partition(cmds, lambda c: calls_cargo(ROOT / "scripts" / script_of(c)), args.cargo)
    logs = args.logs or Path(tempfile.mkdtemp(prefix="test-yml-steps-"))
    logs.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    ref = args.compare_ref
    env.setdefault("RANGE", f"{ref}..HEAD" if ref else "origin/main..HEAD")
    print(f"run_test_yml_steps: {len(cmds)} distinct invocations; running {len(todo)}; "
          + (f"bare-cargo scripts INCLUDED (CARGO_TARGET_DIR={os.environ['CARGO_TARGET_DIR']})" if args.cargo else
             f"skipped {len(skipped)} that call a bare cargo: {', '.join(sorted({script_of(c) for c in skipped})) or 'none'}"))
    failed = []
    for i, cmd in enumerate(todo):
        rc = run(cmd, ROOT, env, logs / f"here-{i:03d}.log", timeout)
        if rc != 0:
            failed.append((i, cmd, rc))
    wt = None
    results = []
    try:
        if failed and ref:
            wt = Path(tempfile.mkdtemp(prefix="test-yml-ref-")) / "tree"
            subprocess.run(["git", "worktree", "add", "-q", "--detach", wt, ref], cwd=ROOT, check=True)
            if (ROOT / ".venv").is_dir():
                (wt / ".venv").symlink_to(ROOT / ".venv")
        for i, cmd, rc in failed:
            rc_ref = run(cmd, wt, env, logs / f"ref-{i:03d}.log", timeout) if wt else None
            results.append((classify(rc, rc_ref), cmd, rc, rc_ref, i))
    finally:
        if wt is not None:
            subprocess.run(["git", "worktree", "remove", "--force", wt], cwd=ROOT)
            shutil.rmtree(wt.parent, ignore_errors=True)
    mine = [r for r in results if r[0] in ("MINE", "FAIL")]
    for kind, cmd, rc, rc_ref, i in results:
        print(f"  {kind:4} rc={rc}/{rc_ref if rc_ref is not None else '-'}  {cmd}  [log here-{i:03d}.log]")
    print(f"run_test_yml_steps: ran {len(todo)}, failed here {len(failed)}, "
          f"{'on both sides ' + str(len(results) - len(mine)) + ', ' if ref else ''}YOURS {len(mine)}; logs {logs}")
    print(footer(args.cargo, os.environ.get("CARGO_TARGET_DIR", "")))
    return 1 if mine else 0


if __name__ == "__main__":
    sys.exit(main())
