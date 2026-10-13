//
//  TPPAgeCheckTests.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-03-09.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
class TPPAgeCheckTests: XCTestCase {

    // Classes/mocks needed for testing
    var ageCheckChoiceStorageMock: TPPAgeCheckChoiceStorageMock!
    var userAccountProviderMock: TPPUserAccountProviderMock!
    var simplyeLibraryAccountProviderMock: TPPCurrentLibraryAccountProviderMock!
    var ageCheck: TPPAgeCheck!
    var presenterSpy: AgeVerificationPresenterSpy!

    // TPPAgeCheck checks the property userAboveAgeLimit in AccountDetails before performing age check
    // This property is store in UserDefault which can be different value when testing on different machine
    // And AccountDetails class is final and not protocol so we cannot override/mock it
    // The workaround here is to store the value of userAboveAgeLimit and restore it after each test
    // This way we can set whatever value we need in each tests, and no need to worry about the default value on different machine
    var defaultUserAboveAgeLimit: Bool!

    // Use expectation to test result within closure
    var expectation: XCTestExpectation!

    override func setUpWithError() throws {
        try super.setUpWithError()

        ageCheckChoiceStorageMock = TPPAgeCheckChoiceStorageMock()
        simplyeLibraryAccountProviderMock = TPPCurrentLibraryAccountProviderMock()
        userAccountProviderMock = TPPUserAccountProviderMock()

        defaultUserAboveAgeLimit = simplyeLibraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit ?? false
        simplyeLibraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit = false

        // `verifyCurrentAccountAgeRequirement` awaits `Account.awaitReady()` instead of reading raw
        // `details?`. Drive the state machine to `.detailsLoaded` so the
        // awaiter resolves immediately and the existing age-logic
        // assertions still apply.
        if let account = simplyeLibraryAccountProviderMock.currentAccount,
           let details = account.details {
            account._setState(.detailsLoaded(details))
        }

        expectation = self.expectation(description: "AgeChecking")

        presenterSpy = AgeVerificationPresenterSpy()
        ageCheck = TPPAgeCheck(ageCheckChoiceStorage: ageCheckChoiceStorageMock,
                               presentAgeVerification: presenterSpy.present)
    }

    override func tearDownWithError() throws {
        simplyeLibraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit = defaultUserAboveAgeLimit
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
    }

    func testAge0() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (aboveAgeLimit) in
            XCTAssertFalse(aboveAgeLimit)
            XCTAssertTrue(self?.ageCheckChoiceStorageMock.userPresentedAgeCheck ?? false)
            self?.expectation.fulfill()
        }

        let birthYear = Calendar.current.component(.year, from: Date())
        ageCheck.didCompleteAgeCheck(birthYear)
        waitForExpectations(timeout: 1, handler: nil)
    }

    func testAge12() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (aboveAgeLimit) in
            XCTAssertFalse(aboveAgeLimit)
            XCTAssertTrue(self?.ageCheckChoiceStorageMock.userPresentedAgeCheck ?? false)
            self?.expectation.fulfill()
        }

        let birthYear = Calendar.current.component(.year, from: Date()) - 12
        ageCheck.didCompleteAgeCheck(birthYear)
        waitForExpectations(timeout: 1, handler: nil)
    }

    func testAge13() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (aboveAgeLimit) in
            XCTAssertFalse(aboveAgeLimit)
            XCTAssertTrue(self?.ageCheckChoiceStorageMock.userPresentedAgeCheck ?? false)
            self?.expectation.fulfill()
        }

        let birthYear = Calendar.current.component(.year, from: Date()) - 13
        ageCheck.didCompleteAgeCheck(birthYear)
        waitForExpectations(timeout: 1, handler: nil)
    }

    func testAge14() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (aboveAgeLimit) in
            XCTAssertTrue(aboveAgeLimit)
            XCTAssertTrue(self?.ageCheckChoiceStorageMock.userPresentedAgeCheck ?? false)
            self?.expectation.fulfill()
        }

        let birthYear = Calendar.current.component(.year, from: Date()) - 20
        ageCheck.didCompleteAgeCheck(birthYear)
        waitForExpectations(timeout: 1, handler: nil)
    }

    /// The age-check screen goes through the injected presenter, wrapped in a
    /// navigation controller, so tests never put it on the host window.
    func testVerify_WhenAgeNotYetChecked_PresentsAgeCheckScreenThroughPresenter() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] _ in
            self?.expectation.fulfill()
        }
        ageCheck.flushPendingForTests()
        drainMainQueue()

        XCTAssertEqual(presenterSpy.presented.count, 1)
        let nav = try XCTUnwrap(presenterSpy.presented.first as? UINavigationController)
        XCTAssertTrue(nav.viewControllers.first is TPPAgeCheckViewController)

        ageCheck.didCompleteAgeCheck(Calendar.current.component(.year, from: Date()) - 30)
        waitForExpectations(timeout: 1, handler: nil)
    }

    /// A second request while the screen is up queues its completion rather
    /// than presenting a second screen; both completions fire once answered.
    func testVerify_WhileAlreadyPresenting_DoesNotPresentAgain() throws {
        expectation.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                        currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] _ in
                self?.expectation.fulfill()
            }
        }
        ageCheck.flushPendingForTests()
        drainMainQueue()

        XCTAssertEqual(presenterSpy.presented.count, 1)

        ageCheck.didCompleteAgeCheck(Calendar.current.component(.year, from: Date()) - 30)
        waitForExpectations(timeout: 1, handler: nil)
    }

    func testAge100() throws {
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (aboveAgeLimit) in
            XCTAssertTrue(aboveAgeLimit)
            XCTAssertTrue(self?.ageCheckChoiceStorageMock.userPresentedAgeCheck ?? false)
            self?.expectation.fulfill()
        }

        let birthYear = Calendar.current.component(.year, from: Date()) - 100
        ageCheck.didCompleteAgeCheck(birthYear)
        waitForExpectations(timeout: 1, handler: nil)
    }

    func testAgeCheckFailed() throws {
        // Use an inverted expectation to make sure the completion closure is not executed
        self.expectation.isInverted = true
        ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: userAccountProviderMock,
                                                    currentLibraryAccountProvider: simplyeLibraryAccountProviderMock) { [weak self] (_) in
            self?.expectation.fulfill()
        }

        ageCheck.didFailAgeCheck()
        waitForExpectations(timeout: 1, handler: nil)

        // Completion must not have been called after a failed age check
        XCTAssertFalse(ageCheckChoiceStorageMock.userPresentedAgeCheck,
                       "userPresentedAgeCheck should remain false after a failed age check")
        // The age-limit flag on the account should not be set to true when age check fails
        let userAboveAgeLimit = simplyeLibraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit ?? false
        XCTAssertFalse(userAboveAgeLimit,
                       "userAboveAgeLimit should not be set to true when age check fails")
    }
}
