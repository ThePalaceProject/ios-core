---
date: 2026-06-05
pr: "#953 / commit 0bbbf2b4a"
source: shipped-bug
reviewer_ids: []
changeset_id: cs_799e1586
wall: hook
walls: [implementer, TDD, hook, verify-pr]
severity: medium
wall_status: applied
applied_in: "swarm_162a3219 / Module D5"
detector_script: scripts/check-notification-center-observer-storage.py
# doc-lifecycle metadata
name: 2026-06-05-pp4329-notification-observer-leak
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [appinfrastructure, notifications]
description: NotificationCenter closure-form addObserver registered without storing the returned NSObjectProtocol token AND without a class-level removeObserver cleanup — observers stack on re-entry, fanning a single notification into 2-4 modal presentations on a fresh install.
---

# PP-4329 — NotificationCenter observer registered without storage/removal

## Finding (verbatim from PP-4329 user report + root-cause analysis)

> User-reported on 3.0.1 (build 471) and reproduced on iOS 26.4.2 device:
> on a brand-new install, the library selector screen appears 2-4 times;
> the first pick "appears to do nothing" because another selector is
> already on the stack. Count varies with iOS version (≈2 on iOS 26.2
> sim, 4 on iOS 26.4.2 device).
>
> Root cause (commit 0bbbf2b4a): `TPPAppDelegate.presentFirstRunFlowIfNeeded`
> registered a closure-form `.TPPCatalogDidLoad` observer on every recursive
> call without capturing the returned `NSObjectProtocol` token.
> `AccountsManager` posts that notification from 8 sites during a cold-load
> cycle (main fetch, fallback GET, beta/prod hash switch, partial successes,
> retry path, …). Every post fired every accumulated observer; every fire
> called `presentFirstRunFlowIfNeeded` again; every call past the
> `accountsHaveLoaded` guard called `top.present(accountList)`. Net: 2-4
> stacked modals.

## What actually happened

The closure form `NotificationCenter.default.addObserver(forName:object:queue:using:)` returns an `NSObjectProtocol` token that the caller MUST hold onto if they want to deregister later. If the token is discarded, the observer remains alive and registered against the notification center for the process lifetime — unless the `removeObserver(self)` shape is used (which only works for selector-form observers where `self` was the registered observer).

In PP-4329, the method re-entered itself via the notification callback, registering a fresh observer every time. Each round-trip:
1. `presentFirstRunFlowIfNeeded()` runs while accounts haven't loaded → register observer #1
2. `loadCatalogs` posts `.TPPCatalogDidLoad`
3. Observer #1 fires → calls `presentFirstRunFlowIfNeeded()` → accounts NOW loaded → present()
4. Same load cycle posts `.TPPCatalogDidLoad` 7 more times → no observers stacked yet, but…

But the bug is worse than that: there are recovery paths where `accountsHaveLoaded` is still false during a second invocation, so observer #2 (and observer #3, observer #4) accumulate. On iOS 26.4.2, the worst-case fallback path posted the notification 4 times before any observer's first call hit the loaded branch, leaving 4 observers that all then re-invoked `presentFirstRunFlowIfNeeded` after the first present(), stacking 4 modals.

## Walls that should have caught it (and why they didn't)

- **implementer**: the original implementer (pre-3.0.1) treated `addObserver(forName:)` like `addObserver(_:selector:)` — fire-and-forget. No token-binding convention enforced.
- **TDD**: no unit test pinned "presentFirstRunFlowIfNeeded called twice should register at most one observer." The class is a UIApplicationDelegate which is awkward to unit-test, so the leak survived all the way to a release build.
- **hook**: there was no pre-commit detector for the "closure-form addObserver without storage AND without class-level cleanup" shape. The class is recognizable structurally; a regex-level scan can catch every case.
- **verify-pr**: same — no verify-pr gate looked for this pattern.

## Proposed permanent fix (applied in swarm_162a3219 Module D5)

Land `scripts/check-notification-center-observer-storage.py` as a verify-pr + pre-commit gate that flags:

> a call to `NotificationCenter.default.addObserver(forName:object:queue:using:)` whose return value is NOT bound to a property/local AND whose enclosing type body has NO `removeObserver(` call anywhere AND has no `// no-observer-storage: <reason>` escape annotation on the addObserver line or the 3 preceding lines.

The detector handles both single-line and multi-line addObserver call forms. The annotation escape lets app-lifetime singleton observers (like `NotificationService.shared`'s installNotificationObservers) opt out explicitly with rationale, while still blocking the silent leak shape that produced PP-4329.

### Canonical fix patterns (any of these closes the predicate):

1. **Capture the token in a stored property** (PP-4329's actual fix):
   ```swift
   private var firstRunFlowObserver: NSObjectProtocol?
   ...
   if let t = firstRunFlowObserver { NotificationCenter.default.removeObserver(t) }
   firstRunFlowObserver = NotificationCenter.default.addObserver(forName: ...) { ... }
   ```

2. **Use `deinit { NotificationCenter.default.removeObserver(self) }`** at the class level (catches selector-form AND any closure-form against this instance):
   ```swift
   deinit {
       NotificationCenter.default.removeObserver(self)
   }
   ```

3. **Local self-removing closure** (e.g. `DLNavigator.callOnce`):
   ```swift
   var token: NSObjectProtocol?
   token = NotificationCenter.default.addObserver(forName: name, ...) { notification in
       if let t = token { NotificationCenter.default.removeObserver(t) }
       ...
   }
   ```

4. **Annotation escape** when the observer is intentionally app-lifetime:
   ```swift
   // no-observer-storage: app-lifetime singleton; never deregisters.
   NotificationCenter.default.addObserver(forName: ...) { ... }
   ```

## Survivors found and fixed in this swarm

`python3 scripts/check-notification-center-observer-storage.py --scan .` against `develop` HEAD (post-PP-4329 fix) returned 2 survivors, both in `Palace/Notifications/NotificationService.swift`:

- `NotificationService.swift:139` — `.TPPCurrentAccountDidChange` observer
- `NotificationService.swift:143` — `.TPPIsSigningIn` observer

Both are inside `NotificationService.shared` — an app-lifetime singleton wired in `AppContainer.production()`. Process-lifetime ≈ observer-lifetime; the PP-4329 double-fire-on-reinit class doesn't apply (the singleton is one-shot per `static let shared`). Annotated both with `// no-observer-storage: NotificationService.shared is an app-lifetime singleton…` rather than restructuring storage.

## Application log

- 2026-06-05 — fix applied in `swarm_162a3219` Module D5 (this entry's `detector_script`).
- 2026-05-13 — original PP-4329 instance fix in commit `0bbbf2b4a` (TPPAppDelegate.swift; capture token in property + clear before re-register + idempotency flag).

## Related entries

- `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` — same swarm wave, different bug class (auth-host scoping).
- This is the first detector-script-frontmatter entry in the catalog; see Module A for the `detector_script:` convention.
