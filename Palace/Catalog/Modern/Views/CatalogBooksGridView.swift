//
//  CatalogBooksGridView.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// Grid view for displaying books in ungrouped catalog feeds
struct CatalogBooksGridView: View {
    let books: [TPPBook]
    
    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(books, id: \.identifier) { book in
                BookGridItemView(book: book)
            }
        }
        .padding(.horizontal)
        .padding(.vertical)
    }
}

/// Individual book item in grid layout
struct BookGridItemView: View {
    let book: TPPBook
    @State private var isShowingDetail = false
    
    var body: some View {
        Button(action: { isShowingDetail = true }) {
            VStack(spacing: 12) {
                // Book cover
                AsyncImage(url: book.imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "book.fill")
                                    .foregroundColor(.secondary)
                                    .font(.title2)
                                
                                if let contentType = book.defaultAcquisition?.type {
                                    TPPContentTypeBadgeView(contentType: contentType)
                                }
                            }
                        )
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                
                // Book info
                VStack(spacing: 4) {
                    Text(book.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    if let author = book.authors.first {
                        Text(author)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Book status indicator
                    BookStatusIndicator(book: book)
                }
                .frame(height: 60) // Fixed height for consistent grid
            }
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $isShowingDetail) {
            BookDetailViewWrapper(book: book)
        }
    }
}

/// Status indicator for book availability
struct BookStatusIndicator: View {
    let book: TPPBook
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.caption2)
                .foregroundColor(statusColor)
            
            Text(statusText)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var statusIcon: String {
        switch book.defaultBookState() {
        case .downloadSuccessful:
            return "checkmark.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .downloadFailed:
            return "exclamationmark.triangle"
        case .unregistered:
            return "plus.circle"
        case .downloadNeeded:
            return "icloud.and.arrow.down"
        case .holdable:
            return "hand.raised"
        case .onHold:
            return "clock"
        case .unsupported:
            return "minus.circle"
        @unknown default:
            return "questionmark.circle"
        }
    }
    
    private var statusColor: Color {
        switch book.defaultBookState() {
        case .downloadSuccessful:
            return .green
        case .downloading:
            return .blue
        case .downloadFailed:
            return .red
        case .unregistered, .downloadNeeded:
            return .accentColor
        case .holdable, .onHold:
            return .orange
        case .unsupported:
            return .secondary
        @unknown default:
            return .secondary
        }
    }
    
    private var statusText: String {
        switch book.defaultBookState() {
        case .downloadSuccessful:
            return "Read"
        case .downloading:
            return "Downloading"
        case .downloadFailed:
            return "Failed"
        case .unregistered:
            return "Get"
        case .downloadNeeded:
            return "Download"
        case .holdable:
            return "Reserve"
        case .onHold:
            return "Reserved"
        case .unsupported:
            return "Unsupported"
        @unknown default:
            return "Unknown"
        }
    }
}

/// SwiftUI wrapper for TPPContentTypeBadge
struct TPPContentTypeBadgeView: UIViewRepresentable {
    let contentType: String
    
    func makeUIView(context: Context) -> TPPContentTypeBadge {
        let badge = TPPContentTypeBadge()
        badge.contentType = contentType
        return badge
    }
    
    func updateUIView(_ uiView: TPPContentTypeBadge, context: Context) {
        uiView.contentType = contentType
    }
}

// MARK: - Search Results View

struct SearchResultsView: View {
    let searchResults: CatalogSearchResult
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Search header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search Results")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(searchResults.totalResults) results for \"\(searchResults.query)\"")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    onDismiss()
                }
                .foregroundColor(.accentColor)
            }
            .padding()
            
            Divider()
            
            // Search results grid
            ScrollView {
                CatalogBooksGridView(books: searchResults.books)
                
                // Pagination info
                if searchResults.totalPages > 1 {
                    HStack {
                        Text("Page \(searchResults.currentPage) of \(searchResults.totalPages)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        // Pagination buttons could be added here
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CatalogBooksGridView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            CatalogBooksGridView(books: mockBooks)
        }
        .preferredColorScheme(.light)
        
        ScrollView {
            CatalogBooksGridView(books: mockBooks)
        }
        .preferredColorScheme(.dark)
    }
    
    static var mockBooks: [TPPBook] {
        // Mock books for preview - in real implementation, these would be actual TPPBook instances
        []
    }
}
#endif 