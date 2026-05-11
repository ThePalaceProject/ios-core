# .palace-state — deterministic Palace app state for automated testing

The starting state of an automated test is a **contract**. The recording
captures coordinates assuming "the app is showing screen X." The replay drives
those coordinates assuming the same. If the assumption breaks — fresh install
when the recording expected a signed-in session, notifications alert blocking
the first tap, downloaded books that don't exist — the test silently drives
against the wrong UI and reports success.

This directory is the primitive layer that makes that contract explicit and
restorable.

## What's here

```
.palace-state/
├── operations/
│   ├── reset-fresh-install.sh   # uninstall + pre-grant + install [+ launch]
│   └── reset-clean-sim.sh       # nuclear: simctl erase + boot
├── fixtures/
│   ├── <name>.tgz               # tar of Documents/ + Library/ (no Caches)
│   └── <name>.meta.json         # device, app version, capture time
├── snapshot.sh                   # capture current state into a named fixture
├── restore.sh                    # restore a named fixture
└── README.md                     # this file
```

## When to use which

| Goal | Tool |
|---|---|
| Start every test from "Add Library" screen with no alerts in the way | `operations/reset-fresh-install.sh` |
| Reset sim-wide state (keychain, system prefs, all apps) before a test session | `operations/reset-clean-sim.sh --force` |
| Capture "Palace signed into A1QA with 3 books downloaded" as a reusable starting point | `snapshot.sh signed-in-a1qa` |
| Restore that captured state before running a test | `restore.sh signed-in-a1qa` |

## Common invocations

```bash
# Set the sim + app once for the session
export PALACE_STATE_SIM_UDID=DF4A2A27-9888-429D-A749-2E157A049A37
export PALACE_STATE_APP_PATH=/path/to/built/Palace.app

# Drop into a fresh-install state (notifications + location pre-granted)
.palace-state/operations/reset-fresh-install.sh

# After manually configuring a state, capture it
.palace-state/snapshot.sh signed-in-a1qa

# Later, restore it
.palace-state/restore.sh signed-in-a1qa
```

## What gets captured in a snapshot

| Captured | Excluded |
|---|---|
| `Documents/` (account list, settings, bookmarks) | `Library/Caches/` (regenerable) |
| `Library/Application Support/` | `Documents/Books/` (large; use `--include-books` to keep) |
| `Library/Preferences/` (NSUserDefaults) | `Documents/audiobooks/` |

### Known v1 gaps

- **Keychain is not captured.** Palace stores credentials in the iOS keychain,
  which lives at the sim level (not the app level) and is shared across apps.
  Restoring keychain reliably requires matching sim + Xcode-keychain access
  groups and is not portable across machines. Snapshots restore *everything
  the app sees in its data container*; if the test needs signed-in state,
  the snapshot must be paired with an upstream "fresh sign-in" step OR the
  user must manually re-authenticate after restore.
- **Build product mismatch is not auto-detected.** If `PALACE_STATE_APP_PATH`
  points at a `xcodebuild build-for-testing` product, install succeeds but
  launch fails with a misleading `SBMainWorkspace` error. The reset script
  surfaces a hint in stderr; future iteration may add a `file Palace`
  check to fail-fast.
- **The notification + location pre-grants assume iOS ≥18 simctl syntax.**
  Older sim runtimes may silently ignore the privacy grants. Newer iOS
  versions may add new permission classes that need to be added here.

## Why the dot-prefix directory name

`.palace-state/` is gitignored by some tooling that excludes dotfile dirs by
default, AND treated as a "build/test artifact" location by tooling that
respects the convention. We *want* the operation scripts tracked (they're
the contract) but not the captured fixtures (large, machine-specific,
regenerable). The `fixtures/.gitkeep` + a fixture-specific `.gitignore`
inside the directory handles that split.

## How this composes with simdrive

Today: recordings have no `requires:` block; replay drives against whatever's
on screen.

After this PR: recordings can document their starting state in a comment
and call the appropriate operation/restore in their pre-flight. Once simdrive
adopts a first-class `requires:` schema (separate proposal), the operation
names here become the canonical reset targets simdrive recordings reference.

## How this composes with `scripts/regression/side-by-side.sh`

`side-by-side.sh` had a 4-line inline uninstall+install per sim. With this
PR it shells out to `operations/reset-fresh-install.sh` once per sim, with
`--no-launch` (side-by-side controls its own launch timing). DRY and
consistent with anyone else who wants the same primitive.
