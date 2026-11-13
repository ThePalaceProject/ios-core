# Ledger configuration for Palace iOS

[CodeAtlas Ledger](https://github.com/mauricecarrier7/ledger-dist) analyses the
dependency graph — component boundaries, layer violations, dependency cycles.

This directory holds **one file that matters**: `ledger-config.json`. The
analysis itself runs in CI, from `.github/workflows/ledger.yml`, which installs
a pinned ledger release and copies this config to `.ledger/config.json` before
invoking it. There is no local runner here, and no binary is vendored.

## What the config declares

| Key | Meaning |
|---|---|
| `componentRoots` | Directories treated as separate components. **Package-first**: the twelve `Palace/Packages/*` roots lead, app-target directories follow. |
| `layerRules` | The layer names and the edges allowed between them. Note `allowedEdges` lists no same-layer edge. |
| `layerOverrides` | Explicit layer for a component the inference would otherwise guess. The extracted packages are deliberately NOT listed — see below. |
| `knownFalsePositiveEdges` | Edges the name-based inference invents that the compiler cannot produce. Discounted from the cycle count by `scripts/ledger_scc.py`. |
| `excludePaths` / `submoduleExclusions` | Vendored and generated trees kept out of the graph. |

## The packages have no layer override yet

`componentRoots` names the packages, so the graph sees them; `layerOverrides`
does not, so their layer is inferred. That is deliberate and it is unfinished
work, not a settled choice.

Assigning them by hand needs an answer this repo does not have yet: the real
package DAG contains same-layer edges — `PalaceBookModel` depends on
`PalaceCatalog`, `PalaceBookRegistry` on both — and `allowedEdges` permits no
edge within a layer. Hand-assigning both to Domain would either report
violations that are not violations, or reveal that the layer model needs an
intra-layer rule. Which one is true is a question for a ledger run, and the
run happens in CI.

Read the CI job's output on a PR that touches this config before adding
overrides.

## Changing it

Edit `ledger-config.json` and open a PR; the CI job reports against the change.
The job is advisory — three steps carry `continue-on-error`, so a finding
comments rather than blocks.
