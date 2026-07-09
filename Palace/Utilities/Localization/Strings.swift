//
//  DisplayStrings.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog

struct Strings {

    struct Accessibility {
        static let navigationTitle = "navigationTitle"
        static let librarySwitchButton = "librarySwitchButton"
        static let viewBookmarksAndTocButton = "viewBookmarksAndTocButton"
        // PP-4326: VoiceOver hint announced after the book row's canonical
        // "Title, by Author" label so users hear what activating the row does.
        static let opensBookDetails = NSLocalizedString(
            "Opens book details",
            comment: "VoiceOver hint for the tap target on a book row in search results, More…, My Books, and Holds — announced after 'Title, by Author' to explain that activating the row opens the Book Details screen."
        )
    }

    struct AgeCheck {
        static let title = NSLocalizedString("Age Verification", comment: "Title for Age Verification")
        static let titleLabel = NSLocalizedString("Please enter your birth year", comment: "Caption for asking user to enter their birth year")
        static let done =  NSLocalizedString("Done", comment: "Button title for hiding picker view")
        static let placeholderString = NSLocalizedString("Select Year", comment: "Placeholder for birth year textfield")
        static let rightBarButtonItem = NSLocalizedString("Next", comment: "Button title for completing age verification")
    }

    struct CatalogContinueRows {
        static let continueListeningTitle = NSLocalizedString(
            "Continue Listening",
            comment: "Title above the Catalog hero row that resumes the active audiobook session."
        )
        static let continueReadingTitle = NSLocalizedString(
            "Continue Reading",
            comment: "Title above the Catalog hero row that resumes the most-recent in-progress ebook."
        )
        static let continueListeningHint = NSLocalizedString(
            "Opens the audiobook player.",
            comment: "VoiceOver hint for the Continue Listening row card; activating it expands the audiobook player."
        )
        static let continueReadingHint = NSLocalizedString(
            "Opens the book at your last position.",
            comment: "VoiceOver hint for the Continue Reading row card; activating it opens the reader at the saved position."
        )
        static let currentlyPlaying = NSLocalizedString(
            "currently playing",
            comment: "VoiceOver fragment appended to a Continue Listening row card when the audiobook is actively playing."
        )
        static let continueHeader = NSLocalizedString(
            "Continue",
            comment: "Polish-phase: collapsible single-row title above the most-recent Continue Reading/Listening item on the Catalog top."
        )
        static let expandHint = NSLocalizedString(
            "Expands to show the most recent book.",
            comment: "VoiceOver hint for the Continue section header when collapsed."
        )
        static let collapseHint = NSLocalizedString(
            "Collapses the Continue section.",
            comment: "VoiceOver hint for the Continue section header when expanded."
        )
        static func byAuthor(_ author: String) -> String {
            String(
                format: NSLocalizedString(
                    "by %@",
                    comment: "VoiceOver fragment '%@' is an author name — used in Continue Listening / Continue Reading card labels."
                ),
                author
            )
        }
    }

    struct Announcments {
        static let alertTitle = NSLocalizedString("Announcement", comment: "")
        static let ok = NSLocalizedString("OK", comment: "Button to dismiss announcement alert")
    }

    struct Error {
        static let loginFailedErrorTitle = NSLocalizedString("Login Failed", comment: "")
        static let loadFailedError = NSLocalizedString("The page could not load due to a conection error.", comment: "")
        static let invalidCredentialsErrorTitle = NSLocalizedString("Invalid Credentials", comment: "")
        static let invalidCredentialsErrorMessage = NSLocalizedString("Please check your username and password and try again.", comment: "")
        static let networkUnavailableErrorTitle = NSLocalizedString("No Internet Connection", comment: "Title shown when sign-in fails because the device lost connectivity")
        static let networkUnavailableErrorMessage = NSLocalizedString("Check your connection and try again.", comment: "Message shown when sign-in fails because the device lost connectivity")
        static let sessionExpiredTitle = NSLocalizedString("Session Expired", comment: "Title for session expired alert")
        static let sessionExpiredMessage = NSLocalizedString("Your session has expired. Please sign in again to continue.", comment: "Message explaining that the user's session has expired")
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
        static let userDeniedLocationAccess = NSLocalizedString("User denied location access. Go to system settings to enable location access for the Palace App.", comment: "Error message shown to user when location services are denied.")
        static let uknownLocationError = NSLocalizedString("Unkown error occurred. Please try again.", comment: "Error message shown to user when an unknown location error occurs.")
        static let locationFetchFailed = NSLocalizedString("Failed to get current location. Please try again.", comment: "Error message shown to user when CoreLocation does not return the current location.")
        static let tryAgain = NSLocalizedString("Please try again later.", comment: "Error message to please try again.")
    }

    struct Generic {
        static let back = NSLocalizedString("Back", comment: "Text for Back button")
        static let more = NSLocalizedString("More...", comment: "")
        static let error = NSLocalizedString("Error", comment: "")
        static let ok = NSLocalizedString("OK", comment: "")
        static let cancel = NSLocalizedString("Cancel", comment: "Button that says to cancel and go back to the last screen.")
        static let reload = NSLocalizedString("Reload", comment: "Button that says to try again")
        static let delete = NSLocalizedString("Delete", comment: "")
        static let wait = NSLocalizedString("Wait", comment: "button title")
        static let reject = NSLocalizedString("Reject", comment: "Title for a Reject button")
        static let accept = NSLocalizedString("Accept", comment: "Title for a Accept button")
        static let signin = NSLocalizedString("Sign in", comment: "")
        static let close = NSLocalizedString("Close", comment: "Title for close button")
        static let yes = NSLocalizedString("Yes", comment: "Affirmative answer in a confirmation prompt.")
        static let no = NSLocalizedString("No", comment: "Negative answer in a confirmation prompt.")
        static let search = NSLocalizedString("Search", comment: "Placeholder for Search Field")
        static let done =  NSLocalizedString("Done", comment: "Title for Done button")
        static let clear = NSLocalizedString("Clear", comment: "Button to clear selection")

