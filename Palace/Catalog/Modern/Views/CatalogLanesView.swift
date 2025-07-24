//
//  CatalogLanesView.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// View for displaying catalog lanes (grouped feed sections)
struct CatalogLanesView: View {
    let lanes: [CatalogLane]
    let onTapLane: (CatalogLane) -> Void
    
    var body: some View {
        LazyVStack(spacing: 24) {
            ForEach(lanes) { lane in
                CatalogLaneView(lane: lane) {
                    onTapLane(lane)
                }
            }
        }
        .padding(.vertical)
    }
}

/// Individual lane view with horizontal scrolling books
struct CatalogLaneView: View {
    let lane: CatalogLane
    let onTapLane: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Lane header
            HStack {
                Text(lane.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if lane.hasMore {
                    Button("See All") {
                        onTapLane()
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            // Books horizontal scroll
            if !lane.books.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(lane.books, id: \.identifier) { book in
                            BookCoverView(book: book)
                                .frame(width: 120, height: 180)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                // Empty state
                Text("No books available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 40)
            }
        }
    }
}

/// Individual book cover view for lanes
struct BookCoverView: View {
    let book: TPPBook
    @State private var isShowingDetail = false
    
    var body: some View {
        Button(action: { isShowingDetail = true }) {
            VStack(spacing: 8) {
                // Book cover image
                AsyncImage(url: book.imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .overlay(
                            Image(systemName: "book.fill")
                                .foregroundColor(.secondary)
                                .font(.title)
                        )
                }
                .frame(width: 120, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                
                // Book title
                Text(book.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .frame(height: 32)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $isShowingDetail) {
            BookDetailViewWrapper(book: book)
        }
    }
}

/// Wrapper to integrate with existing book detail view
struct BookDetailViewWrapper: UIViewControllerRepresentable {
    let book: TPPBook
    
    func makeUIViewController(context: Context) -> UIViewController {
        let detailVC = TPPBookDetailViewController(book: book)
        return UINavigationController(rootViewController: detailVC)
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No updates needed
    }
}

// MARK: - Preview

#if DEBUG
struct CatalogLanesView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            CatalogLanesView(lanes: mockLanes) { lane in
                print("Tapped lane: \(lane.title)")
            }
        }
        .preferredColorScheme(.light)
        
        ScrollView {
            CatalogLanesView(lanes: mockLanes) { lane in
                print("Tapped lane: \(lane.title)")
            }
        }
        .preferredColorScheme(.dark)
    }
    
    static var mockLanes: [CatalogLane] {
        [
            CatalogLane(
                id: "1",
                title: "New Releases",
                books: mockBooks,
                subsectionURL: URL(string: "https://example.com/new")
            ),
            CatalogLane(
                id: "2",
                title: "Popular Fiction",
                books: Array(mockBooks.prefix(3)),
                subsectionURL: URL(string: "https://example.com/fiction")
            )
        ]
    }
    
    static var mockBooks: [TPPBook] {
        // Mock books for preview - in real implementation, these would be actual TPPBook instances
        []
    }
}
#endif 