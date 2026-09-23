---
name: 0f06402c-dominant-color-coreimage-render-abort
created: 2026-06-29
author: claude-opus-4-8
type: bugfix
tracking: Crashlytics 0f06402c — TPPBook.updateDominantColor SIGABRT, 4 events / 4 users / 14d on 3.1.0 (478). develop-only (3.2.0 RC frozen per palace-pm).
related_prs: []
---

# Intent: 0f06402c — dominant-color CoreImage render abort (createCGImage)

## Claims
- Replaces `CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)` in
  `TPPBook.updateDominantColor` with `CIContext.createCGImage(_:from:format:colorSpace:)`
  (returns nil on failure) + a 1x1 `CGContext` pixel readback.
- Removes the dead `do/catch` (the render call is non-throwing; a native C++
  abort cannot be caught by Swift). Any failure now falls back to
  `dominantUIColor = .gray`.

## Anti-claims
- Does NOT change the areaAverage computation, the pre-render validation guards,
  the low-memory skip, or the resize path — only the final 1x1 readback that
  aborted.
- Does NOT alter `dominantUIColor`'s type or any caller.
- No `#if DEBUG` on production code.

## Files in scope
- Palace/Book/Models/TPPBook+Presentation.swift

## Reproduction
- Real artifact: Crashlytics 0f06402c — SIGABRT, C++ abort inside native
  CoreImage `render`, blamed `closure #1 in closure #1 in
  TPPBook.updateDominantColor(using:)` at the `Self.sharedCIContext.render(...,
  toBitmap:...)` call. Sample events are preceded by clusters of "Failed to
  decode image data" / "Failed to create resized CGImage" warnings — corrupt /
  degenerate cover images that pass the pre-render guards yet leave the CIImage
  in a state where `CIContext.render(toBitmap:)` aborts internally.
- Deterministic unit repro is not reliable (the abort is in closed-source
  CoreImage on specific malformed covers); the fix is structural — eliminate the
  call that can abort.

## Root cause
`CIContext.render(_:toBitmap:)` performs an internal CoreImage render task that
calls `abort()` (not a Swift error, not a force-unwrap) on certain degenerate
inputs. Because it is non-throwing, the surrounding `do/catch` never executed and
the process was killed. `createCGImage(_:from:)` is the defensive variant — it
returns nil on failure instead of aborting — so routing the 1x1 readback through
it removes the abort path while preserving the averaged-pixel result.

## Verification
- Build + `PalaceTests` green (no regression in cover/color paths).
- simdrive smoke: catalog renders with cover dominant-colors applied, no crash
  (the corrupt-cover abort is intermittent/data-specific; durable confirmation is
  3.3.0 telemetry).

**Not done / deferred:** stricter upstream cover-decode validation (the warnings
that precede the crash originate in `TPPBookCoverRegistry` decode) — separate,
lower-priority surface; this change removes the fatal abort regardless.
