# Claude Computer Use Regression Tests

This directory contains visual regression test definitions designed to be executed via Claude's computer use capability.

## Test Format

Each regression test is defined as a YAML file describing a sequence of visual assertions and interactions.

### YAML Structure

```yaml
# test-name.regression.yml
name: "Descriptive test name"
description: "What this test validates"
priority: smoke | tier1 | tier2
preconditions:
  - "App is launched on the home screen"
  - "User is signed out"

steps:
  - action: launch
    target: "Palace"
    verify: "Home screen is visible with catalog tab selected"

  - action: tap
    target: "Settings tab"
    verify: "Settings screen is displayed with library list"

  - action: screenshot
    label: "settings-initial-state"
    assert:
      - "Add Library button is visible"
      - "Current library name is displayed"

  - action: tap
    target: "Add Library button"
    verify: "Library picker modal appears"

  - action: type
    target: "Search field"
    value: "New York"
    verify: "Search results show New York Public Library"

  - action: screenshot
    label: "library-search-results"
    assert:
      - "At least one library result is visible"
      - "Result contains 'New York' in the name"

  - action: back
    verify: "Returns to previous screen"

cleanup:
  - "Close the app"
```

### Field Descriptions

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable test name |
| `description` | Yes | What the test validates |
| `priority` | Yes | `smoke`, `tier1`, or `tier2` -- determines which plan includes it |
| `preconditions` | No | Required state before test begins |
| `steps` | Yes | Ordered list of actions to perform |
| `cleanup` | No | Steps to restore state after test |

### Step Actions

| Action | Description | Required Fields |
|--------|-------------|-----------------|
| `launch` | Open the app | `target` (app name) |
| `tap` | Tap a UI element | `target` (element description) |
| `type` | Enter text | `target` (field), `value` (text) |
| `swipe` | Swipe gesture | `target`, `direction` (up/down/left/right) |
| `screenshot` | Capture screen state | `label` (filename prefix) |
| `back` | Navigate back | -- |
| `wait` | Pause execution | `duration` (seconds) |

### Assertions

The `verify` field on each step is a natural-language assertion that Claude evaluates visually after performing the action. The `assert` field on `screenshot` steps is a list of visual conditions that must all be true.

## Execution

Tests are executed by Claude using computer use (screen observation + mouse/keyboard control):

1. Claude reads the YAML test definition
2. For each step, Claude performs the described action on the simulator
3. After each action, Claude visually verifies the `verify` condition
4. On `screenshot` steps, Claude evaluates all `assert` conditions
5. Results are reported as pass/fail with screenshots attached

### Running Tests

```bash
# Via the orchestrator (when computer use is available)
palace-test ui --plan smoke

# Individual regression test (manual invocation)
# Provide the YAML file to Claude with computer use enabled
```

## Example Test

```yaml
name: "Catalog Browse - Smoke"
description: "Verify user can browse the book catalog and view book details"
priority: smoke
preconditions:
  - "App is launched"
  - "A library is configured"

steps:
  - action: launch
    target: "Palace"
    verify: "Catalog screen loads with book covers visible"

  - action: screenshot
    label: "catalog-home"
    assert:
      - "At least one book lane is visible"
      - "Navigation tabs are present at the bottom"

  - action: tap
    target: "First book in the catalog"
    verify: "Book detail screen opens"

  - action: screenshot
    label: "book-detail"
    assert:
      - "Book title is displayed"
      - "Book cover image is visible"
      - "Borrow or Download button is present"

  - action: back
    verify: "Returns to catalog screen"
```

## Directory Structure

```
tests/claude-regression/
  README.md                          # This file
  catalog-browse.regression.yml      # Example test
  settings-library.regression.yml    # Example test
  ...
```

Test files use the `.regression.yml` suffix to distinguish them from other YAML configurations.
