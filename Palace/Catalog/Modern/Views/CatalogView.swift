//
//  CatalogView.swift
//  Palace
//
//  Created by Palace Modernization on Catalog Renovation
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

/// Main catalog view using SwiftUI
struct CatalogView: View {
    
    @StateObject private var viewModel = CatalogViewModel()
    @State private var showingSearch = false
    @State private var searchText = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                if viewModel.isLoading && viewModel.currentFeed == nil {
                    LoadingView()
                } else if let error = viewModel.error {
                    ErrorView(error: error) {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                } else if viewModel.hasSearchResults {
                    SearchResultsView(searchResults: viewModel.searchResults!) {
                        viewModel.clearSearch()
                    }
                } else {
                    CatalogContentView(viewModel: viewModel)
                }
            }
            .navigationTitle(viewModel.navigationState.title ?? "Catalog")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if viewModel.canSearch {
                            Button(action: { showingSearch = true }) {
                                Image(systemName: "magnifyingglass")
                            }
                            .accessibilityLabel("Search")
                        }
                        
                        if viewModel.navigationState.canGoBack {
                            Button(action: {
                                Task {
                                    await viewModel.navigateBack()
                                }
                            }) {
                                Image(systemName: "arrow.left")
                            }
                            .accessibilityLabel("Go Back")
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $showingSearch,
                placement: .navigationBarDrawer(displayMode: .always)
            ) {
                // Search suggestions could go here
            }
            .onSubmit(of: .search) {
                performSearch()
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        Task {
            await viewModel.searchCatalog(query: searchText)
        }
    }
}

// MARK: - Catalog Content View

struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Entry Points (if available)
                if !viewModel.entryPoints.isEmpty {
                    EntryPointsView(entryPoints: viewModel.entryPoints) { facet in
                        Task {
                            await viewModel.applyFacet(facet)
                        }
                    }
                    .padding(.horizontal)
                }
                
                // Facets (if available)
                if !viewModel.facetGroups.isEmpty {
                    FacetGroupsView(facetGroups: viewModel.facetGroups) { facet in
                        Task {
                            await viewModel.applyFacet(facet)
                        }
                    }
                    .padding(.horizontal)
                }
                
                // Content based on feed type
                if viewModel.isGroupedFeed {
                    CatalogLanesView(lanes: viewModel.lanes) { lane in
                        if let url = lane.subsectionURL {
                            Task {
                                await viewModel.navigateToSection(url: url, title: lane.title)
                            }
                        }
                    }
                } else {
                    CatalogBooksGridView(books: viewModel.books)
                }
            }
        }
    }
}

// MARK: - Entry Points View

struct EntryPointsView: View {
    let entryPoints: [CatalogFacet]
    let onTapEntryPoint: (CatalogFacet) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse")
                .font(.headline)
                .foregroundColor(.primary)
            
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(entryPoints) { entryPoint in
                    EntryPointCard(entryPoint: entryPoint) {
                        onTapEntryPoint(entryPoint)
                    }
                }
            }
        }
        .padding(.vertical)
    }
    
    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }
}

struct EntryPointCard: View {
    let entryPoint: CatalogFacet
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Text(entryPoint.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var iconName: String {
        // Map entry point labels to appropriate SF Symbols
        let label = entryPoint.label.lowercased()
        
        if label.contains("fiction") { return "book.fill" }
        if label.contains("non") { return "newspaper.fill" }
        if label.contains("audio") { return "headphones" }
        if label.contains("children") { return "person.3.fill" }
        if label.contains("teen") { return "graduationcap.fill" }
        if label.contains("new") { return "sparkles" }
        if label.contains("popular") { return "star.fill" }
        
        return "books.vertical.fill"
    }
}

// MARK: - Facet Groups View

struct FacetGroupsView: View {
    let facetGroups: [CatalogFacetGroup]
    let onTapFacet: (CatalogFacet) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            ForEach(facetGroups) { group in
                FacetGroupView(group: group, onTapFacet: onTapFacet)
            }
        }
        .padding(.vertical)
    }
}

struct FacetGroupView: View {
    let group: CatalogFacetGroup
    let onTapFacet: (CatalogFacet) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.facets) { facet in
                        FacetChip(facet: facet) {
                            onTapFacet(facet)
                        }
                    }
                }
                .padding(.horizontal, 1) // Prevents clipping of shadows
            }
        }
    }
}

struct FacetChip: View {
    let facet: CatalogFacet
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(facet.label)
                    .font(.caption)
                    .fontWeight(.medium)
                
                if let count = facet.count {
                    Text("(\(count))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                facet.isActive ? Color.accentColor : Color.secondary.opacity(0.2)
            )
            .foregroundColor(
                facet.isActive ? .white : .primary
            )
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Loading catalog...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Error View

struct ErrorView: View {
    let error: CatalogError
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text("Unable to Load Catalog")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Preview

#if DEBUG
struct CatalogView_Previews: PreviewProvider {
    static var previews: some View {
        CatalogView()
            .preferredColorScheme(.light)
        
        CatalogView()
            .preferredColorScheme(.dark)
    }
}
#endif 