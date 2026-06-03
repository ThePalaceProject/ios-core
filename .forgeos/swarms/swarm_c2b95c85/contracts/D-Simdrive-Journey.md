# Module D — Simdrive Journey + Baselines

**Standard risk.** Pure YAML + per-version baseline directory. Zero
production code. Records the end-to-end PP-4161 flow against the lyrasis-
reads (staging) repro book.

## Goal

Record a simdrive journey covering the full user flow for streaming-HTML
titles, with SSIM-gated visual regression and structural-check verification
of the reader chrome.

## What public types/protocols change

None. Pure tooling artifacts.

## Files scoped to THIS implementer

NEW:
- `.simdrive/journeys/PP-4161-streaming-html-reader.yaml`
- `.simdrive/fixtures/baselines/<current-version>/PP-4161-streaming/<step>.{png,json}` (one per step from the journey recording)

Tooling:
- `~/harness/bin/harness simdrive status` to confirm version + active sessions before recording.
- `simdrive record_start` / `record_stop` workflow per CLAUDE.md "simdrive" section.
- Pre-grant permissions before `session_start` (per `feedback_simdrive_pregrant_alerts.md`).

## Files explicitly OFF-LIMITS

- All production Swift / pbxproj
- All test Swift
- `.simdrive/_archive/` (legacy SpecterQA — do not extend)

## Test contracts the module must satisfy

The journey YAML must:

1. **Be tier1 + blocking + recording-aligned.** `tier: stateful`, `blocking: true`,
   `recording.path: ~/.simdrive/recordings/PP-4161-streaming-html-reader/recording.yaml`.

2. **Cover the full flow.**
   - launch + sign-in to Palace Bookshelf (staging)
   - search urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef
   - open book detail
   - tap Read (or Borrow if not yet borrowed → then Read)
   - reader renders
   - scroll (≥200px)
   - tap Close
   - reopen the same book
   - reader returns to saved position (structural check: same scroll y-coordinate within tolerance)

3. **Structural checks.**
   - After "tap Read": `required_text: ["Close"]` AND `min_marks: 5` (web content visible).
   - After "tap Close": `required_text: ["Read", "Borrow"]` (back to detail).
   - After "reopen": `required_text: ["Close"]` AND a step-level note that the
     baseline PNG for this step encodes the scroll-restored position.

4. **SSIM gating.** `threshold: 0.85`, `on_drift: warn` (since web content can
   re-flow on different network latencies).

5. **Rationale block** documenting the repro book + intent reference.

## Verification criteria (MANDATORY)

1. **Journey YAML exists:**
   ```bash
   test -f .simdrive/journeys/PP-4161-streaming-html-reader.yaml && echo OK
   ```

2. **Journey validates via simdrive MCP** (preflight-confirmed v2 per Phase 1a
   advisory D: `harness simdrive validate-journey` does NOT exist; use the
   MCP `validate_replay` instead):
   ```
   mcp__simdrive__validate_replay name=PP-4161-streaming-html-reader
   ```
   Returns success — paste the MCP response.

3. **Baselines exist for each step:**
   ```bash
   ls .simdrive/fixtures/baselines/*/PP-4161-streaming/ | wc -l
   ```
   Should return ≥ N×2 where N is the step count (each step has .png + .json).

4. **Recording path exists:**
   ```bash
   test -d ~/.simdrive/recordings/PP-4161-streaming-html-reader/ && echo OK
   ```

5. **Journey replays end-to-end via simdrive MCP:**
   ```
   mcp__simdrive__replay name=PP-4161-streaming-html-reader on_drift=halt drift_threshold=0.85
   ```
   Returns success — paste the MCP response.

5. **No production-code edits:**
   ```bash
   git diff origin/feat/PP-4161-streaming-html-reader --name-only -- 'Palace/' 'PalaceTests/'
   ```
   Must return empty.

## Definition of Done evidence

1. Journey replays successfully — paste the replay output.
2. Validation passes — paste the lint output.
3. Per-step baselines committed — paste `ls .simdrive/fixtures/baselines/<ver>/PP-4161-streaming/`.
4. No anti-scope edits — paste empty git diff output.

## Implementer prompt

You are Module D implementer for swarm_c2b95c85 (PP-4161). Record a
simdrive journey covering the full streaming-HTML reader flow against the
repro book `urn:uuid:84dac408-77ce-4afc-8393-9e0ced7ea3ef` on lyrasis-reads
(staging). Read `.forgeos/intent/pp-4161-streaming-html-reader.md` "simdrive
journey" Claims section + CLAUDE.md "simdrive" section. Module C must be
merged before you start — the journey records against working production
code. Pre-grant permissions before `session_start`. Always `observe` with
`annotate=true` before `tap text=...`. Re-observe after every navigation.
SSIM gating 0.85 with `on_drift: warn`. NO production edits.
