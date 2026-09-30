#!/usr/bin/env python3
"""Split the unit-test classes into CI shards, and prove every class ran once.

The Unit Tests workflow builds once (`build-for-testing`) and runs the tests in
N matrix jobs (`test-without-building`), so a flaky or failing test costs one
shard's re-run instead of the whole ~50-minute job. Everything that decides
which class runs where lives in this file, so it can be tested without Xcode.

prior-art-checked: nothing under scripts/ splits a CI test run, and the harness
tooling that allocates simulators is local-only by design (CLAUDE.local.md #8).

The risk sharding adds is a class that runs in NO shard. xcodebuild ignores an
`-only-testing:` name that matches nothing, so a class dropped by the split, or
misspelt in the plan, produces a green shard and simply never executes. Three
checks close that, each at the point where it can still be seen:

  plan            every enumerated class lands in exactly one shard, and every
                  isolated-serial name matches an enumerated class
  verify-shard    every class assigned to a shard appears in that shard's
                  result bundle, and no class from another shard does
  verify-union    the union of the per-shard reports equals the enumerated
                  class list, with no class reported by two shards

Subcommands:

  timings        regenerate scripts/ci-test-timings.json from recent green CI
                 runs (per-class seconds, median across runs sampled once)
  plan           enumerated tests + timings -> plan JSON
  args           print the -only-testing arguments for one shard, one per line
  verify-shard   compare one shard's xcresult test tree against the plan
  verify-union   compare every shard report against the plan (the CI gate)
  kills          list the tests killed at the execution-time allowance, for
                 the shard's one second chance
  check-rerun    confirm every second-chance test ran and passed

Assignment is longest-processing-time-first over the historical per-class
seconds, which is deterministic: ties break on the class name and then the
lowest shard index. A class with no timing data is placed by a stable hash of
its name (sha256, not Python's salted hash()), so a new class always lands in
the same shard without moving any other class.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_TIMINGS = REPO / "scripts" / "ci-test-timings.json"
DEFAULT_ISOLATED = REPO / "scripts" / "ci-isolated-serial-tests.txt"

# The two test bundles in the Palace scheme. A class outside these is an
# enumeration-format surprise, and is refused rather than guessed at.
TEST_TARGETS = ("PalaceTests", "TenPrintCoverTests")

# Work that is not a test class but has to run on some shard. Each is placed by
# the same balancing as the classes, with the weight from the timings file.
EXTRAS = ("streaming-on", "packages")


class PlanError(Exception):
    """The plan cannot be trusted; the caller must fail the job."""


# --------------------------------------------------------------------------
# Enumeration
# --------------------------------------------------------------------------

def classes_from_enumeration(doc: dict) -> list[str]:
    """-> sorted ["Target/Class", ...] from `xcodebuild -enumerate-tests` JSON.

    Reads the flat style: {"values": [{"enabledTests": [{"identifier":
    "Target/Class/method()"}], "disabledTests": [...]}]}. Disabled tests are
    ignored; they do not run in the unsharded job either.

    A two-part identifier ("Target/Class") is an XCTestCase subclass with no
    test methods — a shared base class such as PalaceTestCase, or a class whose
    tests were all removed. It executes nothing in any configuration, so it is
    not planned: a shard could never show it running, and requiring that would
    fail every run.
    """
    found: set[str] = set()
    if doc.get("errors"):
        raise PlanError(f"test enumeration reported errors: {doc['errors']}")
    values = doc.get("values")
    if not isinstance(values, list):
        raise PlanError("enumeration JSON has no 'values' list; was it produced with "
                        "-test-enumeration-style flat -test-enumeration-format json?")
    for plan in values:
        for t in plan.get("enabledTests", []) or []:
            parts = str(t.get("identifier", "")).split("/")
            if len(parts) not in (2, 3) or not all(parts):
                raise PlanError(f"unrecognised test identifier: {t!r}")
            if len(parts) == 3:
                found.add(f"{parts[0]}/{parts[1]}")
    return sorted(found)


def check_targets(classes: list[str]) -> None:
    unknown = sorted({c.split("/")[0] for c in classes} - set(TEST_TARGETS))
    if unknown:
        raise PlanError(f"enumeration names test target(s) this script does not know: {unknown}")
    missing = [t for t in TEST_TARGETS if not any(c.startswith(t + "/") for c in classes)]
    if missing:
        raise PlanError(f"enumeration contains no class from {missing}; "
                        "a whole bundle would run nowhere")


# --------------------------------------------------------------------------
# Isolated-serial list
# --------------------------------------------------------------------------

def read_isolated(path: Path) -> list[str]:
    """-> ["PalaceTests/Class", ...]; comments (#) and blank lines ignored."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    if not out:
        raise PlanError(f"{path} lists no classes; an empty list would move every "
                        "isolated class into the parallel run without saying so")
    return out


# --------------------------------------------------------------------------
# Assignment
# --------------------------------------------------------------------------

def stable_shard(name: str, shards: int) -> int:
    return int(hashlib.sha256(name.encode("utf-8")).hexdigest(), 16) % shards


def assign(classes: list[str], seconds: dict[str, float], shards: int,
           extras: dict[str, float] | None = None) -> dict:
    """-> {"units": {name: shard}, "load": [seconds per shard], "hashed": [...]}.

    `seconds` is keyed by bare class name (CI logs do not carry the bundle) or
    by "Target/Class"; either matches. Units with timing data are placed
    longest-first onto the least-loaded shard. Units without it are placed by
    stable_shard() and contribute no load, because there is nothing to add.
    """
    if shards < 1:
        raise PlanError("shard count must be at least 1")
    extras = extras or {}
    timed: list[tuple[float, str]] = []
    hashed: list[str] = []
    for c in classes:
        s = seconds.get(c, seconds.get(c.split("/", 1)[-1]))
        if s is None:
            hashed.append(c)
        else:
            timed.append((float(s), c))
    for name, s in extras.items():
        timed.append((float(s), f"@{name}"))

    load = [0.0] * shards
    units: dict[str, int] = {}
    for s, name in sorted(timed, key=lambda t: (-t[0], t[1])):
        k = min(range(shards), key=lambda i: (load[i], i))
        units[name] = k
        load[k] += s
    for c in sorted(hashed):
        units[c] = stable_shard(c, shards)
    return {"units": units, "load": load, "hashed": sorted(hashed)}


def build_plan(classes: list[str], timings: dict, shards: int, isolated: list[str]) -> dict:
    if len(set(classes)) != len(classes):
        raise PlanError("enumeration lists a class twice")
    classes = sorted(classes)
    check_targets(classes)
    unknown_iso = sorted(set(isolated) - set(classes))
    if unknown_iso:
        raise PlanError("isolated-serial names match no enumerated class (xcodebuild would "
                        f"ignore them and the class would run in neither pass): {unknown_iso}")
    scale = float(timings.get("class_scale", 1.0))
    seconds = {c: s * scale for c, s in timings.get("classes", {}).items()}
    extras = {e: timings.get("extras", {}).get(e, 0.0) for e in EXTRAS}
    result = assign(classes, seconds, shards, extras)
    plan = {
        "shards": shards,
        "classes": {c: result["units"][c] for c in classes},
        "isolated": sorted(isolated),
        "extras": {e: result["units"][f"@{e}"] for e in EXTRAS},
        "estimated_seconds": [round(x, 1) for x in result["load"]],
        "hashed": result["hashed"],
    }
    check_plan(plan, classes)
    return plan


def check_plan(plan: dict, classes: list[str]) -> None:
    """Every class in exactly one shard, every shard index in range."""
    assigned = plan["classes"]
    missing = sorted(set(classes) - set(assigned))
    extra = sorted(set(assigned) - set(classes))
    bad = sorted(c for c, k in assigned.items()
                 if not isinstance(k, int) or not (0 <= k < plan["shards"]))
    if missing or extra or bad:
        raise PlanError(f"plan does not partition the classes: missing={missing} "
                        f"unexpected={extra} out-of-range={bad}")
    for e in EXTRAS:
        if not (0 <= plan["extras"].get(e, -1) < plan["shards"]):
            raise PlanError(f"extra {e!r} is not assigned to a shard")


def shard_classes(plan: dict, shard: int, kind: str) -> list[str]:
    iso = set(plan["isolated"])
    mine = sorted(c for c, k in plan["classes"].items() if k == shard)
    if kind == "serial":
        return [c for c in mine if c in iso]
    if kind == "parallel":
        return [c for c in mine if c not in iso]
    return mine


# --------------------------------------------------------------------------
# Result bundles
# --------------------------------------------------------------------------

def _cases(node):
    for ch in node.get("children", []) or []:
        if ch.get("nodeType") == "Test Case":
            yield ch
        else:
            yield from _cases(ch)


def suite_results(tests_doc: dict) -> dict[str, list[str]]:
    """-> {"Target/Class": [result per test case]} from
    `xcresulttool get test-results tests` JSON. A suite with no test cases
    under it is omitted: it did not run anything."""
    out: dict[str, list[str]] = {}

    def walk(node, bundle=None):
        nt = node.get("nodeType")
        if nt == "Unit test bundle":
            bundle = node.get("name")
        if nt == "Test Suite" and bundle:
            rs = [str(c.get("result")) for c in _cases(node)]
            if rs:
                out.setdefault(f"{bundle}/{node.get('name')}", []).extend(rs)
            return
        for ch in node.get("children", []) or []:
            walk(ch, bundle)

    for n in tests_doc.get("testNodes", []) or []:
        walk(n)
    return out


def verify_shard(plan: dict, shard: int, tests_doc: dict) -> dict:
    """-> {"shard", "assigned", "executed", "skipped_only", "missing", "foreign"}.

    A class whose every case reported Skipped is listed separately: XCTSkip is
    a verdict the unsharded job would have reached too, so it is not a class
    lost by the split, but it is not an execution either and stays visible.
    """
    assigned = set(shard_classes(plan, shard, "all"))
    results = suite_results(tests_doc)
    present = set(results)
    skipped = {c for c, rs in results.items() if all(r == "Skipped" for r in rs)}
    ran = present - skipped
    return {"shard": shard, "assigned": sorted(assigned), "executed": sorted(ran),
            "skipped_only": sorted(skipped),
            "missing": sorted(assigned - present), "foreign": sorted(present - assigned)}


def verify_union(plan: dict, reports: list[dict]) -> list[str]:
    """-> problems; empty means every planned class was reported by exactly one shard."""
    problems = []
    seen_shards = sorted(r["shard"] for r in reports)
    if seen_shards != list(range(plan["shards"])):
        problems.append(f"expected one report from each of shards 0..{plan['shards'] - 1}, "
                        f"got {seen_shards}")
    owner: dict[str, list[int]] = defaultdict(list)
    for r in reports:
        for c in set(r["executed"]) | set(r.get("skipped_only", [])):
            owner[c].append(r["shard"])
        if r.get("missing"):
            problems.append(f"shard {r['shard']} did not run: {', '.join(r['missing'])}")
    planned = set(plan["classes"])
    never = sorted(planned - set(owner))
    if never:
        problems.append(f"{len(never)} planned class(es) ran in no shard: {', '.join(never)}")
    twice = sorted(c for c, ks in owner.items() if len(ks) > 1)
    if twice:
        problems.append("class(es) ran in more than one shard: "
                        + ", ".join(f"{c} {owner[c]}" for c in twice))
    unplanned = sorted(set(owner) - planned)
    if unplanned:
        problems.append(f"class(es) ran that the plan does not name: {', '.join(unplanned)}")
    return problems


# --------------------------------------------------------------------------
# Allowance kills: the one failure `-retry-tests-on-failure` never retries
# --------------------------------------------------------------------------
#
# A test XCTest kills at its execution-time allowance gets exactly one
# iteration: 0 of 28 kills in the 2026-09 census were retried, against every
# ordinary failure. The census also found the kills were runner memory stalls
# rather than deadlocks in the test. So the shard gives a killed test one more
# run, alone, in a fresh test process — and only when every failure in the
# shard was a kill, so an assertion failure is never re-run into a pass.

ALLOWANCE_KILL = re.compile(r"exceeded execution time allowance", re.IGNORECASE)


def _messages(node) -> list[str]:
    out = []
    for ch in node.get("children", []) or []:
        if ch.get("nodeType") == "Failure Message":
            out.append(str(ch.get("name", "")))
        else:
            out.extend(_messages(ch))
    return out


def final_failures(tests_doc: dict) -> list[dict]:
    """-> [{"id": "Bundle/Class/method", "test": "Class/method()", "killed": bool}]
    for every test case whose final result is Failed.

    `killed` means every failure message on the test is an allowance kill. A
    test that failed an assertion on one iteration and was killed on another
    is not a kill: it has a failure of its own.
    """
    out = []

    def walk(node, bundle=None):
        nt = node.get("nodeType")
        if nt == "Unit test bundle":
            bundle = node.get("name")
        if nt == "Test Case":
            if node.get("result") == "Failed":
                ident = str(node.get("nodeIdentifier", ""))
                msgs = _messages(node)
                out.append({
                    "id": f"{bundle}/{ident.removesuffix('()')}",
                    "test": ident,
                    "killed": bool(msgs) and all(ALLOWANCE_KILL.search(m) for m in msgs),
                })
            return
        for ch in node.get("children", []) or []:
            walk(ch, bundle)

    for n in tests_doc.get("testNodes", []) or []:
        walk(n)
    return sorted(out, key=lambda f: f["id"])


# Exit codes of `kills`, so the shell can branch without parsing prose.
KILLS_ONLY, KILLS_MIXED, KILLS_NONE = 0, 3, 4


def kill_rerun_candidates(tests_doc: dict) -> tuple[int, list[str]]:
    """-> (status, ids). ids are only returned when status is KILLS_ONLY."""
    failures = final_failures(tests_doc)
    if not failures:
        return KILLS_NONE, []
    if not all(f["killed"] for f in failures):
        return KILLS_MIXED, []
    return KILLS_ONLY, [f["id"] for f in failures]


def rerun_outcome(expected_ids: list[str], rerun_doc: dict) -> list[str]:
    """-> problems; empty means every re-run test ran and passed.

    Checked by name, because xcodebuild runs nothing for an `-only-testing`
    identifier that matches nothing and still exits 0.
    """
    results: dict[str, str] = {}

    def walk(node, bundle=None):
        nt = node.get("nodeType")
        if nt == "Unit test bundle":
            bundle = node.get("name")
        if nt == "Test Case":
            ident = str(node.get("nodeIdentifier", "")).removesuffix("()")
            results[f"{bundle}/{ident}"] = str(node.get("result"))
            return
        for ch in node.get("children", []) or []:
            walk(ch, bundle)

    for n in rerun_doc.get("testNodes", []) or []:
        walk(n)
    problems = []
    for i in expected_ids:
        r = results.get(i)
        if r is None:
            problems.append(f"{i} did not run on the second chance")
        elif r != "Passed":
            problems.append(f"{i} {r.lower()} on the second chance")
    return problems


# --------------------------------------------------------------------------
# Timings from CI logs
# --------------------------------------------------------------------------

PARALLEL = re.compile(
    r"Test case '(\w+)\.(\w+)\(\)' (passed|failed) on '[^']*' \(([\d.]+) seconds\)")
SERIAL = re.compile(
    r"Test Case '-\[[\w.]*?(\w+) (\w+)\]' (passed|failed) \(([\d.]+) seconds\)")
# The ON leg re-runs the flag consumers' classes a second time with a different
# environment; those executions are the ON leg's cost, not the class's. `gh run
# view --log` prefixes each line with "<job>\t<step>\t", so the step is field 2.
ON_LEG_STEP = re.compile(r"flag ON", re.IGNORECASE)


def class_seconds_from_log(log: str) -> tuple[dict[str, float], float]:
    """-> ({class: summed seconds}, depth) for one run's main test passes.

    Depth is executions per distinct test. Only a run sampled once (depth ~1)
    measures a class's cost; a retried run counts its failures twice.
    """
    per_class: dict[str, float] = defaultdict(float)
    per_test: dict[str, int] = defaultdict(int)
    for line in log.splitlines():
        fields = line.split("\t", 2)
        if len(fields) == 3 and ON_LEG_STEP.search(fields[1]):
            continue
        for rx in (PARALLEL, SERIAL):
            for m in rx.finditer(line):
                cls, meth, _verdict, secs = m.groups()
                per_class[cls] += float(secs)
                per_test[f"{cls}.{meth}"] += 1
    if not per_test:
        return {}, 0.0
    return dict(per_class), sum(per_test.values()) / len(per_test)


def median_timings(per_run: list[dict[str, float]]) -> dict[str, float]:
    acc: dict[str, list[float]] = defaultdict(list)
    for run in per_run:
        for c, s in run.items():
            acc[c].append(s)
    return {c: round(statistics.median(v), 3) for c, v in sorted(acc.items())}


# A log with fewer test lines than this cannot have measured the suite.
MIN_CLASSES_PER_RUN = 100
MIN_RUNS = 3


def usable_run(secs: dict[str, float], depth: float) -> bool:
    return len(secs) >= MIN_CLASSES_PER_RUN and 0.99 <= depth <= 1.05


def _gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False).stdout


