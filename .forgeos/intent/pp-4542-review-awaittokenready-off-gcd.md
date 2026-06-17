---
name: PP-4542 review remediation awaitTokenReady off GCD
created: 2026-06-17
author: claude-opus-4-8
---

## Summary

Remediation of the two independent-reviewer BLOCK verdicts on the PP-4542
audiobook cold-load PR (#1094): the architect flagged that
`AudiobookLoader.awaitTokenReady` reintroduced GCD on the audiobook critical
path (recursive `DispatchQueue.global().asyncAfter`) in contradiction of
`adr_a265ec76`, while its sibling `awaitAudiobookContentLocal` already polls
correctly with `Task.sleep`; and both reviewers flagged the open-time
remote-vs-local decision `preferRemotePosition` as shipped without unit
coverage on a critical-path FR. Neither found a correctness defect.

## Claims

- rewrites `AudiobookLoader.awaitTokenReady` from a recursive
  `DispatchQueue.global(qos:).asyncAfter` poll to a `Task` + `Task.sleep`
  loop, keeping the audiobook open path off GCD per `adr_a265ec76`
- preserves the existing `awaitTokenReady` API and semantics exactly: same
  `nonisolated static` signature, same `completion: (Bool) -> Void`, same
  bounded `timeout`/`pollInterval`, same re-read of `currentUserAccount`
  each tick, same terminate-on-token-valid / terminate-on-deadline behaviour
- adds a 7-case table test for `AudiobookSessionManager.preferRemotePosition`
  (the strict `> 5.0s` remote-newer rule, plus the no-local / unparseable-local
  / unparseable-remote / remote-older branches and the exact-5s boundary)
- documents (comment-only) why the upfront `#if LCP` download gate and the
  reactive `.playbackFailed` download gate are mutually exclusive and cannot
  stack to 360s

## Anti-claims

- does NOT change `awaitTokenReady`'s observable behaviour — it is a
  GCD→structured-concurrency swap of the poll mechanism only
- does NOT change `preferRemotePosition` itself (test-only addition)
- does NOT change any control flow on the open/restore path; the
  `AudiobookSessionManager` edit is a clarifying comment, no executable change
- does NOT touch the audiobook toolkit submodule, DRM, or network code

## Files in scope

- Palace/Audiobooks/AudiobookLoader.swift
- Palace/Audiobooks/AudiobookSessionManager.swift (comment only)
- PalaceTests/Audiobooks/AudiobookPositionRestoreTests.swift
- .forgeos/intent/pp-4542-review-awaittokenready-off-gcd.md (NEW)
