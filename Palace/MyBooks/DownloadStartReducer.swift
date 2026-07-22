//
//  DownloadStartReducer.swift
//  Palace
//
//  E2 (WS7) pure decision core extracted from `DownloadStartDispatcher`.
//
//  Per Contract E (swarm_8ce6f5ae) the dispatcher stays as the EFFECT-RUNNER;
//  this reducer owns only the branch SELECTION and the ORDER effects run in.
//  It is pure: inputs are precomputed values (enums / Bools / book-derived
//  facts), the output is an ordered, `Equatable` effect plan. The reducer
//  references NO singletons, `Task`, `Date`, `URLSession`, request construction,
//  logging, or `#if FEATURE_*` runtime checks — Overdrive / streaming / Wi-Fi
//  applicability all arrive as precomputed Bools from the dispatcher.
//
//  Behavior-preservation proof: `DownloadStartReducerContractTests` interprets
//  each emitted plan into a `CallLog` using the SAME collaborator labels as
//  `DownloadStartDispatcherContractTests`, so the reducer's emitted sequence is
//  shape-equal to the E1 dispatcher service snapshot. `[Effect]: Equatable`
//  makes the 100%-mutation bar reachable — a dropped case, flipped guard, or
//  swapped order produces an unequal array.
//

import Foundation

enum DownloadStartReducer {

    // MARK: - processUnregisteredState

    struct UnregisteredInput: Equatable {
        /// `book.defaultAcquisitionIfBorrow != nil`
        let hasBorrowLink: Bool
        /// `book.defaultAcquisitionIfOpenAccess != nil`
        let hasOpenAccess: Bool
        /// `loginRequired ?? false`
        let loginRequired: Bool
    }

    enum UnregisteredDecision: Equatable {
        /// Seed the registry to `.downloadNeeded` and return `.downloadNeeded`.
        case seedDownloadNeeded
        /// Leave the book `.unregistered`; emit nothing.
        case stayUnregistered
    }

    /// Open-access (or no-login) titles with no borrow link are downloadable
    /// immediately — seed `.downloadNeeded`. Everything else stays unregistered
    /// (the borrow path owns it). Mirrors `DownloadStartDispatcher
    /// .processUnregisteredState` L150.
    static func reduceUnregistered(_ input: UnregisteredInput) -> UnregisteredDecision {
        if !input.hasBorrowLink && (input.hasOpenAccess || !input.loginRequired) {
            return .seedDownloadNeeded
        }
        return .stayUnregistered
    }

    // MARK: - processDownloadWithCredentials routing

    struct CredentialsInput: Equatable {
        /// `book.defaultBookContentType == .streamingHTML`
        let isStreamingHTML: Bool
        let state: TPPBookState
        /// FEATURE_OVERDRIVE: overdrive-distributed audiobook. Always `false`
        /// when the Overdrive feature is compiled out.
        let isOverdriveAudiobook: Bool
        /// `MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for:state:)`,
        /// precomputed. Only consulted when `isOverdriveAudiobook`.
        let shouldDeferOverdrive: Bool
    }

    enum CredentialsRoute: Equatable {
        /// Streaming-HTML title — no downloadable asset (PP-4161 Path X).
        case noop
        /// `.unregistered` / `.holding` → borrow before download.
        case startBorrow
        /// Overdrive audiobook still on a borrow link → defer fulfillment.
        case deferOverdrive
        /// Overdrive audiobook ready → issue the fulfillment request.
        case processOverdrive
        /// Not a special route — hand off to `processRegularDownload`.
        case fallThroughToRegular
    }

    /// Selection order matches `DownloadStartDispatcher
    /// .processDownloadWithCredentials` L202-219: streaming skip → borrow-state
    /// route → Overdrive-audiobook divert → regular.
    static func routeWithCredentials(_ input: CredentialsInput) -> CredentialsRoute {
        if input.isStreamingHTML {
            return .noop
        }
        if input.state == .unregistered || input.state == .holding {
            return .startBorrow
        }
        if input.isOverdriveAudiobook {
            return input.shouldDeferOverdrive ? .deferOverdrive : .processOverdrive
        }
        return .fallThroughToRegular
    }

    // MARK: - processRegularDownload

    struct RegularInput: Equatable {
        let state: TPPBookState
        /// `currentBook.isExpired` (re-resolved through the registry).
        let isExpired: Bool
        /// `currentBook.defaultAcquisitionIfBorrow != nil`
        let hasBorrowLink: Bool
        /// `settings.downloadOnlyOnWiFi && !isOnWiFi()`
        let wifiOnlyEnforced: Bool
        /// A caller-supplied `initedRequest` is present.
        let hasInitedRequest: Bool
        /// `currentBook.defaultAcquisition?.hrefURL != nil` — a request can be
        /// built from the acquisition link.
        let hasAcquisitionURL: Bool
        /// `state == .SAMLStarted && userAccount.cookies != nil` — the SAML
        /// cookie-injection download path applies.
        let samlWithCookies: Bool
    }

    enum Effect: Equatable {
        /// `registry.setState(.unregistered, …)` before a (re/auto)borrow.
        case setStateUnregistered
        /// `delegate.startBorrow(…)`. `withCompletion` distinguishes the
        /// auto-borrow-on-`.downloadNeeded` path (completion closure) from the
        /// re-borrow-on-expired path (nil completion).
        case startBorrow(attemptDownload: Bool, withCompletion: Bool)
        /// `delegate.failWithWifiRequired(…)`.
        case failWifi
        /// `delegate.logInvalidURLRequest(…)`. `hasURL` mirrors whether a URL
        /// was resolvable (false = no acquisition + no inited request).
        case logInvalidRequest(hasURL: Bool)
        /// `memoryPressureMonitor.reclaimDiskSpaceIfNeeded(…)` — unconditional
        /// pre-download step. Not a spied collaborator, so it records nothing in
        /// the contract snapshot; modeled so the runner is a pure interpreter.
        case reclaimDiskSpace
        /// `delegate.handleSAMLStartedState(…)`.
        case handleSAML
        /// `delegate.clearAndSetCookies()`.
        case clearAndSetCookies
        /// `delegate.addDownloadTask(…)`.
        case addDownloadTask
    }

    /// Selection order matches `DownloadStartDispatcher.processRegularDownload`
    /// L253-319: re-borrow-on-expired → auto-borrow-on-`.downloadNeeded` →
    /// Wi-Fi guard → request resolution → reclaim → SAML vs normal download.
    static func reduceRegular(_ input: RegularInput) -> [Effect] {
        if input.isExpired && input.hasBorrowLink {
            return [.setStateUnregistered, .startBorrow(attemptDownload: true, withCompletion: false)]
        }
        if input.state == .downloadNeeded && input.hasBorrowLink {
            return [.setStateUnregistered, .startBorrow(attemptDownload: true, withCompletion: true)]
        }
        if input.wifiOnlyEnforced {
            return [.failWifi]
        }
        // Request resolution: a caller-supplied request, else a request built
        // from the acquisition link, else nowhere to download from.
        guard input.hasInitedRequest || input.hasAcquisitionURL else {
            return [.logInvalidRequest(hasURL: false)]
        }
        if input.samlWithCookies {
            return [.reclaimDiskSpace, .handleSAML]
        }
        return [.reclaimDiskSpace, .clearAndSetCookies, .addDownloadTask]
    }
}
