# Reset Library Account — Support Workflow

**Purpose:** Help patrons whose Palace app has gotten into a stuck state that sign-out + uninstall + reinstall does NOT fix.

**Ships in:** Palace iOS **3.1.0** and later. **Not** available in 3.0.3 or earlier — patron must update first.

**Gated by:** Firebase Remote Config (off by default). Support enables it per-device on demand.

---

## When to use this workflow

Look for any of these patterns in a ticket:

- Patron reports that an audiobook or ebook **loaded once, then refuses to load** on every subsequent open.
- Patron tried **sign-out → uninstall → reinstall** and the failure persists.
- **Different patron credentials on the same device** also fail; or the **same patron credentials on a different device** succeed — i.e. the failure is tied to the device, not the patron or the title.
- In-app error overlays the patron sees: *"Audiobook Unavailable,"* *"A Problem Has Occurred,"* or *"The download could not be completed."*
- "It's hit or miss" / "sometimes it loads and sometimes it doesn't" for the same checkout.

Reference reports: HelpSpot 17716 (the original case this feature was built for), 17929, 17964, 17981.

If the symptom is **"can borrow but can't READ an EPUB"** (audio works, ebook spins forever) that's a different bug (PP-3649, Adobe DRM device activation). Reset Account does deauthorize Adobe DRM as part of the cleanup, which can incidentally help — but the underlying fix lives elsewhere.

---

## Workflow

### Step 1 — Confirm the patron is on Palace 3.1.0 or later

Ask the patron to check **Settings → bottom of the screen → "Palace x.y.z (build n)"**.

- 3.1.0+ → continue to Step 2.
- 3.0.3 or earlier → ask them to update from the App Store first. Reset Account does not exist on those versions.

### Step 2 — Get the patron's Device ID

Send the patron this:

> Open the Palace app, then go to **Settings → Developer Settings → Send Error Logs**. You'll see a Device ID at the top of the screen — it looks like `12345678-90AB-CDEF-1234-567890ABCDEF`. Tap **Copy Device ID** and paste it into a reply to this email.

If the patron doesn't see "Developer Settings": ask them to go to **Settings**, scroll to the bottom, and **long-press on the Palace version label** (e.g. *"Palace 3.1.0 (479)"*) until Developer Settings appears.

### Step 3 — Enable the Reset button for that device in Firebase Remote Config

1. Sign in to **Firebase Console → palace-iOS project → Remote Config**.
2. Click **Add parameter** (or **Add condition** if reusing).
3. Fill in:

| Field | Value |
|---|---|
| **Parameter name** | `reset_account_enabled_device_<sanitizedDeviceID>` |
| **Data type** | Boolean |
| **Default value** | `true` |
| **Description** | `Reset Account enabled for HelpSpot ticket #<NNNNN>` |

**Sanitized Device ID =** the Device ID with **all dashes removed**.

Example: device ID `12345678-90AB-CDEF-1234-567890ABCDEF` →
parameter name `reset_account_enabled_device_1234567890ABCDEF1234567890ABCDEF`.

4. Click **Publish changes**. Propagation takes **up to 1 hour**, often <5 minutes.

### Step 4 — Walk the patron through the Reset

Send the patron this:

> 1. **Make sure you're connected to Wi-Fi** (cellular works too, but Wi-Fi is more reliable).
> 2. Open the Palace app and **force-quit it** (swipe up from the bottom and flick the Palace card away), then re-open it.
> 3. Go to **Settings → Accounts → tap your library name**.
> 4. Scroll to the bottom. You should see a red **Reset This Library Account** button. *If you don't see the button, please let us know — we'll double-check our setup.*
> 5. Tap it and confirm. The app will sign you out and return to the library selection screen. This takes about 5–10 seconds.
> 6. Sign back in with your library card and PIN.
> 7. **Try the audiobook again** that was failing.

### Step 5 — Verify the Reset ran end-to-end

If the patron is comfortable sending a sysdiagnose (or you have other diagnostic access), look for these log lines:

```
[RESET_ACCOUNT] start — libraryAccountID=<uuid>
[RESET_ACCOUNT] step 1 ok — FCM token DELETE dispatched (fire-and-forget); hasUpdatedToken cleared
[RESET_ACCOUNT] step 2 ok — bookDownloadsCenter + bookRegistry reset for <uuid>
[RESET_ACCOUNT] step 2.5 — dispatching DRM deauthorize (fire-and-forget)
[RESET_ACCOUNT] step 3 ok — userAccount.removeAll, selectedIDP=nil, samlHelper.clearState
[RESET_ACCOUNT] step 4 ok — networkExecutor cache + URLCache cleared
[RESET_ACCOUNT] step 5 ok — nextOIDCSessionEphemeral flag set
[RESET_ACCOUNT] step 6 ok — WKWebsiteDataStore wiped (all types, since epoch)
[RESET_ACCOUNT] complete — patron should be returned to sign-in flow
```

