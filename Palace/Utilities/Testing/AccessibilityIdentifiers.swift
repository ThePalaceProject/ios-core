import Foundation

/// Centralized accessibility identifier system for UI testing.
/// 
/// **AI-DEV GUIDE:**
/// - Add new identifiers here when creating new UI elements
/// - Use namespaced enums to organize by screen/feature
/// - Format: `screenName.elementType.specificName`
/// - Always use these constants instead of string literals
/// 
/// **USAGE IN VIEWS:**
/// ```swift
/// Button("Get") { }
///   .accessibilityIdentifier(AccessibilityID.BookDetail.getButton)
/// ```
/// 
/// **USAGE IN TESTS:**
/// ```swift
/// let getButton = app.buttons[AccessibilityID.BookDetail.getButton]
/// XCTAssertTrue(getButton.exists)
/// ```
public enum AccessibilityID {
  
  // MARK: - Tab Bar
  
  /// Main app tab bar identifiers
  public enum TabBar {
    public static let catalogTab = "tabBar.catalog"
    public static let myBooksTab = "tabBar.myBooks"
    public static let holdsTab = "tabBar.holds"
    public static let settingsTab = "tabBar.settings"
  }
  
  // MARK: - Catalog Screen
  
  /// Catalog/Browse screen identifiers
  public enum Catalog {
    // Navigation
    public static let navigationBar = "catalog.navigationBar"
    public static let searchButton = "catalog.searchButton"
    public static let accountButton = "catalog.accountButton"
    public static let libraryLogo = "catalog.libraryLogo"
    
    // Content
    public static let scrollView = "catalog.scrollView"
    public static let loadingIndicator = "catalog.loadingIndicator"
    public static let errorView = "catalog.errorView"
    public static let retryButton = "catalog.retryButton"
    
    // Lanes/Sections
    public static func lane(_ index: Int) -> String { "catalog.lane.\(index)" }
    public static func laneTitle(_ index: Int) -> String { "catalog.lane.\(index).title" }
    public static func laneMoreButton(_ index: Int) -> String { "catalog.lane.\(index).moreButton" }
    
    // Book cells in catalog
    public static func bookCell(_ bookID: String) -> String { "catalog.bookCell.\(bookID)" }
    public static func bookCover(_ bookID: String) -> String { "catalog.bookCover.\(bookID)" }
  }
  
  // MARK: - Search Screen
  
  /// Search screen identifiers
  public enum Search {
    public static let searchField = "search.searchField"
    public static let clearButton = "search.clearButton"
    public static let cancelButton = "search.cancelButton"
    public static let resultsScrollView = "search.resultsScrollView"
    public static let noResultsView = "search.noResultsView"
    public static let loadingIndicator = "search.loadingIndicator"
    
    public static func resultCell(_ bookID: String) -> String { "search.result.\(bookID)" }
  }
  
  // MARK: - Book Detail Screen
  
  /// Book detail view identifiers
  public enum BookDetail {
    // Navigation
    public static let navigationBar = "bookDetail.navigationBar"
    public static let backButton = "bookDetail.backButton"
    public static let shareButton = "bookDetail.shareButton"
    
    // Book info
    public static let coverImage = "bookDetail.coverImage"
    public static let title = "bookDetail.title"
    public static let author = "bookDetail.author"
    public static let description = "bookDetail.description"
    public static let moreButton = "bookDetail.moreButton"
    
    // Action buttons
    public static let getButton = "bookDetail.getButton"
    public static let downloadButton = "bookDetail.downloadButton"
    public static let readButton = "bookDetail.readButton"
    public static let listenButton = "bookDetail.listenButton"
    public static let deleteButton = "bookDetail.deleteButton"
    public static let returnButton = "bookDetail.returnButton"
    public static let reserveButton = "bookDetail.reserveButton"
    public static let cancelButton = "bookDetail.cancelButton"
    public static let retryButton = "bookDetail.retryButton"
    public static let manageHoldButton = "bookDetail.manageHoldButton"
    public static let sampleButton = "bookDetail.sampleButton"
    public static let audiobookSampleButton = "bookDetail.audiobookSampleButton"
    
    // Progress
    public static let downloadProgress = "bookDetail.downloadProgress"
    
    // Half sheet (download/return confirmation)
    public static let halfSheet = "bookDetail.halfSheet"
    public static let halfSheetTitle = "bookDetail.halfSheet.title"
    public static let halfSheetMessage = "bookDetail.halfSheet.message"
    public static let halfSheetCloseButton = "bookDetail.halfSheet.closeButton"
    
