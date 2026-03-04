import os
import Foundation
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

final class Log: NSObject {
    /// Subsystem identifier used for unified logging (OSLog).
    /// This makes Palace log entries identifiable when collecting device logs via OSLogStore.
    static let subsystem = "org.thepalaceproject.palace"

    private static let palaceLog = OSLog(subsystem: subsystem, category: "Palace")

    static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func levelToString(_ level: OSLogType) -> String {
        switch level {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        default:
            return "WARNING"
        }
    }

    private static func log(_ level: OSLogType, _ tag: String, _ message: String) {
        let tag = trimTag(tag)

        #if !targetEnvironment(simulator) && !DEBUG
        #if canImport(FirebaseCrashlytics)
        if level != .debug {
            let timestamp = dateFormatter.string(from: Date())
            let formattedMsg = "[\(levelToString(level))] \(timestamp) \(tag): \(message)"
            Crashlytics.crashlytics().log("\(formattedMsg)")
        }
        #endif
        #endif

        #if DEBUG
        if shouldThrottlePalaceLogging(level: level, tag: tag, message: message) {
            return
        }
        #endif

        os_log("%{public}@: %{public}@", log: palaceLog, type: level, tag, message)

        // Persist error and fault level messages to disk for cross-launch diagnostics.
        // OSLogStore entries may be pruned by the system, so PersistentLogger ensures
        // critical messages survive between sessions.
        if level == .error || level == .fault {
            Task {
                await PersistentLogger.shared.log(level: level, tag: tag, message: message)
            }
        }
    }

    /** For objc compatibility only. */
    @objc static func log(_ message: String) {
        log(.default, "", message)
    }

    static func debug(_ tag: String, _ message: String) {
        log(.debug, tag, message)
    }

    static func info(_ tag: String, _ message: String) {
        log(.info, tag, message)
    }

    static func warn(_ tag: String, _ message: String) {
        log(.default, tag, message)
    }

    static func error(_ tag: String, _ message: String) {
        log(.error, tag, message)
    }

    /**
     Fault-level messages are intended for capturing system-level or
     multi-process errors only.
     */
    static func fault(_ tag: String, _ message: String) {
        log(.fault, tag, message)
    }

    // MARK: - Performance Optimizations

    private static var lastPalaceLogMessages: [String: Date] = [:]
    private static let palaceLogThrottleInterval: TimeInterval = 0.3
    private static let throttleQueue = DispatchQueue(label: "org.thepalaceproject.palace.logging.throttle", attributes: .concurrent)

    private static func shouldThrottlePalaceLogging(level: OSLogType, tag: String, message: String) -> Bool {
        guard level != .error && level != .fault else { return false }

        let now = Date()
        let messageKey = "\(tag):\(message.prefix(30))"

        return throttleQueue.sync {
            if let lastTime = lastPalaceLogMessages[messageKey] {
                if now.timeIntervalSince(lastTime) < palaceLogThrottleInterval {
                    return true // Throttle this message
                }
            }

            // Use barrier to ensure exclusive write access
            throttleQueue.async(flags: .barrier) {
                lastPalaceLogMessages[messageKey] = now

                // Clean up old entries periodically to prevent memory growth
                if lastPalaceLogMessages.count > 50 {
                    let cutoffTime = now.addingTimeInterval(-palaceLogThrottleInterval * 20)
                    lastPalaceLogMessages = lastPalaceLogMessages.filter { $0.value > cutoffTime }
                }
            }

            return false
        }
    }

    private static func trimTag(_ tag: String) -> String {
        guard tag.starts(with: "/") else {
            return tag
        }

        var components = tag.components(separatedBy: "/")
        let sourcesRootIndex = (components.firstIndex(of: "Palace") ?? 0) + 1

        if sourcesRootIndex < components.count {
            components.removeFirst(sourcesRootIndex)
        }

        guard !components.isEmpty else {
            return tag
        }

        return components.joined(separator: "/")
    }
}
