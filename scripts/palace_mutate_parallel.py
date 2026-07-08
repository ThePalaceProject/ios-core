#!/usr/bin/env python3
"""
palace-mutate-parallel — file-level worker-pool orchestrator over palace_mutate.py.

Why this exists:
    palace_mutate.py mutation-tests ONE file at a time, serially. On a PR that
    touches several production files the per-file cold-build cost dominates. This
    orchestrator fans the files out across a small worker pool — each worker owns
    one git worktree + one pool simulator + one private DerivedData path — so
    several files mutate concurrently while DerivedData stays warm WITHIN each
    file (file-level fan-out, never mutant-level batching).

CRITICAL design constraints (all enforced/tested):
    - FILE-LEVEL fan-out only. We NEVER batch multiple mutants into one build:
      that would mask a surviving mutant behind a killed one (the killed mutant
      fails the build/test, the whole batch grades as KILLED, the real survivor
      is invisible). Each palace_mutate.py invocation owns one file and reverts
      between mutants exactly as it does today.
    - ISOLATION per worker: a dedicated git worktree (so concurrent in-place
      mutate+revert edits never collide), a dedicated pool sim UDID (so two
      xcodebuild runs don't fight over the same booted device), and a dedicated
      PALACE_MUTATE_DERIVED_DATA_PATH (so build databases don't corrupt each
      other).
    - COST GATE: if there are fewer than 2 files OR --workers 1, we run SERIALLY
      in the MAIN tree (no worktree, no cold build) — a small PR must not get
      slower because of orchestration overhead. The decision is logged, never
      silent.

The pure orchestration logic (worker-count math, serial/parallel decision, sim
round-robin, report aggregation) is factored into module-level functions so the
unit tests exercise it without creating real worktrees or invoking xcodebuild.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

# REPO_ROOT derivation mirrors palace_mutate.py: derive from this file's location
# so the tool works on any host (local dev, CI runners, contributor clones).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Pool simulator UDIDs. One worker pins one UDID via round-robin so concurrent
# xcodebuild runs never fight over a booted device. These are the harness's
# allocated iPhone 16 Pro sims for this project.
DEFAULT_SIM_UDIDS: list[str] = [
    "141BD227-6E9A-4409-8D99-2D4FE818238D",
    "BFB9B169-4E06-4087-BD6B-F54BB56EAA6B",
    "6C6BD82F-D659-4F77-8B9E-C2CBDF3A6CF8",
]

DEFAULT_BASE_REF = "origin/develop"
DEFAULT_REPORT_DIR = os.path.join(REPO_ROOT, ".forgeos", "mutation-reports")
PALACE_MUTATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "palace_mutate.py")


def log(msg: str) -> None:
    """Single logging seam so the serial/parallel decision and per-worker
    progress are always visible (no silent caps). Prefixed for grep-ability."""
    print(f"[palace-mutate-parallel] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Pure orchestration logic (unit-tested without worktrees / xcodebuild)
# ---------------------------------------------------------------------------

def compute_worker_count(num_files: int, num_sims: int, ncpu: int,
                         requested: int | None = None) -> int:
    """Decide how many workers to run.

    Default (requested is None): min(#sims, max(1, ncpu//4), #files). The
    ncpu//4 term keeps a single mutation worker from starving the machine —
    each xcodebuild test build is itself massively parallel, so 1 worker per
    4 logical cores is the empirical sweet spot. We never spawn more workers
    than there are files (idle workers waste a sim claim) or sims (two workers
    on one sim serialize anyway and corrupt each other's device state).

    An explicit `requested` is honored but still clamped to [1, #files] — you
    can't usefully run more workers than files, and 0/negative is meaningless.
    With zero files the answer is 0 (nothing to do).
    """
    if num_files <= 0:
        return 0
    if requested is not None:
        # Honor the explicit ask, clamped to a sane range.
        return max(1, min(requested, num_files))
    cpu_term = max(1, ncpu // 4)
    sim_term = max(1, num_sims)
    return max(1, min(sim_term, cpu_term, num_files))


def should_run_parallel(num_files: int, worker_count: int) -> bool:
    """COST GATE. Parallel only pays off when there are >=2 files AND we'd
    actually run >=2 workers. Otherwise the worktree + cold-build setup is pure
    overhead and we should run serially in the main tree.
    """
    return num_files >= 2 and worker_count >= 2


def assign_sims(num_workers: int, sims: list[str]) -> list[str]:
    """Round-robin assign a sim UDID to each worker index. With more workers
    than sims (shouldn't happen given compute_worker_count clamps to #sims, but
    defended anyway), workers wrap around and share — they will serialize on the
    shared device, which is correct-but-slow rather than broken.
    """
    if not sims:
        return []
    return [sims[i % len(sims)] for i in range(num_workers)]


def changed_prod_swift_files(base_ref: str, repo_root: str = REPO_ROOT,
                             runner=None) -> list[str]:
    """Return production Swift files changed vs base_ref (relative to repo root).

    Production = under Palace/ and NOT a test file (PalaceTests/ excluded, and
    files whose name ends in Tests.swift excluded). `runner` is injectable so
    the unit tests can feed synthetic `git diff` output without a real repo.
    """
    if runner is None:
        runner = lambda argv: subprocess.run(  # noqa: E731
            argv, cwd=repo_root, capture_output=True, text=True, check=False)
    result = runner(["git", "diff", "--name-only", f"{base_ref}...HEAD"])
    if result.returncode != 0:
        log(f"--changed: git diff exit {result.returncode}; no files resolved")
        log(result.stderr.strip())
        return []
    return filter_prod_swift(result.stdout.splitlines())


def filter_prod_swift(paths) -> list[str]:
    """Keep only production Swift sources from a list of repo-relative paths.

    Excludes: non-Swift, anything under PalaceTests/, and any *Tests.swift file
    (a test that happens to live under Palace/). Pure — unit-tested directly.
    """
    out: list[str] = []
    for raw in paths:
        path = raw.strip()
        if not path or not path.endswith(".swift"):
            continue
        if path.startswith("PalaceTests/") or "/PalaceTests/" in path:
            continue
        leaf = os.path.basename(path)
        if leaf.endswith("Tests.swift"):
            continue
        if not (path.startswith("Palace/") or "/Palace/" in path):
            continue
        out.append(path)
    return out


@dataclass
class FileResult:
    """Outcome of mutation-testing one file."""
    file: str
    exit_code: int
    report: dict | None = None  # parsed palace_mutate JSON report, if any
    error: str = ""             # populated when the report couldn't be produced


def aggregate_reports(results: list[FileResult]) -> dict:
    """Combine per-file FileResults into one summary.

    Sums killed/survived/uncovered/suppressed/errored across files, computes the
    overall kill rate over RUN mutants only (mirrors palace_mutate: uncovered and
    suppressed never inflate/deflate it), records per-file kill rates, and
    decides overall pass/fail.

    OVERALL FAIL when ANY file failed its own gate (non-zero palace_mutate exit),
    which already encodes both the <50% kill-rate rule and the critical-path
    consequential-survivor override. We additionally surface the total
    critical_path_survivors so a caller can see the override reason at a glance.

    Pure (no I/O) so it is unit-testable against synthetic report dicts.
    """
    total = {
        "killed": 0, "survived": 0, "errored": 0,
        "uncovered": 0, "suppressed": 0, "critical_path_survivors": 0,
    }
    per_file: list[dict] = []
    any_failed = False
    any_critical_survivor = False

    for r in results:
        if r.exit_code != 0:
            any_failed = True
        summary = (r.report or {}).get("summary", {}) if r.report else {}
        for k in ("killed", "survived", "errored", "uncovered", "suppressed",
                  "critical_path_survivors"):
            total[k] += int(summary.get(k, 0) or 0)
        cps = int(summary.get("critical_path_survivors", 0) or 0)
        if summary.get("is_critical_path") and cps > 0:
            any_critical_survivor = True
        run = int(summary.get("killed", 0) or 0) + int(summary.get("survived", 0) or 0)
        per_file.append({
            "file": r.file,
            "exit_code": r.exit_code,
            "killed": int(summary.get("killed", 0) or 0),
            "survived": int(summary.get("survived", 0) or 0),
            "uncovered": int(summary.get("uncovered", 0) or 0),
            "suppressed": int(summary.get("suppressed", 0) or 0),
            "is_critical_path": bool(summary.get("is_critical_path", False)),
            "critical_path_survivors": cps,
            "kill_rate_pct": round((summary.get("killed", 0) / run * 100), 1) if run else 0.0,
            "passed": r.exit_code == 0,
            "error": r.error,
        })

    run_total = total["killed"] + total["survived"]
    overall_rate = round((total["killed"] / run_total * 100), 1) if run_total else 0.0

    return {
        "overall_passed": not any_failed,
        "any_critical_path_survivor": any_critical_survivor,
        "files_tested": len(results),
        "files_failed": sum(1 for r in results if r.exit_code != 0),
        "totals": total,
        "overall_kill_rate_pct": overall_rate,
        "per_file": per_file,
    }


def aggregate_exit_code(aggregate: dict) -> int:
    """Mirror palace_mutate's contract at the batch level: non-zero if any file
    failed its gate. Pure."""
    return 0 if aggregate.get("overall_passed") else 1


def build_palace_mutate_argv(file_relpath: str, tests: list[str],
                             report_path: str, passthrough: list[str]) -> list[str]:
    """Assemble the argv for one palace_mutate.py invocation. Pure so the
    forwarded-flag wiring is unit-testable."""
    argv = [sys.executable, PALACE_MUTATE, "--file", file_relpath,
            "--report", report_path]
    for t in tests:
        argv += ["--tests", t]
    argv += passthrough
    return argv


def resolve_tests_for_file(file_relpath: str, repo_root: str = REPO_ROOT,
                           runner=None) -> list[str]:
    """Resolve XCTest class selectors for a production file via
    scripts/resolve-tests-for.py. Returns [] if resolution fails (caller skips
    the file with a logged warning — an uncovered file is a real signal, not a
    crash). `runner` injectable for tests.
    """
    resolver = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resolve-tests-for.py")
    if runner is None:
        runner = lambda argv: subprocess.run(  # noqa: E731
            argv, cwd=repo_root, capture_output=True, text=True, check=False)
    result = runner([sys.executable, resolver, file_relpath])
    if result.returncode != 0:
        return []
    return [ln.strip() for ln in result.stdout.splitlines() if ln.strip()]


# ---------------------------------------------------------------------------
# Worktree setup (impure — replicates the swarm Phase 0 Palace recipe)
# ---------------------------------------------------------------------------

def _sh(argv: list[str], cwd: str) -> subprocess.CompletedProcess:
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=False)


def setup_worker_worktree(worker_idx: int, base_ref: str, sim_udid: str) -> dict:
    """Create one isolated git worktree for a worker and wire up the Palace
    build prerequisites (Carthage/Build copy, real ios-audiobooktoolkit clone,
    other submodule symlinks, adobe-rmsdk symlink, gitignored secrets).

    Replicates the swarm SKILL.md Phase 0 recipe verbatim — the same rules apply
    here (Carthage copied not symlinked; ios-audiobooktoolkit a real submodule;
    the other 7 submodules + adobe-rmsdk symlinked) for the same reason: a
    symlinked Carthage/Build resolves to MAIN's path and produces duplicate
    XCFramework build commands on a fresh DerivedData.

    Returns a dict with `path`, `derived_data`, `sim_udid` for the worker.
    """
    wt_root = os.path.join(REPO_ROOT, ".claude", "worktrees")
    os.makedirs(wt_root, exist_ok=True)
    wt_path = os.path.join(wt_root, f"mutate-parallel-w{worker_idx}-{int(time.time())}")
    branch = f"mutate-parallel/w{worker_idx}-{int(time.time())}"

    _sh(["git", "worktree", "add", "-b", branch, wt_path, base_ref], cwd=REPO_ROOT)

    # Carthage/Build — copy, do not symlink.
    cb_src = os.path.join(REPO_ROOT, "Carthage", "Build")
    if os.path.isdir(cb_src):
        os.makedirs(os.path.join(wt_path, "Carthage", "Build"), exist_ok=True)
        _sh(["cp", "-RL", cb_src + "/.", os.path.join(wt_path, "Carthage", "Build") + "/"], cwd=wt_path)

    # ios-audiobooktoolkit — REAL submodule clone.
    _sh(["git", "submodule", "update", "--init", "--", "ios-audiobooktoolkit"], cwd=wt_path)

    # Other 7 submodules — symlinks are safe.
    for sub in ("adept-ios", "adobe-content-filter", "ios-audiobook-overdrive",
                "ios-tenprintcover", "mobile-bookmark-spec", "readium-sdk",
                "readium-shared-js"):
        dst = os.path.join(wt_path, sub)
        src = os.path.join(REPO_ROOT, sub)
        if not os.path.islink(dst):
            if os.path.isdir(dst) and not os.listdir(dst):
                os.rmdir(dst)
            if not os.path.exists(dst) and os.path.exists(os.path.join(src, ".git")):
                os.symlink(src, dst)

    # adobe-rmsdk — external private repo.
    adobe = "/Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector"
    adobe_dst = os.path.join(wt_path, "adobe-rmsdk")
    if not os.path.exists(adobe_dst) and os.path.isdir(adobe):
        os.symlink(adobe, adobe_dst)

    # Gitignored secrets.
    for f in ("Palace/AppInfrastructure/APIKeys.swift",
              "Palace/TPPSecrets.swift",
              "PalaceConfig/GoogleService-Info.plist",
              "PalaceConfig/ReaderClientCert.sig"):
        src = os.path.join(REPO_ROOT, f)
        dst = os.path.join(wt_path, f)
        if os.path.exists(src) and not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)

    dd = os.path.join(wt_path, ".derived")
    return {"path": wt_path, "derived_data": dd, "branch": branch, "sim_udid": sim_udid}


def teardown_worker_worktree(wt: dict) -> None:
    """Remove a worker worktree and its branch. Best-effort; never raises."""
    _sh(["git", "worktree", "remove", "--force", wt["path"]], cwd=REPO_ROOT)
    _sh(["git", "branch", "-D", wt["branch"]], cwd=REPO_ROOT)


# ---------------------------------------------------------------------------
# Per-file execution (impure — invokes palace_mutate.py)
# ---------------------------------------------------------------------------

def run_one_file(file_relpath: str, tests: list[str], report_path: str,
                 passthrough: list[str], cwd: str, env_overrides: dict) -> FileResult:
    """Invoke palace_mutate.py for a single file in `cwd` with env overrides
    (sim UDID + DerivedData path). Reads back the JSON report it wrote."""
    argv = build_palace_mutate_argv(file_relpath, tests, report_path, passthrough)
    env = dict(os.environ)
    env.update(env_overrides)
    log(f"start {file_relpath} (cwd={os.path.relpath(cwd, REPO_ROOT)}, "
        f"sim={env_overrides.get('HARNESS_SESSION_SIM_UDID', '?')[:8]})")
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    report = None
    error = ""
    # palace_mutate writes its report relative to its cwd.
    abs_report = report_path if os.path.isabs(report_path) else os.path.join(cwd, report_path)
    if os.path.isfile(abs_report):
        try:
            with open(abs_report) as f:
                report = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            error = f"report unreadable: {e}"
    else:
        error = f"no report produced (exit {proc.returncode})\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}"
    log(f"done  {file_relpath}: exit {proc.returncode}")
    return FileResult(file=file_relpath, exit_code=proc.returncode, report=report, error=error)


# ---------------------------------------------------------------------------
# Orchestration drivers
# ---------------------------------------------------------------------------

def run_serial(files: list[str], file_tests: dict, passthrough: list[str],
               report_dir: str) -> list[FileResult]:
    """Run every file serially in the MAIN tree — no worktree, no cold build.
    Used when the cost gate says parallel doesn't pay off."""
    results: list[FileResult] = []
    for f in files:
        report_path = os.path.join(report_dir, os.path.basename(f).replace(".swift", "") + ".json")
        results.append(run_one_file(f, file_tests[f], report_path, passthrough,
                                    cwd=REPO_ROOT, env_overrides={}))
    return results


def run_parallel(files: list[str], file_tests: dict, passthrough: list[str],
                 report_dir: str, worker_count: int, sims: list[str]) -> list[FileResult]:
    """Run files across `worker_count` isolated worktrees, one pool sim each.

    Each worker owns ONE worktree for its whole batch (so DerivedData stays warm
    across the files it processes). Files are sharded round-robin across workers.
    """
    sim_assignment = assign_sims(worker_count, sims)
    # Shard files round-robin so each worker gets a roughly equal slice.
    shards: list[list[str]] = [[] for _ in range(worker_count)]
    for i, f in enumerate(files):
        shards[i % worker_count].append(f)

    worktrees: list[dict] = []
    try:
        for w in range(worker_count):
            wt = setup_worker_worktree(w, DEFAULT_BASE_REF, sim_assignment[w])
            worktrees.append(wt)

        results: list[FileResult] = []

        def _worker(w_idx: int) -> list[FileResult]:
            wt = worktrees[w_idx]
            env = {
                "HARNESS_SESSION_SIM_UDID": wt["sim_udid"],
                "PALACE_MUTATE_DERIVED_DATA_PATH": wt["derived_data"],
            }
            out: list[FileResult] = []
            for f in shards[w_idx]:
                # Report written into the shared report_dir (absolute) so the
                # main process can aggregate without reaching into worktrees.
                report_path = os.path.join(
                    report_dir, os.path.basename(f).replace(".swift", "") + ".json")
                out.append(run_one_file(f, file_tests[f], report_path, passthrough,
                                        cwd=wt["path"], env_overrides=env))
            return out

        with ThreadPoolExecutor(max_workers=worker_count) as pool:
            futures = {pool.submit(_worker, w): w for w in range(worker_count)
                       if shards[w]}
            for fut in as_completed(futures):
                results.extend(fut.result())
        return results
    finally:
        for wt in worktrees:
            teardown_worker_worktree(wt)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Parallel file-level mutation orchestrator for Palace iOS")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--files", nargs="+", help="explicit list of production Swift files to mutate")
    src.add_argument("--changed", action="store_true",
                     help="auto-discover changed production Swift files vs --base")
    p.add_argument("--base", default=DEFAULT_BASE_REF,
                   help=f"git ref to diff against for --changed (default: {DEFAULT_BASE_REF})")
    p.add_argument("--workers", type=int, default=None,
                   help="worker count (default: min(#sims, max(1, ncpu//4), #files))")
    p.add_argument("--sims", nargs="+", default=DEFAULT_SIM_UDIDS,
                   help="pool simulator UDIDs (one per worker, round-robin)")
    p.add_argument("--report-dir", default=DEFAULT_REPORT_DIR,
                   help=f"directory for per-file JSON reports (default: {DEFAULT_REPORT_DIR})")
    p.add_argument("--summary-report", default=None,
                   help="optional path to write the aggregated summary JSON")
    # Pass-through flags forwarded verbatim to each palace_mutate.py invocation.
    args, passthrough = p.parse_known_args(argv)

    # 1. Resolve the file set.
    if args.changed:
        files = changed_prod_swift_files(args.base)
    else:
        files = filter_prod_swift(args.files)
    if not files:
        log("no production Swift files to mutate — nothing to do.")
        return 0
    log(f"files to mutate ({len(files)}): {', '.join(files)}")

    # 2. Resolve tests per file; skip uncovered files with a logged warning.
    file_tests: dict = {}
    runnable: list[str] = []
    for f in files:
        tests = resolve_tests_for_file(f)
        if not tests:
            log(f"WARNING: no resolvable tests for {f} — skipping (uncovered file).")
            continue
        file_tests[f] = tests
        runnable.append(f)
    if not runnable:
        log("no files with resolvable tests — nothing to mutate.")
        return 0
    files = runnable

    # 3. Worker count + cost-gate decision.
    worker_count = compute_worker_count(len(files), len(args.sims), os.cpu_count() or 1,
                                        requested=args.workers)
    parallel = should_run_parallel(len(files), worker_count)

    os.makedirs(args.report_dir, exist_ok=True)

    if parallel:
        log(f"PARALLEL: {len(files)} file(s) across {worker_count} worker(s) "
            f"(sims: {len(args.sims)}, ncpu: {os.cpu_count()}).")
        results = run_parallel(files, file_tests, passthrough, args.report_dir,
                               worker_count, args.sims)
    else:
        log(f"SERIAL: {len(files)} file(s) in main tree (cost gate: <2 files or "
            f"workers=1; worker_count={worker_count}). No worktree/cold-build overhead.")
        results = run_serial(files, file_tests, passthrough, args.report_dir)

    # 4. Aggregate + report.
    aggregate = aggregate_reports(results)
    if args.summary_report:
        with open(args.summary_report, "w") as f:
            json.dump(aggregate, f, indent=2)

    log("=" * 60)
    log(f"aggregate: {aggregate['files_tested']} file(s), "
        f"{aggregate['files_failed']} failed gate")
    t = aggregate["totals"]
    log(f"  killed: {t['killed']}  survived: {t['survived']}  "
        f"uncovered: {t['uncovered']}  suppressed: {t['suppressed']}  "
        f"overall kill rate: {aggregate['overall_kill_rate_pct']}%")
    if aggregate["any_critical_path_survivor"]:
        log("  CRITICAL-PATH survivor(s) present — gate FAIL.")
    for pf in aggregate["per_file"]:
        flag = "PASS" if pf["passed"] else "FAIL"
        log(f"  [{flag}] {pf['file']}: kill {pf['kill_rate_pct']}% "
            f"(k{pf['killed']}/s{pf['survived']}/u{pf['uncovered']})"
            + (f"  ERROR: {pf['error'].splitlines()[0]}" if pf["error"] else ""))
    log("=" * 60)

    return aggregate_exit_code(aggregate)


if __name__ == "__main__":
    sys.exit(main())
