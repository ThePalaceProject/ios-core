#!/usr/bin/env python3
"""
Build the coverage report from an xcresult bundle and host package runs.

Usage:
  coverage-report.py <path-to-xcresult> [--json OUT] [options]
  coverage-report.py --xccov-json <xccov-report.json> [--json OUT] [options]

Options:
  --repo-root DIR             checkout root used to make source paths relative
                              (default: current directory)
  --expect-package NAME       a local package the app suite must measure; may repeat
  --expect-local-packages     expect every Palace/Packages/*/Package.swift (CI, where
                              ci-xctestrun-package-coverage.py has pointed coverage
                              at the package binaries; a local Xcode run lacks that)
  --host-package NAME=FILE    llvm-cov export from `swift test --enable-code-coverage`
  --host-package-dir DIR      every DIR/<NAME>.json as --host-package NAME=...
  --expect-host-package NAME  a host package run whose data must be present
  --incomplete-reason TEXT    mark the report incomplete (e.g. a shard lost classes)

Three measurements are kept apart, each with raw executable/covered counts:
  app            source under Palace/ outside Palace/Packages, from the app suite.
                 The top-level fields (testable_coverage, total_coverage, ...)
                 are this measurement, so the gated app metric keeps the
                 denominator it had before package source was collected.
  packages_app_suite  Palace/Packages/<P>/Sources, from the same app suite.
  packages_host       Palace/Packages/<P>/Sources, from `swift test` on macOS.
                 Different instrumentation and platform conditionals, so it is
                 never added to the app-suite numbers.
Files matched by coverage-exclude.json are reported as excluded in each scope.

A source path seen in more than one target (packages link into both the app
and the test bundle) is counted once: the entry with the most covered lines,
a lower bound of the union. Each such path is listed under `duplicates`.

Exit status: 0 complete, 3 incomplete (the JSON is still written, with
`status: incomplete` and the reasons), 2 usage error.
"""
import argparse
import fnmatch
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

EXIT_COMPLETE = 0
EXIT_USAGE = 2
EXIT_INCOMPLETE = 3

PACKAGES_PREFIX = "Palace/Packages/"


def load_exclude_config() -> Tuple[List[str], Dict[str, str]]:
    """Path patterns and named package exemptions from coverage-exclude.json."""
    here = os.path.dirname(os.path.abspath(__file__))
    exclude_path = os.path.join(here, 'coverage-exclude.json')
    if not os.path.exists(exclude_path):
        return [], {}
    try:
        with open(exclude_path) as f:
            data = json.load(f)
        return list(data.get('paths', [])), dict(data.get('unmeasured_packages', {}))
    except (json.JSONDecodeError, OSError) as e:
        print(f"Warning: could not read {exclude_path}: {e}", file=sys.stderr)
        return [], {}


def load_exclude_patterns() -> List[str]:
    return load_exclude_config()[0]


def is_path_excluded(rel_path: str, patterns: List[str]) -> bool:
    """fnmatch the repo-relative path. fnmatch's `*` also matches `/`, so `**`
    and `*` behave the same; patterns keep `**` for readability."""
    if not rel_path:
        return False
    return any(fnmatch.fnmatchcase(rel_path, p) for p in patterns)


def repo_relative(path: str, repo_root: Optional[str]) -> str:
    """Stable identity for a source file: its path relative to the checkout.
    A path outside the checkout is returned unchanged (absolute), so it can
    never be classified as app or package source. CI builds and reports from
    the same checkout path; pass --repo-root to read a bundle built elsewhere."""
    if not path:
        return ""
    if repo_root:
        root = repo_root.rstrip('/') + '/'
        if path.startswith(root):
            return path[len(root):]
    return path


def classify(rel_path: str) -> Tuple[str, Optional[str]]:
    """('app', None), ('package', name) or ('other', None)."""
    if rel_path.startswith(PACKAGES_PREFIX):
        parts = rel_path[len(PACKAGES_PREFIX):].split('/')
        if len(parts) >= 3 and parts[1] == 'Sources':
            return 'package', parts[0]
        return 'other', None
    if rel_path.startswith('Palace/'):
        return 'app', None
    return 'other', None


def discover_packages(repo_root: str) -> List[str]:
    base = os.path.join(repo_root, *PACKAGES_PREFIX.rstrip('/').split('/'))
    if not os.path.isdir(base):
        return []
    return sorted(d for d in os.listdir(base)
                  if os.path.isfile(os.path.join(base, d, 'Package.swift')))


def _pct(covered: int, executable: int) -> float:
    return (covered / executable) * 100 if executable else 0.0


