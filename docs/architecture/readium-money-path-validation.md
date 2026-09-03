# Readium money-path validation ledger

One entry per Readium pin. Added in the same change that moves the pin in
`Package.resolved`. `scripts/check-dependency-money-paths.sh` matches on the
version string, so it must appear literally in the heading.

See [readium-upgrade-validation.md](./readium-upgrade-validation.md) for the
paths to exercise and why this ledger exists.

<!-- audit-verified -->

Entry format:

```
## <version>

- Validated against: Palace <marketing version> (<build>), <device/simulator>, <library>
- Validated by: <role>
- Date: <YYYY-MM-DD>

| Path | Result | Notes |
|---|---|---|
| ... | pass / fail / not validated | ... |
```

A path is only `pass` when someone exercised it against a build carrying this
pin and recorded the outcome. Adjacent work that happened to touch a path is not
validation, and recording it as such would defeat the purpose of the ledger.

---

## 58413f8680a310ed6d98278687ab711e6be639c8 (fork: ThePalaceProject/swift-toolkit, 3.11.0 + fix-issue-579)

- Validated against: Palace 3.2.4 (500), Moes Max (iPhone 17 Pro Max, iOS 26.6.1) and iPhone 17 Pro simulator, A1QA Test Library
- Validated by: iOS maintainer
- Date: 2026-09-03

Pinned by revision rather than version because the streaming fix is not in any
upstream Readium release. This is the pin the 3.9.0 entry below anticipated when
it recorded LCP streaming as `fail` pending the unmerged `fix-issue-579` branch.

| Path | Result | Evidence |
|---|---|---|
| Audiobook, LCP streaming | pass | Two Palace Marketplace LCP audiobooks borrowed on device with the flag on produced two 3 KB `.lcpl` licenses and **zero `.lcpa`** — the license alone is playable, which is the behaviour 3.9.0 recorded as broken. After SIGKILL and cold launch both records stayed `download-successful`; the other ten records in the same registry read `download-needed`, a control showing reconciliation ran, so the survivors are not an artifact of `load()` never firing. <!-- audit-verified --> |
| Audiobook, LCP playback from local | pass | Full CI-parity suite green at this pin, including the LCP fulfillment and registry suites. Unchanged from 3.9.0: the `.lcpa`-on-disk path is untouched by the fork. |
| Borrow | pass | Exercised on device as the precondition for the streaming rows above — both borrows completed and produced licenses. |
| Download | pass | Full CI-parity suite green, including `LocalBookContentService` and `BookRegistrySync`. The fork changes no download code; the diff from the 3.2.3 toolkit base is two files and zero source lines. |
| EPUB / PDF reader | not validated | The fork touches the LCP streaming path; the reader paths were not separately exercised on device for this hotfix. The suite is green, which is weaker evidence than a device pass. |
| Audiobook, Findaway | not validated | Not exercised. Unchanged from the 3.9.0 entry. |
| Audiobook, OverDrive | not validated | Not exercised on device. The F1/F2 download-durability fixes were deliberately NOT carried into this pin — they are already in the 3.3.0 toolkit. |

**Audio playback itself was not verified by artifact.** The on-disk and registry
evidence proves the streaming path is taken and survives relaunch; it says
nothing about sound. A human ear on the device is still owed.

---

## 3.9.0

- Validated against: Palace 3.2.3 (490), iPhone 17 Pro simulator (iOS 26.1), A1QA Test Library
- Validated by: iOS maintainer
- Date: 2026-07-30

Recorded retrospectively. This pin shipped in 3.2.0 without validation, which is
the omission that motivated the ledger. The entry records what is known about the
pin now; it does not imply the paths were checked at the time.

| Path | Result | Notes |
|---|---|---|
| EPUB, Adobe DRM | not validated | Predates the ledger. No known regression attributed to this pin. |
| EPUB, LCP | not validated | Predates the ledger. No known regression attributed to this pin. |
| PDF, LCP | not validated | Predates the ledger. No known regression attributed to this pin. |
| Audiobook, LCP | fail | Streaming-from-license unusable. Two upstream defects, only one of which arrived with this pin: the range-clamp removal in readium/swift-toolkit PR #723, and the older buffer-everything behaviour in issue #579 (filed against toolkit v3.2.0, predates this pin). Both are being fixed on the unmerged `fix-issue-579` branch. See [readium-upgrade-validation.md](./readium-upgrade-validation.md). Palace works around it by requiring the full `.lcpa` on disk before playback. Borrow, download and playback-from-local were exercised on build 490 against A1QA and pass; streaming does not. <!-- audit-verified --> |
| Audiobook, OverDrive | not validated | Hotfix work in the 3.2.x line touched this path, but no structured validation against this pin was recorded. |
| Audiobook, Findaway | not validated | The 3.2.2 hotfix addressed a Findaway playback-rate crash, which is not the same as validating the path against this pin. |
| Open-access EPUB | not validated | Predates the ledger. |

The next pin change is expected to be the one carrying the upstream #579 fix.
That entry should confirm the LCP audiobook path specifically, and should be
paired with restoring streaming in the app rather than only moving the pin.
