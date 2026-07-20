# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-20 15:22:35 UTC
**Commit:** `34c1c896cffc`
**Branch:** `fix/swift6-test-target-repair`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Sending value of non-Sendable type '(inout [Int]) -> Void' risks causing data races
Sending value of non-Sendable type '(@escaping (String) -> Void) -> ()' risks causing data races
Sending value of non-Sendable type '(@escaping (Result<Int, any Error>) -> Void) -> Void' risks causing data races
Sending value of non-Sendable type '(@escaping (Result<Int, any Error>) -> Void) -> Void' risks causing data races
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
