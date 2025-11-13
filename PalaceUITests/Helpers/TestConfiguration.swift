import Foundation

/// Central configuration for UI tests.
///
/// **AI-DEV GUIDE:**
/// - All test configuration lives here
/// - Use environment variables for sensitive data
/// - Add new test libraries and credentials here
/// - Configure launch arguments for app state
///
/// **ENVIRONMENT VARIABLES:**
/// Set these in your Xcode scheme's Test section:
/// - `LYRASIS_BARCODE`: Test account barcode for Lyrasis Reads
/// - `LYRASIS_PIN`: Test account PIN
/// - `TEST_MODE`: Set to "1" to enable test mode features
/// - `SKIP_ANIMATIONS`: Set to "1" to disable animations for faster tests
enum TestConfiguration {
  
  // MARK: - Test Libraries
  
  /// Test library configurations
  enum Library {
    case palaceBookshelf
    case lyrasisReads
    case a1qaTestLibrary
    
    /// Human-readable library name
    var name: String {
      switch self {
      case .palaceBookshelf:
        return "Palace Bookshelf"
      case .lyrasisReads:
        return "Lyrasis Reads"
      case .a1qaTestLibrary:
        return "A1QA Test Library"
      }
    }
    
    /// Library UUID (if known from app)
    var uuid: String? {
      switch self {
      case .palaceBookshelf:
        return "palace-bookshelf-uuid"
      case .lyrasisReads:
        return "lyrasis-uuid"
      case .a1qaTestLibrary:
        return "a1qa-uuid"
      }
    }
    
    /// Authentication requirements
    var requiresAuth: Bool {
      switch self {
      case .palaceBookshelf:
        return false
      case .lyrasisReads, .a1qaTestLibrary:
        return true
      }
    }
    
    /// Test credentials for this library
    var credentials: TestCredentials? {
      switch self {
      case .palaceBookshelf:
        return nil
      case .lyrasisReads:
        return TestCredentials.lyrasis
      case .a1qaTestLibrary:
        return TestCredentials.a1qa
      }
    }
  }
  
  // MARK: - Test Credentials
  
  /// Test account credentials
  struct TestCredentials {
    let barcode: String
    let pin: String
    
    /// Lyrasis Reads test account
    static var lyrasis: TestCredentials {
      TestCredentials(
        barcode: ProcessInfo.processInfo.environment["LYRASIS_BARCODE"] ?? "01230000000002",
        pin: ProcessInfo.processInfo.environment["LYRASIS_PIN"] ?? "Lyrtest123"
      )
    }
    
    /// A1QA Test Library account
    static var a1qa: TestCredentials {
      TestCredentials(
        barcode: ProcessInfo.processInfo.environment["A1QA_BARCODE"] ?? "testuser",
        pin: ProcessInfo.processInfo.environment["A1QA_PIN"] ?? "testpass"
      )
    }
  }
  
  // MARK: - Test Books
  
  /// Known test books for deterministic testing
  enum TestBook {
    case aliceInWonderland
    case prideAndPrejudice
    case mobyDick
    case metamorphosis
    
    /// Book title for searching
    var title: String {
      switch self {
      case .aliceInWonderland:
        return "Alice's Adventures in Wonderland"
      case .prideAndPrejudice:
        return "Pride and Prejudice"
      case .mobyDick:
        return "Moby Dick"
      case .metamorphosis:
        return "Metamorphosis"
      }
    }
    
    /// Expected author
    var author: String {
      switch self {
      case .aliceInWonderland:
        return "Lewis Carroll"
      case .prideAndPrejudice:
        return "Jane Austen"
      case .mobyDick:
        return "Herman Melville"
      case .metamorphosis:
        return "Franz Kafka"
      }
    }
    
    /// Search term that should find this book
    var searchTerm: String {
      switch self {
      case .aliceInWonderland:
        return "alice wonderland"
      case .prideAndPrejudice:
        return "pride prejudice"
      case .mobyDick:
        return "moby dick"
      case .metamorphosis:
        return "metamorphosis"
      }
    }
  }
  
  // MARK: - Distributors
  
  /// Book distributors to test
  enum Distributor: String {
    case bibliotheca = "Bibliotheca"
    case axis360 = "Axis 360"
    case palaceMarketplace = "Palace Marketplace"
    case biblioBoard = "BiblioBoard"
    case overdrive = "Overdrive"
  }
  
  // MARK: - App Launch Configuration
  
  /// Launch arguments for app configuration
  static var launchArguments: [String] {
    var args = [
      "-testMode", "1",  // Enable test mode
      "-resetState", "1"  // Reset app state before tests
    ]
    
    if skipAnimations {
      args.append(contentsOf: ["-UIAnimationDragCoefficient", "100"])
    }
    
    return args
  }
  
  /// Environment variables for app configuration
  static var launchEnvironment: [String: String] {
    var env: [String: String] = [:]
    
    if skipAnimations {
      env["DISABLE_ANIMATIONS"] = "1"
    }
    
    return env
  }
  
  // MARK: - Test Settings
  
  /// Whether to skip animations for faster test execution
  static var skipAnimations: Bool {
    ProcessInfo.processInfo.environment["SKIP_ANIMATIONS"] == "1"
  }
  
  /// Whether test mode is enabled
  static var isTestMode: Bool {
    ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
  }
  
  /// Default timeout for network operations (in seconds)
  static let networkTimeout: TimeInterval = 15.0
  
  /// Default timeout for UI updates (in seconds)
  static let uiTimeout: TimeInterval = 5.0
  
  /// Short timeout for quick checks (in seconds)
  static let shortTimeout: TimeInterval = 2.0
  
  /// Timeout for book downloads (in seconds)
  static let downloadTimeout: TimeInterval = 30.0
  
  /// Timeout for opening books (in seconds)
  static let bookOpenTimeout: TimeInterval = 10.0
}

// MARK: - Test Data Helpers

extension TestConfiguration {
  
  /// Returns a test book suitable for EPUB testing
  static var testEPUBBook: TestBook {
    .aliceInWonderland
  }
  
  /// Returns a test book suitable for audiobook testing
  static var testAudiobook: TestBook {
    .prideAndPrejudice
  }
  
  /// Returns a test book suitable for PDF testing
  static var testPDFBook: TestBook {
    .metamorphosis
  }
  
  /// Returns the primary test library (no auth required)
  static var primaryTestLibrary: Library {
    .palaceBookshelf
  }
  
  /// Returns a library requiring authentication
  static var authTestLibrary: Library {
    .lyrasisReads
  }
}

