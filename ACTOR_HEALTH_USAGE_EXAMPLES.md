# ActorHealthMonitor - Usage Examples & Integration Guide

## 🎯 **Quick Reference**

### **When to Use ActorHealthMonitor**

✅ **Use it for:**
- Long-running actor operations (>1s expected)
- Network operations through actors
- Database queries
- File I/O in actors
- Complex calculations in actors
- Any operation that could hang

❌ **Don't use it for:**
- Simple property access (<0.1s)
- Trivial calculations
- Non-actor operations
- Already fast operations

---

## 📖 **Method 1: withActorMonitoring Wrapper (RECOMMENDED)**

### **Basic Usage:**

```swift
func downloadManifest() async throws -> Manifest {
    return try await withActorMonitoring("downloadManifest", actorType: "DownloadActor") {
        // Your async work here
        let data = await networkActor.fetch(url)
        return try parseManifest(data)
    }
}
```

### **What Happens:**
1. **Before operation:** Starts timer and registers operation
2. **After 5s:** Logs warning if still running
3. **After 10s:** Logs critical alert to Crashlytics
4. **After completion:** Logs if it was slow, removes from tracking

### **Automatic Logging:**
```
// If operation takes 7s:
⚠️ Slow actor operation: downloadManifest in DownloadActor took 7.23s

// If operation takes 12s:
🚨 CRITICAL: Actor operation timeout - downloadManifest in DownloadActor exceeded 10.0s
[Logged to Crashlytics with full metadata]
```

---

## 📖 **Method 2: Manual Monitoring (Advanced)**

### **For Complex Control Flow:**

```swift
func multiStepOperation() async throws {
    let monitorId = await ActorHealthMonitor.shared.startOperation(
        name: "multiStepOperation",
        actorType: "DataProcessor"
    )
    
    defer {
        Task {
            await ActorHealthMonitor.shared.completeOperation(id: monitorId)
        }
    }
    
    // Step 1
    await processStep1()
    
    // Early return possible
    guard someCondition else { return }  // defer ensures cleanup
    
    // Step 2
    await processStep2()
}
```

### **Benefits:**
- Works with early returns
- Works with throws
- Flexible control
- Still gets automatic logging

---

## 📖 **Method 3: Health Reporting (Production Debugging)**

### **Integration into Developer Settings:**

```swift
// Add to TPPDeveloperSettingsTableViewController.swift

private func showActorHealthReport() {
    Task {
        let report = await ActorHealthMonitor.shared.getHealthReport()
        
        let activeCount = report["activeOperationCount"] as? Int ?? 0
        let slowCount = report["slowOperationCount"] as? Int ?? 0
        let criticalCount = report["criticalOperationCount"] as? Int ?? 0
        
        var message = """
        Actor Health Status:
        
        Active Operations: \(activeCount)
        Slow Operations (>5s): \(slowCount)
        Critical Operations (>10s): \(criticalCount)
        """
        
        if let slowOps = report["slowOperations"] as? [[String: Any]] {
            message += "\n\nSlow Operations:"
            for op in slowOps {
                let name = op["name"] as? String ?? "unknown"
                let actor = op["actorType"] as? String ?? "unknown"
                let duration = op["duration"] as? TimeInterval ?? 0
                message += "\n- \(name) in \(actor): \(String(format: "%.2f", duration))s"
            }
        }
        
        let alert = UIAlertController(
            title: "Actor Health Report",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        
        await MainActor.run {
            self.present(alert, animated: true)
        }
    }
}
```

### **Add to Developer Menu:**

```swift
// In your settings table view

case .actorHealth:
    cell.textLabel?.text = "Actor Health Report"
    cell.accessoryType = .disclosureIndicator
    
    // On tap:
    showActorHealthReport()
```

---

## 🔧 **Real-World Integration Examples**

### **Example 1: Monitoring OPDSFeedService**

```swift
// In Palace/OPDS2/OPDSFeedService.swift

actor OPDSFeedService {
    func fetchLoans() async throws -> [TPPBook] {
        return try await withActorMonitoring("fetchLoans", actorType: "OPDSFeedService") {
            // Network call that could be slow
            let feed = try await networkExecutor.get(loansURL)
            return parseFeed(feed)
        }
    }
    
    func borrowBook(_ book: TPPBook) async throws {
        return try await withActorMonitoring("borrowBook", actorType: "OPDSFeedService") {
            // OPDS borrow operation
            try await performBorrow(book)
        }
    }
}
```

