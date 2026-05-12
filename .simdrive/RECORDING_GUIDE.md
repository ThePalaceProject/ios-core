# simdrive Auth Recording Guide

How to record a Palace sign-in flow that:
- pulls credentials from the harness vault (no plaintext in repo or transcript)
- captures the Layer-2 state contract automatically
- runs in CI replay against future PR builds via the `chaos-replay-on-pr` workflow

## Quick start

```bash
# Run from the repo root.
scripts/record-auth-flow.sh <recording-name> <creds-slug>
```

### Per-library invocations

| Library | Auth type | Creds slug | Recording name |
|---|---|---|---|
| A1QA Test Library | Basic (barcode + PIN) | `palace-ios.lib.a1qa` | `a1qa-basic-signin` |
| Danny Test Library on Gorgon | SAML | `palace-ios.lib.danny-test-gorgon` | `danny-saml-signin` |
| (any OIDC test lib once vaulted) | OIDC | `palace-ios.lib.<name>` | `<name>-oidc-signin` |
| (any OAuth test lib once vaulted) | OAuth | `palace-ios.lib.<name>` | `<name>-oauth-signin` |

Add more slugs to the vault first:
```bash
~/harness/bin/harness creds add palace-ios.lib.<name> \
    --username <user> --password <pass>
```

## Recording workflow

The script handles the credential injection + recording start/stop + state-contract backfill. You drive the in-app navigation interactively. Here's what each step looks like:

1. **Pre-flight** — make sure the target library is already added under Settings → Libraries (the Add-Library picker is its own flow and isn't part of the signin recording). The Account view should show the "Sign in" button.

2. **Script reads creds into env** — `harness creds export` emits shell-exportable lines, `eval` consumes them, values never reach stdout.

3. **Script pre-stages the pasteboard** — `pbcopy` puts the username into the system clipboard. simdrive's `type_text` mangles mixed-case input (memory: `feedback_simdrive_credential_typing_gap.md`), so we paste with Cmd-V instead.

4. **Script starts the recording** — simdrive captures every tap/swipe/type with state metadata.

5. **You drive the form** — tap Sign In, then the username field, Cmd-V, then the PIN field. For the PIN you'll need to `pbcopy` the password manually first:
   ```bash
   # In a separate shell — does NOT echo the value:
   eval "$(~/harness/bin/harness creds export palace-ios.lib.a1qa)"
   echo -n "$HARNESS_PASSWORD" | pbcopy
   ```

6. **You press Enter** when sign-in completes (Account view shows the username, sign-out option). The script:
   - stops recording
   - runs `migrate-recording --force` to backfill the Layer-2 state contract from the step-0 screenshot
   - runs `lint-recordings` to verify corpus integrity

## What the recording captures

```yaml
name: a1qa-basic-signin
device: iPhone 16 Pro
os_version: '18.4'
app_bundle_id: org.thepalaceproject.palace
steps:
  - id: 1
    action: tap
    args: { x: 600, y: 1222, stable_id: <hash>, text: "Sign in" }
    pre_screenshot: snapshots/001_pre.png
  - id: 2
    action: tap  # username field
    args: { x: <focus_x>, y: <focus_y>, stable_id: <hash>, text: "Library Card" }
  - id: 3
    action: press_key  # Cmd-V paste
    args: { key: "v", modifiers: ["cmd"] }
  - ...
requires:
  app: { bundle_id: org.thepalaceproject.palace, version: any }
  sim: { device: iPhone 16 Pro, ios_version: '18.4' }
  initial_state:
    text_subset_required: ["Account", "<library name>", "Sign in", "Report an Issue"]
    text_subset_forbidden: ["Add Library", "More...", "Allow", "Read", "Remove"]
    primary_button_label: "Sign in"
```

## Why this matters

Before this scaffolding, only 1 SAML signin recording (`pr907-saml-signin-gorgon`) existed in the simdrive corpus. Per the 2026-05-11 regression coverage analysis: **OAuth, OIDC, Basic auth and sign-out had ZERO replay coverage**. This is the gap that lets a regression in those auth paths reach TestFlight before any gate catches it.

Each new recording becomes part of the `chaos-replay-on-pr` workflow's matrix — every PR build replays them all and gets a state-contract halt + step-by-step similarity report. The pattern that closed PR #907's pr907-saml-signin-gorgon replay is the same pattern that closes every other auth surface.

## Conventions

- **Recording names** — `<lib-or-flow>-<auth>-<action>`, e.g. `a1qa-basic-signin`, `danny-saml-signin`, `nypl-oauth-signin`
- **Creds slug** — `palace-ios.lib.<name>` (matches the slug naming in `~/harness/projects/palace-ios.yml`)
- **Auth flow only** — recordings start from the library's Account view (not the Add-Library picker) and end at the signed-in Account view. Browse/borrow/download flows are separate recordings.
- **One recording per auth type per library** — don't add 5 SAML recordings for 5 SAML libraries; the SAML flow is the same modulo cosmetics, and the state contract handles the library-name discrimination.

## CI integration

Once a recording lands in `.simdrive/recordings/<name>/`, it's automatically picked up by `chaos-replay-on-pr.yml` (per CLAUDE.md memory: `.simdrive/replays/chaos/` is the curated corpus). The Layer-2 state contract gates the replay so a wrong app state fails-fast with a clear `expected/actual/reasons/remedy` block instead of executing blind taps.

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `creds slug 'X' not in harness vault` | `harness creds add palace-ios.lib.<name>` first |
| `0 tests executed` on replay | Recording dir missing or state contract halt fired at step 0 — check `recording.yaml`'s `requires:` block matches the sim's current state |
| Cmd-V types literal "v" | Mac keyboard focus isn't on the sim window — click into the sim before pasting, or use `osascript -e 'tell application "Simulator" to activate'` first |
| `type_text` lowercases mixed-case password | Use pbcopy + Cmd-V pattern (this script's default) instead of `type_text` |
| Recording captures pre-state taps that fail next session | Each replay must start from the exact recorded state. Use `simdrive migrate-recording` to backfill the state contract; the gate then halts cleanly instead of executing wrong-state taps. |
