//
//  DisplayStrings.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

struct DisplayStrings {
  struct Generic {
    static let back = NSLocalizedString("Back", comment: "Text for Back button")
    static let more = NSLocalizedString("More...", comment: "").localized
    static let error = NSLocalizedString("Error", comment: "").localized
    static let ok = NSLocalizedString("OK", comment: "").localized
    static let cancel = NSLocalizedString("Cancel", comment: "Button that says to cancel and go back to the last screen.")
    static let reload = NSLocalizedString("Reload", comment: "Button that says to try again")
    static let delete = NSLocalizedString("Delete", comment:"")
  }

  struct Settings {
    static let settings = NSLocalizedString("Settings", comment: "").localized
    static let libraries = NSLocalizedString("Libraries", comment: "A title for a list of libraries the user may select or add to.").localized
    static let addLibrary = NSLocalizedString("Add Library", comment: "Title of button to add a new library").localized
    static let aboutApp = NSLocalizedString("AboutApp", comment: "").localized
    static let softwareLicenses = NSLocalizedString("SoftwareLicenses", comment: "").localized
    static let privacyPolicy = NSLocalizedString("PrivacyPolicy", comment: "").localized
    static let eula = NSLocalizedString("EULA", comment: "").localized
    static let developerSettings = NSLocalizedString("Testing", comment: "Developer Settings").localized
  }

  struct Error {
    static let loadFailedError = NSLocalizedString("The page could not load due to a conection error.", comment: "").localized
    static let unknownRequestError = NSLocalizedString("UnknownRequestError", comment: "A generic error message for when a network request fails").localized
    static let connectionFailed = NSLocalizedString(
      "Connection Failed",
      comment: "Title for alert that explains that the page could not download the information").localized
    static let syncSettingChangeErrorTitle = NSLocalizedString("Error Changing Sync Setting", comment: "").localized
    static let syncSettingsChangeErrorBody = NSLocalizedString("There was a problem contacting the server.\nPlease make sure you are connected to the internet, or try again later.", comment: "").localized
    static let invalidBookError = NSLocalizedString("The book you were trying to open is invalid.", comment: "Error message used when trying to import a publication that is not valid").localized
    static let openFailedError = NSLocalizedString("An error was encountered while trying to open this book.", comment: "Error message used when a low-level error occured while opening a publication").localized
    static let formatNotSupportedError = NSLocalizedString("The book you were trying to read is in an unsupported format.", comment: "Error message when trying to read a publication with a unsupported format").localized
    static let epubNotValidError = NSLocalizedString("The book you were trying to read is corrupted. Please try downloading it again.", comment: "Error message when trying to read an EPUB that is invalid")
  }
  
  struct AgeCheck {
    static let title = NSLocalizedString("Age Verification", comment: "Title for Age Verification").localized
    static let titleLabel = NSLocalizedString("Please enter your birth year", comment: "Caption for asking user to enter their birth year").localized
    static let done =  NSLocalizedString("Done", comment: "Button title for hiding picker view").localized
    static let placeholderString = NSLocalizedString("Select Year", comment: "Placeholder for birth year textfield").localized
    static let rightBarButtonItem = NSLocalizedString("Next", comment: "Button title for completing age verification").localized
  }
  
  struct Announcments {
    static let alertTitle = NSLocalizedString("Announcement", comment: "").localized
    static let ok = NSLocalizedString("Announcement", comment: "").localized
  }
  
  struct UserNotifications {
    static let downloadReady = NSLocalizedString("Ready for Download", comment: "").localized
    static let checkoutTitle = NSLocalizedString("Check Out", comment: "").localized
  }
  
  struct ReturnPromptHelper {
    static let audiobookPromptTitle = NSLocalizedString("Your Audiobook Has Finished", comment: "").localized
    static let audiobookPromptMessage = NSLocalizedString("Would you like to return it?", comment: "").localized
    static let keepActionAlertTitle = NSLocalizedString("Keep",
                                                        comment: "Button title for keeping an audiobook").localized
    static let returnActionTitle = NSLocalizedString("Keep",
                                                     comment: "Button title for keeping an audiobook").localized
  }
  
  struct TPPBook {
    static let epubContentType = NSLocalizedString("ePub", comment: "ePub").localized
    static let pdfContentType = NSLocalizedString("PDF", comment: "PDF").localized
    static let audiobookContentType = NSLocalizedString("Audiobook", comment: "Audiobook").localized
    static let unsupportedContentType = NSLocalizedString("Unsupported format", comment: "Unsupported format").localized
  }
  