**Benefit:** Automatically detect slow OPDS responses in production

---

### **Example 2: Monitoring Book Registry Sync**

```swift
// In Palace/Book/Models/TPPBookRegistryAsync.swift

extension TPPBookRegistry {
    func syncAsync() async throws -> (errorDoc: [AnyHashable: Any]?, newBooks: Bool) {
        return try await withActorMonitoring("syncAsync", actorType: "TPPBookRegistry") {
            // Sync operation could take time
            try await withCheckedThrowingContinuation { continuation in
                self.sync { errorDoc, newBooks in
                    continuation.resume(returning: (errorDoc, newBooks))
                }
            }
        }
    }
}
```

**Benefit:** Detect slow sync operations (network issues, large catalogs)

---

### **Example 3: Monitoring SafeDictionary Operations**

Already integrated! When you wrap SafeDictionary access:

```swift
func getSomeInfo() async -> Info? {
    return await withActorMonitoring("getSomeInfo", actorType: "SafeDictionary") {
        await safeDictionary.get(key)
    }
}
```

**Benefit:** Detect actor contention if multiple operations are queued

---

## 🎛️ **Production Monitoring Dashboard**

### **Create a Health Status View:**

```swift
// Palace/Settings/DeveloperSettings/ActorHealthView.swift

import SwiftUI

struct ActorHealthView: View {
    @State private var healthReport: [String: Any] = [:]
    @State private var isRefreshing = false
    
    var body: some View {
        List {
            Section("Current Status") {
                HStack {
                    Text("Active Operations")
                    Spacer()
                    Text("\(healthReport["activeOperationCount"] as? Int ?? 0)")
                        .foregroundColor(.blue)
                }
                
                HStack {
                    Text("Slow Operations")
                    Spacer()
                    Text("\(healthReport["slowOperationCount"] as? Int ?? 0)")
                        .foregroundColor(.orange)
                }
                
                HStack {
                    Text("Critical Operations")
                    Spacer()
                    Text("\(healthReport["criticalOperationCount"] as? Int ?? 0)")
                        .foregroundColor(.red)
                }
            }
            
            if let slowOps = healthReport["slowOperations"] as? [[String: Any]], !slowOps.isEmpty {
                Section("Slow Operations") {
                    ForEach(slowOps.indices, id: \.self) { index in
                        let op = slowOps[index]
                        VStack(alignment: .leading) {
                            Text(op["name"] as? String ?? "Unknown")
                                .font(.headline)
                            Text("Actor: \(op["actorType"] as? String ?? "Unknown")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Duration: \(String(format: "%.2f", op["duration"] as? Double ?? 0))s")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Actor Health")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Refresh") {
                    refreshHealth()
                }
                .disabled(isRefreshing)
            }
        }
        .task {
            await refreshHealth()
        }
    }
    
    private func refreshHealth() {
        isRefreshing = true
        Task {
            healthReport = await ActorHealthMonitor.shared.getHealthReport()
            isRefreshing = false
        }
    }
}
```

---

## 🚨 **Alerting & Notifications**

### **Example 4: Alert on Critical Operations**

```swift
// Add to AppDelegate or monitoring service

class AppHealthMonitor {
    private var healthCheckTimer: Timer?
    
    func startMonitoring() {
        // Check every 30 seconds
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task {
                let report = await ActorHealthMonitor.shared.getHealthReport()
                
                if let criticalCount = report["criticalOperationCount"] as? Int, criticalCount > 0 {
                    // Alert user or log to analytics
                    Log.error(#file, "🚨 CRITICAL: \(criticalCount) actor operations running critically slow")
                    
                    // Send to analytics
                    TPPErrorLogger.logError(
                        withCode: .downloadFail,
                        summary: "Critical actor performance issue detected",
                        metadata: report
                    )
                }
            }
        }
    }
}
```

---

## 📊 **SafeDictionary Metrics**

### **Example 5: Monitor Dictionary Health**

