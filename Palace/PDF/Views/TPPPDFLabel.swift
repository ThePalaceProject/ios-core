//
//  TPPPDFLabel.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

/// Floating label
///
/// PDF name, page number
struct TPPPDFLabel: View {

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .palaceFont(.subheadline, weight: .semibold)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // A translucent dark capsule (not a SwiftUI material): the label floats
            // over arbitrary PDF page content, and materials render unreliably over
            // a UIViewRepresentable (PDFView) backdrop. Dark + white text stays
            // legible over both light pages and dark scans.
            .background(Color.black.opacity(0.55), in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}
