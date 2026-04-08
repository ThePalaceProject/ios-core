//
//  TPPPDFBackButton.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Preconfigured back button view
struct TPPPDFBackButton: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.medium))
                .accessibilityHidden(true)
        }
        .toolbarButtonSize()
        .accessibilityLabel(Strings.Generic.goBack)
    }
}

struct TPPPDFBackButton_Previews: PreviewProvider {
    static var previews: some View {
        TPPPDFBackButton {

        }
    }
}
