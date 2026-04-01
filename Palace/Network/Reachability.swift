//
//  Reachability.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02/02/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import Network
import SystemConfiguration

@objcMembers
class Reachability: NSObject {
    static let shared = Reachability()

    private let connectionMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private let stateLock = NSLock()

    /// Publishes connectivity changes (replaces `.TPPReachabilityChanged` notification)
    private let connectivitySubject = CurrentValueSubject<Bool, Never>(false)

    /// Publisher for connectivity state. Use instead of observing `.TPPReachabilityChanged`.
    var connectivityPublisher: AnyPublisher<Bool, Never> {
        connectivitySubject
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var _isConnected = false
    private(set) var isConnected: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isConnected }
        set { stateLock.lock(); _isConnected = newValue; stateLock.unlock() }
    }

    func startMonitoring() {
        connectionMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus = (path.status == .satisfied)

            guard newStatus != self.isConnected else { return }
            self.isConnected = newStatus
            DispatchQueue.main.async {
                self.connectivitySubject.send(newStatus)
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .TPPReachabilityChanged,
                    object: newStatus
                )
            }
        }
        connectionMonitor.start(queue: monitorQueue)
    }

    func stopMonitoring() {
        connectionMonitor.cancel()
    }

    // MARK: - Connection Type

    /// Returns `true` when the current path uses a Wi-Fi (or Ethernet) interface.
    /// Ethernet is treated as equivalent to Wi-Fi for download-restriction purposes.
    var isOnWiFi: Bool {
        let path = connectionMonitor.currentPath
        return path.status == .satisfied
            && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
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

        Log.debug(#file, "Reachability check: reachable=\(reachable), needsConnection=\(needsConnection), result=\(isConnected)")

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
