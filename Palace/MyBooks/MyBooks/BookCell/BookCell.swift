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
    /// PP-4326: forwarded to NormalBookCell, where it wires the cover +
    /// title/author region's SwiftUI Button to open book detail. Optional
    /// so callsites that embed BookCell outside of BookListView (snapshots,
    /// previews) keep rendering with no tap target.
    var onSelect: (() -> Void)? = nil

    var body: some View {
        NormalBookCell(model: model, previewEnabled: previewEnabled, onSelect: onSelect)
    }
}
