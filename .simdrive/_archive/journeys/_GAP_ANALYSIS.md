# CUJ Gap Analysis — Palace iOS Master Test Plan vs SpecterQA Journeys

Generated 2026-04-08. Compares the 6 Critical User Journeys against the 17 existing journey YAMLs in `.specterqa/journeys/`.

| CUJ | Covered by | Gap | New YAML(s) |
|---|---|---|---|
| CUJ-1 Borrow → Download → Read (EPUB) | `borrow-book.yaml`, `book-transactions.yaml`, `epub-reading.yaml` | None significant. Download step is implicit (Borrow → Read). | — |
| CUJ-2 Audiobook listen + sleep timer | None. `app-launch.yaml` only taps the Audiobooks filter tab. | Entire playback flow: open audiobook, play, pause, scrub, chapter nav, sleep timer. | `audiobook-playback.yaml`, `sleep-timer.yaml` |
| CUJ-3 Sync across devices (annotations) | None. | Requires two simulator instances + a shared account. Out of scope for single-session scripting. | — (interactive only) |
| CUJ-4 Offline mode | None. | Borrow + download online, toggle airplane mode, open downloaded book offline, re-enable network, verify re-sync. | `offline-mode.yaml` |
| CUJ-5 Sign-in (6 auth methods) | `settings-screen.yaml` mentions Sign In button only. | No flow exercises basic barcode/PIN, OAuth, SAML, OIDC, Clever, or card creation. | `sign-in-basic.yaml`, `sign-out.yaml` (others deferred — need test creds + provider sandbox) |
| CUJ-6 CarPlay | None. | Requires CarPlay simulator window setup that must be done interactively. | `carplay-stub.yaml` (stub with instructions) |

Plus a cross-cutting gap: **bookmark persistence across reader close/reopen** is touched by `epub-reading.yaml` step `add_bookmark` but the same step does not verify the bookmark survives a full reader close + relaunch. Added `bookmark-add-and-restore.yaml` to cover that explicitly.

## Overall Coverage State

CUJ-1 is well covered. CUJs 2, 4, 5, 6 are essentially uncovered. CUJ-3 cannot be covered by the SpecterQA single-session model and needs an interactive multi-device harness or a server-side sync test instead. After this pass, CUJs 1, 2, 4 will have first-pass YAMLs; CUJ-5 will cover only basic auth (5 of 6 methods still need interactive authoring with real provider credentials); CUJ-6 remains a stub. Sign-out and bookmark persistence are added as supporting journeys.
