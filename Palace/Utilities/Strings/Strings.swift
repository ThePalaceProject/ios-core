//
//  DisplayStrings.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

struct Strings {
  struct AgeCheck {
    static let title = "Age Verification".localized
    static let titleLabel = "Please enter your birth year".localized
    static let done =  "Done".localized
    static let placeholderString = "Select Year".localized
    static let rightBarButtonItem = "Next".localized
  }
  
  struct Announcments {
    static let alertTitle = "Announcement".localized
    static let ok = "Announcement".localized
  }
  
  struct Error {
    static let loadFailedError = "The page could not load due to a conection error.".localized
    static let unknownRequestError = "UnknownRequestError".localized
    static let connectionFailed = "Connection Failed".localized
    static let syncSettingChangeErrorTitle = "Error Changing Sync Setting".localized
    static let syncSettingsChangeErrorBody = "There was a problem contacting the server.\nPlease make sure you are connected to the internet, or try again later.".localized
    static let invalidBookError = "The book you were trying to open is invalid.".localized
    static let openFailedError = "An error was encountered while trying to open this book.".localized
    static let formatNotSupportedError = "The book you were trying to read is in an unsupported format.".localized
    static let epubNotValidError = "The book you were trying to read is corrupted. Please try downloading it again.".localized
    static let pageLoadFailedError = "The page could not load due to a connection error.".localized
    static let serverConnectionErrorDescription = "Unable to contact the server because the URL for signing in is missing.".localized
    static let serverConnectionErrorSuggestion = "Try force-quitting the app and repeat the sign-in process.".localized
    static let cardCreationError = "We're sorry. Currently we do not support signups for new patrons via the app.".localized
    static let signInErrorTitle = "Sign In Error".localized
    static let signInErrorDescription = "The DRM Library is taking longer than expected. Please wait and try again later.\n\nIf the problem persists, try to sign out and back in again from the Library Settings menu.".localized
    static let loginErrorTitle = "SettingsAccountViewControllerLoginFailed".localized
    static let loginErrorDescription = "An error occurred during the authentication process".localized
  }
  
  struct Generic {
    static let back = "Back".localized
    static let more = "More...".localized
    static let error = "Error".localized
    static let ok = "OK".localized
    static let cancel = "Cancel".localized
    static let reload = "Reload".localized
    static let delete = "Delete".localized
    static let wait = "Wait".localized
    static let reject = "Reject".localized
    static let accept = "Accept".localized
    static let signin = "Sign In".localized
    static let close = "Close".localized
  }
  
  struct OETutorialChoiceViewController {
    static let loginMessage = "You need to login to access the collection.".localized
    static let requestNewCodes = "Request New Codes".localized
  }
  
  struct OETutorialEligibilityViewController {
    static let description = "Open eBooks provides free books to the children who need them the most.\n\nThe collection includes thousands of popular and award-winning titles as well as hundreds of public domain works.".localized
  }
  
  struct OETutorialWelcomeViewController {
    static let description = "Welcome to Open eBooks".localized
  }
  
  struct ProblemReportEmail {
    static let noAccountSetupTitle = "NoEmailAccountSet".localized
    static let reportSentTitle = "Thank You".localized
    static let reportSentBody = "Your report will be reviewed as soon as possible.".localized
  }
  
  struct ReturnPromptHelper {
    static let audiobookPromptTitle = "Your Audiobook Has Finished".localized
    static let audiobookPromptMessage = "Would you like to return it?".localized
    static let keepActionAlertTitle = "Keep".localized
    static let returnActionTitle = "Keep".localized
  }
  
  struct Settings {
    static let settings = "Settings".localized
    static let libraries = "Libraries".localized
    static let addLibrary = "Add Library".localized
    static let aboutApp = "AboutApp".localized
    static let softwareLicenses = "SoftwareLicenses".localized
    static let privacyPolicy = "PrivacyPolicy".localized
    static let eula = "EULA".localized
    static let developerSettings = "Testing".localized
  }
  
