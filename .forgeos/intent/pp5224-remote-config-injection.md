---
name: pp5224-remote-config-injection
created: 2026-09-23
author: claude-opus-5
---

## Summary

PP-5224. `RemoteFeatureFlagsTests.testInAppPlaybackNav_noOverride_defaultsOff`
claims to prove the in-app player is off by default. It pins the one input it
controls — the local override, in a throwaway UserDefaults suite — and the code
under test then reads a second input the test never touches: Remote Config, via
the uninjected `FirebaseManager.shared` singleton. The assertion therefore only
holds on a machine where Remote Config never fetched. It is green in CI (fresh
simulators never fetch) and red on any developer machine that has run the app
since `in_app_playback_nav_enabled` was switched on.

`RemoteFeatureFlags` already injects `defaults` for exactly this reason, with a
doc comment saying "There is NO fallback once injected". This gives the Firebase
side the same treatment.

Two findings that enlarge the ticket as written:

- The ticket says to check "the sibling flag". There are EIGHT flags with the
  override-then-Firebase shape, not one: triageBot, triageBotTicketSubmission,
  triageBotAIFallback, triageBotForceSubmitFailure, inAppPlaybackNav,
  continuationCards, sideLoading, lcpAudiobookStreaming. Injecting the source
  fixes the class of defect for all of them at once.
- `testContinuationCards_noOverride_defaultsOff` carries the identical defect
  today and passes only because `continuation_cards_enabled` has not been
  switched on yet. It is the same failure waiting for its rollout, not a
  different one.

## Claims

- adds a `RemoteConfigProviding` protocol naming the six FirebaseManager members RemoteFeatureFlags actually consumes
- conforms FirebaseManager to that protocol without changing any of its behaviour
- adds a `remoteConfig` parameter to the RemoteFeatureFlags initializer, defaulting to FirebaseManager.shared so every production call site is unchanged
- replaces all six direct FirebaseManager.shared reads inside RemoteFeatureFlags with the injected provider
- rewrites testInAppPlaybackNav_noOverride_defaultsOff to pin the Remote Config value instead of inheriting the machine's
- rewrites testContinuationCards_noOverride_defaultsOff the same way, since it carries the same defect
- adds tests asserting the override still wins over the injected Remote Config value, in both directions

## Anti-claims

- does NOT change what any flag returns in production; the default argument preserves every existing call site
- does NOT change FirebaseManager's own behaviour, threading, or its RemoteConfig access pattern
- does NOT move `FirebaseManager.RemoteConfigKey`, which the file's own comment records as the SDK adapter that cannot move to the leaf package
- does NOT touch the PalaceFeatureFlags leaf package or the `FeatureFlagProviding` seam
- does NOT alter the flag values held in Firebase Remote Config
- does NOT address the `AccountsManagerStateMachineWiringTests` singleFlight flake, which is a separate pre-existing issue

## Files in scope

- Palace/FeatureFlags/RemoteFeatureFlags.swift
- PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift
- .forgeos/intent/pp5224-remote-config-injection.md (NEW)