def regenerate_timings(repo: str, workflow: str, limit: int, previous: dict) -> dict:
    listing = json.loads(_gh(["run", "list", "--repo", repo, "--workflow", workflow,
                              "--status", "success", "--limit", str(limit),
                              "--json", "databaseId"]) or "[]")
    per_run, used = [], []
    for r in listing:
        log = _gh(["run", "view", str(r["databaseId"]), "--repo", repo, "--log"])
        secs, depth = class_seconds_from_log(log)
        if not usable_run(secs, depth):
            continue  # an unreadable log, or a run whose retries inflate the sums
        per_run.append(secs)
        used.append(r["databaseId"])
    if len(per_run) < MIN_RUNS:
        raise PlanError(f"only {len(per_run)} usable run(s); refusing to overwrite timings "
                        "from that little evidence")
    return timings_doc(per_run, used, previous)


def run_scale(per_run: list[dict[str, float]], medians: dict[str, float]) -> float:
    """-> median over runs of (run's total class seconds / sum of class medians).

    Per-class durations are skewed by occasional stalls, so the sum of the
    per-class medians is well below what a typical run spends; the shard wall
    clock follows the run total. The planner multiplies class seconds by this
    so they are in the same unit as the extras, which are measured wall time.
    """
    base = sum(medians.values())
    if base <= 0:
        return 1.0
    return round(statistics.median(sum(r.values()) / base for r in per_run), 3)


