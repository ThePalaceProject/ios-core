//
//  MemoryEventRecorder.swift
//  Palace
//
//  Writes one line per memory event (a memory warning or a system memory
//  pressure event) with the app's footprint, the memory still available to it,
//  and the size of each registered cache (PP-5509). Device runs read these
//  lines from the app's log file to set the memory budget.
//

import Foundation
import os
import PalaceLogging

/// What raised the memory event.
enum MemoryEventKind: String, Sendable {
    case warning
    case pressureWarning = "pressure-warning"
    case pressureCritical = "pressure-critical"

    /// The kind for a system memory pressure event: critical wins when both
    /// flags are set.
    init(pressure: DispatchSource.MemoryPressureEvent) {
        self = pressure.contains(.critical) ? .pressureCritical : .pressureWarning
    }
}

final class MemoryEventRecorder: @unchecked Sendable {

    /// The process footprint in bytes: the figure iOS uses to end an app for
    /// memory. nil when the kernel call fails.
    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private let footprint: @Sendable () -> UInt64?
    private let available: @Sendable () -> UInt64
    private let write: @Sendable (String) -> Void
    /// Cache name to a reader of its current size in bytes. Guarded by `lock`.
    private var cacheSizes: [String: @Sendable () -> Int] = [:]
    private let lock = NSLock()

    init(
        footprint: @escaping @Sendable () -> UInt64? = { MemoryEventRecorder.physicalFootprint() },
        available: @escaping @Sendable () -> UInt64 = { UInt64(os_proc_available_memory()) },
        write: @escaping @Sendable (String) -> Void = { Log.record("MemoryEvent", $0) }
    ) {
        self.footprint = footprint
        self.available = available
        self.write = write
    }

    /// Adds a cache to every later record. `size` must be safe to call from
    /// any thread, and returns the cache's current size in bytes.
    func registerCache(named name: String, size: @escaping @Sendable () -> Int) {
        lock.withLock { cacheSizes[name] = size }
    }

    /// Writes one record. The line is `key=value` pairs so a device run can
    /// parse it: sizes are in whole megabytes, caches in name order.
    func record(_ kind: MemoryEventKind) {
        let caches = lock.withLock { cacheSizes }
        var fields = [
            "event=\(kind.rawValue)",
            "footprintMB=\(footprint().map { String(Self.megabytes($0)) } ?? "unknown")",
            "availableMB=\(Self.megabytes(available()))"
        ]
        for name in caches.keys.sorted() {
            fields.append("cache.\(name)MB=\(Self.megabytes(UInt64(max(0, caches[name]?() ?? 0))))")
        }
        write(fields.joined(separator: " "))
    }

    private static func megabytes(_ bytes: UInt64) -> UInt64 {
        bytes / (1024 * 1024)
    }
}
