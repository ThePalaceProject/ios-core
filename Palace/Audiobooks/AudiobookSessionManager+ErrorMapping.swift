//
//  AudiobookSessionManager+ErrorMapping.swift
//  Palace
//
//  Pure error mapping for the audiobook session, moved out of
//  AudiobookSessionManager.swift unchanged to keep that file under its
//  line-count ceiling (PP-5241).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

extension AudiobookSessionManager {

    static func mapLoadError(_ error: AudiobookLoadError) -> AudiobookSessionError {
        switch error {
        case .cancelled:
            return .unknown("Load cancelled")
        case .tokenRefreshFailed, .missingCredentialsForTokenRefresh:
            return .notAuthenticated
        case .manifestFetchFailed, .manifestParseFailed, .manifestSerializationFailed, .manifestDecodingFailed:
            return .manifestLoadFailed
        case .lcpNotAvailable, .lcpInstantiationFailed, .lcpDecryptionFailed,
             .licenseDownloadFailed, .licenseSaveFailed, .missingFulfillURL, .missingContentDirectory:
            return .manifestLoadFailed
        case .vendorKeyUpdateFailed(let nsError):
            return .unknown(nsError.localizedDescription)
        case .factoryFailed:
            return .playerCreationFailed
        }
    }

    /// Pure network-rules validator. Extracted for deterministic testing against
    /// every combination of connectivity + user WiFi-only preference. The rules:
    ///   - Fully-downloaded books never need the network → no error
    ///   - Streaming books with no network at all → .networkUnavailable
    ///   - Streaming books on cellular when the user has WiFi-only enabled
    ///     → .wifiRequired (refusing to burn their cell data against their
    ///     stated preference, and surfacing the same "connect to Wi-Fi or
    ///     change settings" alert the download path uses)
    static func networkValidationError(
        bookState: TPPBookState,
        isConnectedToNetwork: Bool,
        isOnWiFi: Bool,
        downloadOnlyOnWiFi: Bool
    ) -> AudiobookSessionError? {
        let isFullyDownloaded = bookState == .downloadSuccessful || bookState == .used
        guard !isFullyDownloaded else { return nil }

        if !isConnectedToNetwork {
            return .networkUnavailable
        }
        if downloadOnlyOnWiFi && !isOnWiFi {
            return .wifiRequired
        }
        return nil
    }
}
