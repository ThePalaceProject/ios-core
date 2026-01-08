#!/usr/bin/env python3
"""
Process snapshot test failures and generate comparison images.
Usage: python3 process-snapshots.py <snapshot-failures-dir> [--output <output-dir>]

Generates:
- Side-by-side comparison images
- JSON manifest of all failures
- Markdown summary
"""
import os
import sys
import json
import shutil
import subprocess
from pathlib import Path
from typing import Dict, List, Tuple, Optional

def find_snapshot_pairs(snapshot_dir: str) -> List[Dict]:
    """
    Find related snapshot files (reference, actual, diff).
    SnapshotTesting typically creates files like:
    - testName.reference.png (expected)
    - testName.actual.png (what was rendered)
    - testName.diff.png (difference overlay)
    """
    snapshot_path = Path(snapshot_dir)
    if not snapshot_path.exists():
        return []
    
    # Group files by test name
    files = list(snapshot_path.glob('*.png'))
    test_groups = {}
    
    for file in files:
        name = file.stem
        # Parse common naming patterns
        # Pattern 1: testName.reference.png, testName.actual.png
        # Pattern 2: testName_reference.png, testName_actual.png
        # Pattern 3: testName-reference.png, testName-actual.png
        
        test_name = name
        file_type = 'unknown'
        
        for sep in ['.', '_', '-']:
            for suffix in ['reference', 'expected', 'baseline']:
                if name.endswith(f'{sep}{suffix}'):
                    test_name = name[:-len(f'{sep}{suffix}')]
                    file_type = 'reference'
                    break
            for suffix in ['actual', 'failure', 'new']:
                if name.endswith(f'{sep}{suffix}'):
                    test_name = name[:-len(f'{sep}{suffix}')]
                    file_type = 'actual'
                    break
            for suffix in ['diff', 'difference']:
                if name.endswith(f'{sep}{suffix}'):
                    test_name = name[:-len(f'{sep}{suffix}')]
                    file_type = 'diff'
                    break
        
        if test_name not in test_groups:
            test_groups[test_name] = {
                'name': test_name,
                'reference': None,
                'actual': None,
                'diff': None,
                'files': []
            }
        
        test_groups[test_name]['files'].append(str(file))
        
        if file_type == 'reference':
            test_groups[test_name]['reference'] = str(file)
        elif file_type == 'actual':
            test_groups[test_name]['actual'] = str(file)
        elif file_type == 'diff':
            test_groups[test_name]['diff'] = str(file)
        elif test_groups[test_name]['actual'] is None:
            # Default: treat as actual if no other match
            test_groups[test_name]['actual'] = str(file)
    
    return list(test_groups.values())

