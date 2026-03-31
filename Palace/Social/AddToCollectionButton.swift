//
//  AddToCollectionButton.swift
//  Palace
//
//  Created for Social Features — reusable button for adding a book to a collection.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// A button that presents the "Add to Collection" sheet for a given book.
/// Drop this into any book detail or context menu.
struct AddToCollectionButton: View {
    let bookID: String
    let bookTitle: String
    let collectionService: BookCollectionServiceProtocol

    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Add to Collection", systemImage: "folder.badge.plus")
        }
        .accessibilityLabel("Add \(bookTitle) to a collection")
        .sheet(isPresented: $showSheet) {
            AddToCollectionSheet(
                bookID: bookID,
                bookTitle: bookTitle,
                viewModel: CollectionsViewModel(collectionService: collectionService)
            )
        }
    }
}
