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

# The Xcode project this script drives. Overridable via --project/--scheme/
# --repo-root so the tool can mutate code in a SIBLING checkout — notably
# ios-audiobooktoolkit, which is the audiobook playback/download critical
# path and could not be mutated at all while these were literals. That gap
# is why PP-4724 wave 3 was "verified" with hand-authored mutants, which
# inherit the author's blind spots: a reviewer's mechanically-derived
# mutant later survived a suite those hand-written ones had passed.
PROJECT = "Palace.xcodeproj"
SCHEME = "Palace"

# SIM_ID: prefer the harness-allocated UDID (HARNESS_SESSION_SIM_UDID env var)
# so parallel agents and CI can each pin a different sim. Fall back to the
# author's local sim for direct dev invocation; the script is still allowed to
# pick a different UDID via env without code changes.
SIM_ID = os.environ.get("HARNESS_SESSION_SIM_UDID", "DF4A2A27-9888-429D-A749-2E157A049A37")
DEFAULT_CACHE_DIR = os.path.join(REPO_ROOT, ".forgeos", "mutation-cache")
# Per-mutant incremental cache lives in a subdir so it never collides with the
# whole-file cache files (which sit directly in DEFAULT_CACHE_DIR).
DEFAULT_MUTANT_CACHE_DIR = os.path.join(DEFAULT_CACHE_DIR, "mutants")
CACHE_VERSION = 2  # bump when cache schema changes (v2: keys include test CONTENT)

# Coverage-gating support is OPTIONAL — palace_mutate must still run if Component
# A's mutate_coverage.py is somehow absent (fresh checkout before that file lands,
# a partial sync, etc.). Guard the import so a missing module disables gating
# rather than crashing the whole tool. _COVERAGE_AVAILABLE gates every call site.
# Ensure the scripts/ dir is importable regardless of how palace_mutate was
# invoked (cwd-relative `scripts/palace_mutate.py`, `python -m scripts.…`, etc.).
if os.path.dirname(os.path.abspath(__file__)) not in sys.path:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import mutate_coverage  # noqa: E402  (intentional optional import after sys.path setup)
    _COVERAGE_AVAILABLE = True
except ImportError:
    mutate_coverage = None  # type: ignore[assignment]
    _COVERAGE_AVAILABLE = False

# --- Tier-1 per-build waste flags ------------------------------------------
# These shave per-invocation overhead off every targeted xcodebuild test run.
# They are SAFE for a mutation loop because the tree's package state is already
# resolved and pinned, and mutation runs are inherently serial per file:
#   -disableAutomaticPackageResolution        don't re-resolve SPM graph each run
#   -onlyUsePackageVersionsFromResolvedFile    trust Package.resolved verbatim
#   -skipPackagePluginValidation               skip plugin fingerprint prompts
#   -parallel-testing-enabled NO               serial — we run ONE narrow class
#   COMPILER_INDEX_STORE_ENABLE=NO  (build setting) no index store writes
# NOTE: we deliberately do NOT add -quiet — any_tests_ran() greps the
# 'Executed N tests' summary lines, which -quiet suppresses, so adding it would
# make every mutant grade as a 0-tests-ran ERROR.
DEFAULT_FAST_FLAGS: list[str] = [
    "-disableAutomaticPackageResolution",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackagePluginValidation",
    "-parallel-testing-enabled", "NO",
    "COMPILER_INDEX_STORE_ENABLE=NO",
]

# Critical-path source roots. A SURVIVED consequential mutant on any of these
# files fails the gate (exit 1) regardless of kill rate — a surviving cmp/bool/
# bound/retval/cond flip on auth/borrow/return/download/DRM/audiobook/migration
# code is a real test-coverage hole on a path that handles user money/access.
# Mirrors the "Critical paths" list in CLAUDE.md.
CRITICAL_PATH_REGEX = re.compile(
    r"(?:^|/)Palace/(?:"
    r"Audiobooks/"
    r"|SignInLogic/"
    r"|MyBooks/Download"
    r"|MyBooks/Borrow"
    r"|MyBooks/BookReturn"
    r"|Migrations/"
    r"|Network/TPPNetworkResponder"
    r"|Network/TPPNetworkExecutor"
    r"|Packages/PalaceAuth/"
    r")"
)

# Mutation operators whose survival on a critical path is CONSEQUENTIAL. An
# `assign` flip (+= 1 -> -= 1) surviving is far less alarming than a cmp/bool/
# bound/retval/cond flip surviving on an auth decision, so the critical-path
# gate counts only these ops. (assign is intentionally excluded.)
CONSEQUENTIAL_OPS = frozenset({"cmp", "bool", "bound", "retval", "cond"})


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
    # Stripped text of the immediately preceding / following source lines.
    # These anchor the per-mutant cache key so it (a) survives edits ELSEWHERE
    # in the file and (b) disambiguates two byte-identical lines in different
    # locations. "" when at the file boundary. Defaulted so older callers /
    # tests constructing Mutation without them still work.
    context_before: str = ""
    context_after: str = ""


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

