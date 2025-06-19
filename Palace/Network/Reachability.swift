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
    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
    zeroAddress.sin_family = sa_family_t(AF_INET)

    guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        SCNetworkReachabilityCreateWithAddress(nil, $0)
      }
    }) else {
      return false
    }

    var flags = SCNetworkReachabilityFlags()
    if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
      return false
    }

    let reachable = flags.contains(.reachable)
    let needsConnection = flags.contains(.connectionRequired)
    return (reachable && !needsConnection)
  }
}