  struct TPPProblemDocument {
    static let authenticationExpiredTitle = NSLocalizedString("Authentication Expired",
                                                              comment: "Title for an error related to expired credentials").localized
    static let authenticationExpiredBody = NSLocalizedString("Your authentication details have expired. Please sign in again.",
                                                             comment: "Message to prompt user to re-authenticate").localized
    static let authenticationRequiredTitle =  NSLocalizedString("Authentication Required",
                                                                comment: "Title for an error related to credentials being required").localized
    static let authenticationRequireBody = NSLocalizedString("Your authentication details have expired. Please sign in again.",
                                                             comment: "Message to prompt user to re-authenticate").localized
  }
  
  struct ProblemReportEmail {
    static let noAccountSetupTitle = NSLocalizedString("NoEmailAccountSet", comment: "Alert title").localized
    static let reportSentTitle = NSLocalizedString("Thank You", comment: "Alert title").localized
    static let reportSentBody = NSLocalizedString("Your report will be reviewed as soon as possible.", comment: "Alert message").localized
  }

  struct TPPReaderFont {
    static let original = NSLocalizedString("OriginalFont", comment: "OriginalFont").localized
    static let sans = NSLocalizedString("SansFont", comment: "SansFont").localized
    static let serif = NSLocalizedString("SerifFont", comment: "SerifFont").localized
    static let dyslexic = NSLocalizedString("OpenDyslexicFont", comment: "OpenDyslexicFont").localized
  }
  
  struct TPPReaderAppearance {
    static let blackOnWhiteText = NSLocalizedString("OpenDyslexicFont", comment: "OpenDyslexicFont").localized
    static let blackOnSepiaText = NSLocalizedString("BlackOnSepiaText", comment: "BlackOnSepiaText").localized
    static let whiteOnBlackText = NSLocalizedString("WhiteOnBlackText", comment: "WhiteOnBlackText").localized
  }
  
  struct TPPLastReadPositionSynchronizer {
    static let syncReadingPositionAlertTitle = NSLocalizedString("Sync Reading Position", comment: "An alert title notifying the user the reading position has been synced").localized
    static let syncReadingPositionAlertBody = NSLocalizedString("Do you want to move to the page on which you left off?", comment: "An alert message asking the user to perform navigation to the synced reading position or not").localized
    static let stay = NSLocalizedString("Stay", comment: "Do not perform navigation").localized
    static let move = NSLocalizedString("Move", comment: "Perform navigation").localized
  }
  
  struct TPPReaderTOCBusinessLogic {
    static let tocDisplayTitle = NSLocalizedString("ReaderTOCViewControllerTitle", comment: "Title for Table of Contents in eReader").localized
  }
  
  struct TPPReaderBookmarksBusinessLogic {
    static let noBookmarks = NSLocalizedString("There are no bookmarks for this book.", comment: "Text showing in bookmarks view when there are no bookmarks").localized
  }
  
  struct TPPBaseReaderViewController {
    static let tocAndBookmarks = NSLocalizedString("Table of contents and bookmarks", comment: "Table of contents and bookmarks").localized
    static let removeBookmark = NSLocalizedString("Remove Bookmark",
                                                  comment: "Accessibility label for button to remove a bookmark").localized
    static let addBookmark = NSLocalizedString("Add Bookmark",
                                               comment: "Accessibility label for button to add a bookmark")
    static let previousChapter = NSLocalizedString("Previous Chapter", comment: "Accessibility label to go backward in the publication").localized
    static let nextChapter = NSLocalizedString("Next Chapter", comment: "Accessibility label to go forward in the publication").localized
  }
  
  struct TPPEPUBViewController {
    static let readerSettings = NSLocalizedString("Reader settings", comment: "Reader settings").localized
  }
  
  struct TPPBarCode {
    static let cameraAccessDisabledTitle = NSLocalizedString("Camera Access Disabled",
                                                        comment: "An alert title stating the user has disallowed the app to access the user's location").localized
    static let cameraAccessDisabledBody = NSLocalizedString(
      ("You must enable camera access for this application " +
        "in order to sign up for a library card."),
      comment: "An alert message informing the user that camera access is required").localized
    static let openSettings = NSLocalizedString("Open Settings",
                                                comment: "A title for a button that will open the Settings app").localized
  }
  
  struct TPPDeveloperSettingsTableViewController {
    static let developerSettingsTitle = NSLocalizedString("Testing", comment: "Developer Settings").localized
  }
  
  struct TPPSettingsAdvancedViewController {
    static let advanced = NSLocalizedString("Advanced", comment: "").localized
    static let pleaseWait = NSLocalizedString("Please wait...", comment:"Generic Wait message").localized
    static let deleteServerData = NSLocalizedString("Delete Server Data", comment:"").localized
  }
}
