//
//  MyBooksDownloadCenter+AuthRetry.swift
//  Palace
//
//  How MBDC composes its `DownloadAuthRetryHandler`. Extracted from the init so
//  the handler's two policy decisions — which hosts count as ours, and where a
//  returned book's borrow link is re-read from — are stated somewhere smaller
//  than the download centre.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAuth
import PalaceBookRegistry

extension MyBooksDownloadCenter {

    /// Builds the handler MBDC routes download auth failures through.
    ///
    /// Static because it runs during `init`, before `self` is available.
    static func makeAuthRetryHandler(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        reauthenticator: Reauthenticator,
        alertPresenter: DownloadAlertPresenter,
        userAccountProvider: @escaping () -> TPPUserAccount,
        authCoordinator: AuthCoordinator?,
        accountScope: any DownloadAccountScopeProviding,
        opdsFeedService: OPDSFeedService
    ) -> DownloadAuthRetryHandler {
        DownloadAuthRetryHandler(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            reauthenticator: reauthenticator,
            alertPresenter: alertPresenter,
            userAccountProvider: userAccountProvider,
            authCoordinator: authCoordinator,
            // Foreign-host guard (PR #1018 cross-host logout).
            currentAccountHostsProvider: {
                accountScope.currentAccountAuthSurfaceHosts
            },
            // PP-5397: a returned book's stored acquisitions are fulfillment
            // links scoped to the loan that ended, so the no-active-loan retry
            // asked the link that had just answered 400. This lets it re-read
            // the catalog entry, whose links are not loan-scoped, first.
            catalogEntryFetcher: CatalogEntryReborrowFetcher.make(feedFetcher: opdsFeedService)
        )
    }
}
