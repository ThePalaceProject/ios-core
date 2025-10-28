//
//  PalaceError.swift
//  Palace
//
//  Created for Swift Concurrency Modernization
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Comprehensive error types for the Palace application
/// Provides structured error handling with recovery suggestions
enum PalaceError: LocalizedError {
  // MARK: - Network Errors
  case network(NetworkError)
  
  // MARK: - Book Registry Errors
  case bookRegistry(BookRegistryError)
  
  // MARK: - Download Errors
  case download(DownloadError)
  
  // MARK: - Parsing Errors
  case parsing(ParsingError)
  
  // MARK: - DRM Errors
  case drm(DRMError)
  
  // MARK: - Authentication Errors
  case authentication(AuthenticationError)
  
  // MARK: - Storage Errors
  case storage(StorageError)
  
  // MARK: - Book Reader Errors
  case bookReader(BookReaderError)
  
  // MARK: - Audiobook Errors
  case audiobook(AudiobookError)
  
  // MARK: - LocalizedError Implementation
  var errorDescription: String? {
    switch self {
    case .network(let error): return error.errorDescription
    case .bookRegistry(let error): return error.errorDescription
    case .download(let error): return error.errorDescription
    case .parsing(let error): return error.errorDescription
    case .drm(let error): return error.errorDescription
    case .authentication(let error): return error.errorDescription
    case .storage(let error): return error.errorDescription
    case .bookReader(let error): return error.errorDescription
    case .audiobook(let error): return error.errorDescription
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .network(let error): return error.recoverySuggestion
    case .bookRegistry(let error): return error.recoverySuggestion
    case .download(let error): return error.recoverySuggestion
    case .parsing(let error): return error.recoverySuggestion
    case .drm(let error): return error.recoverySuggestion
    case .authentication(let error): return error.recoverySuggestion
    case .storage(let error): return error.recoverySuggestion
    case .bookReader(let error): return error.recoverySuggestion
    case .audiobook(let error): return error.recoverySuggestion
    }
  }
  
  var errorCode: Int {
    switch self {
    case .network(let error): return 1000 + error.rawValue
    case .bookRegistry(let error): return 2000 + error.rawValue
    case .download(let error): return 3000 + error.rawValue
    case .parsing(let error): return 4000 + error.rawValue
    case .drm(let error): return 5000 + error.rawValue
    case .authentication(let error): return 6000 + error.rawValue
    case .storage(let error): return 7000 + error.rawValue
    case .bookReader(let error): return 8000 + error.rawValue
    case .audiobook(let error): return 9000 + error.rawValue
    }
  }
}

// MARK: - Network Errors

enum NetworkError: Int, LocalizedError {
  case noConnection = 0
  case timeout = 1
  case invalidURL = 2
  case invalidResponse = 3
  case unauthorized = 4
  case forbidden = 5
  case notFound = 6
  case serverError = 7
  case rateLimited = 8
  case cancelled = 9
  case unknown = 10
  
  var errorDescription: String? {
    switch self {
    case .noConnection:
      return "No internet connection available"
    case .timeout:
      return "The request timed out"
    case .invalidURL:
      return "The URL is invalid"
    case .invalidResponse:
      return "Received an invalid response from the server"
    case .unauthorized:
      return "Authentication required"
    case .forbidden:
      return "Access to this resource is forbidden"
    case .notFound:
      return "The requested resource was not found"
    case .serverError:
      return "A server error occurred"
    case .rateLimited:
      return "Too many requests. Please try again later"
    case .cancelled:
      return "The request was cancelled"
    case .unknown:
      return "An unknown network error occurred"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .noConnection:
      return "Please check your internet connection and try again."
    case .timeout:
      return "Please check your internet connection and try again."
    case .invalidURL:
      return "Please contact support if this problem persists."
    case .invalidResponse:
      return "Please try again later. If the problem persists, contact support."
    case .unauthorized:
      return "Please sign in again."
    case .forbidden:
      return "You don't have permission to access this resource."
    case .notFound:
      return "The item you're looking for is no longer available."
    case .serverError:
      return "The server is experiencing issues. Please try again later."
    case .rateLimited:
      return "Please wait a few moments before trying again."
    case .cancelled:
      return nil
    case .unknown:
      return "Please try again. If the problem persists, contact support."
    }
  }
}

// MARK: - Book Registry Errors

enum BookRegistryError: Int, LocalizedError {
  case bookNotFound = 0
  case registryCorrupted = 1
  case syncFailed = 2
  case saveFailed = 3
  case loadFailed = 4
  case invalidState = 5
  case concurrencyViolation = 6
  
  var errorDescription: String? {
    switch self {
    case .bookNotFound:
      return "Book not found in registry"
    case .registryCorrupted:
      return "The book registry is corrupted"
    case .syncFailed:
      return "Failed to sync books with the server"
    case .saveFailed:
      return "Failed to save book registry"
    case .loadFailed:
      return "Failed to load book registry"
    case .invalidState:
      return "Book is in an invalid state"
    case .concurrencyViolation:
      return "A concurrency error occurred"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .bookNotFound:
      return "Try refreshing your library."
    case .registryCorrupted:
      return "The app will attempt to rebuild your library. Please sync again."
    case .syncFailed:
      return "Please check your internet connection and try again."
    case .saveFailed, .loadFailed:
      return "Please ensure you have sufficient storage space and try again."
    case .invalidState:
      return "Please try removing and re-adding this book."
    case .concurrencyViolation:
      return "Please restart the app and try again."
    }
  }
}

