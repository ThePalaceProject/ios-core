# ActorHealthMonitor - Complete Usage Guide

## 🎯 **Overview**

ActorHealthMonitor is now a **configurable feature** integrated into Developer Settings with automatic production disabling.

---

## ⚙️ **Configuration**

### **Automatic Behavior:**

| Build Type | Default State | Can Toggle? |
|------------|---------------|-------------|
| **DEBUG** | ✅ Enabled | Yes (in settings) |
| **RELEASE/Production** | ⚠️ Disabled | Yes (but disabled by default) |

### **Why This Design?**

✅ **No performance overhead in production** (auto-disabled)  
✅ **Full debugging in development** (auto-enabled)  
✅ **Flexibility** (can enable in beta builds for testing)  
✅ **Safe** (minimal impact when disabled)

---

## 📱 **How to Use in the App**

### **1. Access Developer Settings**

**Steps:**
1. Open app
2. Go to **Settings** tab
3. **Long press** on version number (bottom) for 5 seconds
4. **Developer Settings** menu appears
5. Tap **Developer Settings**
6. Scroll to **"Performance Monitoring"** section

**You'll see:**
```
Performance Monitoring
├─ 🔘 Enable Actor Health Monitoring [Toggle]
└─ ▶️ View Actor Health Report [Tap to view]
```

---

### **2. Toggle Monitoring On/Off**

**Toggle the switch:**
- **ON (Green):** Actor health monitoring active
  - Operations >5s log warnings
  - Operations >10s log critical alerts
  - Real-time tracking enabled

- **OFF (Gray):** Actor health monitoring disabled
  - Zero performance overhead
  - No logging
  - No tracking

**When you toggle, you'll see:**
```
Actor Monitoring
Actor health monitoring enabled. Slow operations will be logged.
[OK]
```

---

### **3. View Health Report**

**Tap "View Actor Health Report":**

You'll see a popup showing:

```
Actor Health Report

Monitoring: ✅ Enabled

Active Operations: 2
Slow Operations (>5s): 0
Critical Operations (>10s): 0

✅ All operations running smoothly!

[OK] [Copy Report]
```

**If there are slow operations:**
```
Actor Health Report

Monitoring: ✅ Enabled

Active Operations: 5
Slow Operations (>5s): 2
Critical Operations (>10s): 1

--- Slow Operations ---
• downloadManifest
  Actor: OPDSFeedService
  Duration: 7.23s
  
• syncRegistry
  Actor: TPPBookRegistry
  Duration: 12.45s

[OK] [Copy Report]
```

---

## 👨‍💻 **How to Use in Code**

### **Option 1: Automatic Conditional Monitoring (RECOMMENDED)**

The monitoring now checks its enabled state automatically:

```swift
func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
    // Auto-checks if monitoring is enabled
    let monitoringEnabled = await ActorHealthMonitor.shared.getEnabled()
    if monitoringEnabled {
        return await withActorMonitoring("downloadInfoAsync", actorType: "SafeDictionary") {
            await _downloadInfoAsyncCore(forBookIdentifier: bookIdentifier)
        }
    } else {
        // No overhead when disabled
        return await _downloadInfoAsyncCore(forBookIdentifier: bookIdentifier)
    }
}
```

**Benefits:**
- Zero overhead when disabled
- Full monitoring when enabled
- Automatic check

---

### **Option 2: Always-On Monitoring (Simple)**

For operations you always want monitored in DEBUG:

```swift
func criticalOperation() async throws -> Result {
    return try await withActorMonitoring("criticalOperation", actorType: "MyActor") {
        // Your work here
        try await doWork()
    }
}
```

**Note:** `withActorMonitoring` internally checks `isEnabled`, so this has zero overhead in production even without the conditional.

---

### **Option 3: Manual Control (Advanced)**

```swift
func customMonitoring() async {
    let id = await ActorHealthMonitor.shared.startOperation(
        name: "customOperation",
        actorType: "CustomActor"
    )
    
    defer {
        Task {
            await ActorHealthMonitor.shared.completeOperation(id: id)
        }
    }
    
    // Your work
    await doWork()
}
```

---

## 🔧 **Developer Workflows**

### **Workflow 1: Debugging Slow Downloads**

**Scenario:** Downloads feel slow

1. Enable **Actor Health Monitoring** in settings
2. Start a download
3. Check **Actor Health Report**
4. Look for operations >5s:
   ```
   • downloadManifest
     Actor: OPDSFeedService
     Duration: 8.5s  ← Problem found!
   ```
5. Investigate why that operation is slow
6. Copy report and share with team

---

### **Workflow 2: Performance Testing**

**Before release:**

1. Enable monitoring in TestFlight/beta build
2. Test app normally
3. Periodically check health report
4. Look for any critical operations
5. Optimize if needed
6. Disable before App Store release (auto-disabled)

---

### **Workflow 3: Production Debugging**

**User reports slow app:**

1. Ask user to enable Developer Settings
2. Toggle **Actor Health Monitoring** ON
3. Reproduce issue
4. Check **Actor Health Report**
5. Copy report
6. Send to support team
7. Toggle OFF when done

---

## 📊 **What Gets Monitored**

### **Currently Monitored:**

✅ **MyBooksDownloadCenter:**
- `downloadInfoAsync()` - Download info lookups
- (More can be added as needed)

