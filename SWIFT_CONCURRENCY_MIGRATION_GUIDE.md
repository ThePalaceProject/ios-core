# Swift Concurrency Migration Guide

**For**: Palace iOS Development Team  
**Purpose**: Guidelines for using new async/await infrastructure  
**Last Updated**: October 27, 2025

---

## 📚 Table of Contents

1. [Quick Start](#quick-start)
2. [Error Handling](#error-handling)
3. [Network Operations](#network-operations)
4. [Download Operations](#download-operations)
5. [Registry Operations](#registry-operations)
6. [Concurrency Patterns](#concurrency-patterns)
7. [Testing](#testing)
8. [Common Patterns](#common-patterns)
9. [Migration Checklist](#migration-checklist)

---

## 🚀 Quick Start

### Before You Begin

All new concurrency infrastructure is available in:
- `Palace/ErrorHandling/PalaceError.swift` - Error types
- `Palace/Network/TPPNetworkExecutor+Async.swift` - Network operations
- `Palace/OPDS2/OPDSFeedService.swift` - OPDS feed operations
- `Palace/Utilities/Concurrency/MainActorHelpers.swift` - Concurrency utilities
- `Palace/Utilities/Concurrency/AsyncBridge.swift` - Callback bridging

### Key Principles

1. **Use `@MainActor`** for UI-related classes (ViewModels, Views)
2. **Use actors** for shared mutable state
3. **Throw `PalaceError`** for domain-specific errors
4. **Prefer async/await** over callbacks
5. **Use Task** instead of DispatchQueue for async work

---

## 🎯 Error Handling

### Using PalaceError

```swift
// ✅ Good: Throw structured errors
func fetchBook() async throws -> TPPBook {
  guard let url = bookURL else {
    throw PalaceError.network(.invalidURL)
  }
  
  do {
    let data = try await networkExecutor.get(url)
    return try parseBook(data)
  } catch {
    throw PalaceError.from(error)
  }
}

// ✅ Good: Handle structured errors
do {
  let book = try await fetchBook()
  // Use book
} catch let error as PalaceError {
  showAlert(
    title: "Error",
    message: error.localizedDescription,
    recovery: error.recoverySuggestion
  )
}

// ❌ Avoid: Generic error handling
catch {
  print("Error: \(error)") // Not user-friendly
}
```

### Error Conversion

```swift
// Automatic conversion from NSError
let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
let palaceError = PalaceError.from(urlError)
// Result: PalaceError.network(.timeout)
```

---

## 🌐 Network Operations

### Basic GET Request

```swift
// ❌ Old Pattern
TPPNetworkExecutor.shared.GET(url) { result in
  DispatchQueue.main.async {
    switch result {
    case .success(let data, _):
      // Process data
    case .failure(let error, _):
      // Handle error
    }
  }
}

// ✅ New Pattern (@MainActor context)
do {
  let data = try await TPPNetworkExecutor.shared.get(url)
  // Process data
} catch let error as PalaceError {
  // Handle structured error
}
```

### With Retry Logic

```swift
// Automatic retry on transient failures
let data = try await TPPNetworkExecutor.shared.getWithRetry(
  url,
  maxRetries: 3,
  useToken: true
)
```

### With Circuit Breaker

```swift
// Fail fast when service is down
let data = try await TPPNetworkExecutor.shared.getWithCircuitBreaker(
  url,
  serviceKey: "my-service",
  useToken: true
)
```

---

## 📚 OPDS Feed Operations

### Fetching Feeds

```swift
// ❌ Old Pattern
TPPOPDSFeed.withURL(url, shouldResetCache: true, useTokenIfAvailable: true) { feed, error in
  DispatchQueue.main.async {
    if let feed = feed {
      // Process feed
    } else {
      // Handle error
    }
  }
}

// ✅ New Pattern
do {
  let feed = try await OPDSFeedService.shared.fetchFeed(
    from: url,
    resetCache: true,
    useToken: true
  )
  // Process feed
} catch {
  // Handle structured error
}
```

### Borrowing Books

```swift
// ✅ Using OPDSFeedService
let borrowedBook = try await OPDSFeedService.shared.borrowBook(
  book,
  attemptDownload: true
)
```

### Convenience Methods

```swift
// Fetch user's loans
let loansFeed = try await OPDSFeedService.shared.fetchLoans()

// Fetch catalog root
let catalogFeed = try await OPDSFeedService.shared.fetchCatalogRoot()
```

---

## ⬇️ Download Operations

### Starting Downloads

```swift
// ❌ Old Pattern
MyBooksDownloadCenter.shared.startBorrow(for: book, attemptDownload: true) {
  DispatchQueue.main.async {
    // Update UI
  }
}

// ✅ New Pattern (with all safety checks)
do {
  let borrowedBook = try await MyBooksDownloadCenter.shared.borrowAsync(
    book,
    attemptDownload: true
  )
  // Update UI (already on MainActor)
} catch let error as PalaceError {
  // Show error with recovery suggestion
  showAlert(error: error)
}

// ✅ Or just download
try await MyBooksDownloadCenter.shared.startDownloadAsync(for: book)
// Automatically checks disk space and network conditions!
```

### Monitoring Progress

```swift
// ❌ Old Pattern (Combine)
downloadCenter.downloadProgressPublisher
  .filter { $0.0 == bookId }
  .map { $0.1 }
  .receive(on: DispatchQueue.main)
  .sink { progress in
    self.progress = progress
  }

// ✅ New Pattern (AsyncStream)
for await progress in downloadCenter.downloadProgressStream(for: bookId) {
  self.progress = progress
}

// ✅ Or wait for completion
let success = await downloadCenter.waitForDownloadCompletion(for: bookId, timeout: 300)
```

### Batch Downloads

```swift
// Download multiple books with concurrency limit
await MyBooksDownloadCenter.shared.downloadBooksAsync(
  books,
  maxConcurrent: 3
)
```

---

## 📖 Registry Operations

### Sync Operation

```swift
// ❌ Old Pattern
TPPBookRegistry.shared.sync { errorDoc, hasNewBooks in
  DispatchQueue.main.async {
    // Update UI
  }
}

// ✅ New Pattern
do {
  let (errorDoc, hasNewBooks) = try await TPPBookRegistry.shared.syncAsync()
  if hasNewBooks {
    // Update UI
  }
} catch {
  // Handle error
}
```

### State Updates

```swift
// Async state update
await registry.setStateAsync(.downloadSuccessful, for: bookId)

// Wait for a specific state
let didComplete = await registry.waitForState(
  .downloadSuccessful,
  for: bookId,
  timeout: 60
)
```

### Monitoring Changes

```swift
// ✅ AsyncStream instead of Combine
for await (bookId, state) in registry.bookStateUpdates() {
  if bookId == myBookId {
    handleStateChange(state)
  }
}
```

---

## 🔄 Concurrency Patterns

### In @MainActor Classes

```swift
@MainActor
class MyViewModel: ObservableObject {
  
  // ❌ Avoid: Redundant main queue dispatch
  func updateData() {
    DispatchQueue.main.async {
      self.data = newData
    }
  }
  
  // ✅ Correct: Already on main actor
  func updateData() {
    self.data = newData
  }
  
  // ✅ Combine: Remove .receive(on: DispatchQueue.main)
  func setupPublishers() {
    publisher
      .sink { [weak self] value in
        self?.data = value // Already on main thread
      }
      .store(in: &cancellables)
  }
  
  // ✅ Background work: Use Task
  func doBackgroundWork() {
    Task {
      let result = await heavyComputation() // Runs in background
      self.data = result // Back to main actor
    }
  }
}
```

### Debouncing

```swift
// ❌ Old Pattern
var debounceTimer: Timer?
func didType(_ text: String) {
  debounceTimer?.invalidate()
  debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
    self.search(text)
  }
}

// ✅ New Pattern
let debouncer = Debouncer(duration: .milliseconds(500))

func didType(_ text: String) {
  Task {
    await debouncer.debounce {
      await self.search(text)
    }
  }
}
```

### Serial Execution

```swift
// ❌ Old Pattern
let serialQueue = DispatchQueue(label: "com.palace.serial")
serialQueue.async { /* task 1 */ }
serialQueue.async { /* task 2 */ }

// ✅ New Pattern
let executor = SerialExecutor()
await executor.enqueue { /* task 1 */ }
await executor.enqueue { /* task 2 */ }
```

### Parallel Execution

```swift
// ✅ Execute multiple tasks in parallel
let results = try await runParallel([
  { try await fetchBook1() },
  { try await fetchBook2() },
  { try await fetchBook3() }
])

// ✅ Fire and forget
await runParallelFireAndForget([
  { await logEvent1() },
  { await logEvent2() }
])
```

---

## 🧪 Testing

### Testing Async Code

```swift
func testAsyncOperation() async throws {
  let result = try await myAsyncFunction()
  XCTAssertEqual(result, expected Value)
}
```

### Testing Actors

```swift
func testActorIsolation() async {
  let actor = MyActor()
  await actor.setValue(42)
  let value = await actor.getValue()
  XCTAssertEqual(value, 42)
}
```

### Testing Concurrent Access

```swift
func testConcurrentAccess() async {
  let dict = SafeDictionary<String, Int>()
  
  await withTaskGroup(of: Void.self) { group in
    for i in 0..<100 {
      group.addTask {
        await dict.set("key\(i)", value: i)
      }
    }
  }
  
  let count = await dict.count()
  XCTAssertEqual(count, 100)
}
```

---

## 📋 Common Patterns

### Converting Callbacks to Async

```swift
// ❌ Callback-based
func fetchData(completion: @escaping (Data?, Error?) -> Void) {
  // ...
}

// ✅ Async wrapper
func fetchDataAsync() async throws -> Data {
  try await asyncCompletion { completion in
    fetchData(completion: completion)
  }
}
```

### Bridging Objective-C

```swift
// Objective-C method with callback
// - (void)loadWithCompletion:(void (^)(BOOL success))completion;

// ✅ Swift async wrapper
func loadAsync() async -> Bool {
  await asyncSuccess { completion in
    self.load(completion: completion)
  }
}
```

### Ensuring Main Thread for Callbacks

```swift
// ❌ Old way
func callLegacyAPI(completion: @escaping (Result) -> Void) {
  legacyAPI.fetch { result in
    DispatchQueue.main.async {
      completion(result)
    }
  }
}

// ✅ New way
func callLegacyAPI(completion: @escaping (Result) -> Void) {
  legacyAPI.fetch(ensureMainThread(completion))
}
```

---

## ✅ Migration Checklist

### For Each File

- [ ] Check if class should be `@MainActor`
- [ ] Remove redundant `DispatchQueue.main.async` calls
- [ ] Remove `.receive(on: DispatchQueue.main)` from Combine chains
- [ ] Replace callbacks with async/await where possible
- [ ] Use `PalaceError` for error throwing
- [ ] Add async wrapper methods for high-value operations
- [ ] Use actors for shared mutable state
- [ ] Replace `Timer` with `Task` for delays
- [ ] Test thoroughly for race conditions

### For New Code

- [ ] Use async/await from the start
- [ ] Mark UI classes as `@MainActor`
- [ ] Use actors for shared state
- [ ] Throw `PalaceError` for errors
- [ ] Leverage existing async utilities
- [ ] Add tests for concurrent access
- [ ] Document actor reentrancy if complex

---

## 🎓 Best Practices

### DO ✅

- Use `@MainActor` for ViewModels and UI classes
- Use actors for shared mutable state
- Throw `PalaceError` for structured errors
- Use `async/await` for asynchronous operations
- Use `Task` for fire-and-forget work
- Use `withTaskGroup` for parallel work
- Add `[weak self]` in closures captured by Tasks
- Test concurrent access patterns

### DON'T ❌

- Don't use `DispatchQueue.main.async` in `@MainActor` classes
- Don't use `.receive(on: DispatchQueue.main)` with `@MainActor`
- Don't use `DispatchQueue` for serial execution (use `SerialExecutor`)
- Don't use `Timer` for delays (use `Task.sleep`)
- Don't force cast without fallback
- Don't use `fatalError` in production code paths
- Don't mix Combine and AsyncSequence unnecessarily
- Don't forget to handle Task cancellation

---

## 📞 Getting Help

### Resources

- **Comprehensive Examples**: See modernized ViewModels in commit history
- **Test Files**: `PalaceTests/ConcurrencyTests/` for patterns
- **Documentation**: `MODERNIZATION_PROGRESS.md` for overall plan
- **Session Summary**: `MODERNIZATION_SESSION_SUMMARY.md` for details

### Common Questions

**Q**: When should I use an actor vs @MainActor?  
**A**: Use `@MainActor` for UI classes. Use custom actors for non-UI shared state.

**Q**: How do I convert a callback to async?  
**A**: Use `withCheckedThrowingContinuation` or helpers from `AsyncBridge.swift`

**Q**: Should I remove all DispatchQueue usage?  
**A**: Only in `@MainActor` classes. Keep DispatchQueue for background work that truly needs manual queue management.

**Q**: How do I handle errors from legacy Objective-C code?  
**A**: Use `PalaceError.from(error)` to convert NSError to PalaceError

**Q**: What about NotificationCenter?  
**A**: Prefer Combine publishers for SwiftUI, AsyncStream for actors. Keep NotificationCenter only for Objective-C interop.

---

## 🎯 Migration Priority

### High Priority (Do First)
1. UI classes → Add `@MainActor`, remove redundant dispatches
2. Network calls → Use async APIs with automatic retries
3. Downloads → Use async APIs with error recovery
4. Error handling → Convert to PalaceError

### Medium Priority
1. Business logic → Convert to actors where appropriate
2. Shared state → Wrap in actors
3. Callbacks → Add async wrappers

### Low Priority (Nice to Have)
1. Complete Combine → AsyncStream conversion
2. Full OPDS layer Swift conversion
3. Eliminate all NotificationCenter usage

---

## 📊 Success Metrics

### Per File/Feature
- [ ] Compiles without warnings
- [ ] Linter passes
- [ ] Manual testing completed
- [ ] No new crashes introduced
- [ ] Memory leaks checked
- [ ] Performance acceptable

### Overall
- Track DispatchQueue reduction
- Monitor crash rates
- Check memory usage
- Measure download success rates

---

**Remember**: Incremental migration is key. Don't try to modernize everything at once!

