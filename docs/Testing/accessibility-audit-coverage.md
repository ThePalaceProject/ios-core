# Accessibility-audit coverage after the PalaceUITests removal

**Status:** recommendation · **Date:** 2026-07-06 · **Context:** PR #1188 removed the
never-wired `PalaceUITests/` XCUITest bundle. Its `Accessibility/` suite
(`AccessibilityAuditTests`, `DynamicTypeSnapshotTests`) *aspired* to run
`XCUIApplication.performAccessibilityAudit(...)` across Catalog / My Books /
Book Detail / Sign In / Settings and across Dynamic Type sizes. Because the
bundle had no build target it **never executed** — so nothing regressed. But
`performAccessibilityAudit` is the one capability simdrive's vision-first OCR
loop does **not** replicate, so this note pins how we cover element-level
accessibility going forward and what (if anything) to rebuild.

## What each tool actually covers

| Capability | Tool | Status |
|---|---|---|
| Missing `.accessibilityLabel` / `.accessibilityIdentifier` on changed UI files (static) | `scripts/verify-pr.sh` a11y gate (§6) | **active** — blocks PRs that add UI without labels |
| Contrast / white-on-white, light **and** dark | simdrive `visual_checks` (vision review, both appearances) | **active** — caught the PP-4168 dark-mode contrast bug |
| VoiceOver announcements + rotor custom actions (dynamic) | simdrive `get_announcements`, `perform_accessibility_action` | **active** — `.simdrive/journeys/PP-4529-print-page-navigation-voiceover.yaml` |
| Element-level runtime audit: contrast ratios, hit-region ≥44pt, clipped/truncated text, element-with-no-label, trait mismatches | `XCUIApplication.performAccessibilityAudit` | **GAP** — no runner since the orphan bundle went |
| Layout integrity across Dynamic Type sizes | (was `DynamicTypeSnapshotTests`) | **GAP** — partially reachable via simdrive per-size screenshots + vision review, but not an automated audit |

The static gate catches *authoring* omissions; the simdrive journeys catch
*dynamic* VoiceOver behavior and *visual* contrast. The gap is the **automated,
element-level runtime audit** — the thing `performAccessibilityAudit` uniquely
does in one call.

## Options for the gap

1. **Minimal audit-only XCUITest target (recommended if we want the audit back).**
   A UI-testing bundle whose *entire* job is `performAccessibilityAudit` on a
   handful of key screens. Audits are **deterministic** (no flaky UI hunting —
   launch, navigate to a screen, audit, assert zero issues), so they don't
   violate the green-board contract the way live chaos does. This is a
   *deliberate, wired* target (real pbxproj entry + scheme reference + a CI
   job), not resurrected orphan scaffolding. Cost: one small target + a slow-ish
   CI lane. **Do this only if element-level audit coverage is judged worth a
   second UI target** — that's the decision this note surfaces, not assumes.

2. **Lean on the active layers (recommended if audit coverage is "nice to have").**
   Static label gate (verify-pr) + simdrive contrast `visual_checks` in both
   appearances on every gate/dialog screen + simdrive VoiceOver journeys for the
   dynamic paths. This covers the highest-severity, most-regressed classes
   (missing labels, contrast, VoiceOver wiring) without a new target. It does
   **not** cover hit-region size or clipped-text-at-large-Dynamic-Type
   automatically.

3. **simdrive vision heuristics for Dynamic Type (complementary).**
   Drive each key screen at the largest accessibility text size and run a
   `visual_checks` vision pass for truncation/overlap. Not a substitute for a
   real audit, but closes the most visible Dynamic Type regressions cheaply.

## Recommendation

Adopt **Option 2 as the standing floor** (it's already active and covers the
high-severity classes), and treat **Option 1 as an explicit, separately-decided
follow-up** — a *wired* audit-only XCUITest target is the only way to get
`performAccessibilityAudit`'s element-level checks back, and it should be added
on purpose (with its own CI lane and a pytest-style green-path assertion) rather
than by un-orphaning the deleted bundle. Add Option 3's largest-Dynamic-Type
vision pass to the standing local chaos-QA checklist for any PR that changes a
text-bearing surface.

Owner decision needed on Option 1: is element-level runtime audit coverage worth
one deliberate UI-testing target? Until that's answered, the gap is covered at
the "labels + contrast + VoiceOver" level, not the "full audit" level — stated
here so the reduction is explicit, not silent.
