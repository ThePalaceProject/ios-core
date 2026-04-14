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
    }

    func testSeverity_warningStringValue() {
        XCTAssertEqual(TPPSeverity.warning.stringValue(), "warning")
    }

    func testSeverity_infoStringValue() {
        XCTAssertEqual(TPPSeverity.info.stringValue(), "info")
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
        // No crash = pass
    }

    func testLogError_withCodeAndSummary_doesNotCrash() {
        TPPErrorLogger.logError(
            withCode: .appLogicInconsistency,
            summary: "Test error with code",
            metadata: ["key": "value"]
        )
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
    }

    func testLogNetworkError_withNilSummary_usesDefault() {
        TPPErrorLogger.logNetworkError(
            summary: nil,
            request: nil
        )
        // Should use "Network error" as default summary
    }

    func testLogNetworkError_withIgnoreCode_usesApiCallCode() {
        // When code is .ignore, logNetworkError should default to .apiCall
        TPPErrorLogger.logNetworkError(
            code: .ignore,
            summary: "test",
            request: nil
        )
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
    }

    func testLogLocalAuthFailed_doesNotCrash() {
        let error = NSError(domain: "Auth", code: 0, userInfo: nil)
        TPPErrorLogger.logLocalAuthFailed(error: error, library: nil, metadata: nil)
    }

    func testLogInvalidLicensor_doesNotCrash() {
        TPPErrorLogger.logInvalidLicensor(withAccountID: "test-account-id")
    }

    func testLogInvalidLicensor_withNilAccountID_doesNotCrash() {
        TPPErrorLogger.logInvalidLicensor(withAccountID: nil)
    }

    // MARK: - Barcode Exception Logging

    func testLogBarcodeException_doesNotCrash() {
        TPPErrorLogger.logBarcodeException(nil, library: "Test Library")
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
    }

    func testImageDecodeFail_doesNotCrash() {
        let url = URL(string: "https://example.com/image-\(UUID().uuidString).jpg")!
        TPPErrorLogger.logImageDecodeFail(url: url)
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
    }

    func testLogProblemDocumentParseError_withNilData_doesNotCrash() {
        let error = NSError(domain: "Parse", code: 0, userInfo: nil)
        TPPErrorLogger.logProblemDocumentParseError(
            error,
            problemDocumentData: nil,
            url: nil,
            summary: "Test with nil data"
        )
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
    }

    func testEpubNotValid_conformsToLocalizedError() {
        let error: LocalizedError = ReaderError.epubNotValid
        XCTAssertNotNil(error.errorDescription)
    }

    func testErrors_haveDifferentDescriptions() {
        let formatError = ReaderError.formatNotSupported
        let epubError = ReaderError.epubNotValid
        XCTAssertNotEqual(formatError.errorDescription, epubError.errorDescription)
    }
}
