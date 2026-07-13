---
date: 2026-07-13
pr: PP-4788 (feat/pp4788-advanced-settings-menu)
short_id: showengineeringtools-gate
caught_by: architect SoD review (pre-merge)
status: applied
walls_hit: [implementer, verify-pr, reviewer]
---

# Ported-but-unwired production gate: `showEngineeringTools` dropped in UIKit→SwiftUI migration

## What happened

The UIKit→SwiftUI migration of the Developer/Testing settings screen
(`TPPDeveloperSettingsTableViewController` → `DeveloperSettingsView`) **ported**
the engineering-tier runtime gate as a computed property
(`DeveloperSettingsViewModel.showEngineeringTools`) but **never wired it into the
view body**. The old VC filtered `visibleSections` by
`audience == .support || showEngineeringTools`, so on a **production App Store
build** (`showEngineeringTools == false`) a patron who tripped the version-label
long-press saw *nothing* engineering. The new SwiftUI `body` rendered **all**
engineering sections unconditionally — so on production a patron reaching the
Testing screen would see Feature Flags and could flip `RemoteFeatureFlags` local
overrides, which take **precedence #1** over Firebase/`#if DEBUG` and therefore
**change production behavior on a real user's device**. The ported property was
also dead code (zero usages).

## Why the walls missed it

- **implementer**: the draft moved the gate logic (the pure `shouldShowEngineeringTools`
  is even unit-tested) but didn't connect it to the UI — a classic "logic ported,
  wiring dropped" gap. The unit tests pinned the *decision*, not that the view
  *consults* it.
- **verify-pr / simdrive (DoD #12)**: the on-sim AC-verification ran on a **dev
  build**, where `showEngineeringTools == true`, so the production-only gated
  state is **structurally invisible** to a live dev-build pass. This is the same
  class as the PP-4775 series-plaintext and PP-4797 launch-skeleton states: an
  environment/tier-specific state a normal run can't produce.
- **reviewer**: the architect SoD review **did** catch it (this entry's whole
  point). It only surfaced because this was flagged critical-path-adjacent and
  got an architect pass.

## Permanent fix

1. **Applied (this PR):** gate the Testing-screen body on
   `viewModel.showEngineeringTools`, matching the retired VC's `visibleSections`
   filter (commit gating `DeveloperSettingsView.body`).
2. **Rule (add to the DoD #12 fixture clause):** environment/tier-gated states
   (production-vs-dev, feature-flag on/off, low-memory) are the *same fixture
   case* as transient states — a dev-build sim pass cannot observe a
   production-only gate, so **any migration that ports a visibility/audience gate
   must either (a) add a debug toggle/fixture that simulates the gated (e.g.
   production-tier) build so the gated view can be verified, or (b) get an
   architect review that traces the ported gate to a live use-site.** "The
   property compiles and is unit-tested" is not evidence the gate is wired.
3. **Reviewer checklist add:** when a PR migrates a view that had audience/tier
   filtering, ask "where is the ported gate *consumed*, and is there a test/pass
   that exercises the *gated-off* branch?" A ported gate with zero use-sites is a
   dropped gate, not preserved behavior.

## Link

Fix commit: gating `DeveloperSettingsView.body` on `showEngineeringTools` +
un-staling the `AppAdvancedSettingsView` comment (PP-4788 branch).
