# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-20 16:07:39 UTC
**Commit:** `e8bb0b5c71c5`
**Branch:** `fix/swift6-test-target-repair`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Sending value of non-Sendable type '() -> Bool' risks causing data races
Sending value of non-Sendable type '() -> [PersistedDownloadRecord]' risks causing data races
Sending value of non-Sendable type '() async -> Set<Int>' risks causing data races
Sending value of non-Sendable type '(String) -> TPPBookState' risks causing data races
Sending value of non-Sendable type '(ReconcileDecision) async -> ()' risks causing data races
Sending value of non-Sendable type '() -> Bool' risks causing data races
Sending value of non-Sendable type '() -> [PersistedDownloadRecord]' risks causing data races
Sending value of non-Sendable type '() async -> Set<Int>' risks causing data races
Sending value of non-Sendable type '(String) -> TPPBookState' risks causing data races
... and 5 more errors
```

---

## 📦 Artifacts

| Artifact | Description |
|----------|-------------|
| **test-results** | Full `.xcresult` bundle - open in Xcode for detailed analysis |
| **test-report** | This Markdown report |
| **test-data** | JSON data file for custom tooling |

### How to View in Xcode

1. Download the **test-results** artifact
2. Unzip the downloaded file
3. Double-click the `.xcresult` bundle to open in Xcode
4. Navigate to failed tests to see stack traces and failure details
