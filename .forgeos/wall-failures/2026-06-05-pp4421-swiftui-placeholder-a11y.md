---
date: 2026-06-05
pr: "swarm_162a3219 / Module D2"
source: shipped-bug
reviewer_ids: []
changeset_id: cs_swarm_162a3219_modD2
wall: verify-pr
walls: [verify-pr, hook, reviewer]
severity: medium
wall_status: applied
applied_in: "scripts/check-swiftui-placeholder-a11y.py + scripts/tests/test_check_swiftui_placeholder_a11y.py"
detector_script: scripts/check-swiftui-placeholder-a11y.py
contributing_docs: []
# doc-lifecycle metadata
name: pp4421-swiftui-placeholder-a11y
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [signin, accessibility]
description: SwiftUI bare-string TextField/SecureField/Button labels render `.placeholderText` gray and read as disabled controls — VoiceOver users hear placeholder as the label.
---

# PP-4421 — SwiftUI placeholder/label reads as disabled control

## Finding (verbatim from reviewer / bug report)

HelpSpot 17923 (escalated to PP-4421): patron complaint that the Palace iOS sign-in screen "looks broken — the username and PIN fields look greyed out like they're disabled, but tapping them brings up the keyboard." Sighted users misread the default SwiftUI `.placeholderText` rendering (~30% gray) as a disabled control. VoiceOver users also hear the placeholder text as the field's `accessibilityLabel` because no explicit label was set.

Canonical fix landed in commit `e761a6ed3` (PP-4421): each `TextField` / `SecureField` in `Palace/Settings/AccountDetailView.swift` was wrapped with `prompt: Text(label).foregroundColor(.secondary)`, swapping the placeholder color from `.placeholderText` (~30% opacity) to `.secondary` (~60% opacity).

A prior engineering attempt (commit `547e185aa`, PR pre-#976) wrapped each field in a VStack with a permanently-visible non-tappable "Tap here to enter your X" caption — reverted in PR #976 for shipping unapproved user-facing copy. The current `prompt:` fix is the design-safe path because it touches only platform-semantic colors, no new strings.

## What actually happened

SwiftUI `TextField` / `SecureField` initializers take a `String` label as the first positional argument that does double duty:

1. Visual placeholder rendered in the field while it's empty.
2. The view's implicit `accessibilityLabel` for VoiceOver.

The default placeholder color (`.placeholderText`) is light gray, which on the AccountDetailView surfaces — a white sheet with `.foregroundColor(.primary)` typed text — visually reads as "control is disabled." Patrons reported the sign-in screen looked broken. The same bug class applies anywhere a SwiftUI bare-string label is used (TextField, SecureField, and to a lesser degree Button label-closures when the only content is a bare `Text("short literal")`).

The implementer who landed `547e185aa` saw the visual problem (gray placeholder) and the a11y problem (VoiceOver reads placeholder) and reached for the wrong tool — a permanently-visible caption Text wrapper that introduced new user-facing copy without design sign-off. The right tool was already in the SwiftUI surface: `prompt:` with explicit `.foregroundColor(.secondary)` darkens the placeholder without touching copy or structure.

## Walls that should have caught it (and why they didn't)

- **verify-pr**: had no detector for this SwiftUI pattern. No grep, no AST walker, no lint rule could flag a bare-string `TextField("Foo", text: ...)` and ask "where's the `.accessibilityLabel` or `prompt:` override?" Closed structurally by this entry's `detector_script`.
- **hook**: same — no pre-commit hook had visibility into SwiftUI placeholder semantics. The PR-body language ("fix placeholder text") was a copy-paste of the symptom, not a probe of the surface area.
- **reviewer**: a single PR went to design review at the wrong stage — the reverted "tap here" caption shipped without design seeing it. The `prompt:` fix is the design-safe path that should have been the first move.

## Proposed permanent fix

**Applied:** `scripts/check-swiftui-placeholder-a11y.py` (D2 detector) flags SwiftUI bare-string TextField/SecureField/Button calls that lack a `.accessibilityLabel(...)` modifier within a small downstream window, lack a `prompt:` override on field calls, and aren't suppressed by a `// no-a11y-label: <reason>` annotation. The detector lives at `scripts/check-swiftui-placeholder-a11y.py` and is verified by `scripts/tests/test_check_swiftui_placeholder_a11y.py` (4 fixtures: violation, clean-with-accessibilityLabel, clean-with-bare-text-but-annotation, false-positive-immunity). Integrator wires it into `scripts/verify-pr.sh` via `run_m1_check` and `.claude/settings.json` as a PreToolUse hook in the same shape as the existing M1 detectors.

The detector is greppable:

```bash
python3 scripts/check-swiftui-placeholder-a11y.py --scan Palace --quiet
```

Predicate summary (full spec in the script docstring):

1. `TextField(<short-literal-or-identifier>, text: ...)` / `SecureField(...)` with no `.accessibilityLabel(` and no `prompt:` in the downstream-cure window (8 lines).
2. `Button(action: ..., label: { Text("short-literal") })` (same-line or multi-line opener) with no `.accessibilityLabel` in the downstream window.
3. Short literal threshold: ≤30 characters. Longer strings are body copy, exempt.
4. Annotation escape: `// no-a11y-label: <reason>` in the preceding 3-line window suppresses the finding.

False-positive guards:

- `NavigationLink { ... } label: { Text(...) }` is NOT flagged — navigation labels are the destination name, the right VoiceOver announcement.
- Pre-existing `prompt:` or `.accessibilityLabel` within the downstream window cures the call.

## Survivor wipes

D2 detector found 3 survivor sites outside the original PP-4421 scope (`Palace/SignInLogic/` + `Palace/Settings/`). All 3 wiped in the same swarm following the same `prompt: Text(...).foregroundColor(.secondary)` pattern as the canonical fix:

- `Palace/MyBooks/MyBooks/MyBooksView.swift:161` — search-books TextField.
- `Palace/PDF/Views/TPPPDFSearchView.swift:40` — PDF search TextField.
- `Palace/Reader2/UI/EpubSearchView/EPUBSearchView.swift:51` — EPUB search TextField.

Re-scan after wipes: `0 SwiftUI placeholder-a11y finding(s)`.

## Stale-doc contribution

N/A — `stale-doc` is not in `walls:`.

## Application log

- 2026-06-05 — detector + tests + 3 survivor wipes landed in swarm_162a3219 / Module D2 implementer pass. Integration into `verify-pr.sh` and `.claude/settings.json` is the integrator's job (Phase 4 of the swarm).

## Related entries

- Cluster: SwiftUI a11y / disabled-UI perception — sibling detectors landing in the same swarm (D1 LCP acquisition-chain recursive, D3 completion-nil error suppression, D4 NSError problem-doc preservation, D5 NotificationCenter observer storage) all close similar bug-class holes structurally rather than relying on reviewer vigilance.
- The reverted PR #976 caption attempt is the canonical "wrong tool" pin: shipping new user-facing copy without design review (see also `feedback_no_new_copy_without_design.md` in memory). The detector closes the structural hole the reverted PR exposed.