def timings_doc(per_run: list[dict[str, float]], used: list[int], previous: dict) -> dict:
    medians = median_timings(per_run)
    return {
        "_comment": ("Per-class test seconds for shard balancing: the median, over the runs "
                     "listed, of each class's summed test durations in a run that sampled "
                     "every test once. class_scale converts them to a typical run's wall "
                     "seconds; extras are wall seconds for the streaming-ON leg and the "
                     "package tests. Regenerate with `python3 scripts/ci-test-shards.py "
                     "timings`. A stale file only unbalances the shards; it cannot drop a "
                     "class."),
        "runs": used,
        "class_scale": run_scale(per_run, medians),
        "extras": previous.get("extras", {"streaming-on": 150.0, "packages": 170.0}),
        "classes": medians,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("plan")
    p.add_argument("--enumeration", required=True, help="xcodebuild -enumerate-tests JSON")
    p.add_argument("--shards", type=int, required=True)
    p.add_argument("--timings", default=str(DEFAULT_TIMINGS))
    p.add_argument("--isolated", default=str(DEFAULT_ISOLATED))
    p.add_argument("--out", required=True)

    a = sub.add_parser("args")
    a.add_argument("--plan", required=True)
    a.add_argument("--shard", type=int, required=True)
    a.add_argument("--kind", choices=("parallel", "serial"), required=True)

    x = sub.add_parser("extra")
    x.add_argument("--plan", required=True)
    x.add_argument("--shard", type=int, required=True)
    x.add_argument("name", choices=EXTRAS)

    v = sub.add_parser("verify-shard")
    v.add_argument("--plan", required=True)
    v.add_argument("--shard", type=int, required=True)
    v.add_argument("--tests-json", required=True, help="xcresulttool get test-results tests")
    v.add_argument("--out", required=True, help="shard report JSON for verify-union")

    u = sub.add_parser("verify-union")
    u.add_argument("--plan", required=True)
    u.add_argument("reports", nargs="*")

    k = sub.add_parser("kills", help="print -only-testing args for allowance kills; "
                       "exit 0 only when every failure was one")
    k.add_argument("--tests-json", required=True)

    c = sub.add_parser("check-rerun")
    c.add_argument("--tests-json", required=True, help="the second-chance run's test tree")
    c.add_argument("ids", nargs="+", help="Bundle/Class/method identifiers that were re-run")

    t = sub.add_parser("timings")
    t.add_argument("--repo", default="ThePalaceProject/ios-core")
    t.add_argument("--workflow", default="Unit Tests")
    t.add_argument("--limit", type=int, default=20)
    t.add_argument("--out", default=str(DEFAULT_TIMINGS))

    args = ap.parse_args(argv[1:])
    try:
        if args.cmd == "plan":
            classes = classes_from_enumeration(_load(args.enumeration))
            if not classes:
                raise PlanError("enumeration produced no classes")
            timings = _load(args.timings) if os.path.exists(args.timings) else {}
            plan = build_plan(classes, timings, args.shards, read_isolated(Path(args.isolated)))
            Path(args.out).write_text(json.dumps(plan, indent=1, sort_keys=True) + "\n")
            print(f"{len(classes)} classes -> {args.shards} shards; estimated seconds "
                  f"{plan['estimated_seconds']}; {len(plan['hashed'])} placed by hash "
                  f"(no timing data); extras {plan['extras']}")
        elif args.cmd == "args":
            plan = _load(args.plan)
            for c in shard_classes(plan, args.shard, args.kind):
                print(f"-only-testing:{c}")
        elif args.cmd == "extra":
            plan = _load(args.plan)
            print("true" if plan["extras"][args.name] == args.shard else "false")
        elif args.cmd == "verify-shard":
            plan = _load(args.plan)
            report = verify_shard(plan, args.shard, _load(args.tests_json))
            Path(args.out).write_text(json.dumps(report, indent=1) + "\n")
            print(f"shard {args.shard}: {len(report['assigned'])} assigned, "
                  f"{len(report['executed'])} executed, "
                  f"{len(report['skipped_only'])} with every test skipped")
            if report["missing"] or report["foreign"]:
                print(f"::error::shard {args.shard} did not run {report['missing']}; "
                      f"ran classes assigned elsewhere: {report['foreign']}")
                return 1
        elif args.cmd == "verify-union":
            plan = _load(args.plan)
            problems = verify_union(plan, [_load(p) for p in args.reports])
            for p in problems:
                print(f"::error::{p}")
            if problems:
                return 1
            print(f"all {len(plan['classes'])} planned classes ran in exactly one of "
                  f"{plan['shards']} shards")
        elif args.cmd == "kills":
            status, ids = kill_rerun_candidates(_load(args.tests_json))
            for i in ids:
                print(f"-only-testing:{i}")
            return status
        elif args.cmd == "check-rerun":
            problems = rerun_outcome(args.ids, _load(args.tests_json))
            for p in problems:
                print(f"::error::{p}")
            return 1 if problems else 0
        elif args.cmd == "timings":
            previous = _load(args.out) if os.path.exists(args.out) else {}
            doc = regenerate_timings(args.repo, args.workflow, args.limit, previous)
            Path(args.out).write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n")
            print(f"{len(doc['classes'])} classes from {len(doc['runs'])} run(s) -> {args.out}")
    except PlanError as exc:
        print(f"::error::{exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
