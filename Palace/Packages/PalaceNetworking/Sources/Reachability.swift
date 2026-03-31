import Foundation
import Network

/// Monitors network reachability using NWPathMonitor.
@available(iOS 12.0, macOS 10.14, *)
public final class Reachability: @unchecked Sendable {

  /// Shared instance for app-wide reachability monitoring.
  public static let shared = Reachability()

  private let monitor: NWPathMonitor
  private let queue = DispatchQueue(label: "com.palace.reachability")
  private var _isConnected: Bool = true

  /// Whether the device currently has network connectivity.
  public var isConnected: Bool {
    queue.sync { _isConnected }
  }

  /// The current network path status.
  public var currentStatus: NWPath.Status {
    monitor.currentPath.status
  }

  /// Callback invoked when connectivity changes.
  public var onStatusChange: ((Bool) -> Void)?

  public init() {
    self.monitor = NWPathMonitor()
  }

  /// Starts monitoring network status.
  public func startMonitoring() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let connected = path.status == .satisfied
      self.queue.sync { self._isConnected = connected }
      self.onStatusChange?(connected)
    }
    monitor.start(queue: queue)
  }

  /// Stops monitoring network status.
  public func stopMonitoring() {
    monitor.cancel()
  }

  deinit {
    monitor.cancel()
  }
}
