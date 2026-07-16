# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-07-16 18:55:07 UTC
**Commit:** `0f77bee2a804`
**Branch:** `chore/swift6-test-target`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Non-Sendable type 'BorrowOperationContractTests' cannot be sent into main actor-isolated context in call to property 'log'
Non-Sendable type 'BorrowOperationContractTests' cannot be sent into main actor-isolated context in call to property 'fetchBookResult'
Non-Sendable type 'BorrowOperationContractTests' cannot be sent into main actor-isolated context in call to property 'log'
Main actor-isolated property 'log' cannot be accessed from outside of the actor
Main actor-isolated property 'fetchBookResult' cannot be accessed from outside of the actor
Main actor-isolated property 'log' cannot be accessed from outside of the actor
Instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead
Mutation of captured var 'ranOnMain' in concurrently-executing code
... and 1 more errors
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
