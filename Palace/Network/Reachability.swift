//
//  Reachability.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02/02/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Network
import SystemConfiguration

@objcMembers
class Reachability: NSObject {
  static let shared = Reachability()
  
  private let connectionMonitor = NWPathMonitor()
  private var isConnected = false
  // Status update retries
  private let maxRetries = 30
  private var retriesCounter = 0
  
  func startMonitoring() {
    connectionMonitor.pathUpdateHandler = { [weak self] path in
      // This seems to be the most reliable way to determine the connectin status
      // path.status remains .unsatisfied during off/on testing
      self?.retriesCounter = 0
      self?.updateStatus()
    }
    let queue = DispatchQueue(label: "NetworkMonitor")
    connectionMonitor.start(queue: queue)
  }
  
  func stopMonitoring() {
    connectionMonitor.cancel()
  }
  
  func updateStatus() {
    guard retriesCounter < maxRetries else {
      return
    }
    retriesCounter += 1
    let newStatus = isConnectedToNetwork()
    if isConnected != newStatus {
      isConnected = newStatus
      NotificationCenter.default.post(name: .TPPReachabilityChanged, object: isConnected)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        self?.updateStatus()
      }
    }
  }
  
  func isConnectedToNetwork() -> Bool {
    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
    zeroAddress.sin_family = sa_family_t(AF_INET)
    
    let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {zeroSockAddress in
        SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
      }
    }
    
    var flags = SCNetworkReachabilityFlags()
    if !SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) {
      return false
    }
    let isReachable = (flags.rawValue & UInt32(kSCNetworkFlagsReachable)) != 0
    let needsConnection = (flags.rawValue & UInt32(kSCNetworkFlagsConnectionRequired)) != 0
    return (isReachable && !needsConnection)
  }
}
