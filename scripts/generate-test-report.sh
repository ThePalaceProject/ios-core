#!/bin/bash
# Generate HTML test report from xcresult bundle
# Usage: ./scripts/generate-test-report.sh [xcresult-path]

set -e

XCRESULT_PATH="${1:-TestResults.xcresult}"
OUTPUT_DIR="test-reports"

echo "📊 Generating test report from: $XCRESULT_PATH"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check if xcresult exists
if [ ! -d "$XCRESULT_PATH" ]; then
    echo "❌ Error: $XCRESULT_PATH not found"
    echo "Run tests first: xcodebuild test -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 14 Pro,arch=x86_64' -resultBundlePath TestResults.xcresult"
    exit 1
fi

# Install xcparse if not available
if ! command -v xcparse &> /dev/null; then
    echo "📦 Installing xcparse..."
    brew install chargepoint/xcparse/xcparse
fi

# Extract screenshots
echo "📸 Extracting screenshots..."
xcparse screenshots "$XCRESULT_PATH" "$OUTPUT_DIR/screenshots" --legacy 2>/dev/null || true

# Extract code coverage
echo "📈 Extracting code coverage..."
xcrun xccov view --report --json "$XCRESULT_PATH" > "$OUTPUT_DIR/coverage.json" 2>/dev/null || true

# Generate HTML report
echo "📝 Generating HTML report..."
cat > "$OUTPUT_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Palace Test Report</title>
    <style>
        :root {
            --bg: #0d1117;
            --card-bg: #161b22;
            --border: #30363d;
            --text: #c9d1d9;
            --text-muted: #8b949e;
            --success: #3fb950;
            --error: #f85149;
            --warning: #d29922;
            --accent: #58a6ff;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            background: var(--bg);
            color: var(--text);
            line-height: 1.6;
            padding: 2rem;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { 
            font-size: 2rem; 
            margin-bottom: 1.5rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .stat-card {
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1.5rem;
            text-align: center;
        }
        .stat-value {
            font-size: 2.5rem;
            font-weight: bold;
        }
        .stat-label {
            color: var(--text-muted);
            font-size: 0.875rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }
        .success { color: var(--success); }
        .error { color: var(--error); }
        .warning { color: var(--warning); }
        .section {
            background: var(--card-bg);
            border: 1px solid var(--border);
            border-radius: 8px;
            margin-bottom: 1.5rem;
            overflow: hidden;
        }
        .section-header {
            padding: 1rem 1.5rem;
            border-bottom: 1px solid var(--border);
            font-weight: 600;
        }
        .section-content { padding: 1rem 1.5rem; }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            text-align: left;
            padding: 0.75rem;
            border-bottom: 1px solid var(--border);
        }
        th { 
            color: var(--text-muted); 
            font-weight: 500;
            font-size: 0.75rem;
            text-transform: uppercase;
        }
        tr:last-child td { border-bottom: none; }
        .badge {
            display: inline-block;
            padding: 0.25rem 0.5rem;
            border-radius: 4px;
            font-size: 0.75rem;
            font-weight: 500;
        }
        .badge-success { background: rgba(63, 185, 80, 0.2); color: var(--success); }
        .badge-error { background: rgba(248, 81, 73, 0.2); color: var(--error); }
        .screenshots {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 1rem;
        }
        .screenshot {
            background: var(--bg);
            border-radius: 8px;
            overflow: hidden;
        }
        .screenshot img {
            width: 100%;
            height: auto;
            display: block;
        }
        .screenshot-label {
            padding: 0.75rem;
            font-size: 0.875rem;
            color: var(--text-muted);
        }
        .timestamp {
            color: var(--text-muted);
            font-size: 0.875rem;
            margin-bottom: 2rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>📱 Palace Test Report</h1>
        <p class="timestamp">Generated: <span id="timestamp"></span></p>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-value success" id="passed">-</div>
                <div class="stat-label">Passed</div>
            </div>
            <div class="stat-card">
                <div class="stat-value error" id="failed">-</div>
                <div class="stat-label">Failed</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" id="total">-</div>
                <div class="stat-label">Total Tests</div>
            </div>
            <div class="stat-card">
                <div class="stat-value warning" id="coverage">-</div>
                <div class="stat-label">Coverage</div>
            </div>
        </div>
        
        <div class="section" id="failed-section" style="display: none;">
            <div class="section-header">❌ Failed Tests</div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th>Test</th>
                            <th>Duration</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody id="failed-tests"></tbody>
                </table>
            </div>
        </div>
        
        <div class="section" id="screenshots-section" style="display: none;">
            <div class="section-header">📸 Test Screenshots</div>
            <div class="section-content">
                <div class="screenshots" id="screenshots"></div>
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">✅ All Tests</div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th>Test Suite</th>
                            <th>Tests</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody id="all-tests"></tbody>
                </table>
            </div>
        </div>
    </div>
    
    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        
        // Load test results if available
        fetch('results.json')
            .then(r => r.json())
            .then(data => {
                // Parse and display results
                console.log('Results loaded:', data);
            })
            .catch(() => console.log('No results.json found'));
            
        // Check for screenshots
        fetch('screenshots/')
            .then(r => r.text())
            .then(html => {
                const parser = new DOMParser();
                const doc = parser.parseFromString(html, 'text/html');
                const links = [...doc.querySelectorAll('a')].filter(a => a.href.endsWith('.png'));
                if (links.length > 0) {
                    document.getElementById('screenshots-section').style.display = 'block';
                    const container = document.getElementById('screenshots');
                    links.forEach(link => {
                        const div = document.createElement('div');
                        div.className = 'screenshot';
                        div.innerHTML = `
                            <img src="screenshots/${link.textContent}" alt="${link.textContent}">
                            <div class="screenshot-label">${link.textContent}</div>
                        `;
                        container.appendChild(div);
                    });
                }
            })
            .catch(() => {});
    </script>
</body>
</html>
EOF

# Extract summary from xcresult
xcrun xcresulttool get --path "$XCRESULT_PATH" --format json 2>/dev/null > "$OUTPUT_DIR/results.json" || true

echo ""
echo "✅ Report generated at: $OUTPUT_DIR/index.html"
echo ""
echo "To view the report:"
echo "  open $OUTPUT_DIR/index.html"
echo ""
echo "To upload as artifact in CI, use:"
echo "  - uses: actions/upload-artifact@v4"
echo "    with:"
echo "      name: test-report"
echo "      path: $OUTPUT_DIR/"

