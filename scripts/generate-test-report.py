#!/usr/bin/env python3
"""
Generate a detailed Markdown test report from test-data.json.
Usage: python3 generate-test-report.py <test-data.json> <output.md> [options]

Options:
  --commit SHA        Git commit SHA
  --branch NAME       Branch name
  --snapshot-count N  Number of snapshot failures
"""
import json
import sys
import os
from datetime import datetime, timezone
from typing import Dict, Any

def load_test_data(json_path: str) -> Dict[str, Any]:
    """Load test data from JSON file."""
    try:
        with open(json_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading {json_path}: {e}", file=sys.stderr)
        return {}

def generate_report(data: Dict[str, Any], commit: str = "", branch: str = "", snapshot_count: int = 0) -> str:
    """Generate Markdown report from test data."""
    lines = []
    
    # Header
    lines.append("# 🧪 Palace iOS Unit Test Results")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    if commit:
        lines.append(f"**Commit:** `{commit[:12]}`")
    if branch:
        lines.append(f"**Branch:** `{branch}`")
    lines.append("")
    
    summary = data.get('summary', {})
    tests = summary.get('tests', 0)
    passed = summary.get('passed', 0)
    failed = summary.get('failed', 0)
    skipped = summary.get('skipped', 0)
    duration = summary.get('duration_formatted', 'unknown')
    pass_rate = summary.get('pass_rate', 'N/A')
    
    # Get build info
    build_info = data.get('build', {})
    build_status = build_info.get('status', 'unknown')
    build_errors = build_info.get('errors', [])
    
    # Summary Section
    lines.append("## Summary")
    lines.append("")
    
    if build_status == 'failed':
        lines.append("### 🔴 BUILD FAILED")
        lines.append("")
        lines.append("The build failed before tests could run.")
        lines.append("")
        
        if build_errors:
            lines.append("### Build Errors")
            lines.append("")
            lines.append("```")
            for error in build_errors[:10]:
                # Truncate long errors
                error_text = error[:300] + "..." if len(error) > 300 else error
                lines.append(error_text)
            if len(build_errors) > 10:
                lines.append(f"... and {len(build_errors) - 10} more errors")
            lines.append("```")
            lines.append("")
    elif tests > 0:
        if failed == 0:
            lines.append("### ✅ ALL TESTS PASSED")
        else:
            lines.append(f"### ❌ {failed} TEST{'S' if failed != 1 else ''} FAILED")
        lines.append("")
        
        # Stats table
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append(f"| **Total Tests** | {tests} |")
        lines.append(f"| **Passed** | {passed} ✓ |")
        lines.append(f"| **Failed** | {failed} ✗ |")
        if skipped > 0:
            lines.append(f"| **Skipped** | {skipped} ⊘ |")
        lines.append(f"| **Duration** | {duration} |")
        lines.append(f"| **Pass Rate** | {pass_rate} |")
        lines.append("")
    else:
        lines.append("_No test results available_")
        if build_errors:
            lines.append("")
            lines.append("### Build Errors")
            lines.append("")
            lines.append("```")
            for error in build_errors[:10]:
                error_text = error[:300] + "..." if len(error) > 300 else error
                lines.append(error_text)
            lines.append("```")
        lines.append("")
    
    # Tests by Class
    classes = data.get('classes', {})
    if classes:
        lines.append("## Tests by Class")
        lines.append("")
        lines.append("| Status | Class | Tests | Passed | Failed | Duration |")
        lines.append("|--------|-------|-------|--------|--------|----------|")
        
        for class_name, class_data in sorted(classes.items()):
            stats = class_data.get('stats', {})
            total = stats.get('total', 0)
            cls_passed = stats.get('passed', 0)
            cls_failed = stats.get('failed', 0)
            cls_duration = stats.get('duration_formatted', '-')
            
            status = "✅" if cls_failed == 0 else "❌"
            failed_cell = f"**{cls_failed}**" if cls_failed > 0 else "0"
            
            lines.append(f"| {status} | {class_name} | {total} | {cls_passed} | {failed_cell} | {cls_duration} |")
        lines.append("")
    
    # Failed Tests Details
    failed_tests = data.get('failed_tests', [])
    if failed_tests:
        lines.append("## Failed Tests")
        lines.append("")
        
        for test in failed_tests:
            test_class = test.get('class', 'Unknown')
            test_method = test.get('method', test.get('name', 'Unknown'))
            test_duration = test.get('duration_formatted', '-')
            
            lines.append(f"### ❌ {test_class}.{test_method}")
            lines.append("")
            lines.append(f"- **Duration:** {test_duration}")
            
            failures = test.get('failures', [])
            if failures:
                for failure in failures[:3]:  # Show up to 3 failure messages
                    message = failure.get('message', '')
                    file_name = failure.get('file', '')
                    line_num = failure.get('line', '')
                    
                    if message:
                        # Truncate long messages
                        if len(message) > 500:
                            message = message[:500] + "..."
                        lines.append(f"- **Error:** {message}")
                    if file_name and line_num:
                        lines.append(f"- **Location:** `{file_name}:{line_num}`")
            lines.append("")
    
    # All Tests (Expandable)
    all_tests = data.get('tests', [])
    if all_tests and len(all_tests) <= 200:  # Only show if reasonable number
        lines.append("## All Tests")
        lines.append("")
        lines.append("<details>")
        lines.append("<summary>Click to expand full test list</summary>")
        lines.append("")
        lines.append("| Status | Class | Test | Duration |")
        lines.append("|--------|-------|------|----------|")
        
        for test in sorted(all_tests, key=lambda t: (t.get('class', ''), t.get('name', ''))):
            status_icon = {
                'Success': '✅',
                'Failure': '❌',
                'Skipped': '⊘'
            }.get(test.get('status', ''), '❓')
            
            lines.append(f"| {status_icon} | {test.get('class', '-')} | {test.get('method', test.get('name', '-'))} | {test.get('duration_formatted', '-')} |")
        
        lines.append("")
        lines.append("</details>")
        lines.append("")
    
    # Snapshot Failures
    if snapshot_count and int(snapshot_count) > 0:
        lines.append(f"## 📸 Snapshot Failures ({snapshot_count})")
        lines.append("")
        lines.append("Download the **snapshot-failures** artifact to view visual difference images.")
        lines.append("")
    
    # Artifacts Section
    lines.append("---")
    lines.append("")
    lines.append("## 📦 Artifacts")
    lines.append("")
    lines.append("| Artifact | Description |")
    lines.append("|----------|-------------|")
    lines.append("| **test-results** | Full `.xcresult` bundle - open in Xcode for detailed analysis |")
    lines.append("| **test-report** | This Markdown report |")
    lines.append("| **test-data** | JSON data file for custom tooling |")
    if snapshot_count and int(snapshot_count) > 0:
        lines.append("| **snapshot-failures** | PNG images showing visual differences |")
    lines.append("")
    
    # How to use
    lines.append("### How to View in Xcode")
    lines.append("")
    lines.append("1. Download the **test-results** artifact")
    lines.append("2. Unzip the downloaded file")
    lines.append("3. Double-click the `.xcresult` bundle to open in Xcode")
    lines.append("4. Navigate to failed tests to see stack traces and failure details")
    lines.append("")
    
    return "\n".join(lines)

def main():
    if len(sys.argv) < 3:
        print("Usage: generate-test-report.py <test-data.json> <output.md> [options]", file=sys.stderr)
        sys.exit(1)
    
    json_path = sys.argv[1]
    output_path = sys.argv[2]
    
    # Parse optional arguments
    commit = ""
    branch = ""
    snapshot_count = 0
    
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == '--commit' and i + 1 < len(sys.argv):
            commit = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == '--branch' and i + 1 < len(sys.argv):
            branch = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == '--snapshot-count' and i + 1 < len(sys.argv):
            try:
                snapshot_count = int(sys.argv[i + 1])
            except ValueError:
                pass
            i += 2
        else:
            i += 1
    
    # Load data
    data = load_test_data(json_path)
    
    if not data:
        # Create minimal report
        data = {'summary': {'tests': 0}, 'tests': [], 'classes': {}}
    
    # Generate report
    report = generate_report(data, commit, branch, snapshot_count)
    
    # Write output
    os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)
    with open(output_path, 'w') as f:
        f.write(report)
    
    print(f"Generated report: {output_path}", file=sys.stderr)

if __name__ == '__main__':
    main()
