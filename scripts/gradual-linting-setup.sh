#!/bin/bash

# Gradual Linting Setup for Palace Project
# This script helps migrate an existing codebase to linting standards gradually

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Function to create a baseline configuration
create_baseline_config() {
    echo -e "${BLUE}📊 Creating gradual migration SwiftLint configuration...${NC}"
    
    local baseline_config="$PROJECT_ROOT/.swiftlint-migration.yml"
    
    cat > "$baseline_config" << 'EOF'
# SwiftLint Migration Configuration for Palace Project
# This is a more lenient configuration for gradual adoption

# Paths to include for linting
included:
  - Palace
  - PalaceTests
  - PalaceUIKit
  - ios-audiobooktoolkit/PalaceAudiobookToolkit
  - ios-audiobooktoolkit/PalaceAudiobookToolkitTests
  - ios-audiobook-overdrive/OverdriveProcessor

# Paths to exclude from linting
excluded:
  - Carthage
  - readium-sdk
  - readium-shared-js
  - adept-ios
  - adobe-content-filter
  - adobe-rmsdk
  - ios-tenprintcover
  - mobile-bookmark-spec
  - build
  - DerivedData
  - fastlane
  - scripts
  - "*.generated.swift"

# Start with only the most critical rules
disabled_rules:
  - todo
  - line_length
  - function_body_length
  - type_body_length
  - file_length
  - cyclomatic_complexity
  - function_parameter_count
  - opening_brace  # Common formatting issue - fix with SwiftFormat
  - trailing_closure  # Style preference - can be ignored initially
  - unused_optional_binding  # Not critical for functionality

# Focus on critical opt-in rules only
opt_in_rules:
  - empty_string
  - force_unwrapping  # Critical for crash prevention
  - implicitly_unwrapped_optional  # Critical for crash prevention
  - legacy_random
  - redundant_nil_coalescing
  - unused_import

# More lenient configurations
line_length:
  warning: 150
  error: 200
  ignores_urls: true
  ignores_function_declarations: true
  ignores_comments: true

function_body_length:
  warning: 100
  error: 200

type_body_length:
  warning: 500
  error: 1000

file_length:
  warning: 1000
  error: 2000
  ignore_comment_only_lines: true

cyclomatic_complexity:
  warning: 25
  error: 50

# Set a much higher warning threshold for migration
warning_threshold: 500

# Custom reporter
reporter: "xcode"
EOF

    echo -e "${GREEN}✅ Created migration config: .swiftlint-migration.yml${NC}"
}

# Function to auto-fix easy issues
auto_fix_formatting() {
    echo -e "${BLUE}🔧 Auto-fixing formatting issues with SwiftFormat...${NC}"
    
    # First, format all the code to fix spacing issues
    "$PROJECT_ROOT/scripts/format-code.sh" --all
    
    echo -e "${GREEN}✅ Formatting complete${NC}"
}

# Function to run linting with migration config
run_migration_lint() {
    echo -e "${BLUE}🔍 Running linting with migration configuration...${NC}"
    
    local migration_config="$PROJECT_ROOT/.swiftlint-migration.yml"
    
    if [[ ! -f "$migration_config" ]]; then
        echo -e "${RED}❌ Migration config not found. Run with --create-config first.${NC}"
        return 1
    fi
    
    # Run SwiftLint with the migration config
    swiftlint --config "$migration_config" || true
}

# Function to generate a focused report
generate_focused_report() {
    echo -e "${BLUE}📋 Generating focused linting report...${NC}"
    
    local migration_config="$PROJECT_ROOT/.swiftlint-migration.yml"
    local report_file="$PROJECT_ROOT/linting-report.txt"
    
    if [[ ! -f "$migration_config" ]]; then
        echo -e "${RED}❌ Migration config not found${NC}"
        return 1
    fi
    
    # Generate report focusing on critical issues
    echo "Palace Project Linting Report - $(date)" > "$report_file"
    echo "=============================================" >> "$report_file"
    echo "" >> "$report_file"
    
    # Count violations by type
    echo "Critical Issues (crash-prone):" >> "$report_file"
    swiftlint --config "$migration_config" --reporter json 2>/dev/null | jq -r '.[] | select(.severity == "error") | .reason' | sort | uniq -c | sort -rn >> "$report_file" 2>/dev/null || echo "No critical issues found" >> "$report_file"
    
    echo "" >> "$report_file"
    echo "Most Common Warnings:" >> "$report_file"
    swiftlint --config "$migration_config" --reporter json 2>/dev/null | jq -r '.[] | select(.severity == "warning") | .reason' | sort | uniq -c | sort -rn | head -10 >> "$report_file" 2>/dev/null || echo "Analysis requires jq tool" >> "$report_file"
    
    echo "" >> "$report_file"
    echo "Files with most issues:" >> "$report_file"
    swiftlint --config "$migration_config" --reporter json 2>/dev/null | jq -r '.[].file' | sort | uniq -c | sort -rn | head -10 >> "$report_file" 2>/dev/null || echo "Analysis requires jq tool" >> "$report_file"
    
    echo -e "${GREEN}✅ Report saved to: linting-report.txt${NC}"
}

