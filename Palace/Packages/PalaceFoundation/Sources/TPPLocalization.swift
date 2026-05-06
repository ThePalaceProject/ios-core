import Foundation

/// Marks a string as not needing localization, suppressing analyzer warnings.
public func TPPLocalizationNotNeeded(_ s: String) -> String {
  return s
}
