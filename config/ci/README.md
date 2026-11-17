# config/ci — data files read by CI and repo tooling

| Path | Read by |
|---|---|
| `committed-signing-allowlist.txt` | `scripts/check-no-committed-signing.sh` (override: `NO_SIGNING_ALLOWLIST`) |
| `crashlytics-baseline.json` | `scripts/crashlytics-sentinel.py`; rewritten and committed by `.github/workflows/crashlytics-sentinel.yml` |
| `release-waivers/<branch>.txt` | `scripts/check-release-fix-reconciliation.py` via `.github/workflows/release-gates.yml` (gate 1) |
| `crash-triage/<version>.txt` | `scripts/check-pre-ga-crash-triage.py` via `.github/workflows/release-gates.yml` (gate 2) |
| `mutation-suppressions/<file-leaf>.json` | `scripts/mutate_coverage.py`, used by `scripts/palace_mutate.py` |

Two optional allowlists are also looked up here when present:
`doc-hygiene-allowlist.txt` (`scripts/check-doc-hygiene.sh`) and
`objc-witness-allowlist.txt` (`scripts/check-objc-witness-nearly-matches.sh`).
