# Module D6 — D-scan: class-semantic bugs (no detector — Explore-subagent pass)

**Owner module:** docs only — no Palace/ code
**Risk:** standard
**Est LOC:** ~60 (markdown only)

## Scope (in)

For each of the 3 class-semantic bugs identified in the Module D audit, spawn ONE Explore subagent (per Tier 2 of Phase 3.5) to scan the codebase for similar shapes. Implementer is responsible for spawning and capturing findings; produces ONE outcome doc per ticket at `.forgeos/swarms/swarm_162a3219/d-scan/<ticket>.md`.

| Source ticket | Class to scan | Scope of Explore agent |
|---|---|---|
| HelpSpot 17865 / "NowPlaying backgrounded freeze" | Timer-nil-on-background pattern: any `Timer.publish(every:)` that is invalidated/replaced on `didEnterBackground` without a 15s background re-establishment. Audit `Palace/Audiobooks/` + `Palace/CarPlay/`. | Find all `didEnterBackgroundNotification` observers + paired timers; report which timers are nilled (correct for energy savings) vs which should remain alive at slower cadence (writer-required). |
| PP-4420 / "Audiobook lock-screen freezes" | Similar root cause to 17865 but observed at lock-screen-engagement event. Scan `Palace/CarPlay/CarPlayTemplateManager.swift` + `Palace/Audiobooks/PlaybackBootstrapper.swift` for lock-screen-specific suspend handling. | Sibling-pattern audit; produce file:line list. |
| PP-4326 / "VoiceOver users cannot activate book entries" | SwiftUI `.onTapGesture` without paired `.accessibilityAction(named:)` on list rows. Audit `Palace/MyBooks/` + `Palace/Holds/` + `Palace/Catalog/`. | Find all tap-gesture rows that don't have a paired accessibilityAction. |

## Output

For each, write `.forgeos/swarms/swarm_162a3219/d-scan/<ticket>.md` with: scan result, count of suspect sites, recommended Tier-2 / Tier-3 follow-up (file Jira ticket OR queue detector). NO production diff in this module.

## Scope (out)

- ANY production-Swift change — D6 is observation-only. Follow-ups are filed as Jira tickets and queued for a future swarm/rigorous-fix.
- Detector building — D6's whole point is that these classes don't fit a static detector cleanly; Tier 3 is not appropriate. Document why in the outcome docs.

## Verification

- 3 outcome docs exist at `.forgeos/swarms/swarm_162a3219/d-scan/`
- Each cites file:line evidence
- Follow-up Jira tickets filed (use `mcp__jira__jira_create_issue` if available; else queue under `.forgeos/followups/swarm_162a3219.md`)

## Tests required

N/A — observation module.

## Mutation requirement

N/A.
