#!/usr/bin/env python3
"""
Parse code coverage data from xcresult bundle.
Usage: python3 coverage-report.py <path-to-xcresult> [--json <output.json>]

Outputs coverage metrics to GITHUB_OUTPUT and optionally a JSON file.
"""
import json
import subprocess
import sys
import os
import re
from typing import Dict, List, Any, Optional

def run_command(cmd: List[str], timeout: int = 120) -> Optional[str]:
    """Run a command and return stdout."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode == 0:
            return result.stdout
        else:
            print(f"Command failed: {' '.join(cmd)}", file=sys.stderr)
            print(f"stderr: {result.stderr}", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print(f"Command timed out: {' '.join(cmd)}", file=sys.stderr)
    except Exception as e:
        print(f"Error running command: {e}", file=sys.stderr)
    return None

def get_coverage_from_xcresult(xcresult_path: str) -> Optional[Dict]:
    """Extract coverage data from xcresult using xccov."""
    # First, try to get coverage report using xccov
    cmd = ['xcrun', 'xccov', 'view', '--report', '--json', xcresult_path]
    output = run_command(cmd)
    
    if output:
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            print("Failed to parse xccov JSON output", file=sys.stderr)
    
    return None

def extract_value(obj: Any, *keys) -> Any:
    """Safely extract nested value."""
    for key in keys:
        if isinstance(obj, dict):
            obj = obj.get(key, {})
        else:
            return None
    return obj if obj else None

def parse_coverage_data(data: Dict) -> Dict:
    """Parse coverage JSON into simplified structure."""
    result = {
        'total_coverage': 0.0,
        'line_coverage': 0.0,
        'covered_lines': 0,
        'executable_lines': 0,
        'targets': [],
        'files': []
    }
    
    if not data:
        return result
    
    # Parse targets - we'll calculate coverage from app target only
    targets = data.get('targets', [])
    
    # Filter to only include main app target(s), exclude:
    # - Test targets (ends with Tests)
    # - SPM packages (usually have reverse-DNS names or are third-party)
    # - Framework targets we don't own
    APP_TARGETS = ['Palace']  # Add other app targets if needed
    EXCLUDED_PATTERNS = [
        'Tests',           # Test targets
        'Mock',            # Mock targets
        '.build',          # SPM build artifacts
        'SourcePackages',  # SPM packages
        'Pods',            # CocoaPods
        'Carthage',        # Carthage
    ]
    
    def should_include_target(name: str) -> bool:
        """Check if target should be included in coverage calculation."""
        # First check exclusions - if it matches any exclusion pattern, skip it
        for pattern in EXCLUDED_PATTERNS:
            if pattern in name:
                return False
        
        # Include if it's an explicit app target
        if name in APP_TARGETS:
            return True
        
        # Include Palace-prefixed targets (like PalaceAudiobooks) but not Tests
        if name.startswith('Palace') and not name.endswith('Tests'):
            return True
        
        # Include targets containing "Palace" (case-insensitive) but not tests/mocks
        name_lower = name.lower()
        if 'palace' in name_lower and 'test' not in name_lower and 'mock' not in name_lower:
            return True
        
        return False
    
    # Calculate coverage from filtered targets only
    total_covered = 0
    total_executable = 0
    included_targets = []
    excluded_targets = []
    
    for target in targets:
        target_name = target.get('name', 'Unknown')
        target_coverage = target.get('lineCoverage', 0.0) * 100
        covered = target.get('coveredLines', 0)
        executable = target.get('executableLines', 0)
        
        # Check if this target should be included
        include_in_total = should_include_target(target_name)
        
        if include_in_total:
            total_covered += covered
            total_executable += executable
            included_targets.append(f"{target_name}: {covered}/{executable} lines ({target_coverage:.1f}%)")
        else:
            excluded_targets.append(target_name)
    
    # Debug output
    print(f"\n=== Coverage Target Analysis ===", file=sys.stderr)
    print(f"Total targets in report: {len(targets)}", file=sys.stderr)
    print(f"Included targets ({len(included_targets)}):", file=sys.stderr)
    for t in included_targets:
        print(f"  ✓ {t}", file=sys.stderr)
    print(f"Excluded targets ({len(excluded_targets)}): {', '.join(excluded_targets[:10])}", file=sys.stderr)
    if len(excluded_targets) > 10:
        print(f"  ... and {len(excluded_targets) - 10} more", file=sys.stderr)
    print(f"=================================\n", file=sys.stderr)
        
        result['targets'].append({
            'name': target_name,
            'coverage': target_coverage,
            'covered_lines': covered,
            'executable_lines': executable,
            'coverage_formatted': f"{target_coverage:.1f}%",
            'included_in_total': include_in_total
        })
        
        # Parse files in target (only for included targets)
        if include_in_total:
            files = target.get('files', [])
            for file_data in files:
                file_name = file_data.get('name', 'Unknown')
                file_path = file_data.get('path', '')
                file_coverage = file_data.get('lineCoverage', 0.0) * 100
                file_covered = file_data.get('coveredLines', 0)
                file_executable = file_data.get('executableLines', 0)
                
                # Skip files with no executable lines
                if file_executable == 0:
                    continue
                
                result['files'].append({
                    'name': file_name,
                    'path': file_path,
                    'target': target_name,
                    'coverage': file_coverage,
                    'covered_lines': file_covered,
                    'executable_lines': file_executable,
                    'coverage_formatted': f"{file_coverage:.1f}%"
                })
    
    # Calculate total coverage from filtered targets
    if total_executable > 0:
        result['line_coverage'] = (total_covered / total_executable) * 100
    else:
        result['line_coverage'] = 0.0
    
    result['covered_lines'] = total_covered
    result['executable_lines'] = total_executable
    result['total_coverage'] = result['line_coverage']
    
    # Sort targets by name, showing included targets first
    result['targets'].sort(key=lambda t: (not t.get('included_in_total', False), t['name']))
    
    # Sort files by coverage (ascending - worst first)
    result['files'].sort(key=lambda f: f['coverage'])
    
    return result

def format_coverage_summary(coverage: Dict) -> str:
    """Generate human-readable coverage summary."""
    lines = []
    lines.append("=" * 60)
    lines.append("CODE COVERAGE REPORT")
    lines.append("=" * 60)
    lines.append(f"Palace App Coverage: {coverage['total_coverage']:.1f}%")
    lines.append(f"Lines Covered: {coverage['covered_lines']} / {coverage['executable_lines']}")
    lines.append("")
    
    if coverage['targets']:
        # Separate included vs excluded targets
        included = [t for t in coverage['targets'] if t.get('included_in_total', False)]
        excluded = [t for t in coverage['targets'] if not t.get('included_in_total', False)]
        
        if included:
            lines.append("INCLUDED TARGETS (counted in coverage):")
            for target in included:
                bar = "█" * int(target['coverage'] / 5) + "░" * (20 - int(target['coverage'] / 5))
                lines.append(f"  ✓ {target['name']}: {target['coverage_formatted']} [{bar}]")
                lines.append(f"      ({target['covered_lines']} / {target['executable_lines']} lines)")
        
        if excluded:
            lines.append("")
            lines.append(f"EXCLUDED TARGETS ({len(excluded)} third-party/test targets not counted):")
            for target in excluded[:5]:  # Show first 5
                lines.append(f"  ✗ {target['name']}: {target['coverage_formatted']}")
            if len(excluded) > 5:
                lines.append(f"  ... and {len(excluded) - 5} more")
    
    lines.append("")
    lines.append("LOWEST COVERAGE FILES (Palace only):")
    for file_data in coverage['files'][:10]:
        lines.append(f"  {file_data['coverage_formatted']:>6} - {file_data['name']}")
    
    lines.append("=" * 60)
    return "\n".join(lines)

def output_github_actions(coverage: Dict, output_file: str):
    """Write coverage results in GitHub Actions output format."""
    with open(output_file, 'a') as f:
        f.write(f"coverage={coverage['total_coverage']:.1f}\n")
        f.write(f"coverage_formatted={coverage['total_coverage']:.1f}%\n")
        f.write(f"covered_lines={coverage['covered_lines']}\n")
        f.write(f"executable_lines={coverage['executable_lines']}\n")
        
        # Target summary for PR comment - only show included targets
        included_targets = [t for t in coverage['targets'] if t.get('included_in_total', False)]
        if included_targets:
            f.write("coverage_targets<<EOF\n")
            for target in included_targets:
                f.write(f"{target['name']}|{target['coverage_formatted']}|{target['covered_lines']}|{target['executable_lines']}\n")
            f.write("EOF\n")

def main():
    if len(sys.argv) < 2:
        print("Usage: coverage-report.py <path-to-xcresult> [--json <output.json>]", file=sys.stderr)
        sys.exit(1)
    
    xcresult_path = sys.argv[1]
    json_output_path = None
    
    # Parse arguments
    if '--json' in sys.argv:
        json_idx = sys.argv.index('--json')
        if json_idx + 1 < len(sys.argv):
            json_output_path = sys.argv[json_idx + 1]
    
    if not json_output_path:
        json_output_path = 'coverage-data.json'
    
    if not os.path.exists(xcresult_path):
        print(f"Error: {xcresult_path} not found", file=sys.stderr)
        sys.exit(1)
    
    print(f"Extracting coverage from: {xcresult_path}", file=sys.stderr)
    
    # Get coverage data
    raw_coverage = get_coverage_from_xcresult(xcresult_path)
    
    if not raw_coverage:
        print("Warning: Could not extract coverage data", file=sys.stderr)
        coverage = {
            'total_coverage': 0.0,
            'line_coverage': 0.0,
            'covered_lines': 0,
            'executable_lines': 0,
            'targets': [],
            'files': []
        }
    else:
        coverage = parse_coverage_data(raw_coverage)
    
    # Print summary
    print(format_coverage_summary(coverage), file=sys.stderr)
    
    # Output to GitHub Actions if available
    github_output = os.environ.get('GITHUB_OUTPUT', '')
    if github_output:
        output_github_actions(coverage, github_output)
        print(f"Wrote GitHub Actions output", file=sys.stderr)
    
    # Write JSON
    with open(json_output_path, 'w') as f:
        json.dump(coverage, f, indent=2)
    print(f"Wrote coverage data to: {json_output_path}", file=sys.stderr)

if __name__ == '__main__':
    main()
