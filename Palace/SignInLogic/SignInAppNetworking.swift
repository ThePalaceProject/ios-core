//
//  SignInAppNetworking.swift
//  Palace
//
//  The app-wide executor as sign-in uses it: the bearer-token exchange, and
//  the cache clear on sign-out and account reset (PP-5544).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

protocol SignInAppNetworking: TokenRefreshing, Sendable {
    func clearCache()
}

extension TPPNetworkExecutor: SignInAppNetworking {}
