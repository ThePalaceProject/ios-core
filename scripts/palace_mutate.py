#!/usr/bin/env python3
"""
palace-mutate — focused Swift mutation tester for Palace iOS.

Why this exists:
    Muter (the standard Swift mutation tester) has two failure modes against
    this project: (1) it copies the entire project to a sibling dir which
    fails on submodules / certificates, and (2) it runs the FULL test suite
    once per mutation, taking hours. This tool does neither.

How it works:
    1. Read a single source file
    2. Find mutation points via regex (comparison ops, boundaries, booleans,
       return values, conditional negation)
    3. For each mutation:
        a. Apply the edit IN PLACE
        b. Run a targeted xcodebuild test (-only-testing:<class>)
        c. Mark KILLED if any test failed, SURVIVED if all passed
        d. Revert the edit
    4. Report kill rate per mutation type and overall

Usage:
    scripts/palace_mutate.py \\
      --file Palace/Book/Models/TPPBookState.swift \\
      --tests PalaceTests/Property/PalaceCheckPropertyTests \\
      --max-mutations 20

Mutation operators:
    - cmp:    >  <-> <      >= <-> <=     == <-> !=
    - bool:   && <-> ||
    - bound:  <  ->  <=     >  ->  >=     <= ->  <      >= ->  >
    - retval: return true   <-> return false       (only inside Bool funcs)
    - cond:   if x          ->  if !x              (only top-level)
    - assign: += 1          ->  -= 1               and vice versa
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from typing import Callable, Iterable

REPO_ROOT = "/Users/mauricework/PalaceProject/ios-core"
SIM_ID = "DF4A2A27-9888-429D-A749-2E157A049A37"


# ---------------------------------------------------------------------------
# Mutation point discovery
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class Mutation:
    line: int
    col: int
    op: str           # category: cmp, bool, bound, retval, cond, assign
    original: str     # text in the source
    mutated: str      # text we replace with
    line_text: str    # original full line for context
    mutated_line: str # mutated full line


# (regex, replacement_pairs, op_name)
# Replacement pairs are tried per match.
_MUTATORS: list[tuple[re.Pattern, list[tuple[str, str]], str]] = [
    # cmp operators (whole-token, surrounded by spaces)
    (re.compile(r"(?<= )==(?= )"),  [("==", "!=")],            "cmp"),
    (re.compile(r"(?<= )!=(?= )"),  [("!=", "==")],            "cmp"),
    (re.compile(r"(?<= )>=(?= )"),  [(">=", "<="), (">=", ">")], "cmp"),
    (re.compile(r"(?<= )<=(?= )"),  [("<=", ">="), ("<=", "<")], "cmp"),
    # boolean operators
    (re.compile(r"(?<= )&&(?= )"),  [("&&", "||")],            "bool"),
    (re.compile(r"(?<= )\|\|(?= )"), [("||", "&&")],           "bool"),
    # boundary operators (single < / > — REQUIRE spaces on both sides to avoid
    # matching inside generics like `Set<TransitionPair>` or `Array<Int>`).
    (re.compile(r"(?<= )>(?= )(?![<=])"), [(">", ">="), (">", "<")], "bound"),
    (re.compile(r"(?<= )<(?= )(?![<=])"), [("<", "<="), ("<", ">")], "bound"),
    # return-value flips for Bool literals
    (re.compile(r"\breturn true\b"),  [("return true",  "return false")], "retval"),
    (re.compile(r"\breturn false\b"), [("return false", "return true")],  "retval"),
    # increment / decrement assign
    (re.compile(r"\+= 1\b"),  [("+= 1", "-= 1")], "assign"),
    (re.compile(r"-= 1\b"),   [("-= 1", "+= 1")], "assign"),
]


def discover_mutations(source: str) -> list[Mutation]:
    out: list[Mutation] = []
    lines = source.splitlines(keepends=False)
    line_starts = [0]
    pos = 0
    for ln in lines:
        pos += len(ln) + 1  # +1 for newline
        line_starts.append(pos)

    def offset_to_line(o: int) -> tuple[int, int]:
        # binary-search style; small files so linear is fine
        for i in range(len(line_starts) - 1, -1, -1):
            if line_starts[i] <= o:
                return (i + 1, o - line_starts[i] + 1)
        return (1, 1)

    for pattern, pairs, op in _MUTATORS:
        for m in pattern.finditer(source):
            for orig, repl in pairs:
                ln_no, col = offset_to_line(m.start())
                if ln_no - 1 >= len(lines):
                    continue
                line_text = lines[ln_no - 1]
                # Skip if line looks like a comment or doc
                stripped = line_text.lstrip()
                if stripped.startswith("//") or stripped.startswith("///") or stripped.startswith("*"):
                    continue
                # Build the mutated line by replacing at the column
                start_in_line = col - 1
                end_in_line = start_in_line + len(orig)
                if line_text[start_in_line:end_in_line] != orig:
                    continue  # alignment lost; skip
                mutated_line = line_text[:start_in_line] + repl + line_text[end_in_line:]
                out.append(Mutation(
                    line=ln_no,
                    col=col,
                    op=op,
                    original=orig,
                    mutated=repl,
                    line_text=line_text,
                    mutated_line=mutated_line,
                ))
    return out


# ---------------------------------------------------------------------------
# Mutation application + test execution
# ---------------------------------------------------------------------------

def apply_mutation(file_path: str, mutation: Mutation) -> None:
    with open(file_path, "r") as f:
        lines = f.readlines()
    target = lines[mutation.line - 1]
    # Recompute current matching to avoid clobbering on shifted lines
    if mutation.original not in target:
        raise RuntimeError(f"Could not find original `{mutation.original}` on line {mutation.line}")
    lines[mutation.line - 1] = target.replace(mutation.original, mutation.mutated, 1)
    with open(file_path, "w") as f:
        f.writelines(lines)


def revert_file(file_path: str, original_content: str) -> None:
    with open(file_path, "w") as f:
        f.write(original_content)


def run_targeted_tests(test_class_paths: list[str], timeout: int = 600) -> tuple[bool, str]:
    """
    Run xcodebuild test scoped to the given test classes.
    Returns (all_passed, last_lines_of_output).
    """
    only_testing_args: list[str] = []
    for path in test_class_paths:
        only_testing_args.extend(["-only-testing:" + path])
    cmd = [
        "xcodebuild",
        "-project", "Palace.xcodeproj",
        "-scheme", "Palace",
        "-destination", f"platform=iOS Simulator,id={SIM_ID}",
        "test",
    ] + only_testing_args
    try:
        result = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        return (False, f"TIMEOUT after {timeout}s")
    output = result.stdout + result.stderr
    last = "\n".join(output.splitlines()[-15:])
    passed = result.returncode == 0 and "** TEST SUCCEEDED **" in output
    return (passed, last)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="Focused Swift mutation tester for Palace iOS")
    p.add_argument("--file", required=True, help="source file to mutate (relative to repo root)")
    p.add_argument("--tests", required=True, action="append",
                   help="test class path for -only-testing (repeatable). e.g. PalaceTests/PalaceCheckPropertyTests")
    p.add_argument("--max-mutations", type=int, default=20, help="cap number of mutations")
    p.add_argument("--seed", type=int, default=0xC0FFEE, help="RNG seed for reproducible mutation order")
    p.add_argument("--dry-run", action="store_true", help="discover mutations and exit, don't run tests")
    p.add_argument("--report", default="palace-mutate-report.json", help="output JSON report")
    p.add_argument("--quiet", action="store_true", help="suppress per-mutation output")
    args = p.parse_args()

    file_path = os.path.join(REPO_ROOT, args.file)
    if not os.path.isfile(file_path):
        print(f"error: file not found: {file_path}", file=sys.stderr)
        return 2

    with open(file_path, "r") as f:
        original = f.read()

    mutations = discover_mutations(original)
    if not mutations:
        print(f"No mutation points found in {args.file}")
        print("This file has no testable mutations (no comparison/boolean/return-flip operators).")
        return 1

    # Stable randomized order so each run is reproducible but covers diverse mutations.
    rng = random.Random(args.seed)
    rng.shuffle(mutations)
    mutations = mutations[: args.max_mutations]

    print(f"palace-mutate: {args.file}")
    print(f"  total mutation points discovered: {len(discover_mutations(original))}")
    print(f"  running first {len(mutations)} (seed {args.seed}, deterministic order)")
    print(f"  targeted tests: {', '.join(args.tests)}")
    print()

    if args.dry_run:
        for i, m in enumerate(mutations, 1):
            print(f"  [{i}] line {m.line:>4}  {m.op:<6}  {m.original!r} -> {m.mutated!r}")
            print(f"        - {m.line_text}")
            print(f"        + {m.mutated_line}")
        return 0

    # Sanity-check baseline: tests pass before we mutate anything
    print("baseline: running tests with no mutations...")
    t0 = time.time()
    baseline_ok, baseline_out = run_targeted_tests(args.tests)
    t1 = time.time()
    print(f"baseline: {'PASS' if baseline_ok else 'FAIL'} in {t1-t0:.1f}s")
    if not baseline_ok:
        print("error: baseline test run failed. Cannot mutation-test against a broken suite.", file=sys.stderr)
        print("last lines:")
        print(baseline_out)
        return 2
    print()

    results: list[dict] = []
    killed = 0
    survived = 0
    errored = 0

    for i, m in enumerate(mutations, 1):
        prefix = f"[{i}/{len(mutations)}]"
        if not args.quiet:
            print(f"{prefix} line {m.line} {m.op}: {m.original!r} -> {m.mutated!r}")

        try:
            apply_mutation(file_path, m)
        except RuntimeError as e:
            print(f"  SKIP — {e}")
            results.append({"mutation": dataclasses.asdict(m), "status": "skipped", "reason": str(e)})
            errored += 1
            continue

        try:
            t0 = time.time()
            passed, last = run_targeted_tests(args.tests)
            elapsed = time.time() - t0
        finally:
            revert_file(file_path, original)

        if passed:
            status = "SURVIVED"
            survived += 1
        else:
            status = "KILLED"
            killed += 1

        if not args.quiet:
            print(f"  {status}  ({elapsed:.1f}s)")

        results.append({
            "mutation": dataclasses.asdict(m),
            "status": status.lower(),
            "elapsed_sec": round(elapsed, 1),
        })

    total_run = killed + survived
    kill_rate = (killed / total_run * 100) if total_run else 0.0

    print()
    print("=" * 60)
    print(f"palace-mutate complete")
    print(f"  killed:   {killed}")
    print(f"  survived: {survived}")
    print(f"  errored:  {errored}")
    print(f"  kill rate: {kill_rate:.1f}%")
    print("=" * 60)

    report = {
        "file": args.file,
        "tests": args.tests,
        "seed": args.seed,
        "summary": {
            "killed": killed,
            "survived": survived,
            "errored": errored,
            "kill_rate_pct": round(kill_rate, 1),
        },
        "results": results,
    }
    with open(args.report, "w") as f:
        json.dump(report, f, indent=2)
    print(f"report: {args.report}")

    # Exit non-zero if survival rate is concerningly high
    if total_run > 0 and kill_rate < 50:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
