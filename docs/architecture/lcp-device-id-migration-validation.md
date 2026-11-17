# Validating the LCP device-identifier migration

PP-5091 asks for something no test in this repository can answer: that a patron
upgrading in place from a 3.2.3 build keeps their LCP loans, and that the device
identifier moving from `UserDefaults` into the Keychain does not consume a second
device-registration slot against the license. The slot count lives on the LCP
license status server. Nothing on the device can read it, so nothing on the
device can prove the claim.

This document records what *is* mechanically checkable, why the rest is not, and
the exact procedure a human runs on a real device to close it.

<!-- audit-verified -->

## Two migrations, and the way they interact

They are separate pieces of code that happen to arrive together, and the risk is
in the conjunction rather than in either one.

**Readium's device-ID migration** (`Sources/LCP/Services/DeviceService.swift`,
Readium 3.10+). Palace never supplies a device ID — `LCPLibraryService` builds
`LCPService` without one — so Readium auto-resolves it: reuse the Keychain value,
else migrate the legacy `UserDefaults` key `lcp_device_id` into the Keychain
(leaving the `UserDefaults` value in place), else mint a new UUID. On a Keychain
read failure it deliberately returns *no* ID rather than a fresh one, and the
caller skips the LSD device interactions entirely, because minting a throwaway ID
is precisely what burns a slot.

**Palace's license/passphrase migration**
(`Palace/Migrations/LCPKeychainMigration.swift`, for Readium 3.8+). Copies stored
licenses and passphrases out of the deprecated `ReadiumAdapterLCPSQLite` store
into the Keychain repositories.

The interaction: `DeviceService.registerLicense` registers only when
`repository.isDeviceRegistered(for:)` is false, and that repository *is* the
Keychain license repository. So if the license copy has not happened yet, an
already-registered license looks unregistered and Readium re-registers. That
re-registration is harmless **only if the device ID is stable**, because the LSD
server deduplicates by device ID. A stable ID makes the re-register a no-op
against the slot count; an unstable one spends a slot. The acceptance criterion is
exactly the conjunction of those two, which is why validating either alone proves
nothing.

## The race that made this worth acting on

`TPPMigrationManager.migrate` starts the license copy without awaiting it, and
launch must not block on a Keychain walk, so that stays true. On the first launch
after an in-place upgrade a patron can therefore open an LCP book while the copy
is still running: `LCPLibraryService` builds `LCPKeychainLicenseRepository`,
finds nothing, and the license re-validates from its stored `.lcpl` — the path
that reaches `registerLicense`.

What changed, and what did not:

- `LCPKeychainMigration.runIfNeeded` is now single-flight. Concurrent callers
  share one copy and *wait* for it instead of starting a second concurrent pass
  over the Keychain, so no caller proceeds over a half-populated store.
- `TPPMigrationManager.migrate` returns the migration's `Task` instead of
  discarding it, so a caller — or a test — can await completion.
- The race itself is **not closed**. Closing it means the LCP book-open path
  awaits the migration, and `LCPLibraryService` builds its service inside a
  synchronous `serviceQueue.sync` that cannot await. That restructuring is larger
  than this change and was not in its scope.

## What is covered mechanically

| Property | Where |
|---|---|
| Two callers racing the unwritten flag run **at most one** copy between them | `LCPKeychainMigrationTests.testRunIfNeeded_whenASecondCallerArrivesMidCopy_migratesAtMostOnce` |
| A retry that succeeds after a partial failure sets the flag; the failed attempt leaves it unset and keeps the completed half | `LCPKeychainMigrationTests.testRunIfNeeded_whenARetryAfterAPartialFailureSucceeds_setsTheFlag` |
| Launch actually reaches `LCPKeychainMigration.runIfNeeded` — asserted on the migration flag, which only `runIfNeeded` writes, so a stubbed closure cannot fake it | `TPPMigrationManagerTests.testMigrate_runsTheLCPKeychainMigration` |
| The migration task is reachable rather than discarded | `TPPMigrationManagerTests.testMigrate_returnsAHandleOnTheLCPMigrationRatherThanDiscardingIt` |

**Not covered, deliberately.** That a late caller *waits* for the running copy is
what the code does, but no test asserts it: the test cannot force the
interleaving, so the assertion was green by construction under the fix and only
racily red under the mutant. It was written, observed not to fail, and deleted.
What holds the property is the single flight itself plus the copy-count
assertion above; if you change `SingleFlight`, that is the reasoning you are
responsible for, not a test.

## What cannot be covered mechanically, and why

- **The slot count.** It is server state on the license status document. Reading
  it is a licensing-server operation, not an app one.
- **The Keychain on a simulator.** A simulator build installed through `simctl`
  gets `-34018` with no entitlements and is refused launch with any, so the
  device-ID Keychain path is unverifiable there. CI is worse: its test host was
  unsigned, which is how 111 credential tests silently never ran. Treat any
  simulator result on this path as absent evidence, not as a pass.
- **In-place upgrade.** The whole question is about state a 3.2.3 install left
  behind. A fresh install has no legacy `lcp_device_id` and no SQLite store, so
  it exercises none of it.

## The human procedure

One physical device plus a TestFlight install of the older build. Do not
reinstall between steps — a reinstall is the one thing that invalidates the whole
run.

1. **Establish the "before" state.** Install the last 3.2.3 build (TestFlight or
   an archive of that tag) on a real device. Sign in to the A1QA Test Library,
   borrow an LCP EPUB and an LCP audiobook, and open both so their licenses
   register. Note the titles.
2. **Capture the legacy device ID.** With the 3.2.3 build still installed, read
   `lcp_device_id` from the app's `UserDefaults` (Xcode → Devices → download the
   container, or a debug build reading
   `UserDefaults.standard.string(forKey: "lcp_device_id")`). Record it. This is
   the value the migration must preserve.
3. **Upgrade in place.** Install the 3.3.0 build over the top. Do **not** delete
   the app; do not use a fresh install.
4. **Open a book immediately.** On the very first launch, open one of the
   borrowed LCP titles as fast as the UI allows — this is the race window, and
   the point is to hit it rather than avoid it.
5. **Check the device ID survived.** Read the Keychain item: service
   `org.readium.lcp.device`, account `device-id`. It must equal the value from
   step 2. A different value means a slot was spent; no value at all means the
   Keychain was unreadable and Readium correctly declined to register, which is
   not a failure but is not a pass either — repeat after a device unlock.
6. **Check the loans still open.** Both titles must open without a
   re-fulfillment, a passphrase prompt, or a "device not registered" error.
7. **Confirm the slot count.** Ask the circulation-manager operator for the
   license's registered-device count before and after. One device before, one
   device after. This step is the actual acceptance criterion; steps 5 and 6 are
   its necessary conditions, not a substitute for it.
8. **Record it** in [`readium-money-path-validation.md`](./readium-money-path-validation.md)
   under the pin's entry, with the build number and the device.

If step 7 cannot be arranged, say the criterion is unvalidated. A run of steps
1–6 without step 7 is evidence that the device ID is stable, which is the
mechanism — but the ledger's whole purpose is that a mechanism looking right is
not the same as an outcome being checked.
