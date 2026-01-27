# 🧪 Palace iOS Unit Test Results

**Generated:** 2026-01-27 22:51:30 UTC
**Commit:** `0e1e003a3521`
**Branch:** `feature/enable-carplay`

## Summary

### 🔴 BUILD FAILED

The build failed before tests could run.

### Build Errors

```
Value of type 'CarPlayAudiobookBridge' has no member 'currentManager'
Call to main actor-isolated initializer 'init(sessionManager:)' in a synchronous nonisolated context
Main actor-isolated property 'currentBook' can not be referenced from a nonisolated autoclosure
Main actor-isolated property 'currentChapters' can not be referenced from a nonisolated autoclosure
Main actor-isolated property 'currentChapter' can not be referenced from a nonisolated autoclosure
Call to main actor-isolated initializer 'init(sessionManager:)' in a synchronous nonisolated context
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
