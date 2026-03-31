//
//  CollectionDetailView.swift
//  Palace
//
//  Created for Social Features — displays books in a single collection.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Displays the books within a single collection, with reorder/remove support.
struct CollectionDetailView: View {
    @StateObject private var viewModel: CollectionDetailViewModel
    @State private var isEditingName = false
    @State private var editedName: String = ""
    @State private var showShareSheet = false
    @State private var shareText = ""
    @Environment(\.editMode) private var editMode

    init(viewModel: CollectionDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            // Collection header
            Section {
                if !viewModel.collection.collectionDescription.isEmpty {
                    Text(viewModel.collection.collectionDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text("\(viewModel.books.count) books")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Book list
            Section {
                ForEach(viewModel.books, id: \.identifier) { book in
                    BookRow(book: book)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(book.title), by \(book.authors ?? "Unknown Author")")
                }
                .onDelete { offsets in
                    viewModel.removeBook(at: offsets)
                }
                .onMove { source, destination in
                    viewModel.moveBook(from: source, to: destination)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(viewModel.collection.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .accessibilityLabel("Edit Collection")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        editedName = viewModel.collection.name
                        isEditingName = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        shareText = viewModel.shareCollection()
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Collection Options")
            }
        }
        .alert("Rename Collection", isPresented: $isEditingName) {
            TextField("Collection Name", text: $editedName)
            Button("Save") {
                viewModel.updateName(editedName)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText])
        }
    }
}

// MARK: - Book Row

/// A row showing a book's cover, title, and author.
private struct BookRow: View {
    let book: TPPBook

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail
            if let image = book.thumbnailImage ?? book.coverImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 64)
                    .cornerRadius(4)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 44, height: 64)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.caption)
                            .foregroundColor(.gray)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.body)
                    .lineLimit(2)

                if let authors = book.authors {
                    Text(authors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
