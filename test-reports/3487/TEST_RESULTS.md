# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-16 19:57:34 UTC
**Commit:** `7b4b4386e5c5`
**Branch:** `chore/swift6-test-target`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Non-Sendable type 'BorrowOperationTests' cannot be sent into main actor-isolated context in call to property 'fetchBookResult'
Non-Sendable type 'BorrowOperationTests' cannot be sent into main actor-isolated context in call to property 'oidcReauthResult'
Main actor-isolated property 'fetchBookResult' cannot be accessed from outside of the actor
Main actor-isolated property 'oidcReauthResult' cannot be accessed from outside of the actor
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
