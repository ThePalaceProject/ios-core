import os
import Foundation
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

final class Log: NSObject {
  static var dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  private class func levelToString(_ level: OSLogType) -> String {
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
  
  private class func log(_ level: OSLogType, _ tag: String, _ message: String) {
    let tag = trimTag(tag)

    #if !targetEnvironment(simulator) && !DEBUG
    #if canImport(FirebaseCrashlytics)
    // Send errors and warnings to Crashlytics (standard practice)
    // Only gate verbose info/debug logs behind enhanced logging
    let shouldLogToCrashlytics: Bool
    switch level {
    case .error, .fault:
      shouldLogToCrashlytics = true // Always log errors
    case .default:
      shouldLogToCrashlytics = true // Always log warnings
    case .info:
      // Info logs only when enhanced logging enabled (verbose diagnostic data)
      Task {
        let isEnhanced = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()
        if isEnhanced {
          let timestamp = dateFormatter.string(from: Date())
          let formattedMsg = "[\(levelToString(level))] \(timestamp) \(tag): \(message)"
          Crashlytics.crashlytics().log("\(formattedMsg)")
        }
      }
      shouldLogToCrashlytics = false
    default:
      shouldLogToCrashlytics = false // Never log debug
    }
    
    if shouldLogToCrashlytics {
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

    os_log("%{public}@: %{public}@", type: level, tag, message)
  }

  /** For objc compatibility only. */
  @objc class func log(_ message: String) {
    log(.default, "", message)
  }

  class func debug(_ tag: String, _ message: String) {
    log(.debug, tag, message)
  }
  
  class func info(_ tag: String, _ message: String) {
    log(.info, tag, message)
  }
  
  class func warn(_ tag: String, _ message: String) {
    log(.default, tag, message)
  }

  class func error(_ tag: String, _ message: String) {
    log(.error, tag, message)
  }

  /**
   Fault-level messages are intended for capturing system-level or
   multi-process errors only.
   */
  class func fault(_ tag: String, _ message: String) {
    log(.fault, tag, message)
  }

  // MARK: - Performance Optimizations
  
  private static var lastPalaceLogMessages: [String: Date] = [:]
  private static let palaceLogThrottleInterval: TimeInterval = 0.3
  private static let throttleQueue = DispatchQueue(label: "org.thepalaceproject.palace.logging.throttle", attributes: .concurrent)
  
  private class func shouldThrottlePalaceLogging(level: OSLogType, tag: String, message: String) -> Bool {
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

  private class func trimTag(_ tag: String) -> String {
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
