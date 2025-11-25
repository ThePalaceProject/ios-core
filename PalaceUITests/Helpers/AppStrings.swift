import Foundation

/// Shared string constants between app and tests
///
/// **Purpose:**
/// - Single source of truth for UI text
/// - Tests use same localized strings as app
/// - Scalable and maintainable
///
/// **Source:** These match Strings.swift in the Palace app
enum AppStrings {
  
  /// Tab bar labels (from Strings.Settings and other string enums)
  enum TabBar {
    /// "Catalog" - from Strings.Settings.catalog
    static let catalog = NSLocalizedString("Catalog", comment: "For the catalog tab")
    
    /// "My Books" - from Strings.MyBooksView.navTitle
    static let myBooks = NSLocalizedString("My Books", comment: "")
    
    /// "Reservations" - from Strings.HoldsView.reservations
    static let reservations = NSLocalizedString("Reservations", comment: "Nav title")
    
    /// "Settings" - from Strings.Settings.settings
    static let settings = NSLocalizedString("Settings", comment: "")
  }
  
  /// Common button labels
  enum Buttons {
    static let cancel = NSLocalizedString("Cancel", comment: "")
    static let ok = NSLocalizedString("OK", comment: "")
    static let done = NSLocalizedString("Done", comment: "")
  }
  
  /// Book action buttons (from Strings.BookButton)
  enum BookActions {
    static let get = NSLocalizedString("Get", comment: "")
    static let read = NSLocalizedString("Read", comment: "")
    static let listen = NSLocalizedString("Listen", comment: "")
    static let delete = NSLocalizedString("Delete", comment: "")
    static let reserve = NSLocalizedString("Reserve", comment: "")
  }
}