        // Accessibility - General
        static let audiobook = NSLocalizedString("Audiobook", comment: "VoiceOver: Indicates the book is an audiobook")
        static let ebook = NSLocalizedString("Ebook", comment: "VoiceOver: Indicates the book is an ebook (used by polish-phase Continue row).")
        static let switchLibrary = NSLocalizedString("Switch Library", comment: "VoiceOver: Button to switch between libraries")
        static let selected = NSLocalizedString("Selected", comment: "VoiceOver: Indicates an item is currently selected (e.g. the active library in Settings).")
        static let searchBooks = NSLocalizedString("Search Books", comment: "VoiceOver: Button to search for books")
        static let searchCatalog = NSLocalizedString("Search Catalog", comment: "VoiceOver: Button to search the catalog")
        static let scanBarcode = NSLocalizedString("Scan Barcode", comment: "VoiceOver: Button to scan library card barcode")

        // Accessibility - Search Actions
        static let clearSearch = NSLocalizedString("Clear search", comment: "VoiceOver: Button to clear search text")
        static let goBack = NSLocalizedString("Go back", comment: "VoiceOver: Button to navigate back")

        // Accessibility - Sort/Filter
        static let sortByFormat = NSLocalizedString("Sort by %@", comment: "VoiceOver: Current sort option, e.g. 'Sort by Title'")
        static let filterWithCount = NSLocalizedString("Filter, %d applied", comment: "VoiceOver: Filter button showing count of applied filters")
        static let filter = NSLocalizedString("Filter", comment: "VoiceOver: Filter button with no filters applied")

        // Accessibility - Catalog
        static let moreBooksInLane = NSLocalizedString("More books in %@", comment: "VoiceOver: See more books in a catalog lane")
        static let horizontalLaneHint = NSLocalizedString("Swipe horizontally to browse. Double tap to open a book.", comment: "VoiceOver: Hint for horizontal book lanes")
        static let catalogRegion = NSLocalizedString("Catalog", comment: "VoiceOver: Label for main catalog / browse region")
        static let catalogFilter = NSLocalizedString("Filter by format", comment: "VoiceOver: Label for the catalog format filter (All, Ebooks, Audiobooks)")
        static let booksListLabel = NSLocalizedString("Books list", comment: "VoiceOver: Label for a list of books")
        static let expandSection = NSLocalizedString("Expand section", comment: "VoiceOver: Expand a collapsible section")
        static let collapseSection = NSLocalizedString("Collapse section", comment: "VoiceOver: Collapse an expanded section")

        // Accessibility - Reader Navigation
        static let tableOfContents = NSLocalizedString("Table of contents", comment: "VoiceOver: Open table of contents")
        static let searchInBook = NSLocalizedString("Search in book", comment: "VoiceOver: Search within the current book")
        static let pagePreviewsTab = NSLocalizedString("Page previews", comment: "VoiceOver: Show page thumbnail previews")
        static let bookmarksTab = NSLocalizedString("Bookmarks", comment: "VoiceOver: Show bookmarks list")
        static let closeSample = NSLocalizedString("Close sample", comment: "VoiceOver: Close the sample preview")

        // Accessibility - Audiobook
        static let playAudiobook = NSLocalizedString("Play", comment: "VoiceOver: Play audiobook")
        static let pauseAudiobook = NSLocalizedString("Pause", comment: "VoiceOver: Pause audiobook")
        static let skipBack30 = NSLocalizedString("Skip back 30 seconds", comment: "VoiceOver: Rewind audiobook 30 seconds")
        static let skipForward30 = NSLocalizedString("Skip forward 30 seconds", comment: "VoiceOver: Skip audiobook forward 30 seconds")
        static let dismissPlayer = NSLocalizedString("Dismiss player", comment: "VoiceOver: Done button on the full audiobook player, dismisses to the mini-player")
        // Accessibility - Audiobook mini-player (swarm_0b7616e7 Module D)
        static let nowPlayingLabelTitleAndAuthor = NSLocalizedString(
            "Now playing: %1$@ by %2$@. Double-tap to expand.",
            comment: "VoiceOver: Combined accessibility label for the audiobook mini-player, including title and author"
        )
        static let nowPlayingLabelTitleOnly = NSLocalizedString(
            "Now playing: %1$@. Double-tap to expand.",
            comment: "VoiceOver: Combined accessibility label for the audiobook mini-player when no author is available"
        )
        static let expandPlayerHint = NSLocalizedString(
            "Expands the full audiobook player",
            comment: "VoiceOver hint announced for the audiobook mini-player explaining that tapping expands the full player"
        )
        // Accessibility - Audiobook mini-player dismiss + collapse
        static let stopAudiobook = NSLocalizedString(
            "Stop audiobook",
            comment: "VoiceOver: X button on the audiobook mini-player. Stops playback, saves the position, and dismisses the player."
        )
        static let nowPlayingCompactLabel = NSLocalizedString(
            "Now playing: %@",
            comment: "VoiceOver: Accessibility label for the collapsed audiobook pill; %@ is the book title"
        )
        static let restoreAudiobookPlayerHint = NSLocalizedString(
            "Shows the full audiobook player controls",
            comment: "VoiceOver hint announced for the collapsed audiobook pill explaining that tapping restores the full mini-player"
        )
        // Accessibility - Audiobook full player (parity with toolkit AudiobookPlayerView)
        static let bookCover = NSLocalizedString("Book cover", comment: "VoiceOver: Accessibility label for the audiobook cover art")
        static let audiobookLoading = NSLocalizedString("Loading…", comment: "Shown over the audiobook player while the track buffers")
        static let audiobookLoadErrorTitle = NSLocalizedString("A problem has occurred.", comment: "Title shown when the audiobook fails to load within the timeout")
        static let audiobookLoadErrorMessage = NSLocalizedString("Please try again.", comment: "Message shown when the audiobook fails to load, prompting a retry")
        static let audiobookRetry = NSLocalizedString("Retry", comment: "Button to retry loading an audiobook that timed out")
        static let audiobookDownloading = NSLocalizedString("Downloading", comment: "Label under the audiobook download progress bar")
        static let playbackSpeed = NSLocalizedString("Playback speed", comment: "VoiceOver: Label for the audiobook playback-speed control")
        static let sleepTimer = NSLocalizedString("Sleep timer", comment: "VoiceOver: Label for the audiobook sleep-timer control")
        static let airplay = NSLocalizedString("AirPlay", comment: "VoiceOver: Label for the audiobook AirPlay route picker")
        static let addBookmark = NSLocalizedString("Add bookmark", comment: "VoiceOver: Label for the audiobook add-bookmark control")
        static let bookmarkAdded = NSLocalizedString("Bookmark added", comment: "Toast shown after successfully adding an audiobook bookmark")
        static let bookmarkAddFailed = NSLocalizedString("Could not add bookmark", comment: "Toast shown when adding an audiobook bookmark fails")
        static let playbackPosition = NSLocalizedString("Playback position", comment: "VoiceOver: Label for the audiobook seek slider")
        static let decreaseSpeed = NSLocalizedString("Decrease speed", comment: "VoiceOver: Label for the audiobook speed decrease stepper")
        static let increaseSpeed = NSLocalizedString("Increase speed", comment: "VoiceOver: Label for the audiobook speed increase stepper")
        static func timeElapsedLabel(_ time: String) -> String {
            String(format: NSLocalizedString("Time elapsed: %@", comment: "VoiceOver: audiobook chapter elapsed time, %@ is a spoken duration"), time)
        }
        static func timeRemainingLabel(_ time: String) -> String {
            String(format: NSLocalizedString("Time remaining: %@", comment: "VoiceOver: audiobook chapter remaining time, %@ is a spoken duration"), time)
        }
        static func playbackSpeedValue(_ label: String) -> String {
            String(format: NSLocalizedString("Playback speed: %@", comment: "VoiceOver: current audiobook playback speed value, %@ is a rate like 1.5x"), label)
        }