# Test-environment-detection guards (e.g.
# `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`)
# are inherently unkillable: the suite ALWAYS runs under XCTest, so flipping
# the detection's comparison produces behavior the tests cannot distinguish
# (or selects a test-only branch). Counting them deflates the kill rate of any
# file that special-cases the test runner — TPPReauthenticator.swift:66 is the
# canonical case (1 mutant, apparent 0% kill, zero real coverage signal). Same
# rationale as _LOG_LINE_PATTERN: skip the host line, mutate everything else.
_TEST_DETECTION_PATTERN = re.compile(
    r"XCTestConfigurationFilePath|"
    r"environment\[\s*[\"']XCTest|"
    r"NSClassFromString\(\s*[\"']XCTest"
)


def changed_lines(file_relpath: str, base_ref: str) -> set[int] | None:
    """Return the set of line numbers in `file_relpath` (relative to REPO_ROOT)
    that are added or modified vs `base_ref`. Returns None if git fails so the
    caller falls back to whole-file mutation.

    Uses `git diff --unified=0 <base> -- <path>` and parses the @@ hunk
    headers. Lines reported are 1-indexed against the WORKING-TREE version of
    the file (the version palace_mutate is about to mutate).

    NOTE the diff is `<base>` and NOT `<base>..HEAD`. It used to be the latter,
    which compares base against the last COMMIT while this tool mutates the
    WORKING TREE. With a dirty tree the two files have different line
    numbering, so hunk line numbers referred to one version and the mutations
    were applied to another: genuinely-changed lines were skipped, and stale
    numbers still resolved to *some* line, so the wrong lines could be mutated
    without any error. That is the state you are in whenever you iterate on a
    fix before committing it — the normal case for `--diff-only`.

    Found while mutating a toolkit change: the one behaviour-carrying line in
    the diff had four mutation points and the tool reported "0/57 mutation
    points on changed lines". When the tree is clean the two forms are
    identical, so CI behaviour is unchanged.
    """
    try:
        result = subprocess.run(
            ["git", "diff", "--unified=0", base_ref, "--", file_relpath],
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
                # Skip test-environment-detection guard lines (see
                # _TEST_DETECTION_PATTERN comment) — unkillable by design.
                if _TEST_DETECTION_PATTERN.search(line_text):
                    continue
                # Build the mutated line by replacing at the column
                start_in_line = col - 1
                end_in_line = start_in_line + len(orig)
                if line_text[start_in_line:end_in_line] != orig:
                    continue  # alignment lost; skip
                mutated_line = line_text[:start_in_line] + repl + line_text[end_in_line:]
                # Capture stripped neighbouring lines for the per-mutant cache
                # key (see Mutation.context_before/after). Boundaries -> "".
                context_before = lines[ln_no - 2].strip() if ln_no - 2 >= 0 else ""
                context_after = lines[ln_no].strip() if ln_no < len(lines) else ""
                out.append(Mutation(
                    line=ln_no,
                    col=col,
                    op=op,
                    original=orig,
                    mutated=repl,
                    line_text=line_text,
                    mutated_line=mutated_line,
                    context_before=context_before,
                    context_after=context_after,
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


def classify_test_outcome(*, timed_out: bool, tests_ran: bool, succeeded: bool) -> str:
    """Grade a targeted test run into one of three outcomes:

      - "passed"  — tests ran and all passed (the mutant SURVIVED).
      - "failed"  — tests ran and at least one failed (the mutant was KILLED).
      - "errored" — the run could not judge the mutant: it timed out (a wedged
        run, not a caught mutant) or no test executed at all (a build failure or
        misconfiguration, not a caught mutant).

    Grading a timeout or build-failure as "failed"/killed inflates the kill rate
    with mutants the suite never actually discriminated. "errored" mutants are
    counted separately AND are not cached as terminal, so they retry next run.
    """
    if timed_out or not tests_ran:
        return "errored"
    return "passed" if succeeded else "failed"


_DEFAULT_TARGETED_TEST_TIMEOUT = int(os.environ.get("PALACE_MUTATE_TEST_TIMEOUT", "1200"))


def resolve_fast_flags() -> list[str]:
    """The Tier-1 per-build waste flags to splice into the xcodebuild command.

    Pure (reads env only) so a unit test can assert the defaults and the
    override/suppress behaviour without invoking xcodebuild.

      PALACE_MUTATE_NO_FAST_FLAGS=1   -> no extra flags at all
      PALACE_MUTATE_XCB_EXTRA_FLAGS   -> space-split; REPLACES DEFAULT_FAST_FLAGS
      (unset)                          -> DEFAULT_FAST_FLAGS
    """
    if os.environ.get("PALACE_MUTATE_NO_FAST_FLAGS") == "1":
        return []
    override = os.environ.get("PALACE_MUTATE_XCB_EXTRA_FLAGS")
    if override is not None:
        return override.split()
    return list(DEFAULT_FAST_FLAGS)


def build_xcodebuild_command(test_class_paths: list[str],
                             fast_flags: list[str],
                             derived_data_args: list[str],
                             coverage_bundle_path: str | None = None) -> list[str]:
    """Assemble the full xcodebuild test argv. Pure — no subprocess, no env
    reads beyond what the caller passed in — so the flag-splicing logic is
    unit-testable. When coverage_bundle_path is set, the BASELINE coverage run
    appends `-enableCodeCoverage YES -resultBundlePath <path>`.
    """
    only_testing_args: list[str] = []
    for path in test_class_paths:
        only_testing_args.extend(["-only-testing:" + path])
    coverage_args: list[str] = []
    if coverage_bundle_path is not None:
        coverage_args = ["-enableCodeCoverage", "YES",
                         "-resultBundlePath", coverage_bundle_path]
    return [
        "xcodebuild",
        "-project", PROJECT,
        "-scheme", SCHEME,
        "-destination", f"platform=iOS Simulator,id={SIM_ID}",
        "test",
    ] + derived_data_args + fast_flags + coverage_args + only_testing_args


def run_targeted_tests(test_class_paths: list[str], timeout: int = _DEFAULT_TARGETED_TEST_TIMEOUT,
                       coverage_bundle_path: str | None = None) -> tuple[bool, str]:
    """
    Run xcodebuild test scoped to the given test classes.
    Returns (all_passed, outcome, last_lines_of_output) where outcome is
    "passed" | "failed" | "errored" (see classify_test_outcome). A timeout or a
    run that executed zero tests (build failure / misconfiguration) returns
    outcome="errored" so callers grade it as errored, not KILLED, and don't
    grade mutants as SURVIVED against an empty test set.

    Default timeout is 1200s (20 min). On a cold CI runner the first xcodebuild
    test invocation builds Palace from scratch (Adobe RMSDK, Carthage frameworks,
    SPM dependencies) which routinely takes 8-10 min before any test executes.
    Subsequent invocations within the same job reuse DerivedData and are fast.
    Override with PALACE_MUTATE_TEST_TIMEOUT env var if a faster environment
    only needs the smaller budget.
    """
    # Parallel swarm agents need to point xcodebuild at a per-worktree DerivedData
    # directory so they don't fight over the default `~/Library/Developer/Xcode/DerivedData/Palace-*`
    # build database. PALACE_MUTATE_DERIVED_DATA_PATH lets an outer harness pin a
    # private DD; unset = use default (single-agent dev flow).
    derived_data_args: list[str] = []
    dd_path = os.environ.get("PALACE_MUTATE_DERIVED_DATA_PATH")
    if dd_path:
        derived_data_args = ["-derivedDataPath", dd_path]
    cmd = build_xcodebuild_command(
        test_class_paths,
        fast_flags=resolve_fast_flags(),
        derived_data_args=derived_data_args,
        coverage_bundle_path=coverage_bundle_path,
    )
    try:
        result = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        # A wedged/hung run is NOT the mutant being caught — grade errored.
        return (False, "errored", f"TIMEOUT after {timeout}s")
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
        # No tests executed = build failure / misconfiguration, not a caught mutant.
        return (False, "errored", diagnostic)
    passed = result.returncode == 0 and "** TEST SUCCEEDED **" in output
    outcome = classify_test_outcome(timed_out=False, tests_ran=True, succeeded=passed)
    return (passed, outcome, last)


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------

def discover_test_roots(repo_root: str) -> list[str]:
    """Top-level directories holding test sources, found rather than listed.

    Hardcoding `["PalaceTests", "TenPrintCoverTests"]` looks harmless and is not:
    `--repo-root` deliberately supports mutating a SIBLING checkout, and the
    audiobook toolkit's tests live in `PalaceAudiobookToolkitTests`. Against that
    repo the hardcoded list resolves nothing, `test_fingerprint` returns None, and
    caching silently switches off for every toolkit mutation run.

    That fails closed, so it is safe — but it is a silent, permanent slowdown on
    the audiobook critical path, and it was invisible until a cache audit turned
    up five entries whose test classes could not be resolved. All five were
    toolkit runs.
    """
    try:
        return sorted(
            name for name in os.listdir(repo_root)
            if name.endswith("Tests") and os.path.isdir(os.path.join(repo_root, name))
        )
    except OSError:
        return []


def resolve_test_sources(tests: list[str], repo_root: str,
                         test_roots: list[str] | None = None) -> list[str] | None:
    """Source files declaring the XCTest classes named by `--tests`.

    Returns paths sorted, or **None** if ANY named class cannot be resolved.
    None means "cannot fingerprint the tests" and the caller MUST disable the
    cache rather than fall back — see `test_fingerprint`.

    `--tests` values are `<Bundle>/<Class>` (what `-only-testing` takes), so the
    class name is the last path component.
    """
    roots = test_roots or discover_test_roots(repo_root)
    wanted = {t.rsplit("/", 1)[-1] for t in tests if t.strip()}
    if not wanted:
        return None

    found: dict[str, str] = {}
    for root in roots:
        root_abs = os.path.join(repo_root, root)
        if not os.path.isdir(root_abs):
            continue
        for dirpath, _dirnames, filenames in os.walk(root_abs):
            for fn in filenames:
                if not fn.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    with open(path, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                for name in wanted:
                    if name in found:
                        continue
                    # `class Foo`, `final class Foo`, `open class Foo`, and the
                    # `Foo:` / `Foo {` forms. Word-bounded so `FooTests` does not
                    # match `FooTestsExtra`.
                    if re.search(rf"\bclass\s+{re.escape(name)}\s*[:{{]", text):
                        found[name] = path

    if len(found) != len(wanted):
        return None
    return sorted(found.values())


def test_fingerprint(tests: list[str], repo_root: str,
                     test_roots: list[str] | None = None) -> str | None:
    """Content hash of the test sources `--tests` selects, or None.

    THIS IS THE FIX FOR A FALSE-GREEN DEFECT, and the reason it fails closed.

    Both cache keys used to hash the test *names* and never the test *content*,
    so editing a test body did not invalidate anything. A cached verdict was
    replayed against a suite that no longer produced it. The harmless direction
    is a stale "survived" after tests are strengthened. The dangerous direction
    is a stale **"killed"** after a test is weakened or deleted while the
    production file is untouched — mutation then reports a kill it never
    measured, which is exactly the "a build failure is not a kill" class of lie
    this tool exists to avoid.

    Returning None (unresolvable class, missing file) disables caching for the
    run. Falling back to name-only hashing would silently restore the defect.

    KNOWN BOUND, stated rather than papered over: this fingerprints the files
    DECLARING the named classes. A verdict can still change from an edit to a
    shared helper those tests use — `PalaceTests/Mocks/`, fixtures, a base
    class — so those are folded in below when present. It cannot cover a change
    to a *production* file other than the one under mutation; that gap is
    inherent to per-file caching and predates this fix.
    """
    sources = resolve_test_sources(tests, repo_root, test_roots)
    if sources is None:
        return None

    # Shared test infrastructure that many suites depend on. Included because a
    # mock change really can flip a verdict; the cost is broader invalidation,
    # which is the safe direction.
    shared: list[str] = []
    for root in (test_roots or discover_test_roots(repo_root)):
        mocks = os.path.join(repo_root, root, "Mocks")
        if os.path.isdir(mocks):
            for dirpath, _d, filenames in os.walk(mocks):
                shared += [os.path.join(dirpath, fn)
                           for fn in filenames if fn.endswith(".swift")]

    h = hashlib.sha256()
    for path in sources + sorted(shared):
        try:
            with open(path, "rb") as f:
                content = f.read()
        except OSError:
            return None  # fail closed
        h.update(os.path.relpath(path, repo_root).encode())
        h.update(b"\n")
        h.update(hashlib.sha256(content).hexdigest().encode())
        h.update(b"\n")
    return h.hexdigest()[:16]


def cache_key(file_content: str, tests: list[str], seed: int, max_mutations: int,
              diff_only: bool = False, diff_base: str = "",
              tests_fingerprint: str | None = None) -> str:
    """Stable hash of the inputs that determine mutation results.

    Cache invalidates when the file changes, the test selection changes, the
    CONTENT of those tests changes, or the run parameters change. Cache survives
    unrelated edits to other files.

    --diff-only + --diff-base are part of the key so a whole-file scan and a
    diff-scoped scan don't share cache (their mutation lists differ).

    `tests_fingerprint` is required for a cacheable run; callers pass the result
    of `test_fingerprint` and skip the cache entirely when it is None.
    """
    h = hashlib.sha256()
    h.update(f"v{CACHE_VERSION}\n".encode())
    h.update(file_content.encode())
    h.update(b"\n--tests--\n")
    for t in sorted(tests):
        h.update(t.encode())
        h.update(b"\n")
    h.update(b"--tests-content--\n")
    h.update((tests_fingerprint or "UNRESOLVED").encode())
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
# Per-mutant incremental cache
# ---------------------------------------------------------------------------
#
# The whole-file cache (above) is all-or-nothing: any edit to the file
# invalidates the WHOLE report and every mutant re-runs. The per-mutant cache
# is finer: it keys each mutant on its LOCAL context (the line + its immediate
# neighbours + the operator flip + the test selection), so an edit elsewhere in
# the file reuses every untouched mutant's result and only the genuinely new /
# moved mutants re-run. The whole-file cache stays the fast path (checked
# first); this layer is the incremental fallback when the whole-file key misses.

def compute_mutant_key(tests: list[str], context_before: str, line_text: str,
                       context_after: str, original: str, mutated: str,
                       tests_fingerprint: str | None = None) -> str:
    """Stable 16-hex key for one mutant.

    Hashed over (CACHE_VERSION, sorted(tests), tests_fingerprint, context_before
    + '\\n' + line_text + '\\n' + context_after, original, mutated). Properties:
      - STABILITY: identical inputs -> identical key (so a re-run on an
        unchanged file reuses the cached status).
      - LOCALITY: edits ELSEWHERE in the file don't change a mutant's key
        (context is only the immediate neighbours, not line numbers).
      - DISAMBIGUATION: two byte-identical lines in different surrounding
        context get DIFFERENT keys, so their results never collide.
      - TEST-SENSITIVITY: a change to the TESTS changes every key, so a stored
        `killed` cannot outlive the assertion that produced it. This cache is
        the more dangerous of the two — it persists per-mutant verdicts across
        runs, so without the fingerprint a deleted test left "killed" in place
        indefinitely.
    Pure — unit-tested for stability, disambiguation and test-sensitivity.
    """
    h = hashlib.sha256()
    h.update(f"v{CACHE_VERSION}\n".encode())
    h.update(b"--tests--\n")
    for t in sorted(tests):
        h.update(t.encode())
        h.update(b"\n")
    h.update(b"--tests-content--\n")
    h.update((tests_fingerprint or "UNRESOLVED").encode())
    h.update(b"\n")
    h.update(b"--context--\n")
    h.update((context_before + "\n" + line_text + "\n" + context_after).encode())
    h.update(b"\n--ops--\n")
    h.update(original.encode())
    h.update(b"\n")
    h.update(mutated.encode())
    h.update(b"\n")
    return h.hexdigest()[:16]


def mutant_cache_path(mutant_cache_dir: str, file_relpath: str) -> str:
    """Per-mutant cache file: <mutant-cache-dir>/<file-leaf>.json — one JSON
    object per source file mapping mutant_key -> {status, elapsed_sec, stored_at}.
    """
    leaf = os.path.basename(file_relpath).replace(".swift", "")
    return os.path.join(mutant_cache_dir, f"{leaf}.json")


def mutant_cache_load(mutant_cache_dir: str, file_relpath: str) -> dict:
    """Load the per-mutant cache map for a file. Returns {} (never None) on
    absence or corruption so callers can unconditionally `.get(key)`."""
    path = mutant_cache_path(mutant_cache_dir, file_relpath)
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def mutant_cache_store(mutant_cache_dir: str, file_relpath: str, cache_map: dict) -> str:
    """Persist the per-mutant cache map atomically (tmp + rename)."""
    os.makedirs(mutant_cache_dir, exist_ok=True)
    path = mutant_cache_path(mutant_cache_dir, file_relpath)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache_map, f, indent=2)
    os.replace(tmp, path)
    return path


# ---------------------------------------------------------------------------
# Critical-path classification
# ---------------------------------------------------------------------------

def is_critical_path(file_relpath: str) -> bool:
    """True iff file_relpath is on a critical path (CRITICAL_PATH_REGEX)."""
    return bool(CRITICAL_PATH_REGEX.search(file_relpath))


def count_critical_path_survivors(results: list[dict]) -> int:
    """Count SURVIVED mutants whose op is CONSEQUENTIAL (cmp/bool/bound/retval/
    cond; assign excluded). Operates on the report `results` list so it can be
    unit-tested against a hand-built fake report dict.
    """
    count = 0
    for r in results:
        if r.get("status") != "survived":
            continue
        op = (r.get("mutation") or {}).get("op")
        if op in CONSEQUENTIAL_OPS:
            count += 1
    return count


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def build_report(*, file_relpath: str, tests: list[str], seed: int,
                 results: list[dict], planned: int, partial: bool) -> dict:
    """Assemble the report dict from the accumulated per-mutant results.

    BACKWARD COMPATIBLE: every pre-existing key
    (killed/survived/errored/kill_rate_pct/partial/completed_mutations/
    planned_mutations + the file/tests/seed/results top-levels) keeps its exact
    meaning. The coverage/suppress/critical-path work only ADDS keys:
      summary.uncovered, summary.suppressed,
      summary.is_critical_path, summary.critical_path_survivors,
      top-level coverage_gap.

    killed/survived counts derive ONLY from mutants we actually RAN — 'uncovered'
    and 'suppressed' mutants are tracked in their own counters and never inflate
    or deflate the kill rate. Pure (no I/O) so it is unit-testable.
    """
    killed = sum(1 for r in results if r.get("status") == "killed")
    survived = sum(1 for r in results if r.get("status") == "survived")
    errored = sum(1 for r in results if r.get("status") in ("skipped", "errored"))
    uncovered = sum(1 for r in results if r.get("status") == "uncovered")
    suppressed = sum(1 for r in results if r.get("status") == "suppressed")

    total = killed + survived
    rate = (killed / total * 100) if total else 0.0

    critical = is_critical_path(file_relpath)
    cp_survivors = count_critical_path_survivors(results) if critical else 0

    coverage_gap = [
        {"line": (r.get("mutation") or {}).get("line"),
         "op": (r.get("mutation") or {}).get("op")}
        for r in results if r.get("status") == "uncovered"
    ]

    return {
        "file": file_relpath,
        "tests": tests,
        "seed": seed,
        "summary": {
            "killed": killed,
            "survived": survived,
            "errored": errored,
            "kill_rate_pct": round(rate, 1),
            "partial": partial,
            "completed_mutations": total + errored,
            "planned_mutations": planned,
            # --- additive keys ---
            "uncovered": uncovered,
            "suppressed": suppressed,
            "is_critical_path": critical,
            "critical_path_survivors": cp_survivors,
        },
        "coverage_gap": coverage_gap,
        "results": results,
    }


def compute_exit_code(summary: dict) -> int:
    """Map a report summary to the process exit code.

    Exit contract (PRESERVED + extended):
      2  reserved for hard errors (handled by callers before this point)
      1  low kill rate (<50% over RUN mutants) OR — NEW — a critical-path file
         with >=1 consequential SURVIVED mutant, REGARDLESS of kill rate
      0  otherwise
    Pure so the critical-path-overrides-kill-rate rule is unit-testable.
    """
    killed = summary.get("killed", 0) or 0
    survived = summary.get("survived", 0) or 0
    total_run = killed + survived
    kill_rate = summary.get("kill_rate_pct", 0.0) or 0.0
    if summary.get("is_critical_path") and (summary.get("critical_path_survivors", 0) or 0) > 0:
        return 1
    if total_run > 0 and kill_rate < 50:
        return 1
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="Focused Swift mutation tester for Palace iOS")
    p.add_argument("--file", required=True, help="source file to mutate (relative to repo root)")
    p.add_argument("--repo-root", default=None,
                   help="repo containing --file and the Xcode project (default: this script's repo). "
                        "Use to mutate a sibling checkout such as ios-audiobooktoolkit.")
    p.add_argument("--project", default=None,
                   help="Xcode project filename (default: Palace.xcodeproj)")
    p.add_argument("--scheme", default=None,
                   help="scheme to test (default: Palace)")
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
    p.add_argument("--no-coverage-gate", action="store_true",
                   help="disable coverage-gating: mutate every discovered line even if no "
                        "test executes it (today's pre-coverage behavior). Default: gating ON "
                        "— mutations on UNCOVERED lines are recorded 'uncovered' and never run.")
    p.add_argument("--no-test-selection", action="store_true",
                   help="disable per-line test selection: always run the full --tests class "
                        "for every mutant instead of the narrowed selectors that cover its line.")
    p.add_argument("--mutant-cache-dir", default=DEFAULT_MUTANT_CACHE_DIR,
                   help=f"per-mutant incremental cache dir (default: {DEFAULT_MUTANT_CACHE_DIR})")
    args = p.parse_args()

    # Retarget at a different checkout/project before anything reads these.
    # Defaults keep existing invocations byte-identical.
    global REPO_ROOT, PROJECT, SCHEME
    if args.repo_root:
        REPO_ROOT = os.path.abspath(args.repo_root)
    if args.project:
        PROJECT = args.project
    if args.scheme:
        SCHEME = args.scheme

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
    # Fingerprint the CONTENT of the selected tests. None => unresolvable =>
    # caching is disabled for this run rather than falling back to a name-only
    # key, which is what let a stale verdict outlive the assertion that produced
    # it. Fail closed: a slower honest run beats a fast wrong one.
    # REPO_ROOT, not args.repo_root: the flag defaults to None and the module
    # global is what the override above resolves it into, so reading the raw arg
    # crashes every default invocation.
    fingerprint = test_fingerprint(args.tests, REPO_ROOT)
    cache_disabled = args.no_cache or fingerprint is None
    if fingerprint is None and not args.no_cache:
        print("  cache: DISABLED — could not resolve every --tests class to a source "
              "file, so test content cannot be fingerprinted and a cached verdict "
              "could not be trusted. Running in full.")

    key = cache_key(original, args.tests, args.seed, args.max_mutations,
                    diff_only=args.diff_only, diff_base=args.diff_base,
                    tests_fingerprint=fingerprint)
    if not cache_disabled and not args.dry_run:
        cached = cache_load(args.cache_dir, args.file, key)
        if cached:
            report = cached["report"]
            summary = report.get("summary", {})
            print(f"palace-mutate: {args.file}  [CACHED]")
            print(f"  cache key: {key} (stored {cached.get('stored_at', '?')})")
            # PRESERVE the verbatim summary line verify-pr.sh greps for, in the
            # cached branch too.
            print(f"  killed: {summary.get('killed')}  survived: {summary.get('survived')}  "
                  f"errored: {summary.get('errored')}  kill rate: {summary.get('kill_rate_pct')}%")
            with open(args.report, "w") as f:
                json.dump(report, f, indent=2)
            print(f"  report: {args.report}")
            return compute_exit_code(summary)

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

    # Suppress-list: load human-curated equivalent-mutant suppressions ONCE.
    # Mutants matching is_suppressed are recorded 'suppressed', never run, and
    # never counted as survived/killed. Absent / disabled coverage module -> [].
    suppressions: list = []
    if _COVERAGE_AVAILABLE:
        try:
            suppressions = mutate_coverage.load_suppressions(REPO_ROOT, args.file)
        except Exception as e:  # defensive: a broken module must not crash the run
            print(f"suppressions load failed (non-fatal): {e}", file=sys.stderr)

    # Sanity-check baseline: tests pass before we mutate anything. The baseline
    # additionally runs with COVERAGE ON (into a temp .xcresult bundle) so we can
    # gate mutations to lines tests actually execute and (best-effort) narrow the
    # test selection per line. The coverage bundle lives in a tmpdir we clean up.
    import tempfile  # local import: only the baseline path needs it
    coverage_enabled = _COVERAGE_AVAILABLE and not args.no_coverage_gate
    cov_tmpdir = None
    coverage_bundle = None
    if coverage_enabled or (_COVERAGE_AVAILABLE and not args.no_test_selection):
        cov_tmpdir = tempfile.mkdtemp(prefix="palace-mutate-cov-")
        # xcodebuild REQUIRES the resultBundlePath to NOT already exist.
        coverage_bundle = os.path.join(cov_tmpdir, "baseline.xcresult")

    print("baseline: running tests with no mutations...")
    t0 = time.time()
    baseline_ok, _, baseline_out = run_targeted_tests(args.tests, coverage_bundle_path=coverage_bundle)
    t1 = time.time()
    baseline_elapsed = t1 - t0
    # Bound each per-mutant run at 3x the baseline (baseline includes the cold
    # build, so this is a generous ceiling for a warm incremental run), floored
    # at 180s and never exceeding the default ceiling. A wedged mutant is cut
    # here and graded errored, instead of burning the full 20-min default.
    per_mutant_timeout = min(
        _DEFAULT_TARGETED_TEST_TIMEOUT,
        max(180, int(3 * baseline_elapsed)),
    )
    print(f"baseline: {'PASS' if baseline_ok else 'FAIL'} in {baseline_elapsed:.1f}s "
          f"(per-mutant timeout: {per_mutant_timeout}s)")
    if not baseline_ok:
        print("error: baseline test run failed — NOTHING WAS MEASURED.", file=sys.stderr)
        print("error: this is 'could not measure', NOT 'measured clean'. No mutant ran, "
              "so no conclusion about test strength is available from this run.", file=sys.stderr)
        print("error: a failing baseline is usually the environment rather than the code — "
              "a stale DerivedData precompiled header from a parallel build is the common "
              "cause. Retry with an isolated PALACE_MUTATE_DERIVED_DATA_PATH before "
              "believing the suite is broken.", file=sys.stderr)
        print("last lines:")
        print(baseline_out)
        # Overwrite any report from a PREVIOUS run. Leaving a stale one on disk is
        # the silent-success shape: the process exits 2, but anything that reads
        # the artifact instead of the exit code sees the last successful run's
        # numbers and believes them. `summary` is deliberately OMITTED rather than
        # zeroed — a consumer reading `summary.killed` should fail loudly, not read
        # 0 killed / 0 survived as a clean sheet.
        try:
            with open(args.report, "w") as f:
                json.dump({
                    "file": args.file,
                    "tests": args.tests,
                    "measured": False,
                    "error": "baseline-failed",
                    "detail": "The unmutated suite did not pass, so no mutant was run. "
                              "This report records the ABSENCE of a measurement.",
                }, f, indent=2)
            print(f"  report: {args.report} (records NO measurement)")
        except OSError as exc:
            print(f"error: could not write the no-measurement report: {exc}", file=sys.stderr)
        if cov_tmpdir:
            shutil.rmtree(cov_tmpdir, ignore_errors=True)
        return 2
    print()

    # Coverage gating: intersect discovered mutation lines with the lines tests
    # actually executed. covered_lines() returns None on ANY failure -> gating
    # DISABLED, behavior exactly as today (mutate all lines). This graceful
    # degradation is the safety property that makes coverage-gating low-risk.
    covered: set[int] | None = None
    if coverage_enabled and coverage_bundle:
        try:
            covered = mutate_coverage.covered_lines(coverage_bundle, args.file, REPO_ROOT)
        except Exception as e:
            print(f"coverage extraction failed (non-fatal); gating disabled: {e}", file=sys.stderr)
            covered = None
        if covered is None:
            print("coverage: unknown (None) — gating DISABLED, mutating every line")
        else:
            print(f"coverage: {len(covered)} executed line(s) recorded for gating")

    # Per-line test selection: best-effort map line -> [Class/method selectors].
    # None / missing line -> fall back to the full --tests class for that mutant.
    line_to_tests: dict | None = None
    if _COVERAGE_AVAILABLE and not args.no_test_selection and coverage_bundle:
        covered_mutation_lines = {m.line for m in mutations}
        try:
            line_to_tests = mutate_coverage.tests_for_lines(
                coverage_bundle, args.file, covered_mutation_lines, REPO_ROOT)
        except Exception as e:
            print(f"test-selection attribution failed (non-fatal); using full class: {e}", file=sys.stderr)
            line_to_tests = None

    if cov_tmpdir:
        shutil.rmtree(cov_tmpdir, ignore_errors=True)

    # Per-mutant incremental cache (in ADDITION to the whole-file cache, which
    # already missed if we got here). Reuse cached statuses for mutants whose
    # local context is unchanged; only execute misses; persist atomically.
    mutant_cache = {} if cache_disabled else mutant_cache_load(args.mutant_cache_dir, args.file)
    mutant_cache_dirty = False

    results: list[dict] = []

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

    def _flush(partial: bool) -> dict:
        report = build_report(file_relpath=args.file, tests=args.tests, seed=args.seed,
                              results=results, planned=len(mutations), partial=partial)
        _write_report_atomic(report)
        return report

    for i, m in enumerate(mutations, 1):
        prefix = f"[{i}/{len(mutations)}]"
        if not args.quiet:
            print(f"{prefix} line {m.line} {m.op}: {m.original!r} -> {m.mutated!r}")

        # SUPPRESSED: human-reviewed equivalent mutant. Record + skip; not run,
        # not counted as survived/killed.
        if _COVERAGE_AVAILABLE and suppressions and mutate_coverage.is_suppressed(
                suppressions, m.line_text, m.original, m.mutated):
            if not args.quiet:
                print("  SUPPRESSED (equivalent mutant)")
            results.append({"mutation": dataclasses.asdict(m), "status": "suppressed"})
            _flush(partial=True)
            continue

        # UNCOVERED: no test executes this line. It is a guaranteed survivor;
        # running it wastes an xcodebuild cycle and would deflate the kill rate.
        # Record it as a free coverage-gap signal and never run it.
        if covered is not None and m.line not in covered:
            if not args.quiet:
                print("  UNCOVERED (no test executes this line)")
            results.append({"mutation": dataclasses.asdict(m), "status": "uncovered"})
            _flush(partial=True)
            continue

        # PER-MUTANT CACHE: reuse a prior status for an unchanged-context mutant.
        mkey = compute_mutant_key(args.tests, m.context_before, m.line_text,
                                  m.context_after, m.original, m.mutated)
        if not cache_disabled and mkey in mutant_cache:
            cached_entry = mutant_cache[mkey]
            cached_status = cached_entry.get("status")
            if cached_status in ("killed", "survived"):
                if not args.quiet:
                    print(f"  {cached_status.upper()} (cached)")
                results.append({
                    "mutation": dataclasses.asdict(m),
                    "status": cached_status,
                    "elapsed_sec": cached_entry.get("elapsed_sec", 0.0),
                    "from_cache": True,
                })
                _flush(partial=True)
                continue

        # TEST SELECTION: run only the selectors that cover this line, if known.
        selected_tests = args.tests
        if line_to_tests is not None:
            sel = line_to_tests.get(m.line)
            if sel:
                selected_tests = sel

        try:
            apply_mutation(file_path, m)
        except RuntimeError as e:
            print(f"  SKIP — {e}")
            results.append({"mutation": dataclasses.asdict(m), "status": "skipped", "reason": str(e)})
            _flush(partial=True)
            continue

        try:
            t0 = time.time()
            passed, outcome, last = run_targeted_tests(selected_tests, timeout=per_mutant_timeout)
            elapsed = time.time() - t0
        finally:
            revert_file(file_path, original)

        # outcome: passed -> survived, failed -> killed, errored -> errored
        # (timeout / build-failure: the suite never judged the mutant).
        if outcome == "errored":
            status_l = "errored"
            display = "ERRORED"
        else:
            status_l = "survived" if passed else "killed"
            display = status_l.upper()
        if not args.quiet:
            note = ""
            if outcome == "errored":
                note = " — timeout/build-failure; not counted as killed"
            print(f"  {display}  ({elapsed:.1f}s){note}")

        result_entry = {
            "mutation": dataclasses.asdict(m),
            "status": status_l,
            "elapsed_sec": round(elapsed, 1),
        }
        if outcome == "errored":
            result_entry["reason"] = last
        results.append(result_entry)

        # Update the per-mutant cache only for TERMINAL outcomes (killed/survived).
        # An errored mutant (timeout/build-failure) is deliberately NOT cached, so
        # it is retried on the next run instead of frozen as a false result.
        if not cache_disabled and status_l in ("killed", "survived"):
            mutant_cache[mkey] = {
                "status": status_l,
                "elapsed_sec": round(elapsed, 1),
                "stored_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            mutant_cache_dirty = True
            try:
                mutant_cache_store(args.mutant_cache_dir, args.file, mutant_cache)
            except OSError as e:
                print(f"per-mutant cache write failed (non-fatal): {e}", file=sys.stderr)

        # Flush AFTER every mutation. If the process is killed by a CI
        # timeout (the original symptom) or Ctrl-C, the report on disk
        # already reflects everything completed so far — including a
        # partial=True flag the consumer can use to distinguish "ran to
        # completion" from "ran but got cut off."
        _flush(partial=True)

    # Final report flips partial=False since we made it through the loop.
    report = _flush(partial=False)
    summary = report["summary"]

    print()
    print("=" * 60)
    print(f"palace-mutate complete")
    print(f"  killed:   {summary['killed']}")
    print(f"  survived: {summary['survived']}")
    print(f"  errored:  {summary['errored']}")
    print(f"  uncovered: {summary['uncovered']}")
    print(f"  suppressed: {summary['suppressed']}")
    if summary["is_critical_path"]:
        print(f"  critical-path survivors: {summary['critical_path_survivors']}")
    # PRESERVE the verbatim summary line verify-pr.sh greps for.
    print(f"  killed: {summary['killed']}  survived: {summary['survived']}  "
          f"errored: {summary['errored']}  kill rate: {summary['kill_rate_pct']}%")
    print("=" * 60)
    print(f"report: {args.report}")

    if not cache_disabled:
        try:
            stored = cache_store(args.cache_dir, args.file, key, report)
            print(f"cached: {os.path.relpath(stored, REPO_ROOT)}")
        except OSError as e:
            print(f"cache write failed (non-fatal): {e}", file=sys.stderr)
        if mutant_cache_dirty:
            try:
                mutant_cache_store(args.mutant_cache_dir, args.file, mutant_cache)
            except OSError as e:
                print(f"per-mutant cache write failed (non-fatal): {e}", file=sys.stderr)

    if summary["is_critical_path"] and summary["critical_path_survivors"] > 0:
        print("GATE FAIL: critical-path file has surviving consequential mutant(s).", file=sys.stderr)
    return compute_exit_code(summary)


if __name__ == "__main__":
    sys.exit(main())
