# Module D5 — NotificationCenter observer added without removal / storage detector

**Owner module:** scripts/ + verify-pr.sh
**Risk:** standard (observer leak class — PP-4329 manifested as library-selector double-show)
**Est LOC:** ~200

## Background

PP-4329: library selector appears twice on first launch — an observer-leak bug where `NotificationCenter.default.addObserver` was called without storing the returned `NSObjectProtocol` token AND without a matching `removeObserver` on dealloc. The class: any closure-API `addObserver(forName:, object:, queue:, using:)` whose return value is discarded.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-notification-observer-storage.py` (NEW) | Detects `NotificationCenter.default.addObserver(forName:,object:,queue:,using:)` calls whose result is not bound (no `let token = ...`, no `... .store(in: &subscriptions)` equivalent, no assignment to a stored property). Annotation: `// no-observer-storage: <reason>` (e.g. fire-and-forget on app launch). | +130 |
| `scripts/test_check_notification_observer_storage.py` (NEW) | 4 tests — violation, clean-with-let, clean-with-property-store, annotated. | +40 |
| Wiring + hook + wall-failure entry | (analogous) | +30 |

## Predicted survivors

Scan: `grep -rln "addObserver(forName:" Palace/`. Predict 2-6 survivors (the class is common in old Objective-C-ported code). Triage: small class → wipe via `let token = ...` + `removeObserver(token)` on dealloc. Larger class → scope-defer with detector landed.

## Scope (out)

- Selector-based `addObserver(_:selector:name:object:)` — different shape, not the observed leak class.
- KVO observers — out of scope.

## Verification, tests, acceptance — same shape as D1.