  struct TPPAccountListDataSource {
    static let addLibrary = "Add Library".localized
  }
  
  struct TPPBaseReaderViewController {
    static let tocAndBookmarks = "Table of contents and bookmarks".localized
    static let removeBookmark = "Remove Bookmark".localized
    static let addBookmark = "Add Bookmark".localized
    static let previousChapter = "Previous Chapter".localized
    static let nextChapter = "Next Chapter".localized
  }
  
  struct TPPBarCode {
    static let cameraAccessDisabledTitle = "Camera Access Disabled".localized
    static let cameraAccessDisabledBody = "You must enable camera access for this application in order to sign up for a library card.".localized
    static let openSettings = "Open Settings".localized
  }
  
  struct TPPBook {
    static let epubContentType = "ePub".localized
    static let pdfContentType = "PDF".localized
    static let audiobookContentType = "Audiobook".localized
    static let unsupportedContentType = "Unsupported format".localized
  }
  
  struct TPPDeveloperSettingsTableViewController {
    static let developerSettingsTitle = "Testing".localized
  }
  
  struct TPPEPUBViewController {
    static let readerSettings = "Reader settings".localized
  }
  
  struct TPPLastReadPositionSynchronizer {
    static let syncReadingPositionAlertTitle = "Sync Reading Position".localized
    static let syncReadingPositionAlertBody = "Do you want to move to the page on which you left off?".localized
    static let stay = "Stay".localized
    static let move = "Move".localized
  }
  
  struct TPPProblemDocument {
    static let authenticationExpiredTitle = "Authentication Expired".localized
    static let authenticationExpiredBody = "Your authentication details have expired. Please sign in again.".localized
    static let authenticationRequiredTitle =  "Authentication Required".localized
    static let authenticationRequireBody = "Your authentication details have expired. Please sign in again.".localized
  }
  
  struct TPPReaderAppearance {
    static let blackOnWhiteText = "OpenDyslexicFont".localized
    static let blackOnSepiaText = "BlackOnSepiaText".localized
    static let whiteOnBlackText = "WhiteOnBlackText".localized
  }
  
  struct TPPReaderBookmarksBusinessLogic {
    static let noBookmarks = "There are no bookmarks for this book.".localized
  }
  
  struct TPPReaderFont {
    static let original = "OriginalFont".localized
    static let sans = "SansFont".localized
    static let serif = "SerifFont".localized
    static let dyslexic = "OpenDyslexicFont".localized
  }
  
  struct TPPReaderTOCBusinessLogic {
    static let tocDisplayTitle = "ReaderTOCViewControllerTitle".localized
  }
  
  struct TPPSettingsAdvancedViewController {
    static let advanced = "Advanced".localized
    static let pleaseWait = "Please wait...".localized
    static let deleteServerData = "Delete Server Data".localized
  }
  
  struct TPPSettingsSplitViewController {
    static let account = "Account".localized
    static let acknowledgements = "Acknowledgements".localized
    static let eula = "EULA".localized
    static let privacyPolicy = "PrivacyPolicy".localized
  }
  
  struct TPPSigninBusinessLogic {
    static let ecard = "eCard".localized
    static let ecardErrorMessage = "We're sorry. Our sign up system is currently down. Please try again later.".localized
    static let signout =  "SignOut".localized
    static let annotationSyncMessage = "Your bookmarks and reading positions are in the process of being saved to the server. Would you like to stop that and continue logging out?".localized
    static let pendingDownloadMessage = "It looks like you may have a book download or return in progress. Would you like to stop that and continue logging out?".localized
  }
  
  struct TPPWelcomeScreenViewController {
    static let findYourLibrary = "Find Your Library".localized
  }
  
  struct UserNotifications {
    static let downloadReady = "Ready for Download".localized
    static let checkoutTitle = "Check Out".localized
  }
}
