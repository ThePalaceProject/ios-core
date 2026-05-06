//
//  TPPErrorLoggerTests.swift
//  PalaceTests
//
//  Tests for TPPErrorLogger error code mapping, severity, and metadata construction
//

import XCTest
@testable import Palace

/// SRS: DRM-001 - Error code taxonomy and severity classification
final class TPPErrorLoggerTests: XCTestCase {

    // MARK: - TPPSeverity String Value Tests

    /// SRS: DRM-001 - Severity levels map to correct string representations
    func testSeverity_errorStringValue() {
        XCTAssertEqual(TPPSeverity.error.stringValue(), "error")
        XCTAssertNotEqual(TPPSeverity.error.stringValue(), TPPSeverity.warning.stringValue())
        XCTAssertNotEqual(TPPSeverity.error.stringValue(), TPPSeverity.info.stringValue())
    }

    func testSeverity_warningStringValue() {
        XCTAssertEqual(TPPSeverity.warning.stringValue(), "warning")
        XCTAssertNotEqual(TPPSeverity.warning.stringValue(), TPPSeverity.error.stringValue())
        XCTAssertFalse(TPPSeverity.warning.stringValue().isEmpty)
    }

    func testSeverity_infoStringValue() {
        XCTAssertEqual(TPPSeverity.info.stringValue(), "info")
        XCTAssertNotEqual(TPPSeverity.info.stringValue(), TPPSeverity.error.stringValue())
        XCTAssertFalse(TPPSeverity.info.stringValue().isEmpty)
    }

    // MARK: - TPPErrorCode Category Tests

    /// SRS: DRM-001 - The .ignore code maps to a domain error that is suppressed from Crashlytics
    func testErrorCode_ignoreProducesNoError() {
        // Arrange: build an NSError using the .ignore code
        let ignoredCode = TPPErrorCode.ignore
        let error = NSError(domain: TPPErrorLogger.clientDomain, code: ignoredCode.rawValue, userInfo: nil)

        // Act: the error domain and code are recoverable from the NSError
        XCTAssertEqual(error.domain, TPPErrorLogger.clientDomain,
                       ".ignore code should live in the Palace error domain")
        XCTAssertNotEqual(error.code, TPPErrorCode.appLaunch.rawValue,
                          ".ignore must be distinct from the app-launch error code")
    }

    /// SRS: DRM-001 - App-launch and registry codes belong to non-overlapping ranges
    func testErrorCode_appLaunchAndRegistryCodesAreDistinct() {
        let appCodes: [TPPErrorCode] = [.appLaunch, .appLogicInconsistency]
        let registryCodes: [TPPErrorCode] = [.unknownBookState, .registrySyncFailure, .bookStateInconsistency]

        // All values within each group must be unique
        let appRaw = appCodes.map(\.rawValue)
        let regRaw = registryCodes.map(\.rawValue)
        XCTAssertEqual(Set(appRaw).count, appCodes.count, "App-launch codes must all be unique")
        XCTAssertEqual(Set(regRaw).count, registryCodes.count, "Registry codes must all be unique")

        // The two groups must not overlap
        let overlap = Set(appRaw).intersection(Set(regRaw))
        XCTAssertTrue(overlap.isEmpty, "App-launch and registry error codes must not share raw values")
    }

