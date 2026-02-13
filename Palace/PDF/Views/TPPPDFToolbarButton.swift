//
//  TPPPDFToolbarButton.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

/// Preconfigured toolbar button view
struct TPPPDFToolbarButton: View {

    let action: () -> Void
    let image: Image?
    let text: String?
    let accessibilityLabelText: String?

    init(icon: String, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.action = action
        self.image = Image(systemName: icon)
        self.text = nil
        self.accessibilityLabelText = accessibilityLabel
    }

    init(text: String, action: @escaping () -> Void) {
        self.action = action
        self.image = nil
        self.text = text
        self.accessibilityLabelText = text
    }

    var body: some View {
        Button(action: action) {
            if let image = image {
                image
                    .accessibilityHidden(true) // Button provides accessibility
            }
            if let text = text {
                Text(text)
                    .palaceFont(.body)
            }
        }
        .toolbarButtonSize()
        .accessibilityLabel(accessibilityLabelText ?? "")
    }
}

struct ToolbarButton_Previews: PreviewProvider {
    static var previews: some View {
        TPPPDFToolbarButton(text: "Hello") {
            //
        }
    }
}