        // Accessibility - EPUB Reader (Full Keyboard Access)
        static let bookReader = NSLocalizedString("Book reader", comment: "VoiceOver: Accessibility label for the book reading area")
        static let nextPage = NSLocalizedString("Next page", comment: "Full Keyboard Access: Custom action to go to next page (Tab-Z menu)")
        static let previousPage = NSLocalizedString("Previous page", comment: "Full Keyboard Access: Custom action to go to previous page (Tab-Z menu)")
        static let toggleToolbar = NSLocalizedString("Toggle toolbar", comment: "Full Keyboard Access: Custom action to show/hide reader toolbar (Tab-Z menu)")

        // Accessibility - Book cell labels (PP-3968)
        static func bookByAuthor(title: String, author: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%1$@, by %2$@", comment: "VoiceOver: book cell label, e.g. 'The Great Gatsby, by F. Scott Fitzgerald'"),
                title, author
            )
        }
        static func audiobookNarratedBy(title: String, narrator: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%1$@, narrated by %2$@", comment: "VoiceOver: audiobook cell label without author, e.g. 'Title, narrated by Narrator'"),
                title, narrator
            )
        }
        static func audiobookByAuthorNarratedBy(title: String, author: String, narrator: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%1$@, by %2$@, narrated by %3$@", comment: "VoiceOver: audiobook cell label with author and narrator"),
                title, author, narrator
            )
        }
        static func audiobookByAuthor(title: String, author: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%1$@, audiobook, by %2$@", comment: "VoiceOver: audiobook cell label with author but no narrator"),
                title, author
            )
        }
    }

    struct DownloadAnnouncements {
        static func downloadStarted(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Download started for %@.", comment: "VoiceOver announcement when a download begins"),
                title
            )
        }

        static func downloadProgress(_ title: String, _ percent: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Download %d percent complete for %@.", comment: "VoiceOver announcement for download progress"),
                percent,
                title
            )
        }

        static func downloadCompleted(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Download completed for %@.", comment: "VoiceOver announcement when a download finishes"),
                title
            )
        }

        static func downloadFailed(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Download failed for %@.", comment: "VoiceOver announcement when a download fails"),
                title
            )
        }

        static func downloadingTitle(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Downloading %@", comment: "VoiceOver accessibility label for download progress indicator, %@ is the book title"),
                title
            )
        }

        static func percentComplete(_ percent: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%d percent complete", comment: "VoiceOver accessibility value for download progress"),
                percent
            )
        }

        static func borrowStarted(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Borrow started for %@.", comment: "VoiceOver announcement when a borrow starts"),
                title
            )
        }

        static func borrowSucceeded(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Borrowed %@.", comment: "VoiceOver announcement when a borrow succeeds"),
                title
            )
        }

        static func borrowFailed(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Borrow failed for %@.", comment: "VoiceOver announcement when a borrow fails"),
                title
            )
        }

        static func returnStarted(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Return started for %@.", comment: "VoiceOver announcement when a return starts"),
                title
            )
        }

        static func returnSucceeded(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Returned %@.", comment: "VoiceOver announcement when a return succeeds"),
                title
            )
        }

        static func returnFailed(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Return failed for %@.", comment: "VoiceOver announcement when a return fails"),
                title
            )
        }

        static func retryingBorrow(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Retrying borrow for %@.", comment: "VoiceOver announcement when user taps Retry on a failed borrow"),
                title
            )
        }

        static func retryingReturn(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Retrying return for %@.", comment: "VoiceOver announcement when user taps Retry on a failed return"),
                title
            )
        }

        static func retryingDownload(_ title: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Retrying download for %@.", comment: "VoiceOver announcement when user taps Retry on a failed download"),
                title
            )
        }
    }

    // MARK: - Search Announcements (PP-3673)

    struct SearchAnnouncements {
        static func searchResultsFound(_ query: String, count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString(
                    "Showing %d results for %@.",
                    comment: "VoiceOver announcement when search results load. %d is result count, %@ is search term"
                ),
                count,
                query
            )
        }

        static func noSearchResults(_ query: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString(
                    "No results found for %@.",
                    comment: "VoiceOver announcement when search returns no results. %@ is search term"
                ),
                query
            )
        }

        static func searchResultsListValue(bookCount: Int) -> String {
            switch bookCount {
            case 0:
                return NSLocalizedString("No results", comment: "Accessibility value when search has no results")
            case 1:
                return NSLocalizedString("1 book", comment: "Accessibility value when search has one result")
            default:
                return String.localizedStringWithFormat(
                    NSLocalizedString("%d books", comment: "Accessibility value for search results count. %d is number of books"),
                    bookCount
                )
            }
        }

        static let searchResultsListHint = NSLocalizedString(
            "Swipe to browse results. Double tap to open a book.",
            comment: "Accessibility hint for search results list"
        )

        static func searchFailed() -> String {
            NSLocalizedString(
                "Search failed. Please try again.",
                comment: "VoiceOver announcement when a search request fails"
            )
        }

        static func loadingMoreResults() -> String {
            NSLocalizedString(
                "Loading more results.",
                comment: "VoiceOver announcement when loading additional search result pages"
            )
        }

        static func additionalResultsLoaded(_ count: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString(
                    "%d additional results loaded.",
                    comment: "VoiceOver announcement when more search results are loaded. %d is new result count"
                ),
                count
            )
        }

        // MARK: - Empty-state copy (BUG-003)
        //
        // Shown in the Catalog search screen when a completed search returns
        // zero books. The previous behavior was a blank screen, indistinguishable
        // from a hung request.

        static let noResultsTitle = NSLocalizedString(
            "No results",
            comment: "Title of the empty-state shown in the Catalog search screen when a query returns no books"
        )

        static let noResultsBody = NSLocalizedString(
            "Try a different search term.",
            comment: "Body copy of the empty-state shown in the Catalog search screen when a query returns no books"
        )
    }

    // MARK: - Status Announcements (PP-3673)

    struct StatusAnnouncements {
        static func errorOccurred(_ message: String) -> String {
            message
        }

        static func actionFailed(title: String, message: String) -> String {
            "\(title). \(message)"
        }
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
        static let supportEmail = "logs@thepalaceproject.org"
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
        static let catalog = NSLocalizedString("Catalog", comment: "For the catalog tab")
        static let addLibrary = NSLocalizedString("Add Library", comment: "Title of button to add a new library")
        static let switchLibraryPromptFormat = NSLocalizedString("Would you like to switch to %@?", comment: "Confirmation shown when tapping an inactive library in Settings. %@ is the library name.")
        static let switchingLibrary = NSLocalizedString("Switching library…", comment: "Loading overlay text shown while the app switches the active library.")
        static let aboutApp = NSLocalizedString("About App", comment: "")
        static let softwareLicenses = NSLocalizedString("Software Licenses", comment: "")
        static let privacyPolicy = NSLocalizedString("Privacy Policy", comment: "")
        static let eula = NSLocalizedString("User Agreement", comment: "")
        static let developerSettings = NSLocalizedString("Testing", comment: "Developer Settings")
        static let account = NSLocalizedString("Account", comment: "")
        static let advanced = NSLocalizedString("Advanced", comment: "")
        static let contentLicenses = NSLocalizedString("Content Licenses", comment: "")
        static let reportIssue = NSLocalizedString("Report an Issue", comment: "")
        static let ageVerification = NSLocalizedString("Age Verification", comment: "")
        static let syncBookmarks = NSLocalizedString("Sync Bookmarks", comment: "")
        static let showBarcode = NSLocalizedString("Show Barcode", comment: "")
        static let hideBarcode = NSLocalizedString("Hide Barcode", comment: "")
        static let show = NSLocalizedString("Show", comment: "")
        static let hide = NSLocalizedString("Hide", comment: "")
        static let signOut = NSLocalizedString("Sign out", comment: "")
        static let signingOut = NSLocalizedString("Signing out", comment: "")
        static let signingIn = NSLocalizedString("Signing In", comment: "")
        static let verifying = NSLocalizedString("Verifying", comment: "")
        static let barcodeOrUsername = NSLocalizedString("Barcode or Username", comment: "")
        static let pin = NSLocalizedString("PIN", comment: "")
        static let forgotPassword = NSLocalizedString("Forgot your password?", comment: "")
        static let signUpForCard = NSLocalizedString("Sign up for a library card", comment: "")
        static let eulaAgreement = NSLocalizedString("By signing in, you agree to the End User License Agreement.", comment: "")
        static let syncDescription = NSLocalizedString("Toggle on sync bookmarks to save your reading position and bookmarks across all of your devices. This must be done on all devices where you are accessing Palace to synchronize reading position.", comment: "Instructional text under Sync Bookmarks in Settings")
        static let authenticateToRevealPIN = NSLocalizedString("Authenticate to reveal your PIN.", comment: "")
        static let deleteServerData = NSLocalizedString("Delete Server Data", comment: "")
        static let downloads = NSLocalizedString("Downloads", comment: "Section header for download-related settings")
        static let aboutSectionHeader = NSLocalizedString("About and legal", comment: "VoiceOver: Settings list section header for About, Privacy, Licenses")
        static let downloadOnlyOnWiFi = NSLocalizedString("Download Only on Wi-Fi", comment: "Toggle label to restrict downloads to Wi-Fi connections")
        static let downloadOnlyOnWiFiDescription = NSLocalizedString("When enabled, books and audiobooks will only download over Wi-Fi. Downloads will be blocked on cellular data.", comment: "Description for Download Only on Wi-Fi setting")
        static let downloadRestrictedToWiFi = NSLocalizedString("Downloads are restricted to Wi-Fi in Settings. Connect to a Wi-Fi network or change your download settings to continue.", comment: "Alert message when download is blocked due to Wi-Fi only setting")
        static let wifiRequired = NSLocalizedString("Wi-Fi Required", comment: "Alert title when download is blocked due to Wi-Fi only setting")
    }

    struct AccountDetail {
        static func signInMessage(libraryName: String) -> String {
            String(format: NSLocalizedString("To download books, please sign in to %@.", comment: "Sign in prompt"), libraryName)
        }

        static func deleteServerDataMessage(libraryName: String) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("Selecting \"Delete\" will remove all bookmarks from the server for %@.", comment: ""),
                libraryName
            )
        }
    }

    struct TPPAccountListDataSource {
        static let addLibrary = NSLocalizedString("Add Library", comment: "Title that also informs the user that they should choose a library from the list.")
    }

    struct TPPBaseReaderViewController {
        static let removeBookmark = NSLocalizedString("Remove Bookmark",
                                                      comment: "Accessibility label for button to remove a bookmark")
        static let addBookmark = NSLocalizedString("Add Bookmark",
                                                   comment: "Accessibility label for button to add a bookmark")
        static let previousChapter = NSLocalizedString("Previous Chapter", comment: "Accessibility label to go backward in the publication")
        static let nextChapter = NSLocalizedString("Next Chapter", comment: "Accessibility label to go forward in the publication")
        static let read = NSLocalizedString("Read", comment: "Accessibility label to read current chapter")
        static let pageOf = NSLocalizedString("Page %d of ", value: "Page %d of ", comment: "States the page count out of total pages, i.e. `Page 1 of 20`")
        static let navigatedToPage = NSLocalizedString("Page %@", value: "Page %@", comment: "VoiceOver announcement after navigating to a print page, e.g. `Page 12`")
        static let whereAmI = NSLocalizedString("Where am I?", value: "Where am I?", comment: "VoiceOver custom action that announces the patron's current reading position without moving focus")
        static let percentRead = NSLocalizedString("%d%% read", value: "%d%% read", comment: "VoiceOver position component stating how far through the book the patron is, e.g. `45% read`")
        static let positionUnavailable = NSLocalizedString("Current position unavailable", value: "Current position unavailable", comment: "VoiceOver announcement when the current reading position cannot be determined")
        // Footnotes (DAISY reading-420, PP-4531). VoiceOver speaks these labels on
        // the inline EPUB elements so a non-visual reader knows a link is a note
        // reference, hears the note, and can return to the reference.
        static let footnoteReferenceNumbered = NSLocalizedString("Footnote %@", value: "Footnote %@", comment: "VoiceOver label for an inline footnote reference link with a marker, e.g. `Footnote 3`. VoiceOver appends `link` itself.")
        static let footnoteReferenceGeneric = NSLocalizedString("Footnote reference", value: "Footnote reference", comment: "VoiceOver label for a footnote reference link with no readable marker")
        static let footnoteContent = NSLocalizedString("Footnote", value: "Footnote", comment: "VoiceOver label prefix announced when focus reaches footnote content")
        static let footnoteBacklink = NSLocalizedString("Back to reference", value: "Back to reference", comment: "VoiceOver label for the footnote return link (doc-backlink) that returns the reader to the reference")
        // Block-by-block navigation (DAISY reading-810, PP-4533). The title of the
        // VoiceOver custom rotor that steps through logical content blocks.
        static let blockRotorTitle = NSLocalizedString("Blocks", value: "Blocks", comment: "VoiceOver rotor title for block-by-block reader navigation")
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
        /// PP-4161: format-row label for `text/html;profile=streaming-media`
        /// titles. Shown in the BookDetail "Format" row alongside ePub / PDF /
        /// Audiobook.
        static let streamingHTMLContentType = NSLocalizedString("Web Article", comment: "Format label for streaming-media (text/html) titles.")
    }

    struct TPPPDFNavigation {
        static let resume = NSLocalizedString("Resume", comment: "A button to continue reading title.")
        static let loadingPDF = NSLocalizedString("Loading…", comment: "Shown under the book title while an LCP-protected PDF is being decrypted and opened.")
    }

    struct TPPDeveloperSettingsTableViewController {
        static let developerSettingsTitle = NSLocalizedString("Testing", comment: "Developer Settings")
    }

    struct TPPEPUBViewController {
        static let readerSettings = NSLocalizedString("Reader settings", comment: "Reader settings")
        static let emptySearchView = NSLocalizedString("There are no results", comment: "No search results available.")
        static let endOfResults = NSLocalizedString("Reached the end of the results.", comment: "Reached the end of the results.")
        static let previousPage = NSLocalizedString("Previous page", comment: "Keyboard shortcut for navigating to previous page")
        static let nextPage = NSLocalizedString("Next page", comment: "Keyboard shortcut for navigating to next page")
        static let toggleToolbar = NSLocalizedString("Toggle toolbar", comment: "Keyboard shortcut for toggling the reader toolbar")
    }

    struct TPPLastReadPositionSynchronizer {
        static let syncReadingPositionAlertTitle = NSLocalizedString("Sync Reading Position", comment: "An alert title notifying the user the reading position has been synced")
        static let syncReadingPositionAlertBody = NSLocalizedString("Do you want to move to the page on which you left off?", comment: "An alert message asking the user to perform navigation to the synced reading position or not")
        static let stay = NSLocalizedString("Stay", comment: "Do not perform navigation")
        static let move = NSLocalizedString("Move", comment: "Perform navigation")
    }

    struct TPPLastListenedPositionSynchronizer {
        static let syncListeningPositionAlertTitle = NSLocalizedString("Sync Listening Position", comment: "An alert title notifying the user the listening position has been synced")
        static let syncListeningPositionAlertBody = NSLocalizedString("Do you want to move to the time on which you left off?", comment: "An alert message asking the user to perform navigation to the synced listening position or not")
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
        static let blackOnWhiteText = NSLocalizedString("Appearance Selector: Open dyslexic font", comment: "OpenDyslexicFont")
        static let blackOnSepiaText = NSLocalizedString("Appearance Selector: Black on sepia text", comment: "BlackOnSepiaText")
        static let whiteOnBlackText = NSLocalizedString("Appearance Selector: White on black text", comment: "WhiteOnBlackText")
    }

    struct TPPReaderBookmarksBusinessLogic {
        static let noBookmarks = NSLocalizedString("There are no bookmarks for this book.", comment: "Text showing in bookmarks view when there are no bookmarks")
    }

    struct TPPReaderFont {
        static let original = NSLocalizedString("Font selector: Default book font", comment: "OriginalFont")
        static let sans = NSLocalizedString("Font selector: Sans font", comment: "SansFont")
        static let serif = NSLocalizedString("Font selector: Serif font", comment: "SerifFont")
        static let dyslexic = NSLocalizedString("Font selector: Open dyslexic font", comment: "OpenDyslexicFont")
    }

    struct TPPReaderPositionsVC {
        static let contents = NSLocalizedString("Contents", comment: "")
        static let bookmarks = NSLocalizedString("Bookmarks", comment: "")
        static let pages = NSLocalizedString("Pages", comment: "Title of the reader navigation tab listing the book's print pages")
        static let goToPage = NSLocalizedString("Go to Page", comment: "Button and title for the prompt that jumps to a specific print page")
        static let goToPageMessage = NSLocalizedString("Enter a page number", comment: "Message in the prompt asking which print page to navigate to")
        static let pageNotFoundTitle = NSLocalizedString("Page Not Found", comment: "Alert title shown when an entered print page is not in the book")
        static let pageNotFoundMessage = NSLocalizedString("No matching page was found in this book.", comment: "Alert message shown when an entered print page is not in the book")
        static let pageRowAccessibility = NSLocalizedString("Page %@", value: "Page %@", comment: "VoiceOver label for a print page entry in the page list, e.g. `Page 12`")
    }

    struct TPPReaderTOCBusinessLogic {
        static let tocDisplayTitle = NSLocalizedString("Table of Contents", comment: "Title for Table of Contents in eReader")
    }

    struct TPPSettingsAdvancedViewController {
        static let advanced = NSLocalizedString("Advanced", comment: "")
        static let pleaseWait = NSLocalizedString("Please wait...", comment: "Generic Wait message")
        static let deleteServerData = NSLocalizedString("Delete Server Data", comment: "")
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

    struct MyBooksView {
        static let navTitle = NSLocalizedString("My Books", comment: "")
        static let sortBy = NSLocalizedString("Sort By:", comment: "")
        static let searchBooks = NSLocalizedString("Search My Books", comment: "")
        static let emptyViewMessage = NSLocalizedString("Visit the Catalog to\nadd books to My Books.", comment: "")
        static let emptyViewTitle = NSLocalizedString("Your shelf is empty", comment: "Title of the My Books empty state shown when the patron has no books")
        static let browseCatalog = NSLocalizedString("Browse the Catalog", comment: "Button on the My Books empty state that opens the catalog tab")
        static let findYourLibrary = NSLocalizedString("Find Your Library", comment: "Button that lets user know they can select a library they have a card for")
        static let addLibrary = NSLocalizedString("Add Library", comment: "Title of button to add a new library")
        static let accountSyncingAlertTitle = NSLocalizedString("Please wait", comment: "")
        static let accountSyncingAlertMessage = NSLocalizedString("Please wait a moment before switching library accounts", comment: "")
    }

    struct FacetView {
        static let author = NSLocalizedString("Author", comment: "")
        static let title = NSLocalizedString("Title", comment: "")
    }

    struct Catalog {
        static let filter = NSLocalizedString("Filter", comment: "")
        static let sortBy = NSLocalizedString("Sort By", comment: "Header label for sort options")
        static let showResults = NSLocalizedString("SHOW RESULTS", comment: "Button to apply filters and show results")
        // Offline state (PP-4578). Copy pending final design sign-off.
        static let offlineTitle = NSLocalizedString("You're Offline", comment: "Title of the catalog offline state shown when the device has no internet connection")
        static let offlineMessage = NSLocalizedString("The catalog isn't available without an internet connection, but your downloaded books are still here to read and listen to.", comment: "Explains that catalog browsing needs a connection while downloaded books remain available offline")
        static let offlineGoToMyBooks = NSLocalizedString("Go to My Books", comment: "Button on the catalog offline state that takes the patron to their downloaded books")
        static let emptyFeedTitle = NSLocalizedString("Nothing here yet", comment: "Title of the catalog empty state shown when a feed returns no books")
        static let emptyFeedMessage = NSLocalizedString("This part of the catalog doesn't have any books right now. Check back later.", comment: "Body of the catalog empty state shown when a feed returns no books")
    }

    struct BookCell {
        static let delete = NSLocalizedString("Delete", comment: "")
        static let `return` = NSLocalizedString("Return", comment: "")
        static let remove = NSLocalizedString("Remove", comment: "")
        static let deleteMessage = NSLocalizedString("Are you sure you want to delete \"%@\"?", comment: "Message shown in an alert to the user prior to deleting a title")
        static let returnMessage = NSLocalizedString("Are you sure you want to return \"%@\"?", comment: "Message shown in an alert to the user prior to returning a title")
        static let removeReservation = NSLocalizedString("Remove Reservation", comment: "")
        static let removeReservationMessage = NSLocalizedString("Are you sure you want ot remove \"%@\" from your reservations? You will no longer be in line for this book.", comment: "Message shown in an alert to the user prior to returning a reserved title.")
        static let removeHold = NSLocalizedString("Remove Hold", comment: "")
        static let removeHoldMessage = NSLocalizedString("Are you sure you want to remove \"%@\" from your holds? You will no longer be in line for this book.", comment: "Message shown in an alert to the user prior to removing a held title.")
        static let downloading = NSLocalizedString("Downloading", comment: "")
        static let downloadFailedMessage = NSLocalizedString("The download could not be completed.", comment: "")
    }

    struct TPPAccountRegistration {
        static let doesUserHaveLibraryCard = NSLocalizedString("Don't have a library card?", comment: "Title for registration. Asking the user if they already have a library card.")
        static let geolocationInstructions = NSLocalizedString("The Palace App requires a one-time location check in order to verify your library service area. Once you choose \"Create Card\", please select \"Allow Once\" in the popup so we can verify this information.", comment: "Body for registration. Explaining the reason for requesting the user's location and instructions for how to provide permission.")
        static let createCard = NSLocalizedString("Create Card", comment: "")
        static let deniedLocationAccessMessage = NSLocalizedString("The Palace App requires a one-time location check in order to verify your library service area. You have disabled location services for this app. To enable, please select the 'Open Settings' button below then continue with card creation.", comment: "Registration message shown to user when location access has been denied.")
        static let deniedLocationAccessMessageBoldText = NSLocalizedString("You have disabled location services for this app.", comment: "Registration message shown to user when location access has been denied.")
        static let openSettings = NSLocalizedString("Open Settings", comment: "")
    }

    struct ExpiredLoan {
        static let title = NSLocalizedString("Your Loan Has Expired", comment: "Alert title when a book's DRM license has expired")
        static let message = NSLocalizedString("This title is no longer available because your loan period ended. It has been removed from your device.", comment: "Alert message when a book loan expires without a known end date")
        static let messageWithDate = NSLocalizedString("This title is no longer available because your loan ended on %@. It has been removed from your device.", comment: "Alert message when a book loan expires; %@ is the formatted end date")
    }

    struct MyDownloadCenter {
        static let borrowFailed = NSLocalizedString("Borrow Failed", comment: "")
        static let borrowFailedMessage = NSLocalizedString("Borrowing %@ could not be completed.", comment: "")
        static let loanAlreadyExistsAlertMessage = NSLocalizedString("You have already checked out this loan. You may need to refresh your My Books list to download the title.", comment: "")
        static let returnFailed = NSLocalizedString("Return Failed", comment: "Alert title when returning a book fails")
        static let returnFailedMessage = NSLocalizedString("The return of %@ could not be completed.", comment: "Alert message when returning a book fails, %@ is the book title")
        static let downloadFailed = NSLocalizedString("Download Failed", comment: "Alert title when a download fails")
        static let downloadFailedMessage = NSLocalizedString("The download for %@ could not be completed.", comment: "Alert message when downloading a book fails, %@ is the book title")
        static let downloadFailedUnknownReason = NSLocalizedString("Please check your connection and try again.", comment: "Fallback detail shown under the \"Download Failed\" alert when the underlying failure reason has no user-facing description (e.g. a generic URLSession error or DRM fulfillment error with no localizedDescription).")
        static let retry = NSLocalizedString("Retry", comment: "Button to retry a failed operation")
        static let tryAgainLater = NSLocalizedString("Please try again later.", comment: "Message shown when maximum retry attempts have been exceeded")
        static let errorSyncingBookmarks = NSLocalizedString("Error Syncing Bookmarks", comment: "Alert title when bookmark sync fails")
        static let bookmarkSyncError = NSLocalizedString("There was an error syncing bookmarks to the server. Ensure your device is connected to the internet.", comment: "Alert message when bookmark sync fails")
        static let libraryLoadError = NSLocalizedString("We can\u{2019}t get your library right now. Please try again.", comment: "Alert message when library data fails to load, with retry option")
        static let libraryLoadErrorLegacy = NSLocalizedString("We can\u{2019}t get your library right now. Please close and reopen the app to try again.", comment: "Alert message when library data fails to load, no retry available")
        static let wifiRequired = Strings.Settings.wifiRequired
        static let downloadRestrictedToWiFi = Strings.Settings.downloadRestrictedToWiFi
        static let noConnectionTitle = NSLocalizedString("No Connection", comment: "Alert title shown when the user attempts to download or reserve a book while offline")
        static let noConnectionMessage = NSLocalizedString("You don\u{2019}t appear to be connected to the internet. Reconnect and try again.", comment: "Alert message shown when the user attempts to download or reserve a book while offline")
    }

    struct BookDetailView {
        static let audiobookAvailable = NSLocalizedString("Also available as an audiobook.", comment: "")
        static let description = NSLocalizedString("Description", comment: "")
        static let information = NSLocalizedString("Information", comment: "")
        static let preview = NSLocalizedString("Preview", comment: "")
        static let format = NSLocalizedString("Format", comment: "")
        static let audience = NSLocalizedString("Audience", comment: "Book detail metadata label for the target reader audience (Adult, Young Adult, Children, etc.)")
        static let language = NSLocalizedString("Language", comment: "Book detail metadata label for the work's language")
        static let published = NSLocalizedString("Published", comment: "")
        static let publisher = NSLocalizedString("Publisher", comment: "")
        static let category = NSLocalizedString("Category", comment: "")
        static let categories = NSLocalizedString("Categories", comment: "")
        static let distributor = NSLocalizedString("Distributor", comment: "")
        static let series = NSLocalizedString("Series", comment: "Book detail metadata label introducing the series this title belongs to")
        static let narrators = NSLocalizedString("Narrators", comment: "")
        static let duration = NSLocalizedString("Duration", comment: "")
        static let more = NSLocalizedString("More", comment: "")
        static let less = NSLocalizedString("Less", comment: "")
        static let otherBooks = NSLocalizedString("Other books by this author", comment: "Section header for related books")
        static let borrowedUntil = NSLocalizedString("Borrowed until", comment: "")
        static let borrowingFor = NSLocalizedString("Borrowing for", comment: "")
        /// Status text shown alongside the indeterminate spinner during the
        /// borrow phase (network request to the borrow URL is in flight,
        /// before the download itself starts). Distinct from `borrowingFor`,
        /// which renders a loan-duration label on already-borrowed books.
        static let borrowingInProgress = NSLocalizedString("Borrowing…", comment: "Status label shown while a borrow request is in flight, before the download begins.")
        static let due = NSLocalizedString("Due", comment: "")
        static let holdStatus = NSLocalizedString(
            "You are %1$@ in line. %2$d %3$@ in use.",
            comment: "User hold position and number of copies in use. Format: 'You are 5th in line. 3 copies in use.'"
        )
        static let holdPositionOnly = NSLocalizedString(
            "You are %1$@ in line.",
            comment: "User hold position without copies info. Format: 'You are 5th in line.'"
        )
        static let copy = NSLocalizedString("copy", comment: "")
        static let copies = NSLocalizedString("copies", comment: "")
        static let returning = NSLocalizedString("returning", comment: "")
        static let manageHold = BookButton.manageHold
    }

    struct BookButton {
        static let borrow = NSLocalizedString("Borrow", comment: "")
        static let preview = NSLocalizedString("Preview", comment: "")
        static let returnLoan = NSLocalizedString("Return Loan", comment: "")
        static let manageHold = NSLocalizedString("Manage Hold", comment: "")
        static let retry = NSLocalizedString("Retry", comment: "")
        static let read = NSLocalizedString("Read", comment: "")
        static let listen = NSLocalizedString("Listen", comment: "")
        static let download = NSLocalizedString("Download", comment: "")
        static let cancel = NSLocalizedString("Cancel", comment: "")
        static let `return` = NSLocalizedString("Return", comment: "")
        static let remove = NSLocalizedString("Remove", comment: "")
        static let placeHold = NSLocalizedString("Place Hold", comment: "")
        static let onHold = NSLocalizedString("On Hold", comment: "")
        static let keepHold = NSLocalizedString("Keep Hold", comment: "")
        static let cancelHold = NSLocalizedString("Cancel Hold", comment: "")
        static let otherBooks = NSLocalizedString("Other books by this author", comment: "")
        static let close = NSLocalizedString("Close", comment: "")
        /// PP-4161: terminal action label for streaming-HTML titles. Reuses
        /// the "Read" wording — the user-facing affordance is the same, only
        /// the underlying renderer differs (in-app WKWebView vs Reader2).
        static let readStreaming = NSLocalizedString("Read", comment: "Action button title to open a borrowed streaming-media (text/html) title in the in-app web reader.")
    }

    struct HoldsView {
        static let reservations = NSLocalizedString("Holds", comment: "Nav title for Holds tab")
        static let emptyTitle = NSLocalizedString("No holds yet", comment: "Title of the Holds empty state shown when the patron has no reserved or held books")
        static let emptyMessage = NSLocalizedString("""
            When you reserve a book from the catalog, it will show up here. \
            Look here from time to time to see if your book is available to download.
            """, comment: "")
        static let findYourLibrary = NSLocalizedString("Find Your Library", comment: "")
        static let syncFailedMessage = NSLocalizedString(
            "There was a problem loading your holds. Please try again later.",
            comment: "Error message when holds sync fails"
        )
    }

    // PP-4161: copy for the new streaming-media reader chrome. Online-only
    // experience; the offline state surfaces `connectionRequired` plus a
    // Retry button per the reader's `.offline` state. Dismissal is via the
    // system back chevron from the NavigationStack push — no explicit close
    // bar button (see StreamingReaderViewController for the UX rationale).
    struct StreamingReader {
        static let connectionRequired = NSLocalizedString(
            "Connection Required",
            comment: "Title shown in the streaming reader when the device is offline; the asset is online-only and cannot be cached."
        )
        static let loadError = NSLocalizedString(
            "We couldn't load this title. Please check your connection and try again.",
            comment: "Error message shown when the streaming reader's web view fails to load the title."
        )
        static let retry = NSLocalizedString(
            "Retry",
            comment: "Button title in the streaming reader's offline / failed state — re-evaluates reachability and retries the load."
        )
    }

    // Epic PP-4086: the app-rating sentiment gate. A lightweight pre-prompt
    // asks how the patron feels before the native App Store review prompt;
    // a positive answer routes to the system prompt, a negative one to a
    // feedback email, and "Ask me later" defers.
    struct AppRating {
        static let sentimentTitle = NSLocalizedString(
            "Are you enjoying The Palace Project?",
            comment: "Title of the app-rating sentiment gate shown after a positive moment (finishing a book or borrowing)."
        )
        static let positive = NSLocalizedString(
            "Yes, I love it!",
            comment: "Sentiment-gate button; a positive response that leads to the native App Store rating prompt."
        )
        static let negative = NSLocalizedString(
            "Not really",
            comment: "Sentiment-gate button; a negative response that leads to a feedback option instead of the App Store."
        )
        static let askLater = NSLocalizedString(
            "Ask me later",
            comment: "Sentiment-gate button; defers the prompt and resets the cooldown."
        )
        static let feedbackTitle = NSLocalizedString(
            "We're sorry to hear that. Would you like to share feedback?",
            comment: "Follow-up shown after a negative sentiment-gate response, offering to open a feedback email."
        )
        static let feedbackConfirm = NSLocalizedString(
            "Share feedback",
            comment: "Feedback follow-up button; opens a pre-composed support email."
        )
        static let feedbackDecline = NSLocalizedString(
            "No thanks",
            comment: "Feedback follow-up button; dismisses without opening the feedback email."
        )
    }
}
