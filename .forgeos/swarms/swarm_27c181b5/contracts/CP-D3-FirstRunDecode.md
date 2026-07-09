
---

## Phase 1a corrections (MANDATORY before dispatch — the naive fix regresses first-run)

The architect Phase 1a BLOCKED the original "move the dedupe above the bundled branch"
instruction because it produces a real first-run regression. Corrected requirements:

1. **CONSOLIDATE the dedupe, don't just move it.** If you move `addLoadingHandler`
   above the bundled branch AND leave the existing guard at ~:920, the first caller
   registers up top → does the bundled decode → falls to :920 → sees ITS OWN
   registration → returns true → `return` BEFORE `fetchFromNetwork` at :922. Net
   effect: on fresh install the network fetch NEVER fires and the picker is stuck on
   stale bundled data until the next launch. REQUIRED: a SINGLE dedupe guard covering
   the bundled branch; REMOVE the now-redundant :920 guard. The bundled branch's
   completion is `_ in` and does not clear handlers, so handler-clearing still happens
   on network completion — verify that's preserved.

2. **Strengthen the test.** The contract's "bundled decode executes once" test would
   PASS while this regression ships. REQUIRED: add a test asserting the NETWORK FETCH
   still fires exactly once after the bundled decode (not merely that the bundled
   decode runs once). A dedupe that swallows the network fetch must fail this test.

3. **Bump BOTH QoS arms.** The `:475` bump (`.background`→`.utility`) is the RELEASE
   arm; the DEBUG arm at `:471` uses `Task.detached(priority: .background)`. Tests run
   DEBUG, so a `:475`-only change means tests exercise a different QoS than production.
   Bump both (or document why not).

## Rebase note
D3 shares AccountsManager.swift with CP-D1 (now landed on this branch — the slim
snapshot) — build on that version, do NOT touch preloadAccountsFromDiskCacheSync's
slim/lazy hydration. D3 shares TPPAppDelegate.swift with Wave B/Network (merged).
