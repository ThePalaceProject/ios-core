---
name: pp4527-where-am-i-reachable
created: 2026-06-23
author: claude-opus-4-8
---

## Summary

Make the PP-4527 "Where am I?" reading-position report actually REACHABLE for
VoiceOver users. It shipped (#1098) as a `UIAccessibilityCustomAction` on
`navigator.view`, but that view is `isAccessibilityElement = false` and
VoiceOver focuses the Readium WKWebView content (a separate AX tree), so a
custom action on the container never surfaces in the VoiceOver Actions rotor —
confirmed on a physical-device VoiceOver pass AND via host-AX tooling (the
reader content group exposes zero reachable custom actions). The position
report itself (`announceCurrentPosition`) works; only its entry point was
unreachable.

Fix: expose "Where am I?" as a VoiceOver **custom rotor** on `navigator.view`.
Custom ROTORS attached to the container DO surface to VoiceOver while focused on
WKWebView content (verified on-device: the PP-4533 "Blocks" rotor appears),
whereas custom ACTIONS on the container do not. The rotor is non-visual (no
control added to the UI), matching the original "never a visible control"
intent. Also adds a PP-4533 block-nav step `os_log` so the rotor focus-walk
execution is log-verifiable (the WKWebView focus-walk isn't host-AX-observable).

## Claims

- adds `makeWhereAmIRotor()` to `TPPEPUBViewController` — a `UIAccessibilityCustomRotor` named `Strings.TPPBaseReaderViewController.whereAmI` whose search block calls the existing `announceCurrentPosition()` (one-shot trigger; returns nil, focus unchanged)
- attaches the "Where am I?" rotor to `navigator.view.accessibilityCustomRotors` in the VoiceOver branch of `configureAccessibilityActions()` (always present for VoiceOver readers), alongside the existing customRotorActionsEnabled-gated "Blocks" rotor (PP-4533)
- clears the VoiceOver-branch container custom action (`navigator.view.accessibilityCustomActions = nil`), which was unreachable; the keyboard/FKA branch keeps `whereAmIAction` (FKA reaches container custom actions via Tab-Z)
- adds a `Log.info` step line to `evaluateBlockMove` — "PP-4533 block-nav step forward=… moved=… tag=…" — for log-based step verification

## Anti-claims

- does NOT change `announceCurrentPosition` logic or the position-report content
- does NOT make `navigator.view` an accessibility element (preserves the touch-handling guard) and does NOT touch the WKWebView content AX tree or override `accessibilityElements`
- does NOT add any visible control (the rotor is a non-visual VoiceOver affordance)
- does NOT change `TPPBaseReaderViewController` (no toolbar button) and does NOT change the PP-4533 block-marking/rotor behaviour — only adds a step log line
- not a version bump

## Files in scope

- `Palace/Reader2/UI/TPPEPUBViewController.swift`
- `.forgeos/intent/pp4527-where-am-i-reachable.md`
