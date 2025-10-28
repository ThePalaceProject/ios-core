# 📝 Instructions to Add Files to Xcode Project

## Files to Add to **Palace** Target (12 files)

### In Xcode Navigator:

1. **Right-click on "Palace/ErrorHandling" folder** → Add Files to "Palace"...
   - Select: `PalaceError.swift`
   - Select: `CrashRecoveryService.swift`
   - ✅ Check "Palace" target
   - Click "Add"

2. **Right-click on "Palace/Logging" folder** → Add Files to "Palace"...
   - Select: `ErrorLogExporter.swift`
   - Select: `PersistentLogger.swift`
   - ✅ Check "Palace" target
   - Click "Add"

3. **Right-click on "Palace/Network" folder** → Add Files to "Palace"...
   - Select: `TPPNetworkExecutor+Async.swift`
   - Select: `CircuitBreaker.swift`
   - ✅ Check "Palace" target
   - Click "Add"

4. **Right-click on "Palace/OPDS2" folder** → Add Files to "Palace"...
   - Select: `OPDSFeedService.swift`
   - ✅ Check "Palace" target
   - Click "Add"

5. **Right-click on "Palace/MyBooks" folder** → Add Files to "Palace"...
   - Select: `DownloadErrorRecovery.swift`
   - Select: `MyBooksDownloadCenter+Async.swift`
   - ✅ Check "Palace" target
   - Click "Add"

6. **Right-click on "Palace/Book/Models" folder** → Add Files to "Palace"...
   - Select: `TPPBookRegistryAsync.swift`
   - ✅ Check "Palace" target
   - Click "Add"

7. **Right-click on "Palace/Utilities/Concurrency" folder** → Add Files to "Palace"...
   - Select: `MainActorHelpers.swift`
   - Select: `AsyncBridge.swift`
   - ✅ Check "Palace" target
   - Click "Add"

## Files to Add to **PalaceTests** Target (3 files)

8. **Right-click on "PalaceTests" group** → New Group → Name it "ConcurrencyTests"

9. **Right-click on "PalaceTests/ConcurrencyTests" folder** → Add Files to "Palace"...
   - Select all 3 files in `PalaceTests/ConcurrencyTests/`:
     - `ActorIsolationTests.swift`
     - `ErrorHandlingTests.swift`
     - `DownloadRecoveryTests.swift`
   - ✅ Check "PalaceTests" target ONLY
   - Click "Add"

## Verify

After adding all files:
1. Build the project (Cmd+B)
2. Should compile successfully
3. Run tests (Cmd+U) to verify test files work

## If Files Don't Appear

Make sure you're selecting "Add Files" not "New File", and navigate to the actual file locations on disk.

---

**All files are in correct locations on disk - just need to be referenced in the project!**
