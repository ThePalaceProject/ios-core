#!/bin/bash

# Format Swift code using SwiftFormat for the Palace Project
# This script formats all Swift files according to the project's style guide

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

# Function to check if SwiftFormat is available
check_swiftformat() {
    if ! command -v swiftformat >/dev/null 2>&1; then
        echo -e "${RED}❌ SwiftFormat not found in PATH${NC}"
        echo "Please install SwiftFormat first:"
        echo "  ./scripts/install-linting-tools.sh"
        echo "  or"
        echo "  brew install swiftformat"
        exit 1
    fi
}

# Function to format files
format_files() {
    local target_paths=("$@")
    local config_file="$PROJECT_ROOT/.swiftformat"
    
    echo -e "${BLUE}🔧 Formatting Swift files...${NC}"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${YELLOW}⚠️  No .swiftformat config found, using default settings${NC}"
        config_file=""
    else
        echo -e "${GREEN}📋 Using config: $config_file${NC}"
    fi
    
    local format_count=0
    local error_count=0
    
    for path in "${target_paths[@]}"; do
        if [[ -d "$PROJECT_ROOT/$path" ]] || [[ -f "$PROJECT_ROOT/$path" ]]; then
            echo -e "${BLUE}  Formatting: $path${NC}"
            
            local cmd_args=()
            if [[ -n "$config_file" ]]; then
                cmd_args+=("--config" "$config_file")
            fi
            cmd_args+=("$PROJECT_ROOT/$path")
            
            if swiftformat "${cmd_args[@]}" 2>/dev/null; then
                ((format_count++))
            else
                echo -e "${RED}    ❌ Error formatting: $path${NC}"
                ((error_count++))
            fi
        else
            echo -e "${YELLOW}    ⚠️  Path not found: $path${NC}"
        fi
    done
    
    echo ""
    if [[ $error_count -eq 0 ]]; then
        echo -e "${GREEN}✅ Formatting complete! Processed $format_count locations.${NC}"
    else
        echo -e "${YELLOW}⚠️  Formatting complete with $error_count errors. Processed $format_count locations.${NC}"
    fi
}

# Function to show diff preview
preview_changes() {
    echo -e "${BLUE}🔍 Preview mode: showing potential changes...${NC}"
    
    local config_file="$PROJECT_ROOT/.swiftformat"
    local preview_args=("--dryrun")
    
    if [[ -f "$config_file" ]]; then
        preview_args+=("--config" "$config_file")
    fi
    
    # Add target directories
    preview_args+=(
        "$PROJECT_ROOT/Palace"
        "$PROJECT_ROOT/PalaceTests"
        "$PROJECT_ROOT/PalaceUIKit"
        "$PROJECT_ROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit"
        "$PROJECT_ROOT/ios-audiobooktoolkit/PalaceAudiobookToolkitTests"
        "$PROJECT_ROOT/ios-audiobook-overdrive/OverdriveProcessor"
    )
    
    swiftformat "${preview_args[@]}" || true
}

# Function to format specific file
format_single_file() {
    local file_path="$1"
    local config_file="$PROJECT_ROOT/.swiftformat"
    
    if [[ ! -f "$file_path" ]]; then
        echo -e "${RED}❌ File not found: $file_path${NC}"
        exit 1
    fi
    
    if [[ ! "$file_path" =~ \.swift$ ]]; then
        echo -e "${RED}❌ File is not a Swift file: $file_path${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}🔧 Formatting single file: $file_path${NC}"
    
    local cmd_args=()
    if [[ -f "$config_file" ]]; then
        cmd_args+=("--config" "$config_file")
    fi
    cmd_args+=("$file_path")
    
    if swiftformat "${cmd_args[@]}"; then
        echo -e "${GREEN}✅ File formatted successfully!${NC}"
    else
        echo -e "${RED}❌ Error formatting file${NC}"
        exit 1
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Format Swift code using SwiftFormat"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help     Show this help message"
    echo "  -p, --preview  Preview changes without applying them"
    echo "  -f, --file     Format a specific file"
    echo "  -a, --all      Format all Swift files in the project (default)"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                                    # Format all files"
    echo "  $0 --preview                         # Preview all changes"
    echo "  $0 --file Palace/Book/TPPBook.swift  # Format specific file"
    echo ""
}

# Main function
main() {
    cd "$PROJECT_ROOT"
    
    echo -e "${GREEN}🎯 Palace Project - Code Formatter${NC}"
    echo "================================="
    echo ""
    
    # Check if SwiftFormat is installed
    check_swiftformat
    
    # Default target paths
    local target_paths=(
        "Palace"
        "PalaceTests" 
        "PalaceUIKit"
        "ios-audiobooktoolkit/PalaceAudiobookToolkit"
        "ios-audiobooktoolkit/PalaceAudiobookToolkitTests"
        "ios-audiobook-overdrive/OverdriveProcessor"
    )
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -p|--preview)
                preview_changes
                exit 0
                ;;
            -f|--file)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}❌ --file requires a file path${NC}"
                    exit 1
                fi
                format_single_file "$2"
                exit 0
                ;;
            -a|--all)
                # This is the default behavior
                shift
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    
    # Format all target paths
    format_files "${target_paths[@]}"
    
    echo ""
    echo -e "${GREEN}🎉 Code formatting complete!${NC}"
    echo ""
    echo "💡 Tips:"
    echo "  • Run 'git diff' to see what was changed"
    echo "  • Run './scripts/lint-code.sh' to check for any remaining issues"
    echo "  • Consider setting up a pre-commit hook to format automatically"
}

# Run main function with all arguments
main "$@"
