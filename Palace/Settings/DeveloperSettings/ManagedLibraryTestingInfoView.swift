//
//  ManagedLibraryTestingInfoView.swift
//  Palace
//
//  PP-5070 — "How this works", reachable from the Testing screen's MDM row.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct ManagedLibraryTestingInfoView: View {

    /// A paragraph that is a payload rather than prose gets monospaced and
    /// horizontally scrollable, so a long identifier neither wraps mid-token nor
    /// pushes the page sideways.
    private func isPayload(_ text: String) -> Bool {
        text.hasPrefix("<?xml") || text.hasPrefix("<dict")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(ManagedLibraryTestingGuide.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .palaceFont(.headline)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            if isPayload(paragraph) {
                                ScrollView(.horizontal, showsIndicators: true) {
                                    Text(paragraph)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(12)
                                }
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text(paragraph)
                                    .palaceFont(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("MDM Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }
}
