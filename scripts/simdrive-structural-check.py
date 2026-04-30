#!/usr/bin/env python3
"""
simdrive-structural-check.py — OPDS-tolerant journey verifier.

For screens with non-deterministic content (catalog feeds, search results,
recently-borrowed lists), pixel-SSIM is the wrong tool — every cover thumbnail
swap looks like drift. This script replaces the per-step SSIM check with
structural assertions over the OCR marks returned by simdrive.observe():

  * required_text:    must see marks matching these substrings (case-insensitive)
  * required_chrome:  must see marks at these stable_ids (tab bar, nav buttons)
  * min_marks:        at least N marks visible (proxy for "screen loaded")

Journey YAML schema addition:

  structural_checks:
    - after_step: 1
      required_text: ["Catalog", "Settings"]
      required_chrome: ["a229e82e3f00", "3218623d0801", "0f06bf1e2d8b", "7fbaa4deb053"]
      min_marks: 10

Usage:
  python3 scripts/simdrive-structural-check.py \\
      --journey .simdrive/journeys/catalog-browse-stateless.yaml \\
      --sim-id <UDID>

Exits 0 on all checks pass, 1 on any failure, 2 on config error.
"""
from __future__ import annotations
import argparse, json, os, sys, time
from pathlib import Path
from typing import Optional

try:
    import yaml
except ImportError:
    print("ERROR: pip3 install pyyaml", file=sys.stderr)
    sys.exit(2)

try:
    from simdrive import session as sdsession, act
    from simdrive.observe import observe as sd_observe
except ImportError:
    print("ERROR: simdrive not installed (pip3 install --pre simdrive)", file=sys.stderr)
    sys.exit(2)


def execute_step(session, step: dict) -> None:
    """Replicate the action portion of a recording step (no SSIM compare)."""
    action = step.get("action")
    args = step.get("args", {})
    sw = args.get("screenshot_w", 1206)
    sh = args.get("screenshot_h", 2622)
    if action == "tap":
        act.tap(args["x"], args["y"], sw, sh, udid=session.device.udid)
    elif action == "swipe":
        act.swipe(args["x1"], args["y1"], args["x2"], args["y2"], sw, sh,
                  duration_ms=args.get("duration_ms", 300),
                  udid=session.device.udid)
    elif action == "type_text":
        act.type_text(args["text"], udid=session.device.udid)
    elif action == "press_key":
        act.press_key(args["key"], udid=session.device.udid)
    else:
        raise ValueError(f"unknown action: {action}")


def verify_check(check: dict, marks: list[dict]) -> tuple[bool, list[str]]:
    """Apply a single structural check against an observe()'s marks. Returns (ok, errors)."""
    errors: list[str] = []

    required_text = check.get("required_text", [])
    if required_text:
        # OCR is messy — match case-insensitive substring
        text_blob = " ".join((m.get("text") or "") for m in marks).lower()
        for needle in required_text:
            if needle.lower() not in text_blob:
                errors.append(f"required_text missing: '{needle}'")

    required_chrome = check.get("required_chrome", [])
    if required_chrome:
        present_stable_ids = {m.get("stable_id") for m in marks}
        for sid in required_chrome:
            if sid not in present_stable_ids:
                errors.append(f"required_chrome missing stable_id: {sid}")

    min_marks = check.get("min_marks")
    if min_marks is not None and len(marks) < min_marks:
        errors.append(f"only {len(marks)} marks visible (min_marks={min_marks})")

    return (len(errors) == 0, errors)


def run(journey_path: Path, sim_id: str, app_bundle_id: str, verbose: bool = False) -> int:
    journey_yaml = yaml.safe_load(journey_path.read_text())
    scenario = journey_yaml.get("scenario", journey_yaml)
    journey_id = scenario.get("id") or journey_path.stem
    structural_checks = scenario.get("structural_checks") or []

    if not structural_checks:
        print(f"NO-OP: {journey_id} has no structural_checks defined")
        return 0

    # Pull the recording for the action sequence
    rec_path = Path.home() / ".simdrive" / "recordings" / journey_id / "recording.yaml"
    if not rec_path.exists():
        print(f"ERROR: no recording at {rec_path}", file=sys.stderr)
        return 2
    recording = yaml.safe_load(rec_path.read_text())

    # Index checks by step index
    checks_by_step: dict[int, list[dict]] = {}
    for c in structural_checks:
        idx = c.get("after_step")
        if idx is None:
            print(f"WARN: structural_check missing after_step: {c}")
            continue
        checks_by_step.setdefault(idx, []).append(c)

    # Start a fresh session
    s = sdsession.start(udid=sim_id, app_bundle_id=app_bundle_id)
    time.sleep(2)
    out_dir = Path(f"/tmp/simdrive-struct-{journey_id}-{int(time.time())}")
    out_dir.mkdir(parents=True, exist_ok=True)

    fail_count = 0
    pass_count = 0
    try:
        for step in recording.get("steps", []):
            sid = step.get("id")
            if verbose:
                print(f"--- step {sid} ({step.get('action')}) ---")
            try:
                execute_step(s, step)
            except Exception as e:
                print(f"  [ERROR] step {sid} action failed: {e}")
                fail_count += 1
                continue
            time.sleep(1)
            # Run any checks pinned to this step
            for c in checks_by_step.get(sid, []):
                ob = sd_observe(udid=sim_id, out_dir=out_dir, annotate=True)
                # Mark dataclass uses slots — __dict__ drops stable_id. Use to_dict().
                marks = [m.to_dict() if hasattr(m, "to_dict") else m for m in ob.marks]
                ok, errors = verify_check(c, marks)
                if ok:
                    pass_count += 1
                    if verbose:
                        print(f"  [PASS] check after step {sid}: {len(marks)} marks visible")
                else:
                    fail_count += 1
                    print(f"  [FAIL] check after step {sid}:")
                    for e in errors:
                        print(f"           {e}")
    finally:
        sdsession.end(session_id=s.session_id, terminate_app=True)

    print(f"\n=== {journey_id} ===")
    print(f"  Structural checks: {pass_count} passed, {fail_count} failed")
    return 1 if fail_count else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--journey", required=True, help="Path to .simdrive/journeys/<id>.yaml")
    ap.add_argument("--sim-id", default=os.environ.get("SIMDRIVE_SIM_ID",
                    "DF4A2A27-9888-429D-A749-2E157A049A37"))
    ap.add_argument("--app", default="org.thepalaceproject.palace")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()
    return run(Path(args.journey), args.sim_id, args.app, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
