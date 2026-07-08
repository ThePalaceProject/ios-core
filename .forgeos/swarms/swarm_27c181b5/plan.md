# swarm_27c181b5 — Startup + library-switch performance program

## Goal
Cut cold-launch time and library-switch cost. Two user-visible wins: (1) switching
A→B→A serves books from the account-scoped cache instantly instead of 3 full
fetches; (2) covers and feeds reload faster after a switch. Everything is measured
by first wiring the built-but-unwired AppLaunchTracker.

## Modules (8 contracts) — see manifest.yaml
- Tier 1 standard (Wave A / PR1): Startup-AppLifecycle, Accounts-Startup
  (standard-sensitive), Covers, CatalogUI.
- Tier 2 standard, SoD-noted (Wave B / PR2): Network.
- Tier 3 critical_path, separate contracts + architect Phase 1a + SoD (Wave C / PR3):
  CP-D1-LaunchHydration, CP-D2-CredentialSnapshot, CP-D3-FirstRunDecode.
- Tier 4 (deferred, NOT contracted): OPDSFeedCache disk-persist + ETag/304.

## Sequencing (why waves, not one big PR)
AccountsManager.swift and TPPAppDelegate.swift each fan out across fixes. To keep
contracts overlap-free, each file is single-owner PER WAVE, and the critical-path
first-run/state-machine work (CP-D1/CP-D3) is sequenced AFTER the standard
AccountsManager edits (Accounts-Startup C1/C4). CP-D3 depends_on CP-D1.

## Instrumentation-first
AppLaunchTracker milestones land in Wave A so every subsequent fix is measurable
(timeToInteractive, timeToFirstFrame). recordMilestone/LaunchMilestone already
exist — this is pure call-site wiring.

## Landing sequence
PR1 = Wave A (bundled). PR2 = Network (SoD /forge-review). PR3 = CP-D1/D2/D3 as
three separate critical_path reviews. Tier 4 deferred.

## Acceptance criteria
See manifest.acceptance_gates and each contract's Verification criteria. Every
switch-flow / state-machine change ships with the round-trip + consumer tests
CLAUDE.md mandates. Full-suite validation via scripts/verify-pr.sh --quick.
