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
    
    # Get overall line coverage
    result['line_coverage'] = data.get('lineCoverage', 0.0) * 100
    result['covered_lines'] = data.get('coveredLines', 0)
    result['executable_lines'] = data.get('executableLines', 0)
    result['total_coverage'] = result['line_coverage']
    
    # Parse targets
    targets = data.get('targets', [])
    for target in targets:
        target_name = target.get('name', 'Unknown')
        target_coverage = target.get('lineCoverage', 0.0) * 100
        covered = target.get('coveredLines', 0)
        executable = target.get('executableLines', 0)
        
        result['targets'].append({
            'name': target_name,
            'coverage': target_coverage,
            'covered_lines': covered,
            'executable_lines': executable,
            'coverage_formatted': f"{target_coverage:.1f}%"
        })
        
        # Parse files in target
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
    
    # Sort targets by name
    result['targets'].sort(key=lambda t: t['name'])
    
    # Sort files by coverage (ascending - worst first)
    result['files'].sort(key=lambda f: f['coverage'])
    
    return result

def format_coverage_summary(coverage: Dict) -> str:
    """Generate human-readable coverage summary."""
    lines = []
    lines.append("=" * 60)
    lines.append("CODE COVERAGE REPORT")
    lines.append("=" * 60)
    lines.append(f"Overall Coverage: {coverage['total_coverage']:.1f}%")
    lines.append(f"Lines Covered: {coverage['covered_lines']} / {coverage['executable_lines']}")
    lines.append("")
    
    if coverage['targets']:
        lines.append("COVERAGE BY TARGET:")
        for target in coverage['targets']:
            bar = "█" * int(target['coverage'] / 5) + "░" * (20 - int(target['coverage'] / 5))
            lines.append(f"  {target['name']}: {target['coverage_formatted']} [{bar}]")
    
    lines.append("")
    lines.append("LOWEST COVERAGE FILES:")
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
        
        # Target summary for PR comment
        if coverage['targets']:
            f.write("coverage_targets<<EOF\n")
            for target in coverage['targets']:
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
