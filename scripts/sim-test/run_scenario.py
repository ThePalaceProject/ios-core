#!/usr/bin/env python3
"""
CLI entry point for running visual iOS Simulator tests via Claude.

Usage:
    python run_scenario.py scenarios/oidc_signin.yaml [--verbose] [--record]
    python run_scenario.py scenarios/oidc_signin.yaml --verbose --record --udid <UDID>
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

import yaml

from claude_tester import ClaudeTester, ScenarioResult
from sim_driver import SimDriver, SimulatorError


def load_scenario(path: str) -> dict:
    """Load a scenario YAML file and substitute environment variables."""
    with open(path, "r") as f:
        raw = f.read()

    # Substitute ${ENV_VAR} patterns with environment variable values
    def env_sub(match):
        var_name = match.group(1)
        value = os.environ.get(var_name)
        if value is None:
            print(f"WARNING: Environment variable ${{{var_name}}} is not set", file=sys.stderr)
            return match.group(0)  # Leave as-is
        return value

    substituted = re.sub(r"\$\{(\w+)\}", env_sub, raw)
    scenario = yaml.safe_load(substituted)
    return scenario


def setup_recording_dir(scenario_name: str) -> str:
    """Create a timestamped directory for recording screenshots."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_name = re.sub(r"[^\w\-]", "_", scenario_name)
    dir_name = f"{timestamp}_{safe_name}"
    record_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "recordings",
        dir_name,
    )
    os.makedirs(record_dir, exist_ok=True)
    return record_dir


def main():
    parser = argparse.ArgumentParser(
        description="Run visual iOS Simulator tests using Claude computer use",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python run_scenario.py scenarios/oidc_signin.yaml --verbose
  python run_scenario.py scenarios/oidc_signin.yaml --verbose --record
  python run_scenario.py scenarios/oidc_signin.yaml --udid DF4A2A27-9888-429D-A749-2E157A049A37

Environment variables:
  ANTHROPIC_API_KEY    Required. Your Anthropic API key.
  LYRASIS_EMAIL        For OIDC sign-in scenarios.
  LYRASIS_PASSWORD     For OIDC sign-in scenarios.
""",
    )
    parser.add_argument(
        "scenario",
        help="Path to a scenario YAML file",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Print detailed progress information",
    )
    parser.add_argument(
        "--record", "-r",
        action="store_true",
        help="Save all screenshots to a timestamped directory",
    )
    parser.add_argument(
        "--udid",
        default=None,
        help="Simulator UDID (default: iPhone 16 Pro from project config)",
    )
    parser.add_argument(
        "--max-iterations",
        type=int,
        default=40,
        help="Maximum API iterations before stopping (default: 40)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON only (no progress output)",
    )

    args = parser.parse_args()

    # Validate scenario file exists
    if not os.path.isfile(args.scenario):
        print(f"Error: Scenario file not found: {args.scenario}", file=sys.stderr)
        sys.exit(1)

    # Check for API key
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY environment variable is not set", file=sys.stderr)
        sys.exit(1)

    # Load scenario
    try:
        scenario = load_scenario(args.scenario)
    except Exception as e:
        print(f"Error loading scenario: {e}", file=sys.stderr)
        sys.exit(1)

    if args.verbose and not args.json:
        print(f"Loaded scenario: {scenario.get('name', 'Unknown')}")
        print(f"Steps: {len(scenario.get('steps', []))}")
        print(f"Success criteria: {len(scenario.get('success_criteria', []))}")

    # Set up recording directory if requested
    screenshot_dir = None
    if args.record:
        screenshot_dir = setup_recording_dir(scenario.get("name", "test"))
        if args.verbose and not args.json:
            print(f"Recording screenshots to: {screenshot_dir}")

    # Initialize simulator driver
    try:
        sim = SimDriver(udid=args.udid, verbose=args.verbose and not args.json)
    except Exception as e:
        print(f"Error initializing simulator: {e}", file=sys.stderr)
        sys.exit(1)

    # Initialize Claude tester
    tester = ClaudeTester(
        sim_driver=sim,
        verbose=args.verbose and not args.json,
        record_screenshots=args.record,
        screenshot_dir=screenshot_dir,
    )
    tester.MAX_ITERATIONS = args.max_iterations

    # Run the scenario
    try:
        result = tester.run_scenario(scenario)
    except SimulatorError as e:
        print(f"Simulator error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)

    # Copy screenshots to recording dir if recording
    if args.record and screenshot_dir and result.screenshots:
        for i, src_path in enumerate(result.screenshots):
            if os.path.isfile(src_path):
                dst = os.path.join(screenshot_dir, f"step_{i:03d}.png")
                shutil.copy2(src_path, dst)
        if not args.json:
            print(f"\nScreenshots saved to: {screenshot_dir}")

    # Output results
    output = result.to_dict()

    if args.json:
        print(json.dumps(output, indent=2))
    else:
        print("\n" + "=" * 60)
        print(f"SCENARIO: {output['name']}")
        print(f"RESULT:   {'PASSED' if output['success'] else 'FAILED'}")
        print(f"DURATION: {output['duration_seconds']}s")
        print(f"ITERATIONS: {output['total_iterations']}")
        if output['errors']:
            print(f"ERRORS: {len(output['errors'])}")
            for err in output['errors']:
                print(f"  - {err}")
        print("=" * 60)
        print("\nFinal Assessment:")
        print(output.get("final_assessment", "(none)")[:1000])
        print()

    # Exit with appropriate code
    sys.exit(0 if result.success else 1)


if __name__ == "__main__":
    main()
