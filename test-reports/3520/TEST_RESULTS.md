# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-20 13:43:45 UTC
**Commit:** `ca7858f96524`
**Branch:** `fix/audiobook-nowplaying-offmain`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure
Passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure
Sending 'self.publication' risks causing data races
Sending 'self.publication' risks causing data races
Sending 'self.publication' risks causing data races
Sending 'self.publication' risks causing data races
Sending 'self' risks causing data races
Sending 'self' risks causing data races
Non-Sendable 'Publication'-typed result can not be returned from main actor-isolated instance method 'createTestPublication()' to nonisolated context
... and 23 more errors
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
