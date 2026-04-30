# simdrive v0.1.0a1 — Palace iOS dogfood feedback (2026-04-29)

**Tester:** Maurice Carrier · iOS solo · Palace iOS Core
**Workload:** PP-4164 regression (release/3.0.0 vs candidate) — captured a 6-step `anonymous-borrow` flow on two iPhone 16 Pro sims (iOS 18.4) and built a fixture-based test corpus in `.specterqa/fixtures/`.
**Volume:** ~50 `observe` calls, ~30 `tap` / `swipe` / `type_text` calls, 2 sims, 6 successful sessions out of 8 attempts.

## P0 — Blocks fixture-based test infrastructure

### 1. `marks` JSON is not persisted to disk

The MCP response from `observe` returns a rich `marks` array (id, bbox, center, text, confidence). Only the raw PNG and SoM-annotated PNG end up in `~/.simdrive/sessions/<id>/observations/`. The structured data never lands on disk.

- **Impact:** Building a reproducible fixture corpus requires manually capturing every MCP response. Every `.json` file in our PR was hand-curated from the assistant chat history, which is brittle and doesn't scale.
- **Suggested fix:** Sidecar `<screenshot-name>.json` next to each PNG, OR a single `observations.jsonl` per session. Same fields as the MCP response.
- **Bonus:** Persist the `tap` / `swipe` / `type_text` action history alongside, so a session directory becomes a full replay-ready artifact without `record_start`.

## P1 — User-facing reliability issues

### 2. `type_text` mangles case and substitutes characters

Typed `"A1QA"`. Subsequent `observe` showed `"A1qa"` once and `"Alqa"` a second time (`A`, lowercase `l`, `qa` — char substitution, not just lowercasing).

- **Repro:** Add Library screen → tap search Q → `type_text("A1QA")` → observe.
- **Impact:** Any form needing exact strings (most importantly auth creds) is unreliable. We had to skip the A1QA basic-auth path and the SAML/OIDC paths entirely because typed input couldn't be trusted.
- **Likely cause:** HID injection isn't using shift modifiers correctly, or iOS's keyboard auto-capitalization is racing the inject.

### 3. App exits on `< Back` tap (candidate-only)

Tap at y=235 on a clearly-visible "< Back" nav-bar mark caused the app to enter exit handler ~1s later. Reproduced on the candidate build (`regression/PP-4164-3.0.1` head); did NOT reproduce on the baseline (`release/3.0.0`).

Log signature:
```
13:17:34.000 ... [normal scene init / Firebase setup / CoreData attach]
13:17:34.445 E  Palace [com.apple.dt.xctest:Default] Failed to create a bundle
              instance representing '.../Palace.app/PlugIns/PalaceTests.xctest'.
              Check that the bundle exists on disk.
13:17:34.446 Df Palace [com.apple.CoreAnalytics:client] Entering exit handler.
```

The `PalaceTests.xctest` probe error appears in **both** baseline and candidate logs, but the exit only happens on candidate. Suggests simdrive's xctest-runner attachment is interacting with the candidate's scene-lifecycle teardown on dealloc.

- **Workaround:** `session_end(terminate_app: true)` + `session_start` between phases — works, but loses any in-flight UI state.
- **Suggested investigation:** Is the xctest-probe necessary at session_start? Could it be made lazy-on-first-record-call?

## P2 — Quality-of-life

### 4. `mark:N` IDs reshuffle on every `observe`

Designed behavior, but it's a sharp edge. Easy to call `observe` → think → `tap mark:7` and have mark:7 mean a different element than the one the observation showed.

- **Suggestion:** Add a stable id mode, OR include a `text_hash` (e.g., `xxhash64(text + bbox_centerx)`) on each mark so callers can re-find the same element across observations without recapture.

### 5. Swipe coords need a home-indicator guard rail

`swipe(x1=600, y1=1800, x2=600, y2=2400)` on a 1206×2622 simulator fired the iOS home gesture and exited the app twice today.

- **Suggestion:** If `y2 > screen_height - 100`, emit a warning in the response: `"warning": "swipe end y=2400 is in the home-indicator zone; expected home gesture"`. Or auto-clamp with an opt-out flag.

### 6. First-tap on iOS notif-permission alert is sometimes lost

About 1 in 4 first-launch sessions: `tap text="Allow"` on the SpringBoard notification permission alert appeared to register (response said success) but the alert stayed up and on the next observe the app had dropped to home screen. Subsequent `session_start` + retap worked on the same install.

- **Hypothesis:** Race between the alert's PIDChange (it lives in SpringBoard's process) and simdrive's HID injection target.

## What's working great (don't break these)

- **`observe` SoM detection.** Confidence usually 1.0, accurate bboxes, robust on mixed text/icon screens. Annotated PNGs (red-bordered numbered overlays with text labels) are the right visual diff format.
- **`tap` by `text`.** Sensible fuzzy fallback (exact > prefix > substring), and the response includes the resolution path (`"resolved_via": "text:'Borrow'->mark:14"`) which makes it trivial to debug when it picks the wrong target. Keep this.
- **`logs` with NSPredicate.** Genuinely useful — the xctest-probe→exit signature in P1 #3 came straight from a one-line predicate. Keep this surface.
- **`session_end(terminate_app: true)` recovery.** Whenever the sim got into a weird state, ending and restarting the session always recovered cleanly.

## Concrete asks (in order)

1. **Persist `marks` JSON to disk** — biggest unlock for downstream test-infrastructure work.
2. **Fix `type_text` casing/substitution** — biggest unlock for credentialed flows.
3. **Investigate the candidate-only Back-button exit** — biggest unknown; could be ours, could be yours, the log signature is yours.
4. **Add home-indicator guard rail** — small UX polish.
5. **Sidecar action log per session** — enables auto-generation of replay YAMLs from any captured session.

Happy to repro any of the above on a screen-share. Also happy to test a v0.1.0a2 wheel against the same flow as soon as it ships.
