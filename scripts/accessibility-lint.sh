#!/bin/bash
# Run AccessLint accessibility analysis on Palace iOS project
# Version: 1.1.0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ACCESSLINT_PATH="${ACCESSLINT_PATH:-accesslint}"

# Check if accesslint is installed
if ! command -v "$ACCESSLINT_PATH" &> /dev/null; then
    echo "❌ AccessLint not found. Install it with:"
    echo ""
    echo "  curl -L https://github.com/mauricecarrier7/AccessLint-Distribution/releases/download/1.1.0/accesslint -o /usr/local/bin/accesslint"
    echo "  chmod +x /usr/local/bin/accesslint"
    echo ""
    echo "Or set ACCESSLINT_PATH environment variable"
    exit 1
fi

echo "🔍 Running AccessLint v1.1.0 on Palace iOS (WCAG AA preset)..."
echo ""

# Run analysis with WCAG AA preset and config file
"$ACCESSLINT_PATH" analyze \
    --path "$PROJECT_ROOT/Palace" \
    --output "$PROJECT_ROOT/accesslint-reports" \
    --format json \
    --format md \
    --preset wcag-aa \
    --config "$PROJECT_ROOT/.accesslintrc.json" \
    --relative-paths \
    --verbose \
    "$@"

EXIT_CODE=$?

echo ""
echo "📄 Reports saved to: $PROJECT_ROOT/accesslint-reports/"
echo "   - findings.json (machine-readable)"
echo "   - report.md (human-readable)"
echo ""

# Summary
if [ -f "$PROJECT_ROOT/accesslint-reports/findings.json" ]; then
    TOTAL=$(jq 'length' "$PROJECT_ROOT/accesslint-reports/findings.json")
    MAJOR=$(jq '[.[] | select(.severity == "major")] | length' "$PROJECT_ROOT/accesslint-reports/findings.json")
    MINOR=$(jq '[.[] | select(.severity == "minor")] | length' "$PROJECT_ROOT/accesslint-reports/findings.json")
    echo "📊 Summary: $TOTAL findings ($MAJOR major, $MINOR minor)"
fi

exit $EXIT_CODE