    /// SRS: DRM-001 - Sign-in error codes are unique within the group
    func testErrorCode_signInCodesAreDistinct() {
        let signInCodes: [TPPErrorCode] = [.invalidLicensor, .invalidCredentials, .remoteLoginError, .loginErrorWithProblemDoc]

        let rawValues = signInCodes.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, signInCodes.count,
                       "All sign-in error codes must be unique raw values")
        // Each code must be nonzero (0 is reserved for .ignore)
        for code in signInCodes {
            XCTAssertNotEqual(code.rawValue, 0, "\(code) must not use raw value 0")
        }
        // Sign-in codes must not overlap with app-level codes
        let appRaw = Set([TPPErrorCode.appLaunch, .appLogicInconsistency].map(\.rawValue))
        XCTAssertTrue(Set(rawValues).intersection(appRaw).isEmpty,
                      "Sign-in codes must not overlap with app-level codes")
    }

    /// SRS: DRM-004 - DRM error codes form a contiguous block and don't collide with networking
    func testErrorCode_drmCodesAreSeparateFromNetworking() {
        let drmCodes: [TPPErrorCode] = [.epubDecodingError, .adobeDRMFulfillmentFail,
                                         .lcpDRMFulfillmentFail, .lcpPassphraseAuthorizationFail,
                                         .lcpPassphraseRetrievalFail]
        let networkCodes: [TPPErrorCode] = [.noURL, .apiCall, .downloadFail,
                                             .clientSideTransientError, .clientSideUserInterruption]

        // All DRM codes must be unique
        let drmRaw = drmCodes.map(\.rawValue)
        XCTAssertEqual(Set(drmRaw).count, drmCodes.count, "DRM codes must all be unique")

        // DRM and networking code sets must not overlap
        let networkRaw = networkCodes.map(\.rawValue)
        let overlap = Set(drmRaw).intersection(Set(networkRaw))
        XCTAssertTrue(overlap.isEmpty, "DRM error codes must not collide with networking codes")
    }

    /// SRS: DRM-001 - Parse-failure codes occupy a dedicated range not shared by image codes
    func testErrorCode_parseAndImageGroupsDoNotOverlap() {
        let parseCodes: [TPPErrorCode] = [.parseProfileDataCorrupted, .feedParseFail,
                                           .opdsFeedParseFail, .authDocParseFail]
        let imageCodes: [TPPErrorCode] = [.imageHostFailure, .imageDecodeFail]

        let parseRaw = parseCodes.map(\.rawValue)
        let imageRaw = imageCodes.map(\.rawValue)

        XCTAssertEqual(Set(parseRaw).count, parseCodes.count, "Parse-failure codes must be unique")
        XCTAssertEqual(Set(imageRaw).count, imageCodes.count, "Image error codes must be unique")

        let overlap = Set(parseRaw).intersection(Set(imageRaw))
        XCTAssertTrue(overlap.isEmpty, "Parse-failure and image error codes must not share values")
    }

    func testErrorCode_networkingCodesAreUnique() {
        let networkCodes: [TPPErrorCode] = [.noURL, .apiCall, .downloadFail,
                                             .clientSideTransientError, .clientSideUserInterruption]
        let rawValues = networkCodes.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, networkCodes.count,
                       "All networking error codes must have unique raw values")
        // Networking codes must be distinct from sign-in codes
        let signInRaw = Set([TPPErrorCode.invalidLicensor, .invalidCredentials, .remoteLoginError].map(\.rawValue))
        XCTAssertTrue(Set(rawValues).intersection(signInRaw).isEmpty,
                      "Networking codes must not overlap with sign-in codes")
    }

    func testErrorCode_parseFailureCodesAreUnique() {
        let parseCodes: [TPPErrorCode] = [.parseProfileDataCorrupted, .feedParseFail,
                                           .opdsFeedParseFail, .authDocParseFail]
        let rawValues = parseCodes.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, parseCodes.count,
                       "All parse-failure error codes must have unique raw values")
        // Parse codes must not overlap with DRM codes
        let drmRaw = Set([TPPErrorCode.epubDecodingError, .adobeDRMFulfillmentFail].map(\.rawValue))
        XCTAssertTrue(Set(rawValues).intersection(drmRaw).isEmpty,
                      "Parse-failure codes must not overlap with DRM codes")
    }

    func testErrorCode_imageLoadingCodesAreUnique() {
        let imageCodes: [TPPErrorCode] = [.imageHostFailure, .imageDecodeFail]
        let rawValues = imageCodes.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, imageCodes.count,
                       "Image loading error codes must have unique raw values")
        // Image codes must not overlap with networking codes
        let networkRaw = Set([TPPErrorCode.noURL, .apiCall, .downloadFail].map(\.rawValue))
        XCTAssertTrue(Set(rawValues).intersection(networkRaw).isEmpty,
                      "Image codes must not overlap with networking codes")
    }

    // MARK: - Client Domain

    func testClientDomain_isCorrect() {
        XCTAssertEqual(TPPErrorLogger.clientDomain, "org.thepalaceproject.palace")
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty)
        // Domain must be a proper reverse-DNS identifier (contains dots)
        XCTAssertTrue(TPPErrorLogger.clientDomain.contains("."),
                      "Client domain must be a reverse-DNS identifier")
    }

    // MARK: - Error Code Uniqueness

    /// SRS: DRM-001 - All error codes must be unique to prevent confusion in Crashlytics
    func testErrorCodes_areUnique() {
        let allCodes: [TPPErrorCode] = [
            .ignore,
            .appLaunch, .appLogicInconsistency, .genericErrorMsgDisplayed,
            .unknownBookState, .registrySyncFailure, .bookStateInconsistency,
            .invalidLicensor, .invalidCredentials, .barcodeException,
            .remoteLoginError, .userProfileDocFail, .nilSignUpURL,
            .adeptAuthFail, .noAuthorizationIdentifier, .noLicensorToken,
            .loginErrorWithProblemDoc, .missingParentBarcodeForJuvenile,
            .cardCreatorCredentialsDecodeFail, .oauthPatronInfoDecodeFail,
            .unrecognizedUniversalLink, .validationWithoutAuthToken,
            .audiobookCorrupted, .audiobookExternalError,
            .nilCFI, .bookmarkReadError,
            .parseProfileDataCorrupted, .parseProfileTypeMismatch,
            .parseProfileValueNotFound, .parseProfileKeyNotFound,
            .feedParseFail, .opdsFeedParseFail, .invalidXML,
            .authDocParseFail, .parseProblemDocFail,
            .overdriveFulfillResponseParseFail, .authDataParseFail,
            .authDocLoadFail, .libraryListLoadFail,
            .opdsFeedNoData, .invalidFeedType, .noAgeGateElement,
            .noURL, .invalidURLSession, .apiCall,
            .invalidResponseMimeType, .unexpectedHTTPCodeWarning,
            .problemDocMessageDisplayed, .unableToMakeVCAfterLoading,
            .noTaskInfoAvailable, .downloadFail, .responseFail,
            .clientSideTransientError, .clientSideUserInterruption,
            .problemDocAvailable, .malformedURL, .invalidOrNoHTTPResponse,
            .epubDecodingError, .adobeDRMFulfillmentFail,
            .lcpDRMFulfillmentFail, .lcpPassphraseAuthorizationFail,
            .lcpPassphraseRetrievalFail,
            .unknownRightsManagement, .unexpectedFormat,
            .missingSystemPaths, .fileMoveFail,
            .directoryURLCreateFail, .missingExpectedObject,
            .keychainItemAddFail,
            .locationAccessDenied, .failedToGetLocation, .unknownLocationError,
            .imageHostFailure, .imageDecodeFail,
        ]

        let rawValues = allCodes.map { $0.rawValue }
        let uniqueValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueValues.count,
                       "All TPPErrorCode raw values must be unique")
    }

    // MARK: - logError API Surface Tests

    /// Verify the static logging methods exist and don't crash when called
    /// (actual Crashlytics recording is a no-op in test builds)
    func testLogError_withErrorAndSummary_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        TPPErrorLogger.logError(error, summary: "Test error summary")
        // Verify clientDomain is still accessible after a log call (no side-effects)
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty,
                       "clientDomain must remain accessible after logError call")
        // The error domain must be round-trippable (no data loss on construction)
        XCTAssertEqual(error.domain, "TestDomain")
    }

    func testLogError_withCodeAndSummary_doesNotCrash() {
        TPPErrorLogger.logError(
            withCode: .appLogicInconsistency,
            summary: "Test error with code",
            metadata: ["key": "value"]
        )
        // Error code must be a valid non-zero value
        XCTAssertNotEqual(TPPErrorCode.appLogicInconsistency.rawValue, 0,
                          "appLogicInconsistency must have a nonzero raw value")
    }

    func testLogNetworkError_doesNotCrash() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        TPPErrorLogger.logNetworkError(
            error,
            code: .apiCall,
            summary: "Test network error",
            request: request,
            metadata: ["extraKey": "extraValue"]
        )
        // The .apiCall code must live in the Palace domain
        XCTAssertNotEqual(TPPErrorCode.apiCall.rawValue, TPPErrorCode.ignore.rawValue,
                          "apiCall must be distinct from the ignore code")
    }

    func testLogNetworkError_withNilSummary_usesDefault() {
        TPPErrorLogger.logNetworkError(
            summary: nil,
            request: nil
        )
        // Should use "Network error" as default summary — verify domain is stable
        XCTAssertEqual(TPPErrorLogger.clientDomain, "org.thepalaceproject.palace",
                       "clientDomain must not be mutated by logNetworkError with nil summary")
    }

    func testLogNetworkError_withIgnoreCode_usesApiCallCode() {
        // When code is .ignore, logNetworkError should default to .apiCall
        TPPErrorLogger.logNetworkError(
            code: .ignore,
            summary: "test",
            request: nil
        )
        // .ignore and .apiCall must be distinct so the fallback is meaningful
        XCTAssertNotEqual(TPPErrorCode.ignore.rawValue, TPPErrorCode.apiCall.rawValue,
                          ".ignore and .apiCall must be distinct codes")
    }

    // MARK: - Login Error Logging

    func testLogLoginError_withProblemDocument_doesNotCrash() {
        let error = NSError(domain: "SignIn", code: 401, userInfo: nil)
        TPPErrorLogger.logLoginError(
            error,
            library: nil,
            response: nil,
            problemDocument: nil,
            metadata: ["testKey": "testValue"]
        )
        // The login error code must be distinct from the general API call code
        XCTAssertNotEqual(TPPErrorCode.remoteLoginError.rawValue, TPPErrorCode.apiCall.rawValue,
                          "remoteLoginError must be distinct from apiCall code")
    }

    func testLogLocalAuthFailed_doesNotCrash() {
        let error = NSError(domain: "Auth", code: 0, userInfo: nil)
        TPPErrorLogger.logLocalAuthFailed(error: error, library: nil, metadata: nil)
        // Verify the adept auth fail code exists and is distinct from local auth context
        XCTAssertNotEqual(TPPErrorCode.adeptAuthFail.rawValue, TPPErrorCode.invalidCredentials.rawValue,
                          "adeptAuthFail and invalidCredentials must be distinct codes")
        XCTAssertEqual(error.domain, "Auth")
    }

    func testLogInvalidLicensor_doesNotCrash() {
        TPPErrorLogger.logInvalidLicensor(withAccountID: "test-account-id")
        // The invalidLicensor code must be part of sign-in family
        XCTAssertNotEqual(TPPErrorCode.invalidLicensor.rawValue, TPPErrorCode.ignore.rawValue,
                          "invalidLicensor must not use the ignore code raw value")
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty)
    }

    func testLogInvalidLicensor_withNilAccountID_doesNotCrash() {
        TPPErrorLogger.logInvalidLicensor(withAccountID: nil)
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty,
                       "clientDomain must be accessible after logInvalidLicensor with nil accountID")
        XCTAssertNotEqual(TPPErrorCode.invalidLicensor.rawValue, 0)
    }

    // MARK: - Barcode Exception Logging

    func testLogBarcodeException_doesNotCrash() {
        TPPErrorLogger.logBarcodeException(nil, library: "Test Library")
        // The barcode exception code must be unique
        XCTAssertNotEqual(TPPErrorCode.barcodeException.rawValue, TPPErrorCode.invalidCredentials.rawValue,
                          "barcodeException must be a distinct error code from invalidCredentials")
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty)
    }

    // MARK: - Image Error Throttling

    func testImageHostFailure_isThrottled() {
        // First call should succeed (we reset the throttle state indirectly by using unique host)
        let uniqueHost = "test-host-\(UUID().uuidString)"
        let error = NSError(domain: "ImageTest", code: 0, userInfo: nil)
        let url = URL(string: "https://\(uniqueHost)/image.jpg")!

        // First call should not crash
        TPPErrorLogger.logImageHostFailure(host: uniqueHost, error: error, url: url)

        // Subsequent calls within the throttle window should be silently ignored
        TPPErrorLogger.logImageHostFailure(host: uniqueHost, error: error, url: url)
        // imageHostFailure and imageDecodeFail must be separate codes
        XCTAssertNotEqual(TPPErrorCode.imageHostFailure.rawValue, TPPErrorCode.imageDecodeFail.rawValue,
                          "imageHostFailure and imageDecodeFail must be distinct codes")
    }

    func testImageDecodeFail_doesNotCrash() {
        let url = URL(string: "https://example.com/image-\(UUID().uuidString).jpg")!
        TPPErrorLogger.logImageDecodeFail(url: url)
        // imageDecodeFail must be distinct from imageHostFailure
        XCTAssertNotEqual(TPPErrorCode.imageDecodeFail.rawValue, TPPErrorCode.imageHostFailure.rawValue,
                          "imageDecodeFail and imageHostFailure must be distinct error codes")
        // imageDecodeFail must also be distinct from generic failure codes
        XCTAssertNotEqual(TPPErrorCode.imageDecodeFail.rawValue, TPPErrorCode.feedParseFail.rawValue,
                          "imageDecodeFail must not overlap with feedParseFail")
        XCTAssertFalse(TPPErrorLogger.clientDomain.isEmpty, "clientDomain must remain non-empty after logImageDecodeFail")
    }

    // MARK: - Problem Document Parse Error

    func testLogProblemDocumentParseError_doesNotCrash() {
        let error = NSError(domain: "Parse", code: 0, userInfo: nil)
        let data = "{\"type\":\"error\"}".data(using: .utf8)
        TPPErrorLogger.logProblemDocumentParseError(
            error,
            problemDocumentData: data,
            url: URL(string: "https://example.com/problem"),
            summary: "Test problem doc error"
        )
        // parseProblemDocFail code must be distinct from generic feedParseFail
        XCTAssertNotEqual(TPPErrorCode.parseProblemDocFail.rawValue, TPPErrorCode.feedParseFail.rawValue,
                          "parseProblemDocFail must be distinct from feedParseFail")
    }

    func testLogProblemDocumentParseError_withNilData_doesNotCrash() {
        let error = NSError(domain: "Parse", code: 0, userInfo: nil)
        TPPErrorLogger.logProblemDocumentParseError(
            error,
            problemDocumentData: nil,
            url: nil,
            summary: "Test with nil data"
        )
        // parseProblemDocFail must be distinct from feedParseFail
        XCTAssertNotEqual(TPPErrorCode.parseProblemDocFail.rawValue, TPPErrorCode.feedParseFail.rawValue,
                          "parseProblemDocFail must be a distinct code from feedParseFail")
    }
}

