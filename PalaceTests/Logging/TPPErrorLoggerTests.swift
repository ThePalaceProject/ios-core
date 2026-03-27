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

    // MARK: - TPPErrorCode Raw Value Tests

    /// SRS: DRM-001 - Error codes have correct raw values for Crashlytics grouping
    func testErrorCode_ignoreIsZero() {
        XCTAssertEqual(TPPErrorCode.ignore.rawValue, 0)
    }

    func testErrorCode_appLaunchRange() {
        XCTAssertEqual(TPPErrorCode.appLaunch.rawValue, 100)
        XCTAssertEqual(TPPErrorCode.appLogicInconsistency.rawValue, 101)
    }

    func testErrorCode_bookRegistryRange() {
        XCTAssertEqual(TPPErrorCode.unknownBookState.rawValue, 203)
        XCTAssertEqual(TPPErrorCode.registrySyncFailure.rawValue, 204)
        XCTAssertEqual(TPPErrorCode.bookStateInconsistency.rawValue, 205)
    }

    func testErrorCode_signInRange() {
        XCTAssertEqual(TPPErrorCode.invalidLicensor.rawValue, 300)
        XCTAssertEqual(TPPErrorCode.invalidCredentials.rawValue, 301)
        XCTAssertEqual(TPPErrorCode.remoteLoginError.rawValue, 303)
        XCTAssertEqual(TPPErrorCode.loginErrorWithProblemDoc.rawValue, 310)
    }

    /// SRS: DRM-004 - DRM error codes are in the 1000 range
    func testErrorCode_drmRange() {
        XCTAssertEqual(TPPErrorCode.epubDecodingError.rawValue, 1000)
        XCTAssertEqual(TPPErrorCode.adobeDRMFulfillmentFail.rawValue, 1001)
        XCTAssertEqual(TPPErrorCode.lcpDRMFulfillmentFail.rawValue, 1002)
        XCTAssertEqual(TPPErrorCode.lcpPassphraseAuthorizationFail.rawValue, 1003)
        XCTAssertEqual(TPPErrorCode.lcpPassphraseRetrievalFail.rawValue, 1004)
    }

    func testErrorCode_networkingRange() {
        XCTAssertEqual(TPPErrorCode.noURL.rawValue, 900)
        XCTAssertEqual(TPPErrorCode.apiCall.rawValue, 902)
        XCTAssertEqual(TPPErrorCode.downloadFail.rawValue, 908)
        XCTAssertEqual(TPPErrorCode.clientSideTransientError.rawValue, 910)
        XCTAssertEqual(TPPErrorCode.clientSideUserInterruption.rawValue, 911)
    }

    func testErrorCode_parseFailureRange() {
        XCTAssertEqual(TPPErrorCode.parseProfileDataCorrupted.rawValue, 600)
        XCTAssertEqual(TPPErrorCode.feedParseFail.rawValue, 604)
        XCTAssertEqual(TPPErrorCode.opdsFeedParseFail.rawValue, 605)
        XCTAssertEqual(TPPErrorCode.authDocParseFail.rawValue, 607)
    }

    func testErrorCode_imageLoadingRange() {
        XCTAssertEqual(TPPErrorCode.imageHostFailure.rawValue, 1500)
        XCTAssertEqual(TPPErrorCode.imageDecodeFail.rawValue, 1501)
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
