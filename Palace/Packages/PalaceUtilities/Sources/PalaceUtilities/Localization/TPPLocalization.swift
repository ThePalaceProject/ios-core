import Foundation

/// Global function to label strings that do not need to be localized
/// so as to not set off Analyzer localization warnings.
public func TPPLocalizationNotNeeded(_ s: String) -> String {
  return s
}