```swift
// Add to download center debugging

@objc func getDownloadCenterMetrics() -> [String: Any] {
    var metrics: [String: Any] = [:]
    
    Task {
        // Get metrics from each SafeDictionary
        let downloadInfoMetrics = await bookIdentifierToDownloadInfo.getMetrics()
        let taskMetrics = await taskIdentifierToBook.getMetrics()
        
        metrics["downloadInfo"] = downloadInfoMetrics
        metrics["taskMapping"] = taskMetrics
    }
    
    return metrics
}
```

**Metrics Available:**
```swift
[
    "count": 5,              // Number of items
    "accessCount": 1234,     // Total accesses
    "lastAccessTime": Date,  // Most recent access
    "memoryFootprint": 1024  // Bytes used
]
```

---

## 🎨 **SwiftUI Integration**

### **Example 6: Live Health Monitoring View**

```swift
struct DeveloperDashboardView: View {
    @State private var actorHealth: [String: Any] = [:]
    @State private var downloadMetrics: [String: Any] = [:]
    
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    var body: some View {
        List {
            Section("Actor Performance") {
                HealthMetricRow(
                    label: "Active Operations",
                    value: actorHealth["activeOperationCount"] as? Int ?? 0,
                    color: .blue
                )
                
                HealthMetricRow(
                    label: "Slow Operations",
                    value: actorHealth["slowOperationCount"] as? Int ?? 0,
                    color: .orange
                )
                
                HealthMetricRow(
                    label: "Critical Operations",
                    value: actorHealth["criticalOperationCount"] as? Int ?? 0,
                    color: .red
                )
            }
            
            Section("Download State") {
                if let downloadInfo = downloadMetrics["downloadInfo"] as? [String: Any] {
                    Text("Active Downloads: \(downloadInfo["count"] as? Int ?? 0)")
                    Text("Total Accesses: \(downloadInfo["accessCount"] as? Int ?? 0)")
                }
            }
        }
        .onReceive(timer) { _ in
            refreshMetrics()
        }
        .onAppear {
            refreshMetrics()
        }
    }
    
    private func refreshMetrics() {
        Task {
            actorHealth = await ActorHealthMonitor.shared.getHealthReport()
            downloadMetrics = await getDownloadMetrics()
        }
    }
    
    private func getDownloadMetrics() async -> [String: Any] {
        let downloadInfoMetrics = await MyBooksDownloadCenter.shared
            .bookIdentifierToDownloadInfo.getMetrics()
        return ["downloadInfo": downloadInfoMetrics]
    }
}

struct HealthMetricRow: View {
    let label: String
    let value: Int
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .foregroundColor(color)
                .fontWeight(value > 0 ? .bold : .regular)
        }
    }
}
```

---

## 🔔 **Example 7: Alerting System**

### **Alert When Things Are Slow:**

```swift
// Add to MemoryPressureMonitor or similar

extension MemoryPressureMonitor {
    func checkActorHealth() {
        Task {
            let report = await ActorHealthMonitor.shared.getHealthReport()
            
            // Alert if critical operations detected
            if let criticalCount = report["criticalOperationCount"] as? Int, 
               criticalCount > 0 {
                
                // Log to Crashlytics
                TPPErrorLogger.logError(
                    withCode: .downloadFail,
                    summary: "Critical actor performance degradation",
                    metadata: report
                )
                
                // Show user alert (optional - for beta builds)
                #if DEBUG
                await MainActor.run {
                    let alert = UIAlertController(
                        title: "Performance Warning",
                        message: "Detected \(criticalCount) slow operations. Check logs.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    // Present alert
                }
                #endif
            }
        }
    }
}
```

---

## 🧪 **Example 8: Testing & Validation**

### **Unit Test Integration:**

```swift
// In test suite

func testActorPerformance() async throws {
    // Start monitoring
    let id = await ActorHealthMonitor.shared.startOperation(
        name: "testOperation",
        actorType: "TestActor"
    )
    
    // Run operation
    await slowActorOperation()
    
    // Complete monitoring
    await ActorHealthMonitor.shared.completeOperation(id: id)
    
    // Get report
    let report = await ActorHealthMonitor.shared.getHealthReport()
    
    // Assert no critical operations
    XCTAssertEqual(report["criticalOperationCount"] as? Int, 0, 
                   "Should not have critical operations")
}
```

