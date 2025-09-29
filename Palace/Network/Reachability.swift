//
//  Reachability.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02/02/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Network
import SystemConfiguration

@objcMembers
class Reachability: NSObject {
  static let shared = Reachability()

  private let connectionMonitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

  private var pollingTimer: Timer?
  private var retriesCounter = 0
  private let maxRetries = 30
  private(set) var isConnected = false

  func startMonitoring() {
    retriesCounter = 0
    connectionMonitor.pathUpdateHandler = { [weak self] _ in
      self?.beginPolling()
    }
    connectionMonitor.start(queue: monitorQueue)
  }

  func stopMonitoring() {
    connectionMonitor.cancel()
    pollingTimer?.invalidate()
    pollingTimer = nil
  }

  private func beginPolling() {
    pollingTimer?.invalidate()
    retriesCounter = 0

    pollingTimer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(pollNetworkStatus),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func pollNetworkStatus() {
    defer { retriesCounter += 1 }

    guard retriesCounter < maxRetries else {
      pollingTimer?.invalidate()
      pollingTimer = nil
      return
    }

    let newStatus = isConnectedToNetwork()
    if newStatus != isConnected {
      isConnected = newStatus
      NotificationCenter.default.post(
        name: .TPPReachabilityChanged,
        object: newStatus
      )
      pollingTimer?.invalidate()
      pollingTimer = nil
    }
  }

  // MARK: - Reachability Check

  func isConnectedToNetwork() -> Bool {
    if connectionMonitor.currentPath.status == .satisfied {
      return true
    }

    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
    zeroAddress.sin_family = sa_family_t(AF_INET)

    guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        SCNetworkReachabilityCreateWithAddress(nil, $0)
      }
    }) else {
      Log.error(#file, "Failed to create reachability reference")
      return false
    }

    var flags = SCNetworkReachabilityFlags()
    if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
      Log.error(#file, "Failed to get reachability flags")
      return false
    }

    let reachable = flags.contains(.reachable)
    let needsConnection = flags.contains(.connectionRequired)
    let isConnected = (reachable && !needsConnection)

    Log.debug(
      #file,
      "Reachability check: reachable=\(reachable), needsConnection=\(needsConnection), result=\(isConnected)"
    )

    return isConnected
  }

  func getDetailedConnectivityStatus() -> (isConnected: Bool, connectionType: String, details: String) {
    let currentPath = connectionMonitor.currentPath

    switch currentPath.status {
    case .satisfied:
      var connectionType = "Unknown"
      var details = "Connected"

      if currentPath.usesInterfaceType(.wifi) {
        connectionType = "WiFi"
        details += " via WiFi"
      } else if currentPath.usesInterfaceType(.cellular) {
        connectionType = "Cellular"
        details += " via Cellular"
      } else if currentPath.usesInterfaceType(.wiredEthernet) {
        connectionType = "Ethernet"
        details += " via Ethernet"
      }

      if currentPath.isExpensive {
        details += " (Expensive)"
      }

      if currentPath.isConstrained {
        details += " (Constrained)"
      }

      return (true, connectionType, details)

    case .unsatisfied:
      return (false, "None", "No network connection")

    case .requiresConnection:
      return (false, "Pending", "Connection required but not established")

    @unknown default:
      return (false, "Unknown", "Unknown network status")
    }
  }
}