# Function to create a phased migration plan
create_migration_plan() {
    echo -e "${BLUE}📋 Creating phased migration plan...${NC}"
    
    cat > "$PROJECT_ROOT/LINTING_MIGRATION_PLAN.md" << 'EOF'
# Linting Migration Plan for Palace Project

## Overview
This document outlines a phased approach to introduce linting to the Palace project without overwhelming the development process.

## Phase 1: Critical Issues Only (Current)
**Goal**: Fix issues that could cause crashes or serious bugs
**Duration**: 1-2 weeks

### Configuration
- Use `.swiftlint-migration.yml`
- Focus on force unwrapping, implicitly unwrapped optionals
- Disable most style rules

### Steps
1. Run `./scripts/gradual-linting-setup.sh --auto-fix`
2. Fix critical issues one file at a time
3. Run `./scripts/gradual-linting-setup.sh --report` weekly

## Phase 2: Code Quality Rules (Week 3-4)
**Goal**: Improve code maintainability
**Duration**: 2 weeks

### Enable Additional Rules
- `function_body_length` (with higher limits)
- `type_body_length` (with higher limits)
- `cyclomatic_complexity` (with higher limits)

### Steps
1. Update `.swiftlint-migration.yml` to include quality rules
2. Address largest/most complex files first
3. Refactor incrementally

## Phase 3: Style Consistency (Week 5-6)
**Goal**: Ensure consistent code style
**Duration**: 2 weeks

### Enable Style Rules
- `opening_brace`
- `trailing_closure`
- `line_length` (with project-appropriate limits)

### Steps
1. Run SwiftFormat to auto-fix most issues
2. Enable style rules gradually
3. Fix remaining manual issues

## Phase 4: Full Rule Set (Week 7+)
**Goal**: Complete linting coverage
**Duration**: Ongoing

### Final Configuration
- Switch to full `.swiftlint.yml`
- Enable all appropriate rules
- Lower thresholds to final values

### Maintenance
- New code follows all rules
- Legacy code improved opportunistically
- Regular linting in CI/CD

## Daily Workflow During Migration

### For New Code
- Always run linting on new/modified files
- Follow full standards for new code

### For Existing Code
- Fix issues in files you're already modifying
- Don't create separate "linting only" PRs for now

### Commands
```bash
# Check current migration status
./scripts/gradual-linting-setup.sh --report

# Fix formatting issues automatically
./scripts/gradual-linting-setup.sh --auto-fix

# Lint with current migration rules
./scripts/gradual-linting-setup.sh --lint
```

## Success Metrics
- [ ] Phase 1: Zero critical errors (force unwrapping, etc.)
- [ ] Phase 2: Functions < 100 lines, classes < 500 lines
- [ ] Phase 3: Consistent formatting across codebase  
- [ ] Phase 4: < 50 total linting violations

## Tips for Success
1. **Start small**: Fix one file completely rather than partial fixes across many files
2. **Auto-fix first**: Let SwiftFormat handle formatting automatically
3. **Focus on value**: Prioritize rules that prevent bugs over style preferences
4. **Team alignment**: Ensure all developers understand the migration plan
EOF

    echo -e "${GREEN}✅ Created migration plan: LINTING_MIGRATION_PLAN.md${NC}"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Gradual linting setup for Palace Project"
    echo ""
    echo "OPTIONS:"
    echo "  --create-config    Create migration configuration files"
    echo "  --auto-fix         Auto-fix formatting issues with SwiftFormat"
    echo "  --lint             Run linting with migration configuration"
    echo "  --report           Generate focused linting report"
    echo "  --plan             Create migration plan document"
    echo "  --full-setup       Run complete gradual setup"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --full-setup    # Complete initial setup"
    echo "  $0 --auto-fix      # Fix formatting issues"
    echo "  $0 --lint          # Check with migration rules"
    echo ""
}

# Main function
main() {
    cd "$PROJECT_ROOT"
    
    echo -e "${GREEN}🎯 Palace Project - Gradual Linting Setup${NC}"
    echo "=========================================="
    echo ""
    
    case "${1:-}" in
        --create-config)
            create_baseline_config
            ;;
        --auto-fix)
            auto_fix_formatting
            ;;
        --lint)
            run_migration_lint
            ;;
        --report)
            generate_focused_report
            ;;
        --plan)
            create_migration_plan
            ;;
        --full-setup)
            echo -e "${BLUE}Running complete gradual setup...${NC}"
            create_baseline_config
            create_migration_plan
            auto_fix_formatting
            echo ""
            echo -e "${GREEN}🎉 Gradual setup complete!${NC}"
            echo ""
            echo "Next steps:"
            echo "1. Review LINTING_MIGRATION_PLAN.md"
            echo "2. Run: ./scripts/gradual-linting-setup.sh --lint"
            echo "3. Start with critical issues only"
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        "")
            echo -e "${YELLOW}⚠️  No option specified. Use --help for usage.${NC}"
            show_usage
            exit 1
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