class Tally:
    """Raw line counts for one scope, split into testable and excluded."""

    def __init__(self) -> None:
        self.c = {'file_count': 0, 'covered_lines': 0, 'executable_lines': 0,
                  'testable_covered_lines': 0, 'testable_executable_lines': 0,
                  'excluded_file_count': 0, 'excluded_covered_lines': 0,
                  'excluded_executable_lines': 0}

    def add(self, covered: int, executable: int, excluded: bool) -> None:
        c = self.c
        c['file_count'] += 1
        c['covered_lines'] += covered
        c['executable_lines'] += executable
        if excluded:
            c['excluded_file_count'] += 1
            c['excluded_covered_lines'] += covered
            c['excluded_executable_lines'] += executable
        else:
            c['testable_covered_lines'] += covered
            c['testable_executable_lines'] += executable

    def as_dict(self) -> Dict[str, Any]:
        d = dict(self.c)
        d['total_coverage'] = _pct(d['covered_lines'], d['executable_lines'])
        d['testable_coverage'] = _pct(d['testable_covered_lines'], d['testable_executable_lines'])
        return d


def _int(v: Any) -> int:
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


def _collect_app_suite(raw: Dict, repo_root: Optional[str]) -> Tuple[Dict[str, Dict], List[Dict], List[Dict]]:
    """One entry per repo-relative path across every target, plus the target
    rows and the duplicates found."""
    by_path: Dict[str, Dict] = {}
    seen_in: Dict[str, List[str]] = {}
    targets_out = []
    for target in raw.get('targets', []) or []:
        if not isinstance(target, dict):
            continue
        tname = str(target.get('name', 'Unknown'))
        t_cov, t_exe = _int(target.get('coveredLines')), _int(target.get('executableLines'))
        targets_out.append({'name': tname, 'covered_lines': t_cov, 'executable_lines': t_exe,
                            'coverage': _pct(t_cov, t_exe),
                            'coverage_formatted': f"{_pct(t_cov, t_exe):.1f}%"})
        for f in target.get('files', []) or []:
            if not isinstance(f, dict):
                continue
            executable = _int(f.get('executableLines'))
            if executable == 0:
                continue
            covered = _int(f.get('coveredLines'))
            rel = repo_relative(str(f.get('path', '')), repo_root)
            seen_in.setdefault(rel, []).append(tname)
            prev = by_path.get(rel)
            if prev is None or (covered, executable) > (prev['covered_lines'], prev['executable_lines']):
                by_path[rel] = {'name': f.get('name') or os.path.basename(rel), 'path': rel,
                                'target': tname, 'covered_lines': covered,
                                'executable_lines': executable}
    duplicates = [{'path': p, 'targets': ts, 'kept_target': by_path[p]['target']}
                  for p, ts in sorted(seen_in.items()) if len(ts) > 1]
    return by_path, targets_out, duplicates


def _host_package_tally(name: str, export: Any, repo_root: Optional[str],
                        patterns: List[str]) -> Optional[Tally]:
    """Package source lines from an llvm-cov export; None when it holds none."""
    try:
        files = export['data'][0]['files']
    except (KeyError, IndexError, TypeError):
        return None
    tally = Tally()
    for f in files:
        try:
            lines = f['summary']['lines']
            rel = repo_relative(f['filename'], repo_root)
        except (KeyError, TypeError):
            continue
        scope, pkg = classify(rel)
        if scope != 'package' or pkg != name:
            continue
        executable = _int(lines.get('count'))
        if executable == 0:
            continue
        tally.add(_int(lines.get('covered')), executable, is_path_excluded(rel, patterns))
    return tally if tally.c['file_count'] else None


