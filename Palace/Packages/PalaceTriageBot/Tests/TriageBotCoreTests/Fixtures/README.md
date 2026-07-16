# Redaction corpus — SYNTHETIC fixtures (PP-4806)

**Every value in these `*.txt` files is hand-authored and FAKE.** No real
patron credential, barcode, token, cookie, or PIN appears here. The strings are
*shaped* like the secrets the HelpSpot forensic (PR #1278 / PP-4805) found
leaking — Bearer/JWT tokens, `Basic` auth, `Set-Cookie` values, 3-8 digit PINs
adjacent to "pin/passcode", 10-14 digit card barcodes, `password:`/`access_token`
key-value pairs — so that `ContextRedactor` has a realistic, sensitive-flow
payload to prove itself against.

## What these are

Each file mimics the `recentLogLines` a Palace device diagnostic would capture
during one sensitive flow:

| File | Flow |
|------|------|
| `signin_basic.txt` | Basic-auth (barcode + PIN) library sign-in |
| `signin_saml_oauth.txt` | SAML web / OAuth web sign-in (cookies, bearer, id_token) |
| `borrow.txt` | Borrow / loan creation |
| `download.txt` | LCP / Adobe fulfillment + download |
| `audiobook.txt` | Findaway / AudioEngine audiobook playback |

## Standing guard

`RedactionCorpusTests` runs `ContextRedactor` over every line here and asserts a
**credential deny-list survives nothing** — no un-redacted Bearer/JWT, `pin:
<digits>`, raw barcode, `password:`, cookie value, or `access_token=`. It also
asserts the RAW (pre-redaction) corpus DOES trip the deny-list, so the gate can
never pass by degenerating into a corpus of harmless text.

`scripts/triage-corpus-check.sh` re-runs that guard at release time and can
`--self-test` (inject a raw leak, prove the gate goes red, clean up).

## DEFERRED — live device capture

These synthetic fixtures are the *framework*. Capturing REAL (already-fake-account)
device payloads from the sensitive flows on a running sim/device is deferred to
the simdrive / chaos QA runs (PP-4813 / PP-4817). When those land, real captures
drop in here alongside (or replacing) these synthetic files and the same
deny-list guard covers them unchanged.