// MARK: - Download Errors

enum DownloadError: Int, LocalizedError {
  case networkFailure = 0
  case insufficientSpace = 1
  case fileSystemError = 2
  case corruptedDownload = 3
  case cancelled = 4
  case maxRetriesExceeded = 5
  case invalidLicense = 6
  case downloadNotFound = 7
  
  var errorDescription: String? {
    switch self {
    case .networkFailure:
      return "Download failed due to network error"
    case .insufficientSpace:
      return "Insufficient storage space"
    case .fileSystemError:
      return "Failed to save downloaded file"
    case .corruptedDownload:
      return "The downloaded file is corrupted"
    case .cancelled:
      return "Download cancelled"
    case .maxRetriesExceeded:
      return "Download failed after multiple attempts"
    case .invalidLicense:
      return "Invalid or expired license"
    case .downloadNotFound:
      return "Download task not found"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .networkFailure:
      return "Please check your internet connection and try again."
    case .insufficientSpace:
      return "Please free up space on your device and try again."
    case .fileSystemError:
      return "Please ensure the app has proper permissions and try again."
    case .corruptedDownload:
      return "Please try downloading again."
    case .cancelled:
      return nil
    case .maxRetriesExceeded:
      return "Please check your internet connection and try again later."
    case .invalidLicense:
      return "Please return this book and borrow it again."
    case .downloadNotFound:
      return "Please try starting the download again."
    }
  }
}

// MARK: - Parsing Errors

enum ParsingError: Int, LocalizedError {
  case invalidJSON = 0
  case invalidXML = 1
  case missingRequiredField = 2
  case invalidFormat = 3
  case encodingError = 4
  case opdsFeedInvalid = 5
  
  var errorDescription: String? {
    switch self {
    case .invalidJSON:
      return "Invalid JSON data"
    case .invalidXML:
      return "Invalid XML data"
    case .missingRequiredField:
      return "Missing required data field"
    case .invalidFormat:
      return "Data format is invalid"
    case .encodingError:
      return "Text encoding error"
    case .opdsFeedInvalid:
      return "Invalid OPDS feed"
    }
  }
  
  var recoverySuggestion: String? {
    return "The server returned data in an unexpected format. Please try again later or contact support."
  }
}

// MARK: - DRM Errors

enum DRMError: Int, LocalizedError {
  case authenticationFailed = 0
  case tooManyActivations = 1
  case licenseExpired = 2
  case decryptionFailed = 3
  case noActivation = 4
  case adobeError = 5
  case lcpError = 6
  
  var errorDescription: String? {
    switch self {
    case .authenticationFailed:
      return "DRM authentication failed"
    case .tooManyActivations:
      return "Too many device activations"
    case .licenseExpired:
      return "License has expired"
    case .decryptionFailed:
      return "Failed to decrypt content"
    case .noActivation:
      return "Device not activated"
    case .adobeError:
      return "Adobe DRM error"
    case .lcpError:
      return "LCP DRM error"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .authenticationFailed:
      return "Please sign out and sign in again."
    case .tooManyActivations:
      return "Please deauthorize a device and try again."
    case .licenseExpired:
      return "Please return and re-borrow this book."
    case .decryptionFailed:
      return "Please try re-downloading this book."
    case .noActivation:
      return "Please sign in to activate your device."
    case .adobeError, .lcpError:
      return "Please contact support if this problem persists."
    }
  }
}

// MARK: - Authentication Errors

enum AuthenticationError: Int, LocalizedError {
  case invalidCredentials = 0
  case noCredentials = 1
  case tokenExpired = 2
  case tokenRefreshFailed = 3
  case accountNotFound = 4
  case networkError = 5
  
  var errorDescription: String? {
    switch self {
    case .invalidCredentials:
      return "Invalid username or password"
    case .noCredentials:
      return "No credentials available"
    case .tokenExpired:
      return "Authentication token expired"
    case .tokenRefreshFailed:
      return "Failed to refresh authentication token"
    case .accountNotFound:
      return "Account not found"
    case .networkError:
      return "Network error during authentication"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .invalidCredentials:
      return "Please check your username and password and try again."
    case .noCredentials:
      return "Please sign in."
    case .tokenExpired, .tokenRefreshFailed:
      return "Please sign in again."
    case .accountNotFound:
      return "Please check your library selection and try again."
    case .networkError:
      return "Please check your internet connection and try again."
    }
  }
}

// MARK: - Storage Errors

enum StorageError: Int, LocalizedError {
  case insufficientSpace = 0
  case fileNotFound = 1
  case permissionDenied = 2
  case corruptedData = 3
  case writeError = 4
  case readError = 5
  
