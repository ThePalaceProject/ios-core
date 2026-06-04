# F — transcript (orchestrator-readable)

**Status**: READY (audit-only, 0 code changes).

**Full audit**: see [`F-audit.md`](./F-audit.md).

---

## DoD evidence

### 1. Audit doc exists

```
$ [ -f /Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_47883816-orchestrator/.forgeos/swarms/swarm_47883816/transcripts/F-audit.md ] && echo OK
OK
```

### 2. Counts match grep

```
$ wc -l /tmp/F-task-sites.txt /tmp/F-dispatch-sites.txt
     106 /tmp/F-task-sites.txt
      49 /tmp/F-dispatch-sites.txt
     155 total
```

(Architect contract estimated ~170; actual 155 in the worktree at audit time. The delta is comments/method-name matches that don't form fire-and-forget sites — they are accounted for in the classification.)

### 3. Category-iii findings have follow-up ticket proposals

Two **test-side (iii)** findings + three **production-side (iii')** findings, all five with proposed Jira ticket titles in `F-audit.md` section 4:

| # | Title (proposed) | Owner area |
|---|---|---|
| PP-XXXX | DRMAdversarialTests `testAdobe_fulfillmentPath_callsEnsureDeviceActivated` is a fluff test — fix or delete | `PalaceTests/Security/` |
| PP-XXXX | PersistentLoggerTests tearDown leaks Task — migrate to `tearDown() async throws` | `PalaceTests/Logging/` |
| PP-XXXX | `DownloadAuthRetryHandler` — retain/cancel auth-retry Tasks to prevent state leaks across test boundaries | `Palace/MyBooks/DownloadAuthRetryHandler.swift` |
| PP-XXXX | `BookReturnService` — retain/cancel return-flow Tasks (OPDS fetch + cleanup hops) | `Palace/MyBooks/BookReturnService.swift` |
| PP-XXXX | `TPPUserAccount.signOut()` 100ms reset Task — retain handle for test-deterministic teardown | `Palace/Accounts/` or `Palace/SignInLogic/` |

### 4. No code changes

```
$ git status --porcelain | grep -v "^?? "
# (no Palace/ or PalaceTests/ source files modified by F)
```

Only the two transcript files (`F.md` + `F-audit.md`) under `.forgeos/swarms/swarm_47883816/transcripts/` are produced. The contract's ≤2-trivial-fix carve-out was **not** invoked — both test-side (iii) findings require non-trivial behavioral changes (DRM-flag-gated test rewrite; sync→async tearDown migration), and both production-side clusters are in critical paths explicitly off-limits to F.

---

## Classification summary

| Category | Count | Verdict |
|---|---|---|
| (i) Utility drainer / mock completion shim | ~95 | OK |
| (ii) Test-only awaited Task | ~28 | OK |
| (iii) **Test-side fire-and-forget — FLAG** | **2** | Follow-up tickets proposed |
| (iii') **Production fire-and-forget reachable from tests — FLAG** | **3** | Follow-up tickets proposed; off-limits to F |

See `F-audit.md` for per-site evidence, file:line citations, and the structural-lint suggestion for swarm package E (catching `Task { ... }` in a non-`async` test method without `let ... = Task` capture).
