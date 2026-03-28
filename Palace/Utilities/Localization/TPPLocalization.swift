// Swift replacement for TPPLocalization.m
//
// Marks strings that do not need localization, suppressing analyzer warnings.

import Foundation

/// Labels a string that does not need to be localized,
/// so as to not set off Analyzer localization warnings.
func TPPLocalizationNotNeededSwift(_ s: String) -> String {
  return s
}
