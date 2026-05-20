//
//  BookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 1/5/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct BookCell: View {
    @ObservedObject var model: BookCellModel
    var previewEnabled: Bool = true

    var body: some View {
        // PP-4289: `.hoverEffect(.lift)` gives Mac (iPad-on-Mac) and iPadOS
        // pointer users the expected hover feedback on catalog/MyBooks rows.
        // On iPhone (no pointer) this is a no-op, so it costs nothing.
        NormalBookCell(model: model, previewEnabled: previewEnabled)
            .hoverEffect(.lift)
    }
}
