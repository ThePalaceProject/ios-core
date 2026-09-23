//
//  TPPPDFSearchView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct TPPPDFSearchView: View {
    @StateObject var searchDelegate: SearchDelegate
    @EnvironmentObject var metadata: TPPPDFDocumentMetadata

    let document: TPPPDFDocument
    let done: () -> Void

    @State private var searchText = ""

    init(document: TPPPDFDocument, done: @escaping () -> Void) {
        self.document = document
        self.done = done
        self._searchDelegate = StateObject(wrappedValue: SearchDelegate(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    done()
                } label: {
                    Text(Strings.Generic.done)
                        .palaceFont(.body, weight: .bold)
                }
                .padding()
            }
            Divider()
            // PP-4421: explicit prompt with `.secondary` foreground overrides
            // the default `.placeholderText` (~30% gray) that reads as
            // disabled. Entered text retains its own .foregroundColor.
            TextField(Strings.Generic.search,
                      text: Binding(get: { searchText }, set: { searchText = $0; performSearch(string: $0) }),
                      prompt: Text(Strings.Generic.search).foregroundStyle(.secondary))
                .palaceFont(.body)
                .frame(minHeight: 44)
                .padding(.horizontal)
            Divider()
            if Self.showsNoResults(searchText: searchText, resultCount: searchDelegate.searchResults.count) {
                ContentUnavailableView.search(text: searchText)
                    .transition(.opacity)
            } else {
                List {
                    ForEach(searchDelegate.searchResults) { location in
                        TPPPDFLocationView(location: location)
                            .onTapGesture {
                                metadata.currentPage = location.pageNumber
                                done()
                            }
                    }
                }
            }
        }
        .accessibleAnimation(PalaceMotion.standard, value: searchDelegate.searchResults.count)
    }

    /// Whether the "no results" empty state should show: a committed query
    /// (>= 3 chars, matching `SearchDelegate.search`'s threshold) that returned
    /// zero matches. A shorter/empty query shows the (empty) list instead, so
    /// the screen doesn't flash "No Results" before the patron has typed enough.
    static func showsNoResults(searchText: String, resultCount: Int) -> Bool {
        searchText.count >= 3 && resultCount == 0
    }

    func performSearch(string: String) {
        searchDelegate.search(text: string)
    }

    /// `@unchecked Sendable` is safe here: `searchResults` is only ever mutated
    /// on the main thread — `search(text:)` is called from the SwiftUI view (main)
    /// and `didMatchString` writes through a `DispatchQueue.main.async` hop — and
    /// `document` is an immutable `let`. No cross-thread mutable state, so
    /// capturing `self` in the main-hop `@Sendable` closure crosses no boundary.
    final class SearchDelegate: ObservableObject, TPPPDFDocumentDelegate, @unchecked Sendable {

        let document: TPPPDFDocument

        @Published var searchResults: [TPPPDFLocation] = []

        init(document: TPPPDFDocument) {
            self.document = document
            self.document.delegate = self
        }

        func search(text: String) {
            searchResults = []
            if text.count >= 3 {
                document.search(text: text)
            }
        }

        func cancelSearch() {
            document.cancelSearch()
        }

        func didMatchString(_ instance: TPPPDFLocation) {
            DispatchQueue.main.async {
                self.searchResults.append(instance)
            }
        }
    }
}
