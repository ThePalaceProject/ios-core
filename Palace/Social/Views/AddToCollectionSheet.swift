//
//  AddToCollectionSheet.swift
//  Palace
//
//  Created for Social Features — bottom sheet for adding a book to collections.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Bottom sheet listing collections with checkmarks for membership.
struct AddToCollectionSheet: View {
    let bookID: String
    let bookTitle: String
    @ObservedObject var viewModel: CollectionsViewModel
    @State private var showCreateNew = false
    @State private var newCollectionName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(viewModel.collections) { collection in
                        Button {
                            toggleMembership(collection: collection)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(collection.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("\(collection.bookCount) books")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if collection.contains(bookID: bookID) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .accessibilityLabel(
                            "\(collection.name), \(collection.bookCount) books\(collection.contains(bookID: bookID) ? ", selected" : "")"
                        )
                        .accessibilityAddTraits(
                            collection.contains(bookID: bookID) ? .isSelected : []
                        )
                    }
                }

                Section {
                    Button {
                        showCreateNew = true
                    } label: {
                        Label("Create New Collection", systemImage: "plus.circle")
                    }
                    .accessibilityLabel("Create New Collection")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("New Collection", isPresented: $showCreateNew) {
                TextField("Collection Name", text: $newCollectionName)
                Button("Create") {
                    viewModel.createCollection(name: newCollectionName)
                    // Auto-add the book to the newly created collection
                    if let newest = viewModel.collections.last {
                        viewModel.addBook(bookID, to: newest)
                    }
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) {
                    newCollectionName = ""
                }
            } message: {
                Text("Enter a name for your new collection.")
            }
        }
    }

    private func toggleMembership(collection: BookCollection) {
        if collection.contains(bookID: bookID) {
            viewModel.removeBook(bookID, from: collection)
        } else {
            viewModel.addBook(bookID, to: collection)
        }
    }
}