def get_image_dimensions(image_path: str) -> Optional[Tuple[int, int]]:
    """Get image dimensions using sips (macOS) or file command."""
    try:
        # Try sips first (macOS)
        result = subprocess.run(
            ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', image_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            width = height = 0
            for line in result.stdout.split('\n'):
                if 'pixelWidth' in line:
                    width = int(line.split(':')[1].strip())
                elif 'pixelHeight' in line:
                    height = int(line.split(':')[1].strip())
            if width and height:
                return (width, height)
    except Exception:
        pass
    
    # Fallback: try file command
    try:
        result = subprocess.run(
            ['file', image_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            # Parse output like "image.png: PNG image data, 100 x 200, ..."
            import re
            match = re.search(r'(\d+)\s*x\s*(\d+)', result.stdout)
            if match:
                return (int(match.group(1)), int(match.group(2)))
    except Exception:
        pass
    
    return None

def create_comparison_html(snapshots: List[Dict], output_dir: str) -> str:
    """Generate an HTML file for viewing snapshot comparisons."""
    html_parts = ['''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Snapshot Test Failures</title>
    <style>
        :root {
            --bg-primary: #1a1a2e;
            --bg-secondary: #16213e;
            --text-primary: #eee;
            --text-secondary: #aaa;
            --accent: #e94560;
            --success: #4ecca3;
            --border: #333;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            padding: 20px;
            line-height: 1.6;
        }
        
        h1 {
            text-align: center;
            margin-bottom: 30px;
            color: var(--accent);
        }
        
        .summary {
            text-align: center;
            margin-bottom: 30px;
            padding: 20px;
            background: var(--bg-secondary);
            border-radius: 10px;
        }
        
        .snapshot-card {
            background: var(--bg-secondary);
            border-radius: 10px;
            margin-bottom: 30px;
            overflow: hidden;
        }
        
        .snapshot-header {
            padding: 15px 20px;
            background: rgba(233, 69, 96, 0.2);
            border-bottom: 1px solid var(--border);
        }
        
        .snapshot-header h2 {
            font-size: 1.2rem;
            color: var(--accent);
        }
        
        .comparison-container {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            padding: 20px;
        }
        
        .image-panel {
            text-align: center;
        }
        
        .image-panel h3 {
            margin-bottom: 10px;
            color: var(--text-secondary);
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .image-panel img {
            max-width: 100%;
            height: auto;
            border: 2px solid var(--border);
            border-radius: 5px;
            background: #fff;
        }
        
        .image-panel.reference h3 { color: var(--success); }
        .image-panel.actual h3 { color: var(--accent); }
        .image-panel.diff h3 { color: #f39c12; }
        
        .no-image {
            padding: 40px;
            background: var(--bg-primary);
            border-radius: 5px;
            color: var(--text-secondary);
        }
        
        .file-list {
            padding: 15px 20px;
            background: rgba(0,0,0,0.2);
            font-size: 0.85rem;
            color: var(--text-secondary);
        }
        
        .file-list code {
            background: var(--bg-primary);
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 0.8rem;
        }
    </style>
</head>
<body>
    <h1>📸 Snapshot Test Failures</h1>
''']
    
    html_parts.append(f'<div class="summary"><strong>{len(snapshots)}</strong> snapshot failure(s) detected</div>')
    
    for snapshot in snapshots:
        html_parts.append(f'''
    <div class="snapshot-card">
        <div class="snapshot-header">
            <h2>❌ {snapshot['name']}</h2>
        </div>
        <div class="comparison-container">
''')
        
        # Reference image
        if snapshot.get('reference'):
            ref_file = os.path.basename(snapshot['reference'])
            html_parts.append(f'''
            <div class="image-panel reference">
                <h3>Expected (Reference)</h3>
                <img src="{ref_file}" alt="Reference">
            </div>
''')
        
        # Actual image
        if snapshot.get('actual'):
            actual_file = os.path.basename(snapshot['actual'])
            html_parts.append(f'''
            <div class="image-panel actual">
                <h3>Actual (Failed)</h3>
                <img src="{actual_file}" alt="Actual">
            </div>
''')
        
        # Diff image
        if snapshot.get('diff'):
            diff_file = os.path.basename(snapshot['diff'])
            html_parts.append(f'''
            <div class="image-panel diff">
                <h3>Difference</h3>
                <img src="{diff_file}" alt="Diff">
            </div>
''')
        
        # If we only have a single file
        if not snapshot.get('reference') and not snapshot.get('diff') and snapshot.get('files'):
            for f in snapshot['files']:
                file_name = os.path.basename(f)
                html_parts.append(f'''
            <div class="image-panel">
                <h3>Snapshot</h3>
                <img src="{file_name}" alt="Snapshot">
            </div>
''')
        
        html_parts.append('''
        </div>
        <div class="file-list">
            Files: ''')
        
        html_parts.append(', '.join([f'<code>{os.path.basename(f)}</code>' for f in snapshot.get('files', [])]))
        
        html_parts.append('''
        </div>
    </div>
''')
    
    html_parts.append('''
</body>
</html>
''')
    
    return ''.join(html_parts)

def generate_markdown_summary(snapshots: List[Dict]) -> str:
    """Generate Markdown summary of snapshot failures."""
    lines = [
        "# 📸 Snapshot Test Failures",
        "",
        f"**{len(snapshots)} failure(s) detected**",
        "",
        "## Failures",
        ""
    ]
    
    for snapshot in snapshots:
        lines.append(f"### ❌ {snapshot['name']}")
        lines.append("")
        
        if snapshot.get('reference'):
            lines.append(f"- Reference: `{os.path.basename(snapshot['reference'])}`")
        if snapshot.get('actual'):
            lines.append(f"- Actual: `{os.path.basename(snapshot['actual'])}`")
        if snapshot.get('diff'):
            lines.append(f"- Diff: `{os.path.basename(snapshot['diff'])}`")
        
        lines.append("")
    
    lines.append("---")
    lines.append("")
    lines.append("Open `snapshot-viewer.html` in a browser for visual comparison.")
    
    return "\n".join(lines)

def main():
    if len(sys.argv) < 2:
        print("Usage: process-snapshots.py <snapshot-failures-dir> [--output <output-dir>]", file=sys.stderr)
        sys.exit(1)
    
    snapshot_dir = sys.argv[1]
    output_dir = snapshot_dir  # Default to same directory
    
    if '--output' in sys.argv:
        idx = sys.argv.index('--output')
        if idx + 1 < len(sys.argv):
            output_dir = sys.argv[idx + 1]
    
    if not os.path.exists(snapshot_dir):
        print(f"Directory not found: {snapshot_dir}", file=sys.stderr)
        sys.exit(1)
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Find snapshot pairs
    print(f"Scanning: {snapshot_dir}", file=sys.stderr)
    snapshots = find_snapshot_pairs(snapshot_dir)
    
    print(f"Found {len(snapshots)} snapshot failure(s)", file=sys.stderr)
    
    if not snapshots:
        print("No snapshots to process", file=sys.stderr)
        sys.exit(0)
    
    # Copy all snapshot files to output directory if different
    if output_dir != snapshot_dir:
        for snapshot in snapshots:
            for f in snapshot.get('files', []):
                if os.path.exists(f):
                    shutil.copy2(f, output_dir)
    
    # Generate HTML viewer
    html_content = create_comparison_html(snapshots, output_dir)
    html_path = os.path.join(output_dir, 'snapshot-viewer.html')
    with open(html_path, 'w') as f:
        f.write(html_content)
    print(f"Generated: {html_path}", file=sys.stderr)
    
    # Generate Markdown summary
    md_content = generate_markdown_summary(snapshots)
    md_path = os.path.join(output_dir, 'SNAPSHOTS.md')
    with open(md_path, 'w') as f:
        f.write(md_content)
    print(f"Generated: {md_path}", file=sys.stderr)
    
    # Generate JSON manifest
    manifest = {
        'count': len(snapshots),
        'snapshots': snapshots
    }
    json_path = os.path.join(output_dir, 'snapshots.json')
    with open(json_path, 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"Generated: {json_path}", file=sys.stderr)
    
    # Output summary
    print("", file=sys.stderr)
    print("=" * 50, file=sys.stderr)
    print(f"SNAPSHOT FAILURES: {len(snapshots)}", file=sys.stderr)
    for s in snapshots:
        print(f"  ❌ {s['name']}", file=sys.stderr)
    print("=" * 50, file=sys.stderr)

if __name__ == '__main__':
    main()
