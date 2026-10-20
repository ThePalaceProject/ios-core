//
//  Strings+Error.swift
//
//  Extracted from Strings.swift, which sits under a frozen size cap. The
//  error copy is the cluster that grows whenever an alert stops showing a
//  raw identifier, so it earns its own file rather than pushing the hub up.
//

import Foundation

extension Strings {
    struct Error {
        static let loginFailedErrorTitle = NSLocalizedString("Login Failed", comment: "")
        static let loadFailedError = pageLoadFailedError
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
        static let uknownLocationError = NSLocalizedString("Unknown error occurred. Please try again.", value: "Unknown error occurred. Please try again.", comment: "Error message shown to user when an unknown location error occurs.")
        static let locationFetchFailed = NSLocalizedString("Failed to get current location. Please try again.", comment: "Error message shown to user when CoreLocation does not return the current location.")
        static let tryAgain = NSLocalizedString("Please try again later.", comment: "Error message to please try again.")

        // The alert copy below carries `value:` because the keys are
        // identifiers rather than English. Palace ships no
        // `en.lproj/Localizable.strings`, so a lookup with no `value:` returns
        // the key, and each of these was written as a bare literal that
        // `TPPAlertUtils.alert(title:message:style:)` localizes at runtime --
        // a variable lookup, with no literal call site for a fallback to sit
        // on. The English is the app's own, restored from the `en` table that
        // the Transifex integration removed. Same class as PP-5094.
        static let notConnected = NSLocalizedString(
            "NotConnected",
            value: "You are not connected to the internet. Please connect and try again.",
            comment: "Alert message for NSURLErrorNotConnectedToInternet")
        static let timedOut = NSLocalizedString(
            "TimedOut",
            value: "The server did not respond. Please check your connection or try again later.",
            comment: "Alert message for NSURLErrorTimedOut")
        static let unsupportedURL = NSLocalizedString(
            "UnsupportedURL",
            value: "The link could not be opened. Please report an issue from the Settings tab.",
            comment: "Alert message for NSURLErrorUnsupportedURL, where retrying cannot help because the address itself is unusable")
        static let invalidDRMCredentials = NSLocalizedString(
            "SettingsAccountViewControllerInvalidCredentials",
            value: "Your barcode and pin combination was not valid. Please try again.",
            comment: "Alert message for Adobe NYPLADEPTError.authenticationFailed")
        static let tooManyDRMActivations = NSLocalizedString(
            "SettingsAccountViewControllerMessageTooManyActivations",
            value: "Too many devices have been authorized with this library card.",
            comment: "Alert message for Adobe NYPLADEPTError.tooManyActivations")

        static let signOutFailedTitle = NSLocalizedString(
            "SettingsAccountViewControllerLogoutFailed",
            value: "Sign Out Failed",
            comment: "Title of the alert shown when a sign-out request fails")
        static let signOutUnknownError = NSLocalizedString(
            "An unknown error occurred while trying to sign out.",
            comment: "Alert message when sign-out fails and the server supplied no error")
        static let signOutUnexpectedCredentialsTitle = NSLocalizedString(
            "Unexpected Credentials",
            value: "Unexpected Credentials",
            comment: "Title of the alert shown when a sign-out request returns 401")
        static let signOutUnexpectedCredentialsMessage = NSLocalizedString(
            "Your username or password may have changed since the last time you logged in.\n\nIf you believe this is an error, please contact your library.",
            comment: "Alert message shown when a sign-out request returns 401, meaning the card's credentials changed server-side")

        static let cannotSignOutTitle = NSLocalizedString(
            "SettingsAccountViewControllerCannotLogOutTitle",
            value: "Logout Failed",
            comment: "Title of the alert shown when sign-out is refused because the book registry is still syncing")
        static let cannotSignOutMessage = NSLocalizedString(
            "SettingsAccountViewControllerCannotLogOutMessage",
            value: "Please wait for certain download-related actions to finish before logging out.",
            comment: "Message of the alert shown when sign-out is refused because the book registry is still syncing")
    }
}
