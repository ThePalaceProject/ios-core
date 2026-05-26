//
//  TPPSettings+UniversalLinksProviding.swift
//  The Palace Project
//
//  PalaceAuth's `TPPSAMLHelper` reads the universal-links callback URL via
//  the `UniversalLinksProviding` protocol (post swarm_ea663ab6). `TPPSettings`
//  already exposes `universalLinksURL` through the legacy
//  `NYPLUniversalLinksSettings` protocol; this single-line conformance lets
//  the helper consume it without any additional bridging.
//

import Foundation
import PalaceAuth

extension TPPSettings: UniversalLinksProviding {}
