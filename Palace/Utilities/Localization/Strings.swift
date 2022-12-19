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
    static let title = NSLocalizedString("Age Verification", comment: "Title for Age Verification")
    static let titleLabel = NSLocalizedString("Please enter your birth year", comment: "Caption for asking user to enter their birth year")
    static let done =  NSLocalizedString("Done", comment: "Button title for hiding picker view")
    static let placeholderString = NSLocalizedString("Select Year", comment: "Placeholder for birth year textfield")
    static let rightBarButtonItem = NSLocalizedString("Next", comment: "Button title for completing age verification")
  }
  
  struct Announcments {
    static let alertTitle = NSLocalizedString("Announcement", comment: "")
    static let ok = NSLocalizedString("Announcement", comment: "")
  }

  struct Error {
    static let loadFailedError = NSLocalizedString("The page could not load due to a conection error.", comment: "")
    static let unknownRequestError = NSLocalizedString("An unknown error occurred. Please check your connection or try again later.", comment: "A generic error message for when a network request fails")
    static let connectionFailed = NSLocalizedString(
      "Connection Failed",
      comment: "Title for alert that explains that the page could not download the information")
    static let syncSettingChangeErrorTitle = NSLocalizedString("Error Changing Sync Setting", comment: "")
    static let syncSettingsChangeErrorBody = NSLocalizedString("There was a problem contacting the server.\nPlease make sure you are connected to the internet, or try again later.", comment: "")
    static let invalidBookError = NSLocalizedString("The book you were trying to open is invalid.", comment: "Error message used when trying to import a publication that is not valid")
    static let openFailedError = NSLocalizedString("An error was encountered while trying to open this book.", comment: "Error message used when a low-level error occured while opening a publication")
    static let formatNotSupportedError = NSLocalizedString("The book you were trying to read is in an unsupported format.", comment: "Error message when trying to read a publication with a unsupported format")
    static let epubNotValidError = NSLocalizedString("The book you were trying to read is corrupted. Please try downloading it again.", comment: "Error message when trying to read an EPUB that is invalid")
    static let pageLoadFailedError = NSLocalizedString("The page could not load due to a connection error.", comment: "")
    static let serverConnectionErrorDescription = NSLocalizedString("Unable to contact the server because the URL for signing in is missing.",
                                                                    comment: "Error message for when the library profile url is missing from the authentication document the server provided.")
    static let serverConnectionErrorSuggestion = NSLocalizedString("Try force-quitting the app and repeat the sign-in process.",
                                                                   comment: "Recovery instructions for when the URL to sign in is missing")
    static let cardCreationError = NSLocalizedString("We're sorry. Currently we do not support signups for new patrons via the app.", comment: "Message describing the fact that new patron sign up is not supported by the current selected library")
    static let signInErrorTitle = NSLocalizedString("Sign In Error",
                                                    comment: "Title for sign in error alert")
    static let signInErrorDescription = NSLocalizedString("The DRM Library is taking longer than expected. Please wait and try again later.\n\nIf the problem persists, try to sign out and back in again from the Library Settings menu.",
                                                          comment: "Message for sign-in error alert caused by failed DRM authorization")
    static let loginErrorTitle = NSLocalizedString("Login Failed", comment: "Title for login error alert")
    static let loginErrorDescription = NSLocalizedString("An error occurred during the authentication process",
                                                         comment: "Generic error message while handling sign-in redirection during authentication")
  }
  
  struct Generic {
    static let back = NSLocalizedString("Back", comment: "Text for Back button")
    static let more = NSLocalizedString("More...", comment: "")
    static let error = NSLocalizedString("Error", comment: "")
    static let ok = NSLocalizedString("OK", comment: "")
    static let cancel = NSLocalizedString("Cancel", comment: "Button that says to cancel and go back to the last screen.")
    static let reload = NSLocalizedString("Reload", comment: "Button that says to try again")
    static let delete = NSLocalizedString("Delete", comment:"")
    static let wait = NSLocalizedString("Wait", comment: "button title")
    static let reject = NSLocalizedString("Reject", comment: "Title for a Reject button")
    static let accept = NSLocalizedString("Accept", comment: "Title for a Accept button")
    static let signin = NSLocalizedString("Sign in", comment: "")
    static let close = NSLocalizedString("Close", comment: "")
  }
  
  struct OETutorialChoiceViewController {
    static let loginMessage = NSLocalizedString("You need to login to access the collection.", comment: "")
    static let requestNewCodes = NSLocalizedString("Request New Codes", comment: "")
  }
  
  struct OETutorialEligibilityViewController {
    static let description = NSLocalizedString("Open eBooks provides free books to the children who need them the most.\n\nThe collection includes thousands of popular and award-winning titles as well as hundreds of public domain works.", comment: "Description of Open eBooks app displayed during 1st launch tutorial")
  }
  
  struct OETutorialWelcomeViewController {
    static let description = NSLocalizedString("Welcome to Open eBooks",
                                               comment: "Welcome text")
  }
  
  struct ProblemReportEmail {
    static let noAccountSetupTitle = NSLocalizedString("No email account is set for this device.", comment: "Alert title")
    static let reportSentTitle = NSLocalizedString("Thank You", comment: "Alert title")
    static let reportSentBody = NSLocalizedString("Your report will be reviewed as soon as possible.", comment: "Alert message")
  }
  
  struct ReturnPromptHelper {
    static let audiobookPromptTitle = NSLocalizedString("Your Audiobook Has Finished", comment: "")
    static let audiobookPromptMessage = NSLocalizedString("Would you like to return it?", comment: "")
    static let keepActionAlertTitle = NSLocalizedString("Keep",
                                                        comment: "Button title for keeping an audiobook")
    static let returnActionTitle = NSLocalizedString("Return",
                                                     comment: "Button title for keeping an audiobook")
  }
  
  struct Settings {
    static let settings = NSLocalizedString("Settings", comment: "")
    static let libraries = NSLocalizedString("Libraries", comment: "A title for a list of libraries the user may select or add to.")
    static let addLibrary = NSLocalizedString("Add Library", comment: "Title of button to add a new library")
    static let aboutApp = NSLocalizedString("About App", comment: "")
    static let softwareLicenses = NSLocalizedString("Software Licenses", comment: "")
    static let privacyPolicy = NSLocalizedString("Privacy Policy", comment: "")
    static let eula = NSLocalizedString("User Agreement", comment: "")
    static let developerSettings = NSLocalizedString("Testing", comment: "Developer Settings")
  }
  
  struct TPPAccountListDataSource {
    static let addLibrary = NSLocalizedString("Add Library", comment: "Title that also informs the user that they should choose a library from the list.")
  }
  
  struct TPPBaseReaderViewController {
    static let tocAndBookmarks = NSLocalizedString("Table of contents and bookmarks", comment: "Table of contents and bookmarks")
    static let removeBookmark = NSLocalizedString("Remove Bookmark",
                                                  comment: "Accessibility label for button to remove a bookmark")
    static let addBookmark = NSLocalizedString("Add Bookmark",
                                               comment: "Accessibility label for button to add a bookmark")
    static let previousChapter = NSLocalizedString("Previous Chapter", comment: "Accessibility label to go backward in the publication")
    static let nextChapter = NSLocalizedString("Next Chapter", comment: "Accessibility label to go forward in the publication")
  }
  
  struct TPPBarCode {
    static let cameraAccessDisabledTitle = NSLocalizedString("Camera Access Disabled",
                                                             comment: "An alert title stating the user has disallowed the app to access the user's location")
    static let cameraAccessDisabledBody = NSLocalizedString(
      ("You must enable camera access for this application " +
       "in order to sign up for a library card."),
      comment: "An alert message informing the user that camera access is required")
    static let openSettings = NSLocalizedString("Open Settings",
                                                comment: "A title for a button that will open the Settings app")
  }
  
  struct TPPBook {
    static let epubContentType = NSLocalizedString("ePub", comment: "ePub")
    static let pdfContentType = NSLocalizedString("PDF", comment: "PDF")
    static let audiobookContentType = NSLocalizedString("Audiobook", comment: "Audiobook")
    static let unsupportedContentType = NSLocalizedString("Unsupported format", comment: "Unsupported format")
  }
  
  struct TPPPDFNavigation {
    static let resume = NSLocalizedString("Resume", comment: "A button to continue reading title.")
  }
  
  struct TPPDeveloperSettingsTableViewController {
    static let developerSettingsTitle = NSLocalizedString("Testing", comment: "Developer Settings")
  }
  
  struct TPPEPUBViewController {
    static let readerSettings = NSLocalizedString("Reader settings", comment: "Reader settings")
  }
  
  struct TPPLastReadPositionSynchronizer {
    static let syncReadingPositionAlertTitle = NSLocalizedString("Sync Reading Position", comment: "An alert title notifying the user the reading position has been synced")
    static let syncReadingPositionAlertBody = NSLocalizedString("Do you want to move to the page on which you left off?", comment: "An alert message asking the user to perform navigation to the synced reading position or not")
    static let stay = NSLocalizedString("Stay", comment: "Do not perform navigation")
    static let move = NSLocalizedString("Move", comment: "Perform navigation")
  }
  
  struct TPPProblemDocument {
    static let authenticationExpiredTitle = NSLocalizedString("Authentication Expired",
                                                              comment: "Title for an error related to expired credentials")
    static let authenticationExpiredBody = NSLocalizedString("Your authentication details have expired. Please sign in again.",
                                                             comment: "Message to prompt user to re-authenticate")
    static let authenticationRequiredTitle =  NSLocalizedString("Authentication Required",
                                                                comment: "Title for an error related to credentials being required")
    static let authenticationRequireBody = NSLocalizedString("Your authentication details have expired. Please sign in again.",
                                                             comment: "Message to prompt user to re-authenticate")
  }
  
  struct TPPReaderAppearance {
    static let blackOnWhiteText = NSLocalizedString("Open dyslexic font", comment: "OpenDyslexicFont")
    static let blackOnSepiaText = NSLocalizedString("Black on sepia text", comment: "BlackOnSepiaText")
    static let whiteOnBlackText = NSLocalizedString("White on black text", comment: "WhiteOnBlackText")
  }
  
  struct TPPReaderBookmarksBusinessLogic {
    static let noBookmarks = NSLocalizedString("There are no bookmarks for this book.", comment: "Text showing in bookmarks view when there are no bookmarks")
  }
  
  struct TPPReaderFont {
    static let original = NSLocalizedString("Default book font", comment: "OriginalFont")
    static let sans = NSLocalizedString("Sans font", comment: "SansFont")
    static let serif = NSLocalizedString("Serif font", comment: "SerifFont")
    static let dyslexic = NSLocalizedString("Open dyslexic font", comment: "OpenDyslexicFont")
  }
  
  struct TPPReaderTOCBusinessLogic {
    static let tocDisplayTitle = NSLocalizedString("Table of Contents", comment: "Title for Table of Contents in eReader")
  }
  
  struct TPPSettingsAdvancedViewController {
    static let advanced = NSLocalizedString("Advanced", comment: "")
    static let pleaseWait = NSLocalizedString("Please wait...", comment:"Generic Wait message")
    static let deleteServerData = NSLocalizedString("Delete Server Data", comment:"")
  }
  
  struct TPPSettingsSplitViewController {
    static let account = NSLocalizedString("Account", comment: "Title for account section")
    static let acknowledgements = NSLocalizedString("Acknowledgements", comment: "Title for acknowledgements section")
    static let eula = NSLocalizedString("User Agreement", comment: "Title for User Agreement section")
    static let privacyPolicy = NSLocalizedString("Privacy Policy", comment: "Title for Privacy Policy section")
  }
  
  struct TPPSigninBusinessLogic {
    static let ecard = NSLocalizedString("eCard",
                                         comment: "Title for web-based card creator page")
    static let ecardErrorMessage = NSLocalizedString("We're sorry. Our sign up system is currently down. Please try again later.",
                                                     comment: "Message for error loading the web-based card creator")
    static let signout =  NSLocalizedString("Sign out",
                                            comment: "Title for sign out action")
    static let annotationSyncMessage = NSLocalizedString("Your bookmarks and reading positions are in the process of being saved to the server. Would you like to stop that and continue logging out?",
                                                         comment: "Warning message offering the user the choice of interrupting book registry syncing to log out immediately, or waiting until that finishes.")
    static let pendingDownloadMessage = NSLocalizedString("It looks like you may have a book download or return in progress. Would you like to stop that and continue logging out?",
                                                          comment: "Warning message offering the user the choice of interrupting the download or return of a book to log out immediately, or waiting until that finishes.")
  }
  
  struct TPPWelcomeScreenViewController {
    static let findYourLibrary = NSLocalizedString("Find Your Library", comment: "Button that lets user know they can select a library they have a card for")
  }
  
  struct UserNotifications {
    static let downloadReady = NSLocalizedString("Ready for Download", comment: "")
    static let checkoutTitle = NSLocalizedString("Check Out", comment: "")
  }
}
