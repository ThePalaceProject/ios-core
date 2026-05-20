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
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from typing import Callable, Iterable

# Derive REPO_ROOT from this script's location (scripts/palace_mutate.py) so the
# tool works on any host — local dev, GitHub Actions runners, contributors'
# clones. The previous absolute path silently broke CI: palace_mutate.py would
# try to read files at `/Users/mauricework/...`, fail with exit 2, and verify-pr's
# `|| true` masked the failure so the mutation gate "passed" with zero reports.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SIM_ID: prefer the harness-allocated UDID (HARNESS_SESSION_SIM_UDID env var)
# so parallel agents and CI can each pin a different sim. Fall back to the
# author's local sim for direct dev invocation; the script is still allowed to
# pick a different UDID via env without code changes.
SIM_ID = os.environ.get("HARNESS_SESSION_SIM_UDID", "DF4A2A27-9888-429D-A749-2E157A049A37")
DEFAULT_CACHE_DIR = os.path.join(REPO_ROOT, ".forgeos", "mutation-cache")
CACHE_VERSION = 1  # bump when cache schema changes


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


# Patterns matching lines that are PURE diagnostic side effects — mutating
# inside them flips a string interpolation but doesn't change runtime
# behavior. Tests cannot kill these mutants no matter what they assert,
# so including them in the count silently DEFLATES every file's kill rate
# in proportion to how diagnostics-heavy the source is. AudiobookLoader.swift
# is the canonical case: 9 discovered mutants, 7 inside `Log.info`/`Log.debug`
# calls — apparent 0% kill rate, actual production-behavior coverage on
# the 2 real branches is meaningfully better.
#
# We skip mutations whose entire host line is one of these calls. Any
# branch INSIDE a guard/if that happens to log gets mutated normally;
# only the log-call line itself is exempt.
_LOG_LINE_PATTERN = re.compile(
    r"^\s*(?:Log\.(?:trace|debug|info|warn|error)|"
    r"print|NSLog|os_log|Logger\.\w+|os\.Logger\(\)\.\w+)\b"
)


