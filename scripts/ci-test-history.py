#!/usr/bin/env python3
"""Answer "is this test failure OURS?" from CI history, before theorising.

THE INCIDENT THIS EXISTS FOR (2026-08-14, PR #1380). A toolkit-bump PR went red
on `AccountRegistryStorePoolStarvationTests`. The first diagnosis offered was
"CI runs 4 simulator clones per runner, so the machine is oversubscribed and the
probe legitimately cannot be scheduled" — plausible, self-consistent, and WRONG.
Pulling the same test out of the previous GREEN run settled it in one command:

    #1377 (green)  passed 0.183s · passed 0.004s · passed 0.004s
    #1380 (red)    passed 0.215s · FAILED 69.186s · passed 0.003s

Same test, same runner shape, different code. It WAS ours. The reviewer was
right and the theory was wrong, and no amount of reasoning about runners would
have produced that table — only the history did.

WHAT IT ANSWERS, mechanically:

  NEW          the test passed on earlier runs and fails now -> this branch
               introduced it. Fix it; do not blame the runner.
  PRE-EXISTING it fails on other branches too -> not yours. Say so with
               evidence instead of absorbing someone else's red.
  FLAKY        it passes AND fails within a single run's iterations -> retry is
               masking it. This is the dangerous one: `-retry-tests-on-failure
               -test-iterations 3` reports the run green while a real regression
               sits underneath. In the incident above the test passed 2 of 3
               iterations; retry would have swallowed a genuine regression
               exactly as readily as it surfaced a false one.

WHAT IT DOES NOT ANSWER. Whether the failure is test POLLUTION (order-dependent
state from an earlier test). That axis is `scripts/find-test-polluter.sh`, and
the two together are the protocol: history says whose it is, the polluter script
says why. A test that is NEW here but passes in isolation locally is pollution
your branch newly exposed, not necessarily logic your branch broke.

    python3 scripts/ci-test-history.py <TestName>[.method] [options]

      --limit N       CI runs to scan (default 10)
      --branch B      restrict to one branch
      --workflow W    workflow name (default "Unit Tests")
      --repo R        owner/name (default: inferred from origin)
      --no-cache      re-download logs instead of reusing them

Exit 0 whatever the verdict — this is a diagnostic, not a gate.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

# Parallel-clone form:  Test case 'Class.method()' passed on 'Clone 1 of …' (0.004 seconds)
PARALLEL = re.compile(
    r"Test case '([\w]+)\.([\w]+)\(\)' (passed|failed) on '([^']*)' \(([\d.]+) seconds\)"
)
# Serial xcodebuild form:  Test Case '-[Bundle.Class method]' passed (0.038 seconds).
SERIAL = re.compile(
    r"Test Case '-\[[\w.]*?([\w]+) ([\w]+)\]' (passed|failed) \(([\d.]+) seconds\)"
)


def sh(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def infer_repo() -> str:
    url = sh(["git", "remote", "get-url", "origin"]).strip()
    m = re.search(r"[:/]([\w-]+/[\w-]+?)(?:\.git)?$", url)
    if not m:
        print("error: could not infer repo from origin; pass --repo owner/name", file=sys.stderr)
        raise SystemExit(2)
    return m.group(1)


def runs(repo: str, workflow: str, limit: int, branch: str | None) -> list[dict]:
    cmd = ["gh", "run", "list", "--repo", repo, "--workflow", workflow,
           "--limit", str(limit), "--json", "databaseId,headBranch,headSha,conclusion,createdAt"]
    if branch:
        cmd += ["--branch", branch]
    import json
    out = sh(cmd)
    try:
        return json.loads(out) if out.strip() else []
    except json.JSONDecodeError:
        print(f"error: could not list runs (is `gh` authenticated?)\n{out[:200]}", file=sys.stderr)
        raise SystemExit(2)


def log_for(repo: str, run_id: int, use_cache: bool) -> str:
    cache = os.path.join(tempfile.gettempdir(), f"ci-log-{repo.replace('/', '_')}-{run_id}.txt")
    if use_cache and os.path.exists(cache) and os.path.getsize(cache) > 0:
        return open(cache, encoding="utf-8", errors="replace").read()
    text = sh(["gh", "run", "view", str(run_id), "--repo", repo, "--log"])
    if text.strip():
        with open(cache, "w", encoding="utf-8") as fh:
            fh.write(text)
    return text


def results_for(log: str, cls: str, method: str | None) -> list[tuple[str, str, str]]:
    """-> [(method, passed|failed, seconds)] for every iteration found."""
    found = []
    for rx, groups in ((PARALLEL, (1, 2, 3, 5)), (SERIAL, (1, 2, 3, 4))):
        for m in rx.finditer(log):
            c, meth, verdict, secs = (m.group(g) for g in groups)
            if c != cls:
                continue
            if method and meth != method:
                continue
            found.append((meth, verdict, secs))
    return found


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("test", help="TestClass or TestClass.method")
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--branch")
    ap.add_argument("--workflow", default="Unit Tests")
    ap.add_argument("--repo")
    ap.add_argument("--no-cache", action="store_true")
    args = ap.parse_args(argv[1:])

    cls, _, method = args.test.partition(".")
    method = method or None
    repo = args.repo or infer_repo()

    found = runs(repo, args.workflow, args.limit, args.branch)
    if not found:
        print(f"no runs of workflow {args.workflow!r} on {repo}")
        return 0

    print(f"{args.test} — {len(found)} run(s) of {args.workflow!r} on {repo}\n")
    per_branch: dict[str, list[str]] = defaultdict(list)
    flaky_runs: list[str] = []
    any_seen = False

    for r in found:
        log = log_for(repo, r["databaseId"], not args.no_cache)
        res = results_for(log, cls, method)
        stamp = f"{r['createdAt'][5:16]}  {r['headSha'][:8]}  {(r['headBranch'] or '?')[:34]:34s}"
        if not res:
            print(f"  {stamp}  run={r['conclusion'] or '-':8s}  (test not in this run)")
            continue
        any_seen = True
        verdicts = [v for _, v, _ in res]
        detail = " · ".join(f"{v} {s}s" for _, v, s in res)
        mixed = "passed" in verdicts and "failed" in verdicts
        flag = "  <- MIXED, retry is masking this" if mixed else ""
        if mixed:
            flaky_runs.append(r["headSha"][:8])
        print(f"  {stamp}  run={r['conclusion'] or '-':8s}  {detail}{flag}")
        per_branch[r["headBranch"] or "?"].append("failed" if "failed" in verdicts else "passed")

    print()
    if not any_seen:
        print(f"VERDICT: {args.test} never ran in the scanned window.")
        print("  Widen with --limit, or check the name — a renamed/never-registered test")
        print("  silently runs nowhere, which looks identical to passing.")
        return 0

    failing = {b for b, v in per_branch.items() if "failed" in v}
    passing = {b for b, v in per_branch.items() if "passed" in v}

    if flaky_runs:
        print(f"VERDICT: FLAKY — passes and fails within a single run ({', '.join(flaky_runs)}).")
        print("  Retry reports the run green while the defect stays. Do NOT re-run to")
        print("  clear it; a test that flips on load is measuring the machine, not the code.")
    elif failing and not (failing & passing) and len(passing) > 0:
        print(f"VERDICT: NEW — fails only on {', '.join(sorted(failing))}, passes elsewhere.")
        print("  This branch introduced it. Fix the change, not the environment.")
    elif failing and passing:
        print(f"VERDICT: MIXED across branches — fails on {', '.join(sorted(failing))}, "
              f"passes on {', '.join(sorted(passing))}.")
        print("  Compare the per-iteration timings above before concluding; a large")
        print("  duration change is a load/scheduling signal, a hard failure is logic.")
    elif failing:
        print(f"VERDICT: PRE-EXISTING — fails on every branch scanned ({', '.join(sorted(failing))}).")
        print("  Not introduced by your branch. Say so with this evidence rather than")
        print("  absorbing it — but it still needs an owner.")
    else:
        print("VERDICT: green everywhere in the scanned window.")

    print("\nNext, for the pollution axis (order-dependent state, which CI history")
    print("cannot see):  scripts/find-test-polluter.sh --victim " + cls)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
