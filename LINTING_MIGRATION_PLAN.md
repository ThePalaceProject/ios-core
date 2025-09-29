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
