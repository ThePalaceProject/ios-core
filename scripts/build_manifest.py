#!/usr/bin/env python3
"""Record the build inputs a verification report applies to, and say when a
report no longer applies to the tree in front of you.

  write --check NAME (--result R | --from-checks) [--into REPORT] [--udid U]
        [--configuration C] [--recovered-by WHAT]
      Print the manifest, or with --into add it under "manifest" in the JSON
      report REPORT. --from-checks reads the result from the report's
      "checks" list (the shape of the pre-PR check report). Exit 2 when a value would put
      something that is not a plain identifier into the report.
  check-stale REPORT [--tree-only] [--udid U]
      Compare the report's manifest with this checkout and toolchain.
      Exit 0 current, 1 stale (each difference is printed), 3 no usable
      verdict (no manifest, or the report cannot be read). --tree-only skips
      the Xcode, SDK and arch, for reading a CI report on another machine.

The manifest records: the app commit and whether the tree had changes, the
pinned inputs (DRM connector record, AudioEngine version and archive SHA-256,
toolkit submodule), Xcode, SDK, simulator, arch, configuration, the hosted
runner image (CI only), and the check with its result. A new pinned input is
one more entry in INPUT_READERS. Each value is read from the file that pins it,
never from the environment, so no credential can reach the report.

prior-art-checked: reference_toolchain.py records the toolchain to the log only,
and drm_connector.py reads the connector record; this reuses both.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import drm_connector  # noqa: E402
import reference_toolchain  # noqa: E402

SCHEMA = 1
RESULTS = ("passed", "failed", "skipped", "recovered", "unavailable")
# The statuses the pre-PR check records for each of its checks.
CHECK_STATUS = {"pass": "passed", "fail": "failed", "skip": "skipped",
                "recovered": "recovered", "unavailable": "unavailable"}
TOOLKIT = "ios-audiobooktoolkit"
AUDIOENGINE_SCRIPT = Path("scripts/fetch-audioengine.sh")
# Toolchain fields that describe the host rather than the simulator, so they
# can be compared without a UDID.
HOST_TOOLCHAIN = ("xcode_version", "xcode_build", "sdk", "arch")
EXIT_CURRENT, EXIT_STALE, EXIT_REFUSED, EXIT_NO_VERDICT = 0, 1, 2, 3
# Every value in a manifest is an identifier: a SHA, a version, a device or
# runtime name. Anything else (a URL, an address, a token) is refused.
SAFE_VALUE = re.compile(r"^[A-Za-z0-9 ._()+/-]*$")


class ManifestError(Exception):
    pass


def _git(root: Path, *args: str) -> str | None:
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=False)
    return r.stdout.decode(errors="replace").strip() if r.returncode == 0 else None


def read_app(root: Path) -> dict:
    sha = _git(root, "rev-parse", "HEAD")
    if not sha:
        raise ManifestError(f"{root} is not a git checkout")
    # Submodules are left out here: their revisions are recorded as inputs.
    status = _git(root, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all")
    app = {"sha": sha, "dirty": bool(status)}
    if status:
        # Ties a report made from uncommitted changes to those exact changes.
        diff = subprocess.run(["git", "-C", str(root), "diff", "HEAD", "--binary", "--ignore-submodules=all"],
                              capture_output=True, check=False).stdout
        app["diff_sha256"] = hashlib.sha256(diff).hexdigest()
    return app


def read_connector(root: Path) -> dict:
    record = drm_connector.read_record(root)
    out = {"repo": record["repo"], "sha": record["sha"], "generation": record["generation"]}
    # A local DRM build links whatever adobe-rmsdk points at, which can differ
    # from the record; CI checks out the record itself and has no link.
    link = Path(os.environ.get("ADEPT_RMSDK") or root / "adobe-rmsdk")
    if os.path.lexists(link) and Path(os.path.realpath(link)).is_dir():
        linked = _git(Path(os.path.realpath(link)), "rev-parse", "HEAD")
        if linked and linked != _git(root, "rev-parse", "HEAD"):
            out["linked_sha"] = linked
    return out


def read_audioengine(root: Path) -> dict:
    text = (root / AUDIOENGINE_SCRIPT).read_text()
    values = dict(re.findall(r'^(AUDIOENGINE_VERSION|AUDIOENGINE_SHA256)="([^"]*)"', text, re.M))
    if set(values) != {"AUDIOENGINE_VERSION", "AUDIOENGINE_SHA256"}:
        raise ManifestError(f"{AUDIOENGINE_SCRIPT} has no AUDIOENGINE_VERSION/AUDIOENGINE_SHA256")
    return {"version": values["AUDIOENGINE_VERSION"], "sha256": values["AUDIOENGINE_SHA256"]}


def read_toolkit(root: Path) -> dict:
    tree = _git(root, "ls-tree", "HEAD", TOOLKIT) or ""
    m = re.match(r"^160000 commit ([0-9a-f]{40})\t", tree)
    if not m:
        raise ManifestError(f"HEAD has no {TOOLKIT} submodule entry")
    out = {"recorded_sha": m.group(1)}
    # What a local build compiled; a test run has been seen to move it.
    if (root / TOOLKIT / ".git").exists():
        checked_out = _git(root / TOOLKIT, "rev-parse", "HEAD")
        if checked_out:
            out["checked_out_sha"] = checked_out
    return out


INPUT_READERS = {
    "connector": read_connector,
    "audioengine": read_audioengine,
    "toolkit": read_toolkit,
}


def read_toolchain(args: argparse.Namespace) -> dict:
    profile = reference_toolchain.load_profile(args.profile, Path(args.toolchain_config))
    seen = reference_toolchain.observe(argparse.Namespace(
        xcode_version_text=args.xcode_version_text, sdk_version=args.sdk_version,
        simctl_json=args.simctl_json, udid=args.udid or "", arch=args.arch,
        configuration=args.configuration), profile)
    if not args.udid:
        seen.pop("runtime"), seen.pop("device")
    return seen


def read_runner() -> dict | None:
    # The hosted image behind a label such as macos-15 changes weekly and
    # cannot be pinned, so CI records the one it got.
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return None
    return {"image_os": os.environ.get("ImageOS", "unknown"),
            "image_version": os.environ.get("ImageVersion", "unknown")}


def result_from_checks(report: dict) -> tuple[str, dict]:
    counts = dict.fromkeys(RESULTS, 0)
    for entry in report.get("checks", []):
        counts[CHECK_STATUS.get(entry.get("status"), "unavailable")] += 1
    # The run's result is its worst outcome among those that ran; the counts
    # keep every skipped and unavailable check visible beside it.
    for result in ("failed", "recovered", "passed", "skipped"):
        if counts[result]:
            return result, counts
    return "unavailable", counts


def check_safe(node, path: str = "manifest") -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            check_safe(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            check_safe(v, f"{path}[{i}]")
    elif isinstance(node, str) and not SAFE_VALUE.match(node):
        # The value itself is not printed: it may be the credential.
        raise ManifestError(f"{path} is not a plain identifier ({len(node)} characters); "
                            "no manifest was written")


def build(args: argparse.Namespace, report: dict | None) -> dict:
    root = Path(args.repo_root)
    manifest: dict = {"schema": SCHEMA, "check": args.check}
    if args.from_checks:
        manifest["result"], manifest["counts"] = result_from_checks(report or {})
    else:
        manifest["result"] = args.result
    if manifest["result"] == "recovered" and args.recovered_by:
        manifest["recovered_by"] = list(dict.fromkeys(args.recovered_by.split()))
    manifest["app"] = read_app(root)
    manifest["inputs"] = {name: reader(root) for name, reader in INPUT_READERS.items()}
    manifest["toolchain"] = read_toolchain(args)
    runner = read_runner()
    if runner:
        manifest["runner"] = runner
    check_safe(manifest)
    return manifest


def load_report(path: Path) -> dict:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ManifestError(f"{path} is not a JSON object")
    return data


def cmd_write(args: argparse.Namespace) -> int:
    report = load_report(Path(args.into)) if args.into else None
    manifest = build(args, report)
    if not args.into:
        print(json.dumps(manifest, indent=2, sort_keys=True))
        return 0
    report["manifest"] = manifest
    target = Path(args.into)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".manifest-")
    with os.fdopen(fd, "w") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, target)
    print(f"manifest: {args.check} {manifest['result']} at {manifest['app']['sha'][:12]} written to {target}")
    return 0


def _flat(node, prefix: str = "") -> dict:
    out = {}
    for k, v in node.items():
        if isinstance(v, dict):
            out.update(_flat(v, f"{prefix}{k}."))
        else:
            out[f"{prefix}{k}"] = v
    return out


def differences(recorded: dict, current: dict, tree_only: bool) -> list[str]:
    diffs = []
    rec_app, cur_app = recorded.get("app", {}), current["app"]
    for key in ("sha", "dirty", "diff_sha256"):
        if rec_app.get(key) != cur_app.get(key):
            diffs.append(f"app.{key}: report {rec_app.get(key)}, now {cur_app.get(key)}")
    rec_inputs = recorded.get("inputs", {})
    for name, now in current["inputs"].items():
        if name not in rec_inputs:
            # An input the report predates was not recorded, so it cannot be
            # shown unchanged.
            diffs.append(f"inputs.{name}: not recorded in the report")
            continue
        now_flat = _flat(now)
        for key, value in _flat(rec_inputs[name]).items():
            if now_flat.get(key) != value:
                diffs.append(f"inputs.{name}.{key}: report {value}, now {now_flat.get(key, 'not readable here')}")
    if not tree_only:
        rec_tc, cur_tc = recorded.get("toolchain", {}), current["toolchain"]
        keys = HOST_TOOLCHAIN + (("runtime", "device") if "runtime" in cur_tc else ())
        for key in keys:
            if rec_tc.get(key) != cur_tc.get(key):
                diffs.append(f"toolchain.{key}: report {rec_tc.get(key)}, now {cur_tc.get(key)}")
    return diffs


def cmd_check_stale(args: argparse.Namespace) -> int:
    try:
        report = load_report(Path(args.report))
    except (OSError, ValueError, ManifestError) as error:
        print(f"check-stale: cannot read {args.report}: {error}", file=sys.stderr)
        return EXIT_NO_VERDICT
    recorded = report.get("manifest", report if "schema" in report else None)
    if not isinstance(recorded, dict) or recorded.get("schema") != SCHEMA:
        print(f"check-stale: {args.report} has no schema-{SCHEMA} manifest; it cannot be tied to a tree",
              file=sys.stderr)
        return EXIT_NO_VERDICT
    args.check, args.result, args.from_checks, args.recovered_by = "check-stale", "unavailable", False, ""
    current = build(args, None)
    diffs = differences(recorded, current, args.tree_only)
    label = f"{recorded.get('check')} {recorded.get('result')}"
    if diffs:
        print(f"STALE: {args.report} ({label}) does not apply to this tree:")
        for d in diffs:
            print(f"  {d}")
        return EXIT_STALE
    print(f"CURRENT: {args.report} ({label}) matches this tree at {current['app']['sha'][:12]}")
    return EXIT_CURRENT


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    common.add_argument("--toolchain-config", default=str(reference_toolchain.DEFAULT_CONFIG))
    common.add_argument("--profile", default="reference")
    common.add_argument("--udid")
    common.add_argument("--configuration")
    # Replace the live readings (used by the tests).
    common.add_argument("--simctl-json")
    common.add_argument("--xcode-version-text")
    common.add_argument("--sdk-version")
    common.add_argument("--arch")
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("write", parents=[common])
    w.add_argument("--check", required=True)
    which = w.add_mutually_exclusive_group(required=True)
    which.add_argument("--result", choices=RESULTS)
    which.add_argument("--from-checks", action="store_true")
    w.add_argument("--recovered-by", default="")
    w.add_argument("--into")

    s = sub.add_parser("check-stale", parents=[common])
    s.add_argument("report")
    s.add_argument("--tree-only", action="store_true")

    args = ap.parse_args(argv)
    if args.cmd == "write" and args.from_checks and not args.into:
        ap.error("--from-checks needs --into")
    try:
        return cmd_write(args) if args.cmd == "write" else cmd_check_stale(args)
    except (ManifestError, drm_connector.RecordError, reference_toolchain.ConfigError, OSError, ValueError) as error:
        print(f"build_manifest: {error}", file=sys.stderr)
        return EXIT_REFUSED if args.cmd == "write" else EXIT_NO_VERDICT


if __name__ == "__main__":
    sys.exit(main())
