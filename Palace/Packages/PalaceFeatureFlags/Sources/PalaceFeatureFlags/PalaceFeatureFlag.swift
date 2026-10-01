//
//  PalaceFeatureFlag.swift
//  PalaceFeatureFlags
//
//  Typed feature flags. Raw values are Firebase Remote Config wire keys:
//  never change them. The Firebase reader and key mapping stay in the app
//  target; this package knows only the names and their defaults.
//

import Foundation

public enum PalaceFeatureFlag: String, Sendable {
    case enhancedErrorLogging = "enhanced_error_logging_enabled"
    case enhancedErrorLoggingDeviceSpecific = "enhanced_error_logging_device_"
    case downloadRetryEnabled = "download_retry_enabled"
    case circuitBreakerEnabled = "circuit_breaker_enabled"
    case carPlayEnabled = "carplay_enabled"
    case opds2Enabled = "opds2_enabled"
    case advancedTypographyEnabled = "advanced_typography_enabled"
    case triageBotEnabled = "triage_bot_enabled"
    case triageBotTicketSubmissionEnabled = "triage_bot_ticket_submission_enabled"
    case triageBotAIFallbackEnabled = "triage_bot_ai_fallback_enabled"
    /// Gates in-app playback navigation: the Continue Reading/Listening
    /// rows, the mini-player above the tab bar, and tap-to-resume through
    /// `AudiobookSessionPresenter`. Default off; without it users get the
    /// toolkit player. Precedence: UserDefaults local override (dev menu) >
    /// Firebase remote (default false). See `isInAppPlaybackNavEnabled`.
    case inAppPlaybackNavEnabled = "in_app_playback_nav_enabled"
    /// Gates ONLY the Continue Reading / Continue Listening hero rows at the
    /// top of the Catalog (the "continuation" cards). Split out from
    /// `inAppPlaybackNavEnabled` so the cards and the in-app player can be
    /// rolled out independently. Default off, Firebase-gated; see
    /// `isContinuationCardsEnabled`.
    case continuationCardsEnabled = "continuation_cards_enabled"
    /// Gates every side-loading surface (PP-2677 / PP-2678 / PP-2679): the
    /// Settings "Side Loading" import screen and
    /// the catalog side-loaded lane. Test-only capability for exercising
    /// the real reader + DRM stack against local files with no OPDS feed.
    /// Default OFF; enabled via `isSideLoadingEnabled` whose precedence is
    /// UserDefaults local override (dev-menu toggle) > Firebase remote
    /// (default false). No DEBUG auto-enable — QA/TestFlight builds are
    /// non-DEBUG, so the feature is turned on explicitly by the dev-menu
    /// toggle rather than by build configuration.
    case sideLoadingEnabled = "side_loading_enabled"
    /// Gates deploy-time library pre-selection from an MDM's Managed App
    /// Configuration (PP-5070 / PP-5217): reading
    /// `com.apple.configuration.managed` at launch, watching it for changes,
    /// and selecting the library a school configured.
    ///
    /// Default off. It only acts when an MDM supplied a configuration, but it
    /// changes the first-run path every new install takes, and that path has
    /// not yet been exercised on a real cold launch.
    ///
    /// Precedence: UserDefaults local override (dev-menu toggle) > Firebase
    /// remote (default false).
    case managedLibraryConfigurationEnabled = "managed_library_configuration_enabled"
    /// Master kill-switch for the app-rating prompt feature (Epic PP-4086).
    /// Default ON; set to false in Remote Config to suppress the prompt
    /// entirely regardless of engagement state.
    case appRatingPromptEnabled = "app_rating_prompt_enabled"
    /// Gates LCP audiobook streaming-from-license (PP-4957). When ON, an LCP
    /// audiobook becomes playable on the `.lcpl` license alone and the player
    /// streams the encrypted audio on demand via the pinned swift-toolkit fork
    /// (3.11.0 + fix-issue-579); when OFF, the app downloads the full `.lcpa`
    /// before playback (today's behavior). **Default OFF — Firebase-gated;**
    /// the default flip to streaming is a product decision. Precedence is
    /// UserDefaults local override (dev-menu toggle / QA) > Firebase remote
    /// (default false) — see `isLCPAudiobookStreamingEnabled`.
    case lcpAudiobookStreamingEnabled = "lcp_audiobook_streaming_enabled"

    /// In-app fallback when Remote Config has no value. Kept in the package:
    /// it is part of the flag CONTRACT (tests pin it), not Firebase wiring.
    /// NOTE: FirebaseManager.setDefaults registers the same values on the
    /// Remote Config side — a deliberate pre-existing duplication; keep the
    /// two tables in sync when adding a flag.
    public var defaultValue: Bool {
        switch self {
        case .downloadRetryEnabled, .circuitBreakerEnabled:
            return true
        case .carPlayEnabled:
            return true
        case .opds2Enabled:
            return true
        case .appRatingPromptEnabled:
            return true
        default:
            // Includes `.inAppPlaybackNavEnabled`: default OFF in-app —
            // Firebase Remote Config turns it on (see isInAppPlaybackNavEnabled).
            return false
        }
    }
}
