---
name: reset-adobe-activations
description: Clear a test patron's Adobe activation ceiling (E_ACT_TOO_MANY_ACTIVATIONS) by deleting their Adobe identity on the circulation manager, so Adobe DRM borrows work again.
---

# Reset a test patron's Adobe activations

## When this applies

Adobe DRM borrows fail and the device log shows:

    adobeOriginalCode=E_ACT_TOO_MANY_ACTIVATIONS http://adeactivate.adobe.com/adept/Activate <n>:<n>:<n>
    errorDomain=org.nypl.labs.ADEPTErrorDomain  errorCode=5

In the app this surfaces as **"Too many device activations — Please deauthorize
a device and try again."** There is no in-app way to act on it, by decision.

Adobe caps activations per Adobe user. Reinstalling the app, wiping a
simulator, or signing out over a connection that drops all consume a slot
without returning one, so a test account that has been through a few build
cycles reaches the ceiling on its own.

## What the fix actually does — read this before running it

`scripts/dev/reset-adobe-activations.sh` calls `DELETE /patrons/me/adobe_id`.
That deletes the patron's stored Adobe **identifier**; the next sign-in mints a
new one, and the patron is a new Adobe user with an empty activation count.

It does **not** deauthorize anything at Adobe. The old activations stay stranded
under the old identifier permanently — this walks away from them rather than
releasing them. Consequences:

* **Any Adobe-DRM book already downloaded under the old identity becomes
  undecryptable, on every device.** Return them first if they matter.
* The patron **must sign out and back in** afterwards; nothing happens until the
  new identifier is minted.

That is why it is a test-account tool and refuses non-staging hosts.

## Running it

The script takes credentials from a prompt or from the environment, never from
the command line — so they stay out of `ps` and shell history. **The user runs
it; do not ask them to paste a barcode or PIN into the conversation.**

Suggest they run it in-session with the `!` prefix so the output lands here:

    ! scripts/dev/reset-adobe-activations.sh --library a1qa-test

Defaults are `--server https://gorgon.staging.palaceproject.io` and
`--library a1qa-test`; both are overridable, as are `PALACE_SERVER` and
`PALACE_LIBRARY`.

Then have them: sign out of the library in the app → sign back in → borrow an
Adobe title.

## Verifying it worked

Pull the device log and confirm no new `E_ACT_TOO_MANY_ACTIVATIONS`:

    xcrun devicectl device copy from --device <UDID> \
      --domain-type appDataContainer --domain-identifier org.thepalaceproject.palace \
      --source Documents/Logs --destination <dir>

Note the log file is **ERROR-level only** — sign-out deauthorization logs at
info/warn do not appear in it. Use live syslog if you need those.

## Related

* `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeLicensorRefresh.swift`
  — why the CM's 60-minute client token goes stale (PP-3649).
* `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDeauthorization.swift`
  — the sign-out path that is supposed to free a slot, and how it used to fail
  without saying so.