### **Easy to Add Monitoring To:**

**OPDSFeedService:**
```swift
func fetchLoans() async throws -> [TPPBook] {
    return try await withActorMonitoring("fetchLoans", actorType: "OPDSFeedService") {
        try await performFetch()
    }
}
```

**TPPBookRegistry:**
```swift
func syncAsync() async throws -> (errorDoc: [AnyHashable: Any]?, newBooks: Bool) {
    return try await withActorMonitoring("syncAsync", actorType: "TPPBookRegistry") {
        try await performSync()
    }
}
```

**Any Custom Actor:**
```swift
actor MyActor {
    func expensiveOperation() async throws -> Result {
        return try await withActorMonitoring("expensiveOperation", actorType: "MyActor") {
            try await doWork()
        }
    }
}
```

---

## 🚨 **What to Watch For**

### **Warning Signs (in Health Report):**

⚠️ **Slow Operations Count > 0:**
- Some operations taking 5-10s
- Investigate why they're slow
- May be normal (network latency)
- Monitor if it increases

🚨 **Critical Operations Count > 0:**
- Operations taking >10s
- **Investigate immediately**
- Likely network timeout or deadlock
- Check Crashlytics logs

### **In Crashlytics:**

Search for:
- "Actor operation timeout"
- "Slow actor operation"
- Check metadata for operation name & actor type

---

## 🎛️ **Settings Integration**

### **Developer Settings Menu:**

```
┌─ Library Settings ─────────────────┐
│ Enable Hidden Libraries    [Toggle]│
│ Enter LCP Passphrase       [Toggle]│
├─ Library Registry Debugging ───────┤
│ [Custom Registry Cell]             │
├─ Data Management ──────────────────┤
│ Clear Cached Data                  │
├─ Performance Monitoring ───────────┤  ← NEW!
│ Enable Actor Health Monitor [Toggle]│
│ View Actor Health Report        ▶  │
├─ Developer Tools ──────────────────┤
│ Send Error Logs                 ▶  │
│ Email Audiobook Logs            ▶  │
└────────────────────────────────────┘
```

**Footer Text:**
- **DEBUG builds:** "Actor monitoring enabled in DEBUG builds. Tracks slow operations (>5s) and critical delays (>10s)."
- **RELEASE builds:** "Actor monitoring disabled in RELEASE builds by default for performance."

---

## 💡 **Best Practices**

### **DO:**
✅ Enable during development for debugging  
✅ Check health report when app feels slow  
✅ Add monitoring to new actor operations  
✅ Review Crashlytics for timeout alerts  
✅ Keep disabled in production (default)  

### **DON'T:**
❌ Leave enabled in production unnecessarily  
❌ Monitor every tiny operation (<1s)  
❌ Ignore slow operation warnings  
❌ Remove monitoring code (just disable it)  

---

## 🔍 **Example: How to Add Monitoring to New Code**

### **Step 1: Identify Slow Operation**

```swift
actor MyActor {
    func slowOperation() async throws -> Data {
        // This might be slow - let's monitor it!
        let data = try await fetchFromNetwork()
        return data
    }
}
```

### **Step 2: Add Monitoring**

```swift
actor MyActor {
    func slowOperation() async throws -> Data {
        return try await withActorMonitoring("slowOperation", actorType: "MyActor") {
            let data = try await fetchFromNetwork()
            return data
        }
    }
}
```

### **Step 3: Test**

1. Enable monitoring in Developer Settings
2. Call the operation
3. Check health report
4. See if it appears in slow operations

### **Step 4: Optimize (if needed)**

If it shows up as slow:
- Add caching
- Reduce network calls
- Batch operations
- Add parallelization

---

## 📈 **Production Strategy**

### **Phase 1: Development (Current)**
- ✅ Monitoring enabled by default in DEBUG
- ✅ Full logging and tracking
- ✅ Easy to toggle for testing

### **Phase 2: Beta Testing**
- Consider enabling for TestFlight users
- Collect health reports
- Identify bottlenecks
- Optimize hot paths

### **Phase 3: Production**
- ✅ Auto-disabled by default
- Users can enable if needed (advanced users)
- Minimal production impact
- Available for debugging support issues

---

## 🎊 **Summary**

### **What You Get:**

✅ **Configurable from Settings** - Easy toggle  
✅ **Auto-disabled in Production** - No performance impact  
✅ **Real-time Health Reports** - Instant insights  
✅ **Zero Overhead When Off** - Safe by default  
✅ **Full Debugging When On** - Complete visibility  

### **How to Use:**

1. **Development:** Already enabled, just check reports
2. **Beta Testing:** Enable and collect data
3. **Production:** Disabled by default (enable for debugging)
4. **Code:** Use `withActorMonitoring()` for slow operations

---

## 🚀 **Ready to Use!**

The ActorHealthMonitor is now:
- ✅ Fully integrated into Developer Settings
- ✅ Automatically disabled in production
- ✅ Zero overhead when off
- ✅ Full visibility when on
- ✅ Easy to use in code

**Just toggle it on in Developer Settings and start monitoring!** 🎉

---

**Document Version:** 1.0  
**Last Updated:** 2025-10-29  
**Feature Status:** ✅ Production Ready

