#!/bin/bash

# Lint Swift code using SwiftLint for the Palace Project
# This script checks all Swift files for style and potential issues

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

# Function to check if SwiftLint is available
check_swiftlint() {
    if ! command -v swiftlint >/dev/null 2>&1; then
        echo -e "${RED}❌ SwiftLint not found in PATH${NC}"
        echo "Please install SwiftLint first:"
        echo "  ./scripts/install-linting-tools.sh"
        echo "  or"
        echo "  brew install swiftlint"
        exit 1
    fi
}

# Function to run linting
run_lint() {
    local config_file="$PROJECT_ROOT/.swiftlint.yml"
    local should_fix="$1"
    local specific_paths=("${@:2}")
    
    echo -e "${BLUE}🔍 Running SwiftLint...${NC}"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${YELLOW}⚠️  No .swiftlint.yml config found, using default settings${NC}"
        config_file=""
    else
        echo -e "${GREEN}📋 Using config: $config_file${NC}"
    fi
    
    local cmd_args=()
    
    # Add config file if it exists
    if [[ -n "$config_file" ]]; then
        cmd_args+=("--config" "$config_file")
    fi
    
    # Add auto-correct flag if requested
    if [[ "$should_fix" == "true" ]]; then
        cmd_args+=("--fix")
        echo -e "${YELLOW}🔧 Auto-fix mode enabled${NC}"
    fi
    
    # Add specific paths if provided, otherwise use current directory
    if [[ ${#specific_paths[@]} -gt 0 ]]; then
        for path in "${specific_paths[@]}"; do
            if [[ -d "$PROJECT_ROOT/$path" ]] || [[ -f "$PROJECT_ROOT/$path" ]]; then
                cmd_args+=("$PROJECT_ROOT/$path")
            else
                echo -e "${YELLOW}⚠️  Path not found: $path${NC}"
            fi
        done
    else
        cmd_args+=("$PROJECT_ROOT")
    fi
    
    echo ""
    echo -e "${BLUE}Running: swiftlint ${cmd_args[*]##--config*}${NC}"
    echo ""
    
    # Run SwiftLint
    local exit_code=0
    swiftlint "${cmd_args[@]}" || exit_code=$?
    
    echo ""
    case $exit_code in
        0)
            echo -e "${GREEN}✅ No linting issues found!${NC}"
            ;;
        1)
            echo -e "${YELLOW}⚠️  Linting completed with warnings${NC}"
            ;;
        2)
            echo -e "${RED}❌ Linting failed with errors${NC}"
            ;;
        3)
            echo -e "${RED}❌ SwiftLint encountered an internal error${NC}"
            ;;
        *)
            echo -e "${RED}❌ SwiftLint exited with code: $exit_code${NC}"
            ;;
    esac
    
    return $exit_code
}

# Function to show linting rules
show_rules() {
    echo -e "${BLUE}📋 Available SwiftLint rules:${NC}"
    echo ""
    swiftlint rules
}

# Function to generate baseline
generate_baseline() {
    local baseline_file="$PROJECT_ROOT/.swiftlint-baseline.json"
    
    echo -e "${BLUE}📊 Generating SwiftLint baseline...${NC}"
    echo "This will create a baseline of current issues to focus on new problems."
    echo ""
    
    local config_file="$PROJECT_ROOT/.swiftlint.yml"
    local cmd_args=()
    
    if [[ -f "$config_file" ]]; then
        cmd_args+=("--config" "$config_file")
    fi
    
    cmd_args+=("--reporter" "json")
    cmd_args+=("$PROJECT_ROOT")
    
    if swiftlint "${cmd_args[@]}" > "$baseline_file" 2>/dev/null; then
        echo -e "${GREEN}✅ Baseline saved to: $baseline_file${NC}"
        echo "Add this to your .swiftlint.yml:"
        echo "baseline: .swiftlint-baseline.json"
    else
        echo -e "${RED}❌ Failed to generate baseline${NC}"
        return 1
    fi
}

# Function to analyze specific file
analyze_file() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        echo -e "${RED}❌ File not found: $file_path${NC}"
        exit 1
    fi
    
    if [[ ! "$file_path" =~ \.swift$ ]]; then
        echo -e "${RED}❌ File is not a Swift file: $file_path${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}🔍 Analyzing single file: $file_path${NC}"
    echo ""
    
    local config_file="$PROJECT_ROOT/.swiftlint.yml"
    local cmd_args=()
    
    if [[ -f "$config_file" ]]; then
        cmd_args+=("--config" "$config_file")
    fi
    
    cmd_args+=("$file_path")
    
    run_lint "false" "$file_path"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Lint Swift code using SwiftLint"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help       Show this help message"
    echo "  -f, --fix        Auto-fix issues that can be corrected automatically"
    echo "  -r, --rules      Show all available linting rules"
    echo "  -b, --baseline   Generate a baseline file for existing issues"
    echo "  --file FILE      Analyze a specific file"
    echo "  --strict         Treat warnings as errors (exit code 1 on warnings)"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                                    # Lint all files"
    echo "  $0 --fix                             # Lint and auto-fix issues"
    echo "  $0 --file Palace/Book/TPPBook.swift  # Lint specific file"
    echo "  $0 --rules                           # Show available rules"
    echo "  $0 --baseline                        # Generate baseline"
    echo ""
}

# Main function
main() {
    cd "$PROJECT_ROOT"
    
    echo -e "${GREEN}🎯 Palace Project - Code Linter${NC}"
    echo "==============================="
    echo ""
    
    # Check if SwiftLint is installed
    check_swiftlint
    
    local should_fix="false"
    local show_rules_flag="false"
    local generate_baseline_flag="false"
    local analyze_single_file=""
    local strict_mode="false"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -f|--fix)
                should_fix="true"
                shift
                ;;
            -r|--rules)
                show_rules_flag="true"
                shift
                ;;
            -b|--baseline)
                generate_baseline_flag="true"
                shift
                ;;
            --file)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}❌ --file requires a file path${NC}"
                    exit 1
                fi
                analyze_single_file="$2"
                shift 2
                ;;
            --strict)
                strict_mode="true"
                shift
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Handle specific actions
    if [[ "$show_rules_flag" == "true" ]]; then
        show_rules
        exit 0
    fi
    
    if [[ "$generate_baseline_flag" == "true" ]]; then
        generate_baseline
        exit 0
    fi
    
    if [[ -n "$analyze_single_file" ]]; then
        analyze_file "$analyze_single_file"
        exit $?
    fi
    
    # Run linting on the entire project
    echo -e "${GREEN}SwiftLint version: $(swiftlint version)${NC}"
    echo ""
    
    local exit_code=0
    run_lint "$should_fix" || exit_code=$?
    
    # Handle strict mode
    if [[ "$strict_mode" == "true" && $exit_code -eq 1 ]]; then
        echo -e "${RED}💥 Strict mode: treating warnings as errors${NC}"
        exit_code=2
    fi
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}🎉 Linting complete!${NC}"
    else
        echo -e "${YELLOW}💡 Tips:${NC}"
        echo "  • Run '$0 --fix' to auto-correct fixable issues"
        echo "  • Run './scripts/format-code.sh' to format your code first"
        echo "  • Check .swiftlint.yml to customize rules"
    fi
    
    echo ""
    
    exit $exit_code
}

# Run main function with all arguments
main "$@"