All seven steps should appear. A "step X skipped" line for step 1 or 2.5 is OK — it just means there's no Account row or no Adobe DRM activation to clear.

### Step 6 — If the Reset DID fix the patron

1. Reply to the patron confirming the issue is resolved.
2. **Disable the per-device flag in Firebase Remote Config** (delete the parameter or set value to `false`, then Publish). Leaves the Reset button hidden again on that device.
3. Tag the HelpSpot ticket with `reset-account-fixed` and note the Device ID + ticket number in the Firebase parameter description before disabling, so we can track effectiveness.

### Step 7 — If the Reset did NOT fix the patron

This is still valuable signal. It means the failure is **below the local-state layer** — it's not URLCache, not Keychain, not bookRegistry. Likely culprits:

- **CM-side state corruption** (device-token rows, license fulfillment cache). Ask the CM team to inspect the patron's account.
- **iCloud-restored bad state.** If the patron has iCloud Backup enabled and the bad state is in the backup, every reset gets clobbered by the next iCloud restore. Workaround: ask the patron to temporarily disable iCloud Backup for Palace (**Settings → [name] → iCloud → Manage Account Storage → Backups → [device] → Palace** → toggle off), do another Reset, then re-enable iCloud after the next successful checkout.
- **IdP-side session** (SAML/OIDC libraries only). The library's identity provider still has the patron's session active. For Open Athens / SAML libraries, the patron may need to clear cookies in Safari too: **Settings → Safari → Clear History and Website Data**.
- **A real client bug we haven't yet identified.** Escalate to iOS engineering with the patron's Device ID, the failing book IDs, and a sysdiagnose if available.

Leave the `reset_account_enabled_device_<id>` flag ON for now if you escalate to engineering — they may ask the patron to retry after they ship a diagnostic build.

---

## What the patron loses when they Reset

Be transparent about this when you describe the step:

**Cleared on this device:**
- Sign-in (will need to re-enter library card + PIN)
- Downloaded book files (re-download from My Books after sign-in)
- Local reading positions / bookmarks **for any book that hasn't synced to the server yet** (server-synced positions come back on sign-in)
- Adobe DRM device activation (re-activates automatically on next protected ebook open)

**Not affected:**
- The patron's library checkouts / holds (those live on the server)
- Server-synced bookmarks and reading positions
- Other libraries the patron has added (Reset only touches the one selected library)
- The patron's account at the library itself

---

## Email template for the first reply

Adapt as needed:

> Hi <name>,
>
> Thank you for the detailed report and screenshots — they were very helpful.
>
> We have a recovery tool for situations like this that we can enable specifically for your device. To set it up I need one piece of information from you:
>
> Open the Palace app, then go to **Settings → Developer Settings → Send Error Logs**. You'll see a Device ID near the top — it looks like `12345678-90AB-CDEF-1234-567890ABCDEF`. Tap **Copy Device ID** and paste it into a reply to this email.
>
> If you don't see "Developer Settings" at first, go to Settings, scroll to the bottom, and long-press the Palace version label (e.g. *"Palace 3.1.0 (479)"*) until the option appears.
>
> Once I have that Device ID I'll send you the next step — a one-time "Reset This Library Account" button that will appear in your app within an hour. It clears the local cache that we believe is causing the loading failures, without affecting your checkouts on the server side.
>
> If you're still on Palace 3.0.3, please update from the App Store first — this tool ships in version 3.1.0.
>
> Best,
> <Courtney>

---

## What Reset Account actually clears (technical detail for escalation)

For reference when escalating to engineering — full implementation in `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift`:

1. FCM device token DELETE on the Circulation Manager (best-effort, never gates)
2. `bookDownloadsCenter` + `bookRegistry` state for the selected library
3. Adobe DRM device deauthorize (RMSDK clears local activation files regardless of network result)
4. Keychain credentials (`userAccount.removeAll`), `selectedIDP`, `samlHelper.clearState`
5. `NetworkExecutor` cache + `URLCache.shared.removeAllCachedResponses()` — **this is the step that addresses CFNetwork-cached stale fulfillment URLs surviving uninstall**
6. One-shot flag for next OIDC sign-in to force `prefersEphemeralWebBrowserSession = true` (defeats Safari shared-cookie reuse)
7. `WKWebsiteDataStore.default()` — every data type, from epoch (cookies, IndexedDB, local storage, the lot)

What it does **not** touch:
- CM-side device-token rows (CM team intervention needed)
- IdP-side session
- iCloud-backup-restored stale state on next launch
- Server-synced bookmark / position records (intentional — patron keeps their place when they re-sign-in)

---

## Quick reference

**Enable Reset for a device:**

```
Firebase Console → Remote Config → Add parameter
Name:  reset_account_enabled_device_<sanitizedDeviceID>
Value: true
Publish
```

**Disable when done:**

```
Firebase Console → Remote Config → find parameter → delete (or set false)
Publish
```

**Confirm in logs (sysdiagnose):**

```
grep "RESET_ACCOUNT" <sysdiagnose path>
```
