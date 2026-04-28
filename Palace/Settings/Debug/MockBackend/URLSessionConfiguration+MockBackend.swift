//
//  URLSessionConfiguration+MockBackend.swift
//  Palace
//
//  Swizzles URLSessionConfiguration.protocolClasses to inject
//  MockBackendURLProtocol into ALL URLSession instances, including
//  those already created with custom configurations.
//
//  This is the standard approach used by HTTP mocking frameworks
//  (OHHTTPStubs, Mocker, etc.) because URLProtocol.registerClass()
//  only affects URLSession.shared and .default configs, not custom ones.
//

#if DEBUG

import Foundation
import PalaceLogging

extension URLSessionConfiguration {

    private static var isSwizzled = false

    /// Swizzle the `protocolClasses` getter to prepend MockBackendURLProtocol.
    static func mockBackend_swizzleProtocolClasses() {
        guard !isSwizzled else { return }

        let originalSelector = #selector(getter: protocolClasses)
        let swizzledSelector = #selector(getter: mockBackend_protocolClasses)

        guard let originalMethod = class_getInstanceMethod(self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(self, swizzledSelector) else {
            Log.error(#file, "MockBackend: failed to swizzle URLSessionConfiguration.protocolClasses")
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        isSwizzled = true
        Log.info(#file, "MockBackend: swizzled URLSessionConfiguration.protocolClasses")
    }

    /// Undo the swizzle.
    static func mockBackend_unswizzleProtocolClasses() {
        guard isSwizzled else { return }

        let originalSelector = #selector(getter: protocolClasses)
        let swizzledSelector = #selector(getter: mockBackend_protocolClasses)

        guard let originalMethod = class_getInstanceMethod(self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(self, swizzledSelector) else {
            return
        }

        // Swapping again restores the original
        method_exchangeImplementations(originalMethod, swizzledMethod)
        isSwizzled = false
        Log.info(#file, "MockBackend: unswizzled URLSessionConfiguration.protocolClasses")
    }

    /// Swizzled getter that prepends MockBackendURLProtocol.
    @objc private var mockBackend_protocolClasses: [AnyClass]? {
        // This calls the ORIGINAL implementation (because we swapped them)
        var classes = self.mockBackend_protocolClasses ?? []

        // Only inject if the mock backend is active
        if MockBackendURLProtocol.activeScenario != nil {
            if !classes.contains(where: { $0 == MockBackendURLProtocol.self }) {
                classes.insert(MockBackendURLProtocol.self, at: 0)
            }
        }

        return classes
    }
}

#endif
