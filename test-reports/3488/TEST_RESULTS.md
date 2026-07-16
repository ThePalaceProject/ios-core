# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-16 20:11:57 UTC
**Commit:** `90c5d6a17fef`
**Branch:** `chore/swift6-test-target`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Static property 'willSignIn' is not concurrency-safe because non-'Sendable' type 'UnsafeMutableRawPointer' may have shared mutable state
Static property 'validationError' is not concurrency-safe because non-'Sendable' type 'UnsafeMutableRawPointer' may have shared mutable state
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