  var errorDescription: String? {
    switch self {
    case .insufficientSpace:
      return "Insufficient storage space"
    case .fileNotFound:
      return "File not found"
    case .permissionDenied:
      return "Permission denied"
    case .corruptedData:
      return "Data is corrupted"
    case .writeError:
      return "Failed to write data"
    case .readError:
      return "Failed to read data"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .insufficientSpace:
      return "Please free up space on your device and try again."
    case .fileNotFound:
      return "The file may have been deleted. Please try again."
    case .permissionDenied:
      return "Please ensure the app has proper permissions in Settings."
    case .corruptedData:
      return "The data may be corrupted. Please try again or contact support."
    case .writeError, .readError:
      return "Please ensure you have sufficient storage space and try again."
    }
  }
}

// MARK: - Book Reader Errors

enum BookReaderError: Int, LocalizedError {
  case bookNotAvailable = 0
  case corruptedBook = 1
  case unsupportedFormat = 2
  case decryptionRequired = 3
  case renderingError = 4
  case bookmarkError = 5
  
  var errorDescription: String? {
    switch self {
    case .bookNotAvailable:
      return "Book is not available"
    case .corruptedBook:
      return "Book file is corrupted"
    case .unsupportedFormat:
      return "Unsupported book format"
    case .decryptionRequired:
      return "Book requires decryption"
    case .renderingError:
      return "Failed to render book content"
    case .bookmarkError:
      return "Failed to save or load bookmark"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .bookNotAvailable:
      return "Please download the book and try again."
    case .corruptedBook:
      return "Please try re-downloading this book."
    case .unsupportedFormat:
      return "This book format is not supported by the app."
    case .decryptionRequired:
      return "Please ensure you are signed in and try again."
    case .renderingError:
      return "Please try closing and reopening the book."
    case .bookmarkError:
      return "Your bookmark may not have been saved. Please try again."
    }
  }
}

// MARK: - Audiobook Errors

enum AudiobookError: Int, LocalizedError {
  case corruptedManifest = 0
  case missingAudioFiles = 1
  case streamingError = 2
  case decodingError = 3
  case playbackError = 4
  case bookmarkError = 5
  
  var errorDescription: String? {
    switch self {
    case .corruptedManifest:
      return "Audiobook manifest is corrupted"
    case .missingAudioFiles:
      return "Audio files are missing"
    case .streamingError:
      return "Streaming error occurred"
    case .decodingError:
      return "Failed to decode audio"
    case .playbackError:
      return "Playback error occurred"
    case .bookmarkError:
      return "Failed to save listening position"
    }
  }
  
  var recoverySuggestion: String? {
    switch self {
    case .corruptedManifest:
      return "Please try re-downloading this audiobook."
    case .missingAudioFiles:
      return "Please try re-downloading this audiobook."
    case .streamingError:
      return "Please check your internet connection and try again."
    case .decodingError:
      return "There may be an issue with the audio format. Please contact support."
    case .playbackError:
      return "Please try closing and reopening the audiobook."
    case .bookmarkError:
      return "Your listening position may not have been saved."
    }
  }
}

// MARK: - Error Conversion Utilities

extension PalaceError {
  /// Converts NSError to PalaceError when possible
  static func from(_ error: Error) -> PalaceError {
    if let palaceError = error as? PalaceError {
      return palaceError
    }
    
    let nsError = error as NSError
    
    // Network errors
    if nsError.domain == NSURLErrorDomain {
      return .network(networkErrorFrom(nsError))
    }
    
    // Adobe DRM errors
    #if FEATURE_DRM_CONNECTOR
    if nsError.domain == NYPLADEPTErrorDomain {
      return .drm(drmErrorFrom(nsError))
    }
    #endif
    
    // Default to unknown network error
    return .network(.unknown)
  }
  
  private static func networkErrorFrom(_ error: NSError) -> NetworkError {
    switch error.code {
    case NSURLErrorNotConnectedToInternet:
      return .noConnection
    case NSURLErrorTimedOut:
      return .timeout
    case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
      return .invalidURL
    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
      return .serverError
    case NSURLErrorCancelled:
      return .cancelled
    default:
      if error.code >= 400 && error.code < 500 {
        if error.code == 401 {
          return .unauthorized
        } else if error.code == 403 {
          return .forbidden
        } else if error.code == 404 {
          return .notFound
        } else if error.code == 429 {
          return .rateLimited
        }
      } else if error.code >= 500 {
        return .serverError
      }
      return .unknown
    }
  }
  
  #if FEATURE_DRM_CONNECTOR
  private static func drmErrorFrom(_ error: NSError) -> DRMError {
    if let adobeError = NYPLADEPTError(rawValue: error.code) {
      switch adobeError {
      case .authenticationFailed:
        return .authenticationFailed
      case .tooManyActivations:
        return .tooManyActivations
      default:
        return .adobeError
      }
    }
    return .adobeError
  }
  #endif
}

// MARK: - Result Type Extension

extension Result where Failure == PalaceError {
  /// Logs the error if it's a failure
  func logError(context: String) -> Self {
    if case .failure(let error) = self {
      TPPErrorLogger.logError(error, summary: context)
    }
    return self
  }
}

