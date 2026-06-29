import Foundation

/// Receives non-debug log lines from `Log` for forwarding to a crash-reporting
/// service. The package itself has no dependency on any specific service —
/// the host app implements this protocol and registers an instance via
/// `Log.crashlyticsBridge` at startup.
public protocol CrashlyticsLogBridge: AnyObject, Sendable {
    func log(_ message: String)
}
