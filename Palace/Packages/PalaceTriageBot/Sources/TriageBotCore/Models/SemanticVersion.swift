import Foundation

/// Tiny semantic-version compare for the bot's classifier. Just enough to
/// answer "is the user already on / past the version where this bug was
/// fixed?" Not a full SemVer parser — Palace versions are simple
/// MAJOR.MINOR.PATCH (e.g. "3.2.0"), and we coerce missing components to
/// 0 so "3.2" reads as "3.2.0".
///
/// Why a custom comparator instead of relying on Foundation's
/// `String.compare(_:options:)` with `.numeric`: numeric option still
/// compares left-to-right and trips on "3.10.0" vs "3.2.0" depending on
/// how the components ended up tokenized. Component-wise integer compare
/// is unambiguous.
public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse "3.2.0", "3.2", "3", "v3.2.0" — returns nil on garbage like
    /// "next release" or "TBD" so callers can decide what to do (the
    /// classifier treats unparseable fix versions as "applies to everyone").
    public init?(_ raw: String) {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "v", with: "")
        let components = trimmed.split(separator: ".").map { String($0) }
        guard !components.isEmpty,
              let major = Int(components[0]) else { return nil }
        let minor = components.count > 1 ? Int(components[1]) ?? 0 : 0
        let patch = components.count > 2 ? Int(components[2]) ?? 0 : 0
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Helper: is the user's current app version at or past the version where
/// the given entry was supposedly fixed? Returns false for entries without
/// a fix version, unparseable versions, or missing context.
public enum FixVersionGate {
    public static func userAlreadyHasFix(
        for entry: KBEntry,
        userAppVersion: String?
    ) -> Bool {
        guard let fixVersion = entry.fixedInVersion,
              let fix = SemanticVersion(fixVersion),
              let userRaw = userAppVersion,
              let user = SemanticVersion(userRaw) else {
            return false
        }
        return user >= fix
    }
}
