//
//  BotUI+Strings.swift
//  TriageBotUI
//

import Foundation

/// Localized text for the support bot's controls.
///
/// These reach the screen through `BotUI.PrimaryButton(title:)` and friends,
/// which take a `String` and render it with `Text(title)`. `Text` looks a key
/// up only for a string LITERAL — a `String` binds to the `StringProtocol`
/// overload, which renders the characters verbatim — so passing the English
/// literal rendered English in every language. Resolving the value here, at the
/// `NSLocalizedString` call, is what makes the tables reachable.
///
/// No `bundle:` argument: these resolve against `Bundle.main`, which is the
/// app's `Palace/*.lproj`, where they are translated. This package ships no
/// tables of its own and should not — it is compiled into the app, not
/// distributed separately.
enum BotStrings {
    static let walkMeThroughIt = NSLocalizedString(
        "Walk me through it", value: "Walk me through it",
        comment: "Support bot: accept a guided, step-by-step fix.")
    static let fileATicket = NSLocalizedString(
        "File a ticket", value: "File a ticket",
        comment: "Support bot: open a support ticket instead of self-serving.")
    static let notifyMe = NSLocalizedString(
        "Notify me", value: "Notify me",
        comment: "Support bot: be told when a known issue is resolved.")
    static let justFileATicket = NSLocalizedString(
        "Just file a ticket", value: "Just file a ticket",
        comment: "Support bot: skip the guided fix and go straight to a ticket.")
    static let askAnotherQuestion = NSLocalizedString(
        "Ask another question", value: "Ask another question",
        comment: "Support bot: start a new question after one is answered.")
    static let discard = NSLocalizedString(
        "Discard", value: "Discard",
        comment: "Support bot: throw away the drafted ticket without sending it.")
    static let send = NSLocalizedString(
        "Send", value: "Send",
        comment: "Support bot: submit the drafted ticket.")
    static let tryAgain = NSLocalizedString(
        "Try again", value: "Try again",
        comment: "Support bot: retry a submission that failed.")
    static let describeWhatsHappening = NSLocalizedString(
        "Describe what's happening…", value: "Describe what's happening…",
        comment: "Support bot: placeholder in the message field when describing a problem.")
    static let typeYourAnswer = NSLocalizedString(
        "Type your answer (or tap Skip)…", value: "Type your answer (or tap Skip)…",
        comment: "Support bot: placeholder in the message field when answering a follow-up question, which may be skipped.")
}