    // Metadata sections
    public static let informationSection = "bookDetail.informationSection"
    public static let publisherLabel = "bookDetail.publisherLabel"
    public static let categoriesLabel = "bookDetail.categoriesLabel"
    public static let distributorLabel = "bookDetail.distributorLabel"
    public static let relatedBooksSection = "bookDetail.relatedBooksSection"
  }
  
  // MARK: - My Books Screen
  
  /// My Books/Library screen identifiers
  public enum MyBooks {
    public static let navigationBar = "myBooks.navigationBar"
    public static let searchButton = "myBooks.searchButton"
    public static let sortButton = "myBooks.sortButton"
    public static let gridView = "myBooks.gridView"
    public static let emptyStateView = "myBooks.emptyStateView"
    public static let loadingIndicator = "myBooks.loadingIndicator"
    public static let refreshControl = "myBooks.refreshControl"
    
    // Book cells
    public static func bookCell(_ bookID: String) -> String { "myBooks.bookCell.\(bookID)" }
    public static func bookCover(_ bookID: String) -> String { "myBooks.bookCover.\(bookID)" }
    public static func bookTitle(_ bookID: String) -> String { "myBooks.bookTitle.\(bookID)" }
    
    // Sort menu
    public static let sortMenu = "myBooks.sortMenu"
    public static let sortByAuthor = "myBooks.sort.author"
    public static let sortByTitle = "myBooks.sort.title"
  }
  
  // MARK: - Holds/Reservations Screen
  
  /// Holds/Reservations screen identifiers
  public enum Holds {
    public static let navigationBar = "holds.navigationBar"
    public static let sortButton = "holds.sortButton"
    public static let scrollView = "holds.scrollView"
    public static let emptyStateView = "holds.emptyStateView"
    public static let loadingIndicator = "holds.loadingIndicator"
    
    // Hold cells
    public static func holdCell(_ bookID: String) -> String { "holds.holdCell.\(bookID)" }
    public static func cancelHoldButton(_ bookID: String) -> String { "holds.cancelHold.\(bookID)" }
  }
  
  // MARK: - Settings Screen
  
  /// Settings screen identifiers
  public enum Settings {
    public static let navigationBar = "settings.navigationBar"
    public static let scrollView = "settings.scrollView"
    
    // Account section
    public static let accountSection = "settings.accountSection"
    public static let libraryName = "settings.libraryName"
    public static let accountName = "settings.accountName"
    public static let signOutButton = "settings.signOutButton"
    public static let signInButton = "settings.signInButton"
    
    // Library management
    public static let manageLibrariesButton = "settings.manageLibrariesButton"
    public static let addLibraryButton = "settings.addLibraryButton"
    
    // App info
    public static let aboutPalaceButton = "settings.aboutPalaceButton"
    public static let privacyPolicyButton = "settings.privacyPolicyButton"
    public static let userAgreementButton = "settings.userAgreementButton"
    public static let softwareLicensesButton = "settings.softwareLicensesButton"
    
    // Advanced
    public static let advancedButton = "settings.advancedButton"
    public static let deleteServerDataButton = "settings.deleteServerDataButton"
  }
  
  // MARK: - Library Management
  
  /// Add/Manage libraries screen identifiers
  public enum LibraryManagement {
    public static let navigationBar = "libraryManagement.navigationBar"
    public static let searchField = "libraryManagement.searchField"
    public static let libraryList = "libraryManagement.libraryList"
    
    public static func libraryCell(_ libraryID: String) -> String { "libraryManagement.library.\(libraryID)" }
    public static func addButton(_ libraryID: String) -> String { "libraryManagement.add.\(libraryID)" }
    public static func removeButton(_ libraryID: String) -> String { "libraryManagement.remove.\(libraryID)" }
  }
  
  // MARK: - Reader Screens
  
  /// EPUB Reader identifiers
  public enum EPUBReader {
    public static let readerView = "epubReader.view"
    public static let navigationBar = "epubReader.navigationBar"
    public static let closeButton = "epubReader.closeButton"
    public static let tocButton = "epubReader.tocButton"
    public static let bookmarkButton = "epubReader.bookmarkButton"
    public static let settingsButton = "epubReader.settingsButton"
    
    // Table of contents
    public static let tocView = "epubReader.toc"
    public static func tocChapter(_ index: Int) -> String { "epubReader.toc.chapter.\(index)" }
    
    // Settings
    public static let fontSizeSlider = "epubReader.fontSizeSlider"
    public static let brightnessSlider = "epubReader.brightnessSlider"
  }
  
