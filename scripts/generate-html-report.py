#!/usr/bin/env python3
"""
Generate an interactive HTML test report from test-data.json and coverage-data.json.
Usage: python3 generate-html-report.py <test-data.json> <output.html> [options]

Options:
  --coverage <coverage-data.json>   Include coverage data
  --commit SHA                      Git commit SHA
  --branch NAME                     Branch name
"""
import json
import sys
import os
from datetime import datetime
from typing import Dict, Any, Optional
import html

def load_json(path: str) -> Optional[Dict]:
    """Load JSON file safely."""
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading {path}: {e}", file=sys.stderr)
        return None

def escape(text: str) -> str:
    """HTML escape text."""
    return html.escape(str(text)) if text else ""

def generate_html_report(
    test_data: Dict,
    coverage_data: Optional[Dict] = None,
    commit: str = "",
    branch: str = ""
) -> str:
    """Generate interactive HTML report."""
    
    summary = test_data.get('summary', {})
    classes = test_data.get('classes', {})
    all_tests = test_data.get('tests', [])
    failed_tests = test_data.get('failed_tests', [])
    
    tests_count = summary.get('tests', 0)
    passed_count = summary.get('passed', 0)
    failed_count = summary.get('failed', 0)
    skipped_count = summary.get('skipped', 0)
    duration = summary.get('duration_formatted', 'N/A')
    pass_rate = summary.get('pass_rate', 'N/A')
    
    # Coverage info
    coverage_percent = "N/A"
    coverage_targets = []
    if coverage_data:
        coverage_percent = f"{coverage_data.get('total_coverage', 0):.1f}%"
        coverage_targets = coverage_data.get('targets', [])
    
    status_class = "success" if failed_count == 0 else "failure"
    status_icon = "✅" if failed_count == 0 else "❌"
    status_text = "ALL TESTS PASSED" if failed_count == 0 else f"{failed_count} TEST(S) FAILED"
    
    # Generate test rows HTML
    test_rows = []
    for test in sorted(all_tests, key=lambda t: (t.get('class', ''), t.get('name', ''))):
        status = test.get('status', 'Unknown')
        status_icon_small = {'Success': '✅', 'Failure': '❌', 'Skipped': '⊘'}.get(status, '❓')
        status_class_small = {'Success': 'passed', 'Failure': 'failed', 'Skipped': 'skipped'}.get(status, '')
        
        test_rows.append(f'''
            <tr class="test-row {status_class_small}" data-class="{escape(test.get('class', ''))}" data-status="{status.lower()}">
                <td class="status-cell">{status_icon_small}</td>
                <td>{escape(test.get('class', '-'))}</td>
                <td>{escape(test.get('method', test.get('name', '-')))}</td>
                <td>{escape(test.get('duration_formatted', '-'))}</td>
            </tr>''')
    
    # Generate class rows HTML
    class_rows = []
    for class_name, class_data in sorted(classes.items()):
        stats = class_data.get('stats', {})
        cls_failed = stats.get('failed', 0)
        cls_icon = "✅" if cls_failed == 0 else "❌"
        cls_class = "passed" if cls_failed == 0 else "failed"
        
        class_rows.append(f'''
            <tr class="class-row {cls_class}">
                <td class="status-cell">{cls_icon}</td>
                <td><strong>{escape(class_name)}</strong></td>
                <td>{stats.get('total', 0)}</td>
                <td class="passed-cell">{stats.get('passed', 0)}</td>
                <td class="failed-cell">{stats.get('failed', 0)}</td>
                <td>{escape(stats.get('duration_formatted', '-'))}</td>
            </tr>''')
    
    # Generate failed test details
    failed_details = []
    for test in failed_tests:
        failures_html = ""
        for failure in test.get('failures', [])[:3]:
            msg = escape(failure.get('message', ''))[:500]
            loc = f"{failure.get('file', '')}:{failure.get('line', '')}" if failure.get('file') else ""
            failures_html += f'''
                <div class="failure-message">
                    <p>{msg}</p>
                    {f'<code>{escape(loc)}</code>' if loc else ''}
                </div>'''
        
        failed_details.append(f'''
            <div class="failed-test-card">
                <h4>❌ {escape(test.get('class', ''))}.{escape(test.get('method', test.get('name', '')))}</h4>
                <p class="duration">Duration: {escape(test.get('duration_formatted', '-'))}</p>
                {failures_html}
            </div>''')
    
    # Coverage rows
    coverage_rows = []
    for target in coverage_targets:
        cov = target.get('coverage', 0)
        bar_width = min(100, max(0, cov))
        bar_color = "#4ecca3" if cov >= 70 else "#f39c12" if cov >= 50 else "#e94560"
        
        coverage_rows.append(f'''
            <tr>
                <td>{escape(target.get('name', '-'))}</td>
                <td>
                    <div class="coverage-bar-container">
                        <div class="coverage-bar" style="width: {bar_width}%; background: {bar_color};"></div>
                        <span class="coverage-text">{target.get('coverage_formatted', '-')}</span>
                    </div>
                </td>
                <td>{target.get('covered_lines', 0)} / {target.get('executable_lines', 0)}</td>
            </tr>''')

    html_content = f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Palace iOS Test Report</title>
    <style>
        :root {{
            --bg-primary: #0d1117;
            --bg-secondary: #161b22;
            --bg-tertiary: #21262d;
            --text-primary: #f0f6fc;
            --text-secondary: #8b949e;
            --border: #30363d;
            --success: #3fb950;
            --failure: #f85149;
            --warning: #d29922;
            --info: #58a6ff;
            --accent: #7c3aed;
        }}
        
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
        }}
        
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
        }}
        
        /* Header */
        .header {{
            text-align: center;
            padding: 40px 20px;
            background: linear-gradient(135deg, var(--bg-secondary) 0%, var(--bg-tertiary) 100%);
            border-bottom: 1px solid var(--border);
            margin-bottom: 30px;
        }}
        
        .header h1 {{
            font-size: 2.5rem;
            margin-bottom: 10px;
            background: linear-gradient(135deg, var(--info) 0%, var(--accent) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }}
        
        .meta {{
            color: var(--text-secondary);
            font-size: 0.9rem;
        }}
        
        .meta code {{
            background: var(--bg-tertiary);
            padding: 2px 8px;
            border-radius: 4px;
            font-family: 'SF Mono', Monaco, monospace;
        }}
        
        /* Status Banner */
        .status-banner {{
            padding: 30px;
            border-radius: 12px;
            margin-bottom: 30px;
            text-align: center;
        }}
        
        .status-banner.success {{
            background: linear-gradient(135deg, rgba(63, 185, 80, 0.15) 0%, rgba(63, 185, 80, 0.05) 100%);
            border: 1px solid var(--success);
        }}
        
        .status-banner.failure {{
            background: linear-gradient(135deg, rgba(248, 81, 73, 0.15) 0%, rgba(248, 81, 73, 0.05) 100%);
            border: 1px solid var(--failure);
        }}
        
        .status-banner h2 {{
            font-size: 1.8rem;
            margin-bottom: 15px;
        }}
        
        .status-banner.success h2 {{ color: var(--success); }}
        .status-banner.failure h2 {{ color: var(--failure); }}
        
        /* Stats Grid */
        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }}
        
        .stat-card {{
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 20px;
            text-align: center;
        }}
        
        .stat-card .value {{
            font-size: 2rem;
            font-weight: 700;
        }}
        
        .stat-card .label {{
            color: var(--text-secondary);
            font-size: 0.85rem;
            text-transform: uppercase;
            letter-spacing: 1px;
        }}
        
        .stat-card.passed .value {{ color: var(--success); }}
        .stat-card.failed .value {{ color: var(--failure); }}
        .stat-card.coverage .value {{ color: var(--info); }}
        
        /* Sections */
        .section {{
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            margin-bottom: 30px;
            overflow: hidden;
        }}
        
        .section-header {{
            padding: 15px 20px;
            background: var(--bg-tertiary);
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        
        .section-header h3 {{
            font-size: 1.1rem;
        }}
        
        .section-content {{
            padding: 20px;
        }}
        
        /* Tables */
        table {{
            width: 100%;
            border-collapse: collapse;
        }}
        
        th, td {{
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }}
        
        th {{
            background: var(--bg-tertiary);
            color: var(--text-secondary);
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 1px;
        }}
        
        tr:hover {{
            background: var(--bg-tertiary);
        }}
        
        .status-cell {{
            width: 40px;
            text-align: center;
        }}
        
        .passed-cell {{ color: var(--success); }}
        .failed-cell {{ color: var(--failure); }}
        
        tr.failed {{ background: rgba(248, 81, 73, 0.1); }}
        tr.passed {{ }}
        
        /* Filter/Search */
        .filters {{
            display: flex;
            gap: 15px;
            margin-bottom: 15px;
            flex-wrap: wrap;
        }}
        
        .filter-input {{
            flex: 1;
            min-width: 200px;
            padding: 10px 15px;
            background: var(--bg-tertiary);
            border: 1px solid var(--border);
            border-radius: 6px;
            color: var(--text-primary);
            font-size: 0.95rem;
        }}
        
        .filter-input:focus {{
            outline: none;
            border-color: var(--info);
        }}
        
        .filter-btn {{
            padding: 10px 20px;
            background: var(--bg-tertiary);
            border: 1px solid var(--border);
            border-radius: 6px;
            color: var(--text-primary);
            cursor: pointer;
            transition: all 0.2s;
        }}
        
        .filter-btn:hover, .filter-btn.active {{
            background: var(--info);
            border-color: var(--info);
        }}
        
        /* Failed Tests */
        .failed-test-card {{
            background: var(--bg-tertiary);
            border: 1px solid var(--failure);
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 15px;
        }}
        
        .failed-test-card h4 {{
            color: var(--failure);
            margin-bottom: 10px;
        }}
        
        .failed-test-card .duration {{
            color: var(--text-secondary);
            font-size: 0.85rem;
            margin-bottom: 10px;
        }}
        
        .failure-message {{
            background: var(--bg-primary);
            padding: 10px;
            border-radius: 4px;
            margin-top: 10px;
            font-family: 'SF Mono', Monaco, monospace;
            font-size: 0.85rem;
            overflow-x: auto;
        }}
        
        .failure-message code {{
            display: block;
            margin-top: 5px;
            color: var(--info);
        }}
        
        /* Coverage */
        .coverage-bar-container {{
            position: relative;
            height: 24px;
            background: var(--bg-tertiary);
            border-radius: 4px;
            overflow: hidden;
        }}
        
        .coverage-bar {{
            height: 100%;
            transition: width 0.3s;
        }}
        
        .coverage-text {{
            position: absolute;
            right: 10px;
            top: 50%;
            transform: translateY(-50%);
            font-weight: 600;
            font-size: 0.85rem;
        }}
        
        /* Dark mode toggle */
        .theme-toggle {{
            position: fixed;
            top: 20px;
            right: 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 10px;
            cursor: pointer;
            font-size: 1.2rem;
        }}
        
        /* Responsive */
        @media (max-width: 768px) {{
            .header h1 {{ font-size: 1.8rem; }}
            .stats-grid {{ grid-template-columns: repeat(2, 1fr); }}
            th, td {{ padding: 8px 10px; font-size: 0.85rem; }}
        }}
    </style>
</head>
<body>
    <div class="header">
        <h1>🧪 Palace iOS Test Report</h1>
        <p class="meta">
            Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}
            {f' | Commit: <code>{commit[:12]}</code>' if commit else ''}
            {f' | Branch: <code>{branch}</code>' if branch else ''}
        </p>
    </div>
    
    <div class="container">
        <div class="status-banner {status_class}">
            <h2>{status_icon} {status_text}</h2>
            <p>{tests_count} tests completed in {duration}</p>
        </div>
        
        <div class="stats-grid">
            <div class="stat-card">
                <div class="value">{tests_count}</div>
                <div class="label">Total Tests</div>
            </div>
            <div class="stat-card passed">
                <div class="value">{passed_count}</div>
                <div class="label">Passed</div>
            </div>
            <div class="stat-card failed">
                <div class="value">{failed_count}</div>
                <div class="label">Failed</div>
            </div>
            <div class="stat-card">
                <div class="value">{skipped_count}</div>
                <div class="label">Skipped</div>
            </div>
            <div class="stat-card">
                <div class="value">{duration}</div>
                <div class="label">Duration</div>
            </div>
            <div class="stat-card coverage">
                <div class="value">{coverage_percent}</div>
                <div class="label">Coverage</div>
            </div>
        </div>
        
        {'<div class="section"><div class="section-header"><h3>❌ Failed Tests</h3></div><div class="section-content">' + ''.join(failed_details) + '</div></div>' if failed_details else ''}
        
        <div class="section">
            <div class="section-header">
                <h3>📊 Tests by Class</h3>
            </div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th></th>
                            <th>Class</th>
                            <th>Total</th>
                            <th>Passed</th>
                            <th>Failed</th>
                            <th>Duration</th>
                        </tr>
                    </thead>
                    <tbody>
                        {''.join(class_rows)}
                    </tbody>
                </table>
            </div>
        </div>
        
        {f'''<div class="section">
            <div class="section-header">
                <h3>📈 Code Coverage</h3>
            </div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th>Target</th>
                            <th>Coverage</th>
                            <th>Lines</th>
                        </tr>
                    </thead>
                    <tbody>
                        {''.join(coverage_rows)}
                    </tbody>
                </table>
            </div>
        </div>''' if coverage_rows else ''}
        
        <div class="section">
            <div class="section-header">
                <h3>📋 All Tests</h3>
            </div>
            <div class="section-content">
                <div class="filters">
                    <input type="text" class="filter-input" id="searchInput" placeholder="Search tests...">
                    <button class="filter-btn active" onclick="filterTests('all')">All</button>
                    <button class="filter-btn" onclick="filterTests('passed')">Passed</button>
                    <button class="filter-btn" onclick="filterTests('failed')">Failed</button>
                    <button class="filter-btn" onclick="filterTests('skipped')">Skipped</button>
                </div>
                <table id="testsTable">
                    <thead>
                        <tr>
                            <th></th>
                            <th>Class</th>
                            <th>Test</th>
                            <th>Duration</th>
                        </tr>
                    </thead>
                    <tbody>
                        {''.join(test_rows)}
                    </tbody>
                </table>
            </div>
        </div>
    </div>
    
    <script>
        let currentFilter = 'all';
        
        function filterTests(status) {{
            currentFilter = status;
            document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
            event.target.classList.add('active');
            applyFilters();
        }}
        
        document.getElementById('searchInput').addEventListener('input', applyFilters);
        
        function applyFilters() {{
            const search = document.getElementById('searchInput').value.toLowerCase();
            document.querySelectorAll('.test-row').forEach(row => {{
                const matchesStatus = currentFilter === 'all' || row.dataset.status === currentFilter;
                const matchesSearch = row.textContent.toLowerCase().includes(search);
                row.style.display = matchesStatus && matchesSearch ? '' : 'none';
            }});
        }}
    </script>
</body>
</html>'''
    
    return html_content

def main():
    if len(sys.argv) < 3:
        print("Usage: generate-html-report.py <test-data.json> <output.html> [options]", file=sys.stderr)
        sys.exit(1)
    
    test_data_path = sys.argv[1]
    output_path = sys.argv[2]
    
    coverage_path = None
    commit = ""
    branch = ""
    
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == '--coverage' and i + 1 < len(sys.argv):
            coverage_path = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == '--commit' and i + 1 < len(sys.argv):
            commit = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == '--branch' and i + 1 < len(sys.argv):
            branch = sys.argv[i + 1]
            i += 2
        else:
            i += 1
    
    # Load test data
    test_data = load_json(test_data_path)
    if not test_data:
        test_data = {'summary': {'tests': 0}, 'tests': [], 'classes': {}, 'failed_tests': []}
    
    # Load coverage data
    coverage_data = None
    if coverage_path and os.path.exists(coverage_path):
        coverage_data = load_json(coverage_path)
    
    # Generate HTML
    html_content = generate_html_report(test_data, coverage_data, commit, branch)
    
    # Write output
    os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)
    with open(output_path, 'w') as f:
        f.write(html_content)
    
    print(f"Generated HTML report: {output_path}", file=sys.stderr)

if __name__ == '__main__':
    main()