def build_report(raw: Any,
                 exclude_patterns: Optional[List[str]] = None,
                 repo_root: Optional[str] = None,
                 expected_packages: Optional[List[str]] = None,
                 package_exemptions: Optional[Dict[str, str]] = None,
                 host_packages: Optional[Dict[str, Any]] = None,
                 expected_host_packages: Optional[List[str]] = None,
                 incomplete_reasons: Optional[List[str]] = None) -> Dict[str, Any]:
    patterns = exclude_patterns or []
    exemptions = package_exemptions or {}
    reasons: List[str] = list(incomplete_reasons or [])

    app = Tally()
    other = Tally()
    packages: Dict[str, Tally] = {}
    files_out: List[Dict] = []
    targets_out: List[Dict] = []
    duplicates: List[Dict] = []

    if not isinstance(raw, dict) or not isinstance(raw.get('targets'), list):
        reasons.append("the app-suite coverage could not be read (xccov produced no report)")
    else:
        by_path, targets_out, duplicates = _collect_app_suite(raw, repo_root)
        for rel, entry in by_path.items():
            scope, pkg = classify(rel)
            excluded = scope != 'other' and is_path_excluded(rel, patterns)
            cov, exe = entry['covered_lines'], entry['executable_lines']
            if scope == 'app':
                app.add(cov, exe, excluded)
            elif scope == 'package':
                packages.setdefault(pkg, Tally()).add(cov, exe, excluded)
            else:
                other.add(cov, exe, False)
                continue
            files_out.append(dict(entry, package=pkg, excluded_from_testable=excluded,
                                  coverage=_pct(cov, exe),
                                  coverage_formatted=f"{_pct(cov, exe):.1f}%"))
        if app.c['executable_lines'] == 0:
            reasons.append("no application source in the coverage data")
        elif app.c['covered_lines'] == 0:
            reasons.append("the app suite recorded no executed line, so no test ran against an instrumented build")

    for name in expected_packages or []:
        if name not in packages and name not in exemptions:
            reasons.append(f"package {name} has no source in the app-suite coverage")

    host_out: Dict[str, Dict] = {}
    for name, export in sorted((host_packages or {}).items()):
        tally = _host_package_tally(name, export, repo_root, patterns) if export is not None else None
        if tally is None:
            reasons.append(f"host package {name}: no readable package source in its swift test coverage")
        else:
            host_out[name] = tally.as_dict()
    for name in expected_host_packages or []:
        if name not in (host_packages or {}):
            reasons.append(f"host package {name}: swift test coverage file missing")

    a = app.as_dict()
    return {
        'status': 'incomplete' if reasons else 'complete',
        'incomplete_reasons': reasons,
        # What this run was required to measure. The floor step compares
        # package floors only for these; a local run expects none.
        'expected_packages': sorted(expected_packages or []),
        'expected_host_packages': sorted(expected_host_packages or []),
        # App measurement, under the field names the gate and reports read.
        'total_coverage': a['total_coverage'],
        'line_coverage': a['total_coverage'],
        'covered_lines': a['covered_lines'],
        'executable_lines': a['executable_lines'],
        'testable_coverage': a['testable_coverage'],
        'testable_covered_lines': a['testable_covered_lines'],
        'testable_executable_lines': a['testable_executable_lines'],
        'excluded_file_count': a['excluded_file_count'],
        'excluded_executable_lines': a['excluded_executable_lines'],
        'app': a,
        'packages_app_suite': {n: t.as_dict() for n, t in sorted(packages.items())},
        'packages_host': host_out,
        'unmeasured_packages': {n: r for n, r in exemptions.items() if n not in packages},
        'unattributed': other.as_dict(),
        'duplicates': duplicates,
        'targets': sorted(targets_out, key=lambda t: t['name']),
        'files': sorted(files_out, key=lambda f: f['coverage']),
    }


def _row(label: str, d: Dict) -> str:
    return (f"  {label:<28} {d['testable_coverage']:5.1f}%  "
            f"{d['testable_covered_lines']:>6} / {d['testable_executable_lines']:<6}  "
            f"excluded {d['excluded_covered_lines']} / {d['excluded_executable_lines']}")


def format_coverage_summary(coverage: Dict) -> str:
    lines = ["=" * 72, "CODE COVERAGE REPORT", "=" * 72]
    if coverage.get('status') != 'complete':
        lines.append("STATUS: INCOMPLETE — these numbers are not a measurement of the change")
        for r in coverage.get('incomplete_reasons', []):
            lines.append(f"  - {r}")
        lines.append("")
    lines.append("Measurement                  testable  covered / executable  "
                 "(excluded covered / executable)")
    lines.append(_row("app (Palace/)", coverage['app']))
    lines.append(f"  {'app, total incl. excluded':<28} {coverage['total_coverage']:5.1f}%  "
                 f"{coverage['covered_lines']:>6} / {coverage['executable_lines']}")
    pkgs = coverage.get('packages_app_suite', {})
    if pkgs:
        lines.append("Packages, app suite (iOS simulator):")
        for name, d in pkgs.items():
            lines.append(_row(name, d))
    host = coverage.get('packages_host', {})
    if host:
        lines.append("Packages, swift test (macOS host; not combined with the app suite):")
        for name, d in host.items():
            lines.append(_row(name, d))
    for name, why in coverage.get('unmeasured_packages', {}).items():
        lines.append(f"  UNMEASURED {name}: {why}")
    u = coverage.get('unattributed', {})
    if u.get('executable_lines'):
        lines.append(f"Not counted (tests, third-party, generated): "
                     f"{u['covered_lines']} / {u['executable_lines']} lines in {u['file_count']} files")
    if coverage.get('duplicates'):
        lines.append(f"Source paths in more than one target, counted once: {len(coverage['duplicates'])}")
    lines.append("")
    lines.append("LOWEST COVERAGE FILES (app and packages):")
    for f in coverage.get('files', [])[:10]:
        lines.append(f"  {f['coverage_formatted']:>6} - {f['path']}")
    lines.append("=" * 72)
    return "\n".join(lines)


