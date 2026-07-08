import Foundation

/// Everything the bot knows about the user's environment at the moment they
/// opened the chat. Snapshotted once per session — no background collection.
///
/// All fields are optional because the redactor or the user's privacy
/// preferences may strip them. Anything that uniquely identifies a patron
/// (account UUID, email) is hashed or omitted before this struct ever leaves
/// the device — see ContextRedactor.
///
/// New fields are additive and Optional so the JSON schema stays
/// backward-compatible — old catalog clients can decode new context blobs and
/// new clients can decode old context blobs.
public struct ContextSnapshot: Codable, Equatable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let platform: String          // "iOS" | "Android"
    public let osVersion: String         // e.g. "26.4.2"
    public let deviceModel: String       // e.g. "iPhone17,2"
    public let libraryName: String?
    public let libraryUUID: String?      // hashed before send
    public let distributor: String?      // "palace_marketplace" | "open_access" | ...
    public let authType: String?         // "basic" | "oauth" | "saml" | "oidc"
    public let networkState: String?     // "wifi" | "cellular" | "offline"
    public let freeStorageBytes: Int64?
    public let recentLogLines: [String]  // redacted, last ~5 min
    public let crashlyticsFingerprints: [String] // hashes only
    public let capturedAt: Date

    // === Expanded diagnostics (additive, all optional) =====================

    /// Active audio output route. Useful when a patron reports audiobook
    /// playback problems — Bluetooth / AirPlay / CarPlay quirks often
    /// explain symptoms that look like app bugs.
    public let audioOutputRoute: String?

    /// Whether the device is in Low Power Mode. Often explains "downloads
    /// stalled" or "audio dropped" reports.
    public let lowPowerModeEnabled: Bool?

    /// Seconds since the app process started. Helps support distinguish
    /// "first launch after install" from "session that has been running
    /// for days" — both have characteristic bug patterns.
    public let appUptimeSeconds: Int64?

    /// Distribution channel — "appstore" / "testflight" / "debug" / "unknown".
    /// Triagers regularly need to know if the user is on a TestFlight build
    /// or production to choose the right backport target.
    public let buildChannel: String?

    /// Available physical memory in MB at snapshot time. Low memory
    /// correlates with audiobook playback drops and reader rendering issues.
    public let availableMemoryMB: Int64?

    public init(
        appVersion: String,
        appBuild: String,
        platform: String = "iOS",
        osVersion: String,
        deviceModel: String,
        libraryName: String? = nil,
        libraryUUID: String? = nil,
        distributor: String? = nil,
        authType: String? = nil,
        networkState: String? = nil,
        freeStorageBytes: Int64? = nil,
        recentLogLines: [String] = [],
        crashlyticsFingerprints: [String] = [],
        capturedAt: Date = Date(),
        audioOutputRoute: String? = nil,
        lowPowerModeEnabled: Bool? = nil,
        appUptimeSeconds: Int64? = nil,
        buildChannel: String? = nil,
        availableMemoryMB: Int64? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.platform = platform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.libraryName = libraryName
        self.libraryUUID = libraryUUID
        self.distributor = distributor
        self.authType = authType
        self.networkState = networkState
        self.freeStorageBytes = freeStorageBytes
        self.recentLogLines = recentLogLines
        self.crashlyticsFingerprints = crashlyticsFingerprints
        self.capturedAt = capturedAt
        self.audioOutputRoute = audioOutputRoute
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.appUptimeSeconds = appUptimeSeconds
        self.buildChannel = buildChannel
        self.availableMemoryMB = availableMemoryMB
    }
}
