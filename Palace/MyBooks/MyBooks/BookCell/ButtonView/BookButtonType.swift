//
//  BookButtonType.swift
//  Palace
//
//  Created by Maurice Carrier on 2/17/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

enum BookButtonType: String {
    case get
    case reserve
    case download
    case read
    case listen
    case retry
    case cancel
    case close
    case sample
    case audiobookSample
    case remove
    case cancelHold
    case manageHold
    case `return`
    case returning
    /// PP-4161: terminal action for `streaming-media` (text/html) titles.
    /// Borrowed streaming-HTML books show this in place of `.read` / `.listen`;
    /// tapping presents the in-app `StreamingReaderView` (no download).
    case readStreaming

    var localizedTitle: String {
        NSLocalizedString(self.rawValue, comment: "Book Action Button title")
    }

    var displaysIndicator: Bool {
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this if BookButtonType gains a case, so an indicator
        // decision can't be silently defaulted to `false`.
        switch self {
        case .read, .remove, .get, .download, .listen, .readStreaming:
            true
        case .reserve, .retry, .cancel, .close, .sample, .audiobookSample,
             .cancelHold, .manageHold, .return, .returning:
            false
        }
    }

    var isDisabled: Bool {
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this if BookButtonType gains a case, so a new local-only
        // action can't silently inherit the network-gated disabled state.
        switch self {
        case .read, .listen, .remove:
            false
        // PP-4161: streaming-HTML reader is online-only — surface the same
        // reachability gate as the network-bound actions so users can't tap
        // through to an empty web view that's going to fail loadProvisional
        // anyway. (StreamingReaderViewModel will still render `.offline`,
        // but disabling the button at the BookDetail level matches the
        // pre-flight UX everywhere else.)
        case .get, .reserve, .download, .retry, .cancel, .close,
             .sample, .audiobookSample, .cancelHold, .manageHold,
             .return, .returning, .readStreaming:
            !AppContainer.production().reachability.isConnectedToNetwork()
        }
    }
}

private typealias DisplayStrings = Strings.BookButton

extension BookButtonType {
    var title: String {
        switch self {
        case .get: DisplayStrings.borrow
        case .reserve: DisplayStrings.placeHold
        case .download: DisplayStrings.download
        case .return: DisplayStrings.return
        case .remove: DisplayStrings.remove
        case .read: DisplayStrings.read
        case .listen: DisplayStrings.listen
        case .cancel: DisplayStrings.cancel
        case .retry: DisplayStrings.retry
        case .sample: DisplayStrings.preview
        case .audiobookSample: DisplayStrings.preview
        case .returning: DisplayStrings.returnLoan
        case .manageHold: DisplayStrings.manageHold
        case .cancelHold: DisplayStrings.cancelHold
        case .close: DisplayStrings.close
        // PP-4161: reuse the existing "Read" label for streaming-HTML titles.
        // Same affordance from the user's perspective, different render path.
        case .readStreaming: DisplayStrings.readStreaming
        }
    }

    @MainActor
    func title(for book: TPPBook) -> String {
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this if BookButtonType gains a case so a future preview-
        // style button can't silently fall through to the static title.
        switch self {
        case .sample, .audiobookSample:
            return AppContainer.production().samplePreviewManager.isShowingPreview(for: book) ? DisplayStrings.close : DisplayStrings.preview
        case .get, .reserve, .download, .read, .listen, .retry, .cancel,
             .close, .remove, .cancelHold, .manageHold, .return, .returning,
             .readStreaming:
            return title
        }
    }

    var buttonStyle: ButtonStyleType {
        switch self {
        case .sample, .audiobookSample, .close:
            .tertiary
        case .get, .reserve, .download, .read, .listen, .retry, .returning, .manageHold, .readStreaming:
            .primary
        case .return, .cancel, .remove:
            .secondary
        case .cancelHold:
            .destructive
        }
    }

    var isPrimary: Bool {
        buttonStyle == .primary
    }

    var hasBorder: Bool {
        buttonStyle == .secondary || buttonStyle == .destructive
    }

    func buttonBackgroundColor(_ isDarkBackground: Bool) -> Color {
        switch buttonStyle {
        case .primary:
            isDarkBackground ? .white : .black
        case .secondary, .tertiary, .destructive:
            .clear
        }
    }

    func buttonTextColor(_ isDarkBackground: Bool) -> Color {
        switch buttonStyle {
        case .primary:
            isDarkBackground ? .black : .white
        case .secondary, .tertiary:
            isDarkBackground ? .white : .black
        case .destructive:
            .palaceErrorBase

        }
    }

    func borderColor(_ isDarkBackground: Bool) -> Color {
        switch buttonStyle {
        case .secondary:
            (isDarkBackground ? .white : .black)
        case .destructive:
            .palaceErrorBase
        default:
            .clear
        }
    }
}

enum ButtonStyleType {
    case primary
    case secondary
    case tertiary
    case destructive
}