def output_github_actions(coverage: Dict, output_file: str) -> None:
    def one_line(s: str) -> str:
        return s.replace('\n', ' ').replace('\r', ' ')

    with open(output_file, 'a') as f:
        f.write(f"coverage_status={coverage['status']}\n")
        f.write(f"coverage_incomplete_reason={one_line('; '.join(coverage['incomplete_reasons']))}\n")
        f.write(f"coverage={coverage['testable_coverage']:.1f}\n")
        f.write(f"coverage_formatted={coverage['testable_coverage']:.1f}%\n")
        f.write(f"covered_lines={coverage['testable_covered_lines']}\n")
        f.write(f"executable_lines={coverage['testable_executable_lines']}\n")
        f.write(f"total_coverage={coverage['total_coverage']:.1f}\n")
        f.write(f"total_coverage_formatted={coverage['total_coverage']:.1f}%\n")
        f.write(f"total_covered_lines={coverage['covered_lines']}\n")
        f.write(f"total_executable_lines={coverage['executable_lines']}\n")
        f.write(f"excluded_file_count={coverage['excluded_file_count']}\n")
        f.write(f"excluded_executable_lines={coverage['excluded_executable_lines']}\n")
        # measurement|name|testable covered|testable executable|percent
        f.write("coverage_packages<<EOF\n")
        for scope, key in (('app-suite', 'packages_app_suite'), ('host', 'packages_host')):
            for name, d in coverage[key].items():
                f.write(f"{scope}|{name}|{d['testable_covered_lines']}|"
                        f"{d['testable_executable_lines']}|{d['testable_coverage']:.1f}%\n")
        f.write("EOF\n")


def _read_json(path: str) -> Any:
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"Warning: could not read {path}: {e}", file=sys.stderr)
        return None


def get_coverage_from_xcresult(xcresult_path: str) -> Any:
    cmd = ['xcrun', 'xccov', 'view', '--report', '--json', xcresult_path]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"xccov failed: {e}", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(f"xccov failed ({result.returncode}): {result.stderr.strip()}", file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print("xccov output is not JSON", file=sys.stderr)
        return None


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('xcresult', nargs='?')
    p.add_argument('--xccov-json')
    p.add_argument('--json', default='coverage-data.json')
    p.add_argument('--repo-root', default=os.getcwd())
    p.add_argument('--expect-package', action='append', default=[])
    p.add_argument('--expect-local-packages', action='store_true')
    p.add_argument('--host-package', action='append', default=[])
    p.add_argument('--host-package-dir')
    p.add_argument('--expect-host-package', action='append', default=[])
    p.add_argument('--incomplete-reason', action='append', default=[])
    args = p.parse_args(argv)

    if bool(args.xcresult) == bool(args.xccov_json):
        p.print_usage(sys.stderr)
        print("give exactly one of <xcresult> or --xccov-json", file=sys.stderr)
        return EXIT_USAGE

    reasons = [r for r in args.incomplete_reason if r]
    if args.xccov_json:
        raw = _read_json(args.xccov_json)
    elif not os.path.exists(args.xcresult):
        print(f"Error: {args.xcresult} not found", file=sys.stderr)
        raw = None
    else:
        print(f"Extracting coverage from: {args.xcresult}", file=sys.stderr)
        raw = get_coverage_from_xcresult(args.xcresult)

    host: Dict[str, Any] = {}
    if args.host_package_dir and os.path.isdir(args.host_package_dir):
        for fn in sorted(os.listdir(args.host_package_dir)):
            if fn.endswith('.json'):
                host[fn[:-5]] = _read_json(os.path.join(args.host_package_dir, fn))
    for spec in args.host_package:
        name, sep, path = spec.partition('=')
        if not sep:
            print(f"--host-package expects NAME=FILE, got {spec!r}", file=sys.stderr)
            return EXIT_USAGE
        host[name] = _read_json(path)

    patterns, exemptions = load_exclude_config()
    expected = list(args.expect_package)
    if args.expect_local_packages:
        local = discover_packages(args.repo_root)
        if not local:
            reasons.append(f"no local packages found under {args.repo_root}/{PACKAGES_PREFIX}")
        expected += local
    coverage = build_report(raw, exclude_patterns=patterns, repo_root=args.repo_root,
                            expected_packages=expected, package_exemptions=exemptions,
                            host_packages=host, expected_host_packages=args.expect_host_package,
                            incomplete_reasons=reasons)

    print(format_coverage_summary(coverage), file=sys.stderr)
    github_output = os.environ.get('GITHUB_OUTPUT', '')
    if github_output:
        output_github_actions(coverage, github_output)
    with open(args.json, 'w') as f:
        json.dump(coverage, f, indent=2)
    print(f"Wrote coverage data to: {args.json} (status: {coverage['status']})", file=sys.stderr)
    return EXIT_COMPLETE if coverage['status'] == 'complete' else EXIT_INCOMPLETE


if __name__ == '__main__':
    sys.exit(main())
