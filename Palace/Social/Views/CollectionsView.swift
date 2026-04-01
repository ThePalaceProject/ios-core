//
//  CollectionsView.swift
//  Palace
//
//  Created for Social Features — grid of user book collections.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

/// Grid display of all book collections with mosaic cover art.
struct CollectionsView: View {
    @StateObject private var viewModel: CollectionsViewModel
    @State private var showCreateSheet = false
    @State private var newCollectionName = ""

    init(viewModel: CollectionsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    spacing: 16
                ) {
                    // Default collections pinned at top
                    ForEach(viewModel.defaultCollections) { collection in
                        CollectionCard(collection: collection)
                            .onTapGesture {
                                viewModel.selectCollection(collection)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(collection.name), \(collection.bookCount) books")
                            .accessibilityAddTraits(.isButton)
                    }

                    // User collections
                    ForEach(viewModel.userCollections) { collection in
                        CollectionCard(collection: collection)
                            .onTapGesture {
                                viewModel.selectCollection(collection)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    viewModel.deleteCollection(collection)
                                } label: {
                                    Label("Delete Collection", systemImage: "trash")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(collection.name), \(collection.bookCount) books")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding()
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create Collection")
                }
            }
            .alert("New Collection", isPresented: $showCreateSheet) {
                TextField("Collection Name", text: $newCollectionName)
                Button("Create") {
                    viewModel.createCollection(name: newCollectionName)
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
}

// MARK: - Collection Card

/// A single collection card in the grid with mosaic cover art.
private struct CollectionCard: View {
    let collection: BookCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mosaic cover art (up to 4 images)
            MosaicCoverView(imageURLs: collection.coverImageURLs)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(collection.name)
                .font(.headline)
                .lineLimit(1)

            Text("\(collection.bookCount) books")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Mosaic Cover View

/// Displays up to 4 cover images in a 2x2 mosaic grid.
private struct MosaicCoverView: View {
    let imageURLs: [URL]

    var body: some View {
        GeometryReader { geometry in
            if imageURLs.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "books.vertical.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray.opacity(0.5))
                    )
            } else {
                let columns = min(imageURLs.count, 2)
                let rows = imageURLs.count > 2 ? 2 : 1
                let itemWidth = geometry.size.width / CGFloat(columns)
                let itemHeight = geometry.size.height / CGFloat(rows)

                VStack(spacing: 1) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<columns, id: \.self) { col in
                                let index = row * columns + col
                                if index < imageURLs.count {
                                    AsyncImage(url: imageURLs[index]) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Color.gray.opacity(0.2)
                                    }
                                    .frame(width: itemWidth - 0.5, height: itemHeight - 0.5)
                                    .clipped()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