---

## 🎯 **Real-World Usage Patterns**

### **Pattern 1: Wrap All Network Operations**

```swift
actor NetworkActor {
    func fetch(url: URL) async throws -> Data {
        return try await withActorMonitoring("fetch", actorType: "NetworkActor") {
            // Network call
            try await URLSession.shared.data(from: url).0
        }
    }
    
    func upload(data: Data, to url: URL) async throws {
        try await withActorMonitoring("upload", actorType: "NetworkActor") {
            // Upload operation
            try await performUpload(data, to: url)
        }
    }
}
```

---

### **Pattern 2: Wrap Database Operations**

```swift
actor DatabaseActor {
    func query<T>(_ query: String) async throws -> [T] {
        return try await withActorMonitoring("query", actorType: "DatabaseActor") {
            // Database query
            try await executeQuery(query)
        }
    }
}
```

---

### **Pattern 3: Wrap File I/O**

```swift
actor FileActor {
    func readLargeFile(url: URL) async throws -> Data {
        return try await withActorMonitoring("readLargeFile", actorType: "FileActor") {
            // File read
            try Data(contentsOf: url)
        }
    }
}
```

---

## 📈 **Monitoring Best Practices**

### **DO:**
✅ Monitor operations you expect to take >1s
✅ Use descriptive operation names ("fetchLoans", not "fetch")
✅ Include actor type for context
✅ Check health reports during development
✅ Review Crashlytics for timeout alerts

### **DON'T:**
❌ Monitor every tiny operation (overhead)
❌ Use generic names ("process", "handle")
❌ Ignore timeout alerts in production
❌ Remove monitoring after debugging (keep it!)

---

## 🎛️ **Configuration**

### **Adjust Thresholds (if needed):**

```swift
actor ActorHealthMonitor {
    // Default thresholds
    private let warningThreshold: TimeInterval = 5.0   // ⚠️ Warning
    private let criticalThreshold: TimeInterval = 10.0  // 🚨 Critical
    
    // If you need different thresholds:
    // - Increase for legitimately slow operations
    // - Decrease for fast operations that should never be slow
}
```

---

## 🔍 **Debug Scenarios**

### **Scenario 1: "Why is my download slow?"**

```swift
// Check health report
let report = await ActorHealthMonitor.shared.getHealthReport()

// Look for:
if let slowOps = report["slowOperations"] as? [[String: Any]] {
    // See which actor operations are slow
    // Might reveal: "fetchManifest taking 8s" → network issue
}
```

### **Scenario 2: "Is there actor contention?"**

```swift
// Check active operation count
let report = await ActorHealthMonitor.shared.getHealthReport()
let activeCount = report["activeOperationCount"] as? Int ?? 0

if activeCount > 10 {
    // Many operations queued = possible contention
    print("⚠️ High actor contention: \(activeCount) operations queued")
}
```

---

## 🎊 **Summary: How to Use It**

### **Quick Start (3 Steps):**

1. **Wrap slow operations:**
```swift
await withActorMonitoring("operationName", actorType: "ActorType") {
    await slowWork()
}
```

2. **Add debug menu option:**
```swift
let report = await ActorHealthMonitor.shared.getHealthReport()
print(report)
```

3. **Monitor Crashlytics:**
- Search for "Actor operation timeout"
- Review slow operation alerts

### **That's It!** 🎉

The monitoring happens automatically. You just:
1. Wrap operations with `withActorMonitoring()`
2. Check reports when debugging
3. Monitor Crashlytics for production issues

---

## 💡 **Pro Tips**

1. **Start with critical paths:**
   - Downloads
   - Network operations
   - Registry sync
   - Database queries

2. **Use in DEBUG builds first:**
   - Verify overhead is acceptable
   - Tune thresholds
   - Then ship to production

3. **Review weekly:**
   - Check Crashlytics for timeout alerts
   - Review slow operation patterns
   - Optimize hot paths

4. **Don't over-monitor:**
   - Skip trivial operations
   - Focus on user-facing features
   - Monitor what matters

---

**That's how you use ActorHealthMonitor!** It's already working in your codebase - just add more `withActorMonitoring()` wrappers where you want insights. 🚀

