# Visual Regression Fixtures

Structured behavior fixtures captured via simdrive's `observe` tool. Each fixture is a screenshot **plus** a marks JSON describing every visible text region (id, bounding box, center, OCR text, confidence). Together they let unit tests assert what the user actually sees, which catches mutation-survivor classes that ViewModel-property tests will never catch.

## Why this exists

Fixtures are the **reference data layer** that powers visual-regression tooling:

- **`marks-diff.py`** auto-generates findings.csv rows when fixture pairs (baseline vs candidate) diverge.
- **`a11y-coverage.py`** diffs visible marks vs the AX tree to surface VoiceOver gaps.
- **The Visual Coverage Matrix** in the regression report lists which flows have captured fixtures vs which are gaps.
- **Schema-validation tests** (`PalaceTests/VisualRegression/`) catch fixture drift between releases — if a UI dev reorders elements or rewords a label, the next re-capture will diverge from the checked-in JSON, and the test fails on that drift.

## What fixtures do NOT do

**Fixtures do not run production code.** The Swift tests assert against the captured JSON files; mutating `AccountsManager.swift` or `BorrowReducer.swift` does not change the static JSON, so the tests still pass. Verified via `palace_mutate.py` runs on both files (PP-4164 finding F-006): 0 of 8 AccountsManager mutants killed, 0 of 4 BorrowReducer mutants killed.

The mutation-killing layer is **simdrive replays** under `.specterqa/replays/chaos/` — those YAMLs drive the live app and SSIM-drift catches code changes. Fixtures and replays solve different problems; you need both.

## How they compose

```
fixture JSON       ─┐
                    ├──► marks-diff.py ──► auto-findings (regression candidates)
candidate marks    ─┘
fixture JSON       ────► a11y-coverage.py + simctl ax dump ──► VoiceOver coverage %
fixture JSON       ────► generate-regression-report.py --fixtures-dir ──► coverage matrix in report
fixture JSON       ────► MarksFixture.swift assertions ──► drift-catcher CI tests

simdrive replay    ────► live drive on candidate build + SSIM ──► mutation-killing CI tests
chaos-qa session   ────► discovers new replays + fixtures ──► feeds both layers above
```

## Layout

```
.specterqa/fixtures/
├── README.md                  this file
├── flows/                     YAML descriptions of each captured flow
│   └── anonymous-borrow.yaml
└── baselines/
    ├── 3.0.0/                 release version label (for diff base)
    │   └── anonymous-borrow/
    │       ├── 01-launch.png
    │       ├── 01-launch.json
    │       ├── 02-after-allow-notif.png
    │       ├── 02-after-allow-notif.json
    │       └── ...
    └── 3.0.1/                 candidate label (parallel structure)
        └── anonymous-borrow/
            └── ...
```

## Fixture JSON schema

```jsonc
{
  "fixture": "anonymous-borrow/03-catalog",   // <flow>/<step> identifier
  "version": "3.0.0",                          // release version label
  "build": "470",                              // CFBundleVersion
  "device": "iPhone 16 Pro",
  "os": "iOS 18.4",
  "udid": "F3CB599D-B154-4D40-B2C4-52F821EABAD7",
  "captured_at": "2026-04-29T16:22:00Z",       // ISO8601 UTC
  "screen_size": [1206, 2622],                 // [width, height] pixels
  "screenshot_relpath": "01-launch.png",       // sibling PNG
  "marks": [
    {
      "id": 5,                                  // simdrive mark id (per-observation)
      "bbox": [216, 598, 399, 49],              // [x, y, width, height] pixels
      "center": [415, 622],                     // [x, y] pixels
      "text": "Palace Bookshelf",               // OCR'd text
      "confidence": 1.0                         // OCR confidence 0.0–1.0
    }
  ]
}
```

## Capture workflow

1. Add a flow YAML to `flows/` describing the steps (human-readable).
2. Drive the flow via simdrive (`session_start` → `observe` → `tap`/`type_text`/`swipe` → repeat).
3. After every `observe`, save the response as `<step>.json` and copy the `annotated_path` PNG as `<step>.png` into `baselines/<version>/<flow>/`.
4. Commit both files. The PNG is the visual reference; the JSON is the assertion source.

## How tests consume fixtures

```swift
let fixture = try MarksFixture.load("anonymous-borrow/06-after-borrow", version: "3.0.0")
fixture.assertText("Read", nearY: 2222, tolerancePx: 10)
fixture.assertText("Remove", nearY: 2222, tolerancePx: 10)
fixture.assertNoText("Borrow")  // the Borrow button is gone after a successful borrow
```

A failing fixture means the screen no longer matches what was captured — either a UI regression or an intended change. Either way, the test catches it.

## Versioning

Each release that touches user-visible behavior should re-capture the affected flows under a new `baselines/<version>/` directory. Old versions stay in the repo as historical evidence. PR diffs show which fixtures changed alongside the code.

## What this is NOT

- **Not a substitute for unit tests.** ViewModel logic, parsers, and reducers should still have direct unit coverage. Fixtures cover the integration layer where those pieces compose into UI.
- **Not for pixel-perfect snapshot diffing.** OCR/SoM is tolerant by design — small font rendering differences won't fail a fixture. Use SSIM-based replay (simdrive's built-in) for stricter visual checks.
- **Not free.** Re-capturing fixtures costs sim time. Only re-capture when intentional UI changes ship.