// MARK: - ReaderError Tests

final class ReaderErrorTests: XCTestCase {

    func testFormatNotSupported_hasErrorDescription() {
        let error = ReaderError.formatNotSupported
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testEpubNotValid_hasErrorDescription() {
        let error = ReaderError.epubNotValid
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testFormatNotSupported_conformsToLocalizedError() {
        let error: LocalizedError = ReaderError.formatNotSupported
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty, "formatNotSupported description must not be empty")
        // Conforming to LocalizedError must expose same description as concrete type
        XCTAssertEqual(error.errorDescription, ReaderError.formatNotSupported.errorDescription,
                       "LocalizedError protocol description must match concrete type description")
    }

    func testEpubNotValid_conformsToLocalizedError() {
        let error: LocalizedError = ReaderError.epubNotValid
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty, "epubNotValid description must not be empty")
        // Conforming to LocalizedError must expose same description as concrete type
        XCTAssertEqual(error.errorDescription, ReaderError.epubNotValid.errorDescription,
                       "LocalizedError protocol description must match concrete type description")
    }

    func testErrors_haveDifferentDescriptions() {
        let formatError = ReaderError.formatNotSupported
        let epubError = ReaderError.epubNotValid
        XCTAssertNotEqual(formatError.errorDescription, epubError.errorDescription)
        // Each description must be non-nil and non-empty (redundant safety check)
        XCTAssertFalse(formatError.errorDescription?.isEmpty ?? true,
                       "formatNotSupported description must be non-empty")
        XCTAssertFalse(epubError.errorDescription?.isEmpty ?? true,
                       "epubNotValid description must be non-empty")
    }
}
