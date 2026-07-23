import Foundation

// Wave 1c: moved from Palace/Audiobooks/ — prefs-store, not player logic; eventual home is the PalacePreferences package (Wave 1a follow-up).

/// PP-4712 — global, patron-configurable audiobook skip intervals (seconds),
/// independently settable for skip-forward and skip-back and applied to all
/// audiobooks. Backed by `UserDefaults` (inject a suite for tests); both
/// directions default to 30s, so existing patrons see no change until they
/// choose a different value on the Playback settings screen.
///
/// Reads/writes are validated against `options`; an unknown value falls back to
/// the 30s default rather than being persisted, so a corrupt/foreign value can
/// never put the player into an out-of-range skip.
struct AudiobookSkipIntervalSettings {
  /// The interval choices offered on the Settings screen, in seconds.
  static let options: [Int] = [15, 30, 45, 60]
  /// The value both directions default to when unset (no behavior change).
  static let defaultInterval = 30

  static let forwardKey = "PalaceAudiobookSkipForwardInterval"
  static let backKey = "PalaceAudiobookSkipBackInterval"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var forwardInterval: Int {
    get { read(Self.forwardKey) }
    nonmutating set { write(newValue, forKey: Self.forwardKey) }
  }

  var backInterval: Int {
    get { read(Self.backKey) }
    nonmutating set { write(newValue, forKey: Self.backKey) }
  }

  /// The forward interval as a `TimeInterval`, for injection into the toolkit.
  var forwardTimeInterval: TimeInterval { TimeInterval(forwardInterval) }
  /// The back interval as a `TimeInterval`, for injection into the toolkit.
  var backTimeInterval: TimeInterval { TimeInterval(backInterval) }

  private func read(_ key: String) -> Int {
    guard let stored = defaults.object(forKey: key) as? Int,
          Self.options.contains(stored)
    else { return Self.defaultInterval }
    return stored
  }

  private func write(_ value: Int, forKey key: String) {
    let valid = Self.options.contains(value) ? value : Self.defaultInterval
    defaults.set(valid, forKey: key)
  }
}