def changed_lines(file_relpath: str, base_ref: str) -> set[int] | None:
    """Return the set of line numbers in `file_relpath` (relative to REPO_ROOT)
    that are added or modified vs `base_ref`. Returns None if git fails so the
    caller falls back to whole-file mutation.

    Uses `git diff --unified=0 <base>..HEAD -- <path>` and parses the @@ hunk
    headers. Lines reported are 1-indexed against the WORKING-TREE version of
    the file (the version palace_mutate is about to mutate).
    """
    try:
        result = subprocess.run(
            ["git", "diff", "--unified=0", f"{base_ref}..HEAD", "--", file_relpath],
            cwd=REPO_ROOT, capture_output=True, text=True, check=False,
        )
    except OSError as e:
        print(f"--diff-only: git diff failed ({e}); falling back to whole-file scan", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(f"--diff-only: git diff exit {result.returncode}; falling back to whole-file scan", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return None

    lines: set[int] = set()
    # Hunk headers look like: @@ -old_start,old_count +new_start,new_count @@
    # We want new_start..new_start+new_count-1. If count is omitted, it's 1.
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    for ln in result.stdout.splitlines():
        m = hunk_re.match(ln)
        if not m:
            continue
        new_start = int(m.group(1))
        new_count = int(m.group(2)) if m.group(2) is not None else 1
        if new_count == 0:
            # Pure deletion; no working-tree lines to mutate. Skip.
            continue
        for i in range(new_start, new_start + new_count):
            lines.add(i)
    return lines


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
                # Skip mutations whose entire host line is a diagnostic
                # call (see _LOG_LINE_PATTERN comment). Those mutants flip
                # string interpolations without changing observable
                # behavior — they are inherently unkillable.
                if _LOG_LINE_PATTERN.match(line_text):
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


def any_tests_ran(output: str) -> bool:
    """
    True if xcodebuild's output contains at least one `Executed N tests` line
    with N >= 1. A misconfigured `--tests` arg (e.g. a directory instead of an
    XCTestCase class name) silently matches no class and produces only zero-
    count summaries, while still printing `** TEST SUCCEEDED **`. Without this
    check the caller would grade every mutant as SURVIVED.
    """
    return bool(re.search(r"Executed [1-9]\d* test", output))


_DEFAULT_TARGETED_TEST_TIMEOUT = int(os.environ.get("PALACE_MUTATE_TEST_TIMEOUT", "1200"))


def run_targeted_tests(test_class_paths: list[str], timeout: int = _DEFAULT_TARGETED_TEST_TIMEOUT) -> tuple[bool, str]:
    """
    Run xcodebuild test scoped to the given test classes.
    Returns (all_passed, last_lines_of_output).
    Returns (False, "ERROR: ...") if the configuration ran zero tests — that
    is treated as a misconfiguration, not a passing run, so callers don't
    grade mutants as SURVIVED against an empty test set.

    Default timeout is 1200s (20 min). On a cold CI runner the first xcodebuild
    test invocation builds Palace from scratch (Adobe RMSDK, Carthage frameworks,
    SPM dependencies) which routinely takes 8-10 min before any test executes.
    Subsequent invocations within the same job reuse DerivedData and are fast.
    Override with PALACE_MUTATE_TEST_TIMEOUT env var if a faster environment
    only needs the smaller budget.
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
    if not any_tests_ran(output):
        joined = ", ".join(test_class_paths)
        # Surface the LAST 40 lines of xcodebuild output alongside the
        # synthetic error. Without this, "0 tests executed" looked like a
        # misconfigured --tests arg even when the real cause was a CI-only
        # build error (Swift macro failure, signing issue, etc.) that the
        # local resolver couldn't detect. The synthetic message stays as
        # the headline; the xcodebuild tail is the diagnostic.
        xcb_tail = "\n".join(output.splitlines()[-40:])
        diagnostic = (
            f"ERROR: 0 tests executed for {joined} — likely a misconfigured "
            f"--tests arg (directory instead of XCTestCase class name) OR a "
            f"build failure that produced no test execution.\n"
            f"---- last 40 lines of xcodebuild output ----\n{xcb_tail}\n"
            f"---- end xcodebuild output ----"
        )
        return (False, diagnostic)
    passed = result.returncode == 0 and "** TEST SUCCEEDED **" in output
    return (passed, last)


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

def cache_key(file_content: str, tests: list[str], seed: int, max_mutations: int,
              diff_only: bool = False, diff_base: str = "") -> str:
    """Stable hash of the inputs that determine mutation results.

    Cache invalidates when the file changes, the test selection changes, or
    the run parameters change. Cache survives unrelated edits to other files.

    --diff-only + --diff-base are part of the key so a whole-file scan and a
    diff-scoped scan don't share cache (their mutation lists differ).
    """
    h = hashlib.sha256()
    h.update(f"v{CACHE_VERSION}\n".encode())
    h.update(file_content.encode())
    h.update(b"\n--tests--\n")
    for t in sorted(tests):
        h.update(t.encode())
        h.update(b"\n")
    h.update(f"--seed={seed}\n--max={max_mutations}\n".encode())
    if diff_only:
        h.update(f"--diff-only={diff_base}\n".encode())
    return h.hexdigest()[:16]


def cache_path(cache_dir: str, file_relpath: str, key: str) -> str:
    """Cache file path: <cache-dir>/<file-leaf>.<key>.json.

    Including the file leaf in the path makes it easy to find/inspect cached
    runs by eye; the hash makes cache lookup O(1) by exact match.
    """
    leaf = os.path.basename(file_relpath).replace(".swift", "")
    return os.path.join(cache_dir, f"{leaf}.{key}.json")


def cache_load(cache_dir: str, file_relpath: str, key: str) -> dict | None:
    path = cache_path(cache_dir, file_relpath, key)
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def cache_store(cache_dir: str, file_relpath: str, key: str, report: dict) -> str:
    os.makedirs(cache_dir, exist_ok=True)
    path = cache_path(cache_dir, file_relpath, key)
    payload = {
        "cache_version": CACHE_VERSION,
        "cache_key": key,
        "stored_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "report": report,
    }
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
    return path


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
    p.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR,
                   help=f"mutation result cache dir (default: {DEFAULT_CACHE_DIR})")
    p.add_argument("--no-cache", action="store_true",
                   help="ignore cached results and re-run mutations")
    p.add_argument("--diff-only", action="store_true",
                   help="restrict mutations to lines changed vs --diff-base (default: "
                        "origin/develop). Pre-existing untouched code is left unscanned, "
                        "so kill rate reflects the test coverage of *this PR's* changes — "
                        "not the whole file's historical coverage.")
    p.add_argument("--diff-base", default="origin/develop",
                   help="git ref to diff against when --diff-only is set (default: origin/develop)")
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

    if args.diff_only:
        # Restrict to mutations on lines this PR changes. Falls back to whole-file
        # if git diff fails (e.g. base ref unknown). Empty diff -> exit 0 with a
        # message: no diff-scoped mutations is a legitimate state (e.g. PR only
        # changed test files; the production file is untouched on this branch).
        scope = changed_lines(args.file, args.diff_base)
        if scope is None:
            print(f"--diff-only: falling back to whole-file scan ({len(mutations)} mutations)")
        else:
            before = len(mutations)
            mutations = [m for m in mutations if m.line in scope]
            print(f"--diff-only vs {args.diff_base}: {len(scope)} changed line(s) in {args.file}; "
                  f"{len(mutations)}/{before} mutation point(s) on changed lines")
            if not mutations:
                print("No mutation points fall on changed lines — nothing to mutate.")
                return 0

    # Cache check: if we've already mutation-tested this exact file content
    # against this exact test selection, we can skip the (slow) re-run.
    key = cache_key(original, args.tests, args.seed, args.max_mutations,
                    diff_only=args.diff_only, diff_base=args.diff_base)
    if not args.no_cache and not args.dry_run:
        cached = cache_load(args.cache_dir, args.file, key)
        if cached:
            report = cached["report"]
            summary = report.get("summary", {})
            print(f"palace-mutate: {args.file}  [CACHED]")
            print(f"  cache key: {key} (stored {cached.get('stored_at', '?')})")
            print(f"  killed: {summary.get('killed')}  survived: {summary.get('survived')}  "
                  f"errored: {summary.get('errored')}  kill rate: {summary.get('kill_rate_pct')}%")
            with open(args.report, "w") as f:
                json.dump(report, f, indent=2)
            print(f"  report: {args.report}")
            kill_rate = summary.get("kill_rate_pct", 0.0) or 0.0
            total_run = (summary.get("killed", 0) or 0) + (summary.get("survived", 0) or 0)
            return 1 if total_run > 0 and kill_rate < 50 else 0

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

    def _build_report(partial: bool) -> dict:
        total = killed + survived
        rate = (killed / total * 100) if total else 0.0
        return {
            "file": args.file,
            "tests": args.tests,
            "seed": args.seed,
            "summary": {
                "killed": killed,
                "survived": survived,
                "errored": errored,
                "kill_rate_pct": round(rate, 1),
                "partial": partial,
                "completed_mutations": total + errored,
                "planned_mutations": len(mutations),
            },
            "results": results,
        }

    def _write_report_atomic(report: dict) -> None:
        # Write to <path>.tmp then rename. POSIX rename is atomic on the same
        # filesystem, so a reader (CI parse step, dev IDE) never sees a
        # half-written file even if the process is killed mid-write. Defends
        # against the "CI workflow comment says no data" symptom that fired
        # when an external timeout cut palace_mutate mid-run before the
        # tail-end single write.
        tmp_path = args.report + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(report, f, indent=2)
        os.replace(tmp_path, args.report)

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
            _write_report_atomic(_build_report(partial=True))
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

        # Flush AFTER every mutation. If the process is killed by a CI
        # timeout (the original symptom) or Ctrl-C, the report on disk
        # already reflects everything completed so far — including a
        # partial=True flag the consumer can use to distinguish "ran to
        # completion" from "ran but got cut off."
        _write_report_atomic(_build_report(partial=True))

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

    # Final report flips partial=False since we made it through the loop.
    report = _build_report(partial=False)
    _write_report_atomic(report)
    print(f"report: {args.report}")

    if not args.no_cache:
        try:
            stored = cache_store(args.cache_dir, args.file, key, report)
            print(f"cached: {os.path.relpath(stored, REPO_ROOT)}")
        except OSError as e:
            print(f"cache write failed (non-fatal): {e}", file=sys.stderr)

    # Exit non-zero if survival rate is concerningly high
    if total_run > 0 and kill_rate < 50:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