  /// PDF Reader identifiers
  public enum PDFReader {
    public static let readerView = "pdfReader.view"
    public static let navigationBar = "pdfReader.navigationBar"
    public static let closeButton = "pdfReader.closeButton"
    public static let thumbnailButton = "pdfReader.thumbnailButton"
    public static let searchButton = "pdfReader.searchButton"
    public static let bookmarkButton = "pdfReader.bookmarkButton"
    
    // Page navigation
    public static let pageLabel = "pdfReader.pageLabel"
    public static let pageSlider = "pdfReader.pageSlider"
    
    // Search
    public static let searchField = "pdfReader.searchField"
    public static let searchResults = "pdfReader.searchResults"
  }
  
  /// Audiobook Player identifiers
  public enum AudiobookPlayer {
    public static let playerView = "audiobookPlayer.view"
    public static let closeButton = "audiobookPlayer.closeButton"
    
    // Playback controls
    public static let playPauseButton = "audiobookPlayer.playPauseButton"
    public static let skipBackButton = "audiobookPlayer.skipBackButton"
    public static let skipForwardButton = "audiobookPlayer.skipForwardButton"
    public static let rewindButton = "audiobookPlayer.rewindButton"
    public static let fastForwardButton = "audiobookPlayer.fastForwardButton"
    
    // Progress
    public static let progressSlider = "audiobookPlayer.progressSlider"
    public static let currentTimeLabel = "audiobookPlayer.currentTimeLabel"
    public static let remainingTimeLabel = "audiobookPlayer.remainingTimeLabel"
    
    // Settings
    public static let playbackSpeedButton = "audiobookPlayer.playbackSpeedButton"
    public static let sleepTimerButton = "audiobookPlayer.sleepTimerButton"
    public static let tocButton = "audiobookPlayer.tocButton"
    
    // Table of contents
    public static let tocView = "audiobookPlayer.toc"
    public static func tocChapter(_ index: Int) -> String { "audiobookPlayer.toc.chapter.\(index)" }
    
    // Playback speed menu
    public static func playbackSpeed(_ speed: String) -> String { "audiobookPlayer.speed.\(speed)" }
    
    // Sleep timer
    public static let sleepTimerMenu = "audiobookPlayer.sleepTimerMenu"
    public static let sleepTimerEndOfChapter = "audiobookPlayer.sleepTimer.endOfChapter"
    public static func sleepTimerMinutes(_ minutes: Int) -> String { "audiobookPlayer.sleepTimer.\(minutes)min" }
  }
  
  // MARK: - Alerts & Dialogs
  
  /// Common alert and dialog identifiers
  public enum Alert {
    public static let alert = "alert.view"
    public static let title = "alert.title"
    public static let message = "alert.message"
    public static let okButton = "alert.okButton"
    public static let cancelButton = "alert.cancelButton"
    public static let deleteButton = "alert.deleteButton"
    public static let confirmButton = "alert.confirmButton"
  }
  
  // MARK: - Sign In
  
  /// Sign in screen identifiers
  public enum SignIn {
    public static let navigationBar = "signIn.navigationBar"
    public static let barcodeField = "signIn.barcodeField"
    public static let pinField = "signIn.pinField"
    public static let signInButton = "signIn.signInButton"
    public static let cancelButton = "signIn.cancelButton"
    public static let errorLabel = "signIn.errorLabel"
  }
  
  // MARK: - Common Elements
  
  /// Common UI elements used across screens
  public enum Common {
    public static let loadingIndicator = "common.loadingIndicator"
    public static let errorView = "common.errorView"
    public static let retryButton = "common.retryButton"
    public static let backButton = "common.backButton"
    public static let closeButton = "common.closeButton"
    public static let doneButton = "common.doneButton"
  }
}

// MARK: - Testing Helper Extensions

#if DEBUG
extension AccessibilityID {
  /// Returns all accessibility identifiers as a flat list for validation
  /// Useful for debugging and ensuring no duplicates exist
  public static func allIdentifiers() -> [String] {
    // This can be expanded to use reflection to collect all static strings
    // For now, manually maintain critical identifiers
    return [
      // Tab Bar
      TabBar.catalogTab,
      TabBar.myBooksTab,
      TabBar.holdsTab,
      TabBar.settingsTab,
      
      // Book Detail critical buttons
      BookDetail.getButton,
      BookDetail.readButton,
      BookDetail.listenButton,
      BookDetail.deleteButton,
      BookDetail.returnButton,
      BookDetail.reserveButton,
    ]
  }
}
#endif

