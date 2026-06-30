# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-06-30 21:53:01 UTC
**Commit:** `b3bcc29aaf40`
**Branch:** `fix/swift6-bookcell-mainactor-hop`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Testing cancelled because the build failed.
Call to main actor-isolated instance method 'removeProcessingButton' in a synchronous nonisolated context
Main actor-isolated property 'showHalfSheet' can not be mutated from a Sendable closure
Main actor-isolated property 'isManagingHold' can not be mutated from a Sendable closure
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
