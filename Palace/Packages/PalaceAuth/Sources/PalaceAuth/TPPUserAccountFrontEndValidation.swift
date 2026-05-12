//
//  TPPUserAccountFrontEndValidation.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 26/05/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#if canImport(UIKit)
import UIKit

// MARK: - Public seam protocols

/**
 Protocol that represents the input sources / UI requirements for performing
 front-end validation. (Unchanged from the main-target original — kept here
 with the same `@objc` shape so existing ObjC callers can adopt PalaceAuth
 without touching their conformances.)
 */
@objc
public protocol NYPLUserAccountInputProvider {
    var usernameTextField: UITextField? { get set }
    var PINTextField: UITextField? { get set }
    var forceEditability: Bool { get }
}

// Note: `TPPLibraryAccountReadable` is declared in `AuthSeams.swift` (impl 2's
// expanded slice with `uuid` + `hasUpdatedToken`). It used to be co-declared
// here as a `uuid`-only stub; consolidated to the AuthSeams version during
// the recovery wiring stage.

/// What front-end validation needs from the sign-in business logic to
/// answer per-keystroke questions ("is this username field accepting
/// emails?", "what's the passcode max length?"). The bridge stays in
/// the main target — `TPPSignInBusinessLogic` declares conformance via
/// an extension that maps `selectedAuthentication.patronIDKeyboard` etc.
/// into the boolean predicates this protocol exposes.
public protocol TPPSignInValidationContext: AnyObject {
    /// True when the currently-selected auth treats the username as an
    /// email address (skips the 25-char clamp the legacy validator applied
    /// for non-email keyboards).
    var usernameIsEmailKeyboard: Bool { get }

    /// True when the currently-selected auth allows non-numeric PINs.
    /// When false, validation rejects any non-digit input on the PIN field.
    var pinAllowsAlphanumeric: Bool { get }

    /// Maximum length of the PIN. `0` means unlimited (legacy semantics
    /// preserved from `AccountDetails.Authentication.authPasscodeLength`).
    var pinMaxLength: UInt { get }

    /// True when the user already has a stored barcode + PIN in the user
    /// account store. Validation uses this with `forceEditability` to
    /// decide whether tapping a textField re-opens it for editing.
    var hasBarcodeAndPIN: Bool { get }
}

// MARK: - Validator

@objcMembers public class TPPUserAccountFrontEndValidation: NSObject {
    private weak var account: TPPLibraryAccountReadable?
    private weak var validationContext: TPPSignInValidationContext?
    private weak var userInputProvider: NYPLUserAccountInputProvider?

    public init(
        account: TPPLibraryAccountReadable?,
        validationContext: TPPSignInValidationContext?,
        inputProvider: NYPLUserAccountInputProvider
    ) {
        self.account = account
        self.validationContext = validationContext
        self.userInputProvider = inputProvider
    }
}

extension TPPUserAccountFrontEndValidation: UITextFieldDelegate {
    public func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        if let userInputProvider = userInputProvider, userInputProvider.forceEditability {
            return true
        }

        return !(validationContext?.hasBarcodeAndPIN ?? false)
    }

    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard string.canBeConverted(to: .ascii) else { return false }

        if textField == userInputProvider?.usernameTextField,
           !(validationContext?.usernameIsEmailKeyboard ?? false) {

            if let text = textField.text {
                if range.location < 0 || range.location + range.length > text.count {
                    return false
                }

                let updatedText = (text as NSString).replacingCharacters(in: range, with: string)
                // Usernames cannot be longer than 25 characters.
                guard updatedText.count <= 25 else { return false }
            }
        }

        if textField == userInputProvider?.PINTextField {
            let allowedCharacters = CharacterSet.decimalDigits
            let bannedCharacters = allowedCharacters.inverted

            let alphanumericPin = validationContext?.pinAllowsAlphanumeric ?? false
            let containsNonNumeric = !(string.rangeOfCharacter(from: bannedCharacters)?.isEmpty ?? true)
            let abovePinCharLimit: Bool
            let passcodeLength = validationContext?.pinMaxLength ?? 0

            if let text = textField.text,
               let textRange = Range(range, in: text) {

                let updatedText = text.replacingCharacters(in: textRange, with: string)
                abovePinCharLimit = updatedText.count > passcodeLength
            } else {
                abovePinCharLimit = false
            }

            // PIN's support numeric or alphanumeric.
            guard alphanumericPin || !containsNonNumeric else { return false }

            // PIN's character limit. Zero is unlimited.
            if passcodeLength == 0 {
                return true
            } else if abovePinCharLimit {
                return false
            }
        }

        return true
    }
}
#endif

