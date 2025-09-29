#!/bin/bash

# Quick Linting Fix for Palace Project
# This script provides a practical approach to handle linting in a large codebase

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

# Function to switch to migration config temporarily
use_migration_config() {
    local original_config="$PROJECT_ROOT/.swiftlint.yml"
    local migration_config="$PROJECT_ROOT/.swiftlint-migration.yml"
    local backup_config="$PROJECT_ROOT/.swiftlint.yml.backup"
    
    if [[ -f "$migration_config" ]]; then
        # Backup original if it exists
        if [[ -f "$original_config" ]]; then
            cp "$original_config" "$backup_config"
        fi
        # Use migration config
        cp "$migration_config" "$original_config"
        echo -e "${BLUE}📋 Switched to migration configuration${NC}"
        return 0
    else
        echo -e "${RED}❌ Migration config not found. Run gradual setup first.${NC}"
        return 1
    fi
}

# Function to restore original config
restore_original_config() {
    local original_config="$PROJECT_ROOT/.swiftlint.yml"
    local backup_config="$PROJECT_ROOT/.swiftlint.yml.backup"
    
    if [[ -f "$backup_config" ]]; then
        mv "$backup_config" "$original_config"
        echo -e "${BLUE}📋 Restored original configuration${NC}"
    fi
}

# Function to format specific directories
format_by_directory() {
    echo -e "${BLUE}🔧 Formatting code by directory (safer approach)...${NC}"
    
    local dirs=(
        "Palace/Audiobooks"
        "Palace/Book" 
        "Palace/CatalogUI"
        "Palace/ErrorHandling"
        "Palace/MyBooks"
        "Palace/Settings"
        "ios-audiobooktoolkit/PalaceAudiobookToolkit/Player"
        "ios-audiobooktoolkit/PalaceAudiobookToolkit/UI"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ -d "$PROJECT_ROOT/$dir" ]]; then
            echo -e "${BLUE}  Formatting: $dir${NC}"
            swiftformat "$PROJECT_ROOT/$dir" --config "$PROJECT_ROOT/.swiftformat" || echo -e "${YELLOW}    Warning: Some files in $dir had issues${NC}"
        fi
    done
}

# Function to run targeted linting
run_targeted_linting() {
    echo -e "${BLUE}🔍 Running targeted linting on key directories...${NC}"
    
    # Focus on the most important directories first
    local priority_dirs=(
        "Palace/Audiobooks"
        "Palace/Book"
        "Palace/MyBooks"
    )
    
    for dir in "${priority_dirs[@]}"; do
        if [[ -d "$PROJECT_ROOT/$dir" ]]; then
            echo -e "${BLUE}📁 Linting: $dir${NC}"
            swiftlint --path "$PROJECT_ROOT/$dir" || echo -e "${YELLOW}    Issues found in $dir${NC}"
            echo ""
        fi
    done
}

# Function to show current status
show_status() {
    echo -e "${BLUE}📊 Current Linting Status${NC}"
    echo "========================="
    echo ""
    
    # Count Swift files
    local swift_files
    swift_files=$(find "$PROJECT_ROOT/Palace" "$PROJECT_ROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit" -name "*.swift" 2>/dev/null | wc -l | tr -d ' ')
    echo "Swift files in main codebase: $swift_files"
    
    # Quick lint count on a subset
    echo ""
    echo "Sample linting status (Palace/Audiobooks directory):"
    if [[ -d "$PROJECT_ROOT/Palace/Audiobooks" ]]; then
        swiftlint --path "$PROJECT_ROOT/Palace/Audiobooks" 2>/dev/null | tail -1 || echo "Unable to get quick status"
    fi
}

# Function to provide recommendations
show_recommendations() {
    echo ""
    echo -e "${GREEN}💡 Recommendations for Managing Linting${NC}"
    echo "========================================"
    echo ""
    echo "🎯 IMMEDIATE ACTIONS (Today):"
    echo "1. Use migration config: ./scripts/quick-lint-fix.sh --use-migration"
    echo "2. Format key directories: ./scripts/quick-lint-fix.sh --format-priority" 
    echo "3. Fix only new/modified files for now"
    echo ""
    echo "📅 THIS WEEK:"
    echo "1. Set up Xcode integration for new code warnings"
    echo "2. Focus on fixing critical issues (force unwrapping, crashes)"
    echo "3. Run linting on files you're already working on"
    echo ""
    echo "🔄 ONGOING STRATEGY:"
    echo "1. Always lint new code with full rules"
    echo "2. Fix legacy code opportunistically (when you touch it)"
    echo "3. Gradually tighten rules as violations decrease"
    echo ""
    echo "📋 XCODE INTEGRATION:"
    echo "Add this to your Xcode build phases for NEW CODE warnings only:"
    echo ""
    echo "# SwiftLint - New Files Only"
    echo 'if which swiftlint > /dev/null; then'
    echo '  # Only lint files changed in the last commit'
    echo '  git diff --name-only HEAD~1 HEAD | grep "\.swift$" | xargs swiftlint --config .swiftlint-migration.yml'
    echo 'else'
    echo '  echo "warning: SwiftLint not installed"'
    echo 'fi'
    echo ""
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Quick linting fixes for Palace Project"
    echo ""
    echo "OPTIONS:"
    echo "  --use-migration      Switch to migration configuration"
    echo "  --restore-config     Restore original configuration"
    echo "  --format-priority    Format priority directories only"
    echo "  --lint-priority      Lint priority directories only"  
    echo "  --status             Show current linting status"
    echo "  --recommendations    Show management recommendations"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --use-migration       # Switch to lenient config"
    echo "  $0 --format-priority     # Format key directories"
    echo "  $0 --status             # Check current status"
    echo ""
}

# Main function
main() {
    cd "$PROJECT_ROOT"
    
    echo -e "${GREEN}🎯 Palace Project - Quick Lint Fix${NC}"
    echo "=================================="
    echo ""
    
    case "${1:-}" in
        --use-migration)
            use_migration_config
            ;;
        --restore-config)
            restore_original_config
            ;;
        --format-priority)
            format_by_directory
            ;;
        --lint-priority)
            run_targeted_linting
            ;;
        --status)
            show_status
            ;;
        --recommendations)
            show_recommendations
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        "")
            echo -e "${YELLOW}⚠️  No option specified. Showing status and recommendations.${NC}"
            echo ""
            show_status
            show_recommendations
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
}

# Cleanup function
cleanup() {
    # Always try to restore original config if script is interrupted
    restore_original_config 2>/dev/null || true
}

# Set up cleanup trap
trap cleanup EXIT

# Run main function
main "$@"
