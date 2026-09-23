//
//  View+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

/// Simple void-returning closure alias. Relocated here from the (removed)
/// `RefreshableView.swift` where it originally lived; still used by
/// `RegistrationCell.configure(...)`.
typealias Action = () -> Void

extension View {
    func anyView() -> AnyView {
        AnyView(self)
    }

    func verticallyCentered() -> some View {
        VStack {
            Spacer()
            self
            Spacer()
        }
    }

    func horizontallyCentered() -> some View {
        HStack {
            Spacer()
            self
            Spacer()
        }
    }

    func bottomrRightJustified() -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                self
            }
        }
    }

    func square(length: CGFloat) -> some View {
        self.frame(width: length, height: length)
    }
}

extension View {
    func dismissKeyboardOnTap(onDismiss: (() -> Void)? = nil) -> some View {
        modifier(DismissKeyboardOnTap(onDismiss: onDismiss))
    }
}
