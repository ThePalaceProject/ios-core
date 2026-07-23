//
//  SideLoadingView.swift
//  Palace
//
//  Settings "Side Loading" screen (PP-2677). A test-only affordance, gated by
//  `RemoteFeatureFlags.isSideLoadingEnabled` at the call site in
//  `TPPSettingsView`. Lets a tester import a local EPUB / PDF / audiobook
//  manifest file and manage (delete) the imported set. Importing registers the
//  book so it opens in the real reader + DRM stack with no OPDS feed.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import PalaceBookModel

// MARK: - View model

/// Drives `SideLoadingView`. Thin layer over `SideloadedBookManager`.
@MainActor
final class SideLoadingViewModel: ObservableObject {

  /// The imported books, newest state re-read from the manager after every
  /// mutation so the manage-list stays in sync.
  @Published private(set) var books: [TPPBook] = []
  /// Non-nil while an import error alert should be shown.
  @Published var errorMessage: String?
  @Published var isImporterPresented = false

  private let manager: SideloadedBookManager

  init(manager: SideloadedBookManager) {
    self.manager = manager
    refresh()
  }

  func refresh() {
    books = manager.allBooks
  }

  /// Handle the `.fileImporter` result. Security-scoped access is required for
  /// files the document picker returns from outside the app sandbox.
  func handleImport(result: Result<[URL], Error>) {
    switch result {
    case let .success(urls):
      guard let url = urls.first else { return }
      let needsScopedAccess = url.startAccessingSecurityScopedResource()
      defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }
      do {
        _ = try manager.import(fileURL: url)
        refresh()
      } catch {
        errorMessage = "\(error)"
      }
    case let .failure(error):
      errorMessage = error.localizedDescription
    }
  }

  func delete(_ book: TPPBook) {
    manager.remove(identifier: book.identifier)
    refresh()
  }

  func delete(at offsets: IndexSet) {
    for index in offsets {
      guard books.indices.contains(index) else { continue }
      manager.remove(identifier: books[index].identifier)
    }
    refresh()
  }

  /// The caption shown under a book's title in the manage-list (UI-2): the
  /// original imported filename, falling back to the book title when the
  /// filename is unknown. Never the opaque `sideload-<sha256>` identifier.
  func caption(for book: TPPBook) -> String {
    manager.originalFilename(for: book.identifier) ?? book.title
  }

  /// The content types the picker accepts. Audiobooks import as a manifest
  /// JSON (`.json`); EPUB and PDF have first-class UTTypes.
  var allowedContentTypes: [UTType] {
    var types: [UTType] = [.pdf, .json]
    if let epub = UTType(filenameExtension: "epub") {
      types.insert(epub, at: 0)
    }
    return types
  }
}

// MARK: - View

struct SideLoadingView: View {
  @StateObject private var viewModel: SideLoadingViewModel

  init(manager: SideloadedBookManager) {
    _viewModel = StateObject(wrappedValue: SideLoadingViewModel(manager: manager))
  }

  var body: some View {
    List {
      Section(
        header: Text("Import"),
        footer: Text("Import a local EPUB, PDF, or audiobook manifest to open it in the reader without a catalog feed. For testing only.")
      ) {
        Button {
          viewModel.isImporterPresented = true
        } label: {
          Label("Import File…", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("settings.sideloading.import")
      }

      if viewModel.books.isEmpty {
        Section {
          emptyState
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
      } else {
        Section(header: Text("Imported")) {
          ForEach(viewModel.books, id: \.identifier) { book in
            VStack(alignment: .leading, spacing: 2) {
              Text(book.title)
              Text(viewModel.caption(for: book))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .swipeActions {
              Button(role: .destructive) {
                viewModel.delete(book)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
          .onDelete(perform: viewModel.delete(at:))
        }
      }
    }
    .listStyle(GroupedListStyle())
    .navigationTitle("Side Loading")
    .fileImporter(
      isPresented: $viewModel.isImporterPresented,
      allowedContentTypes: viewModel.allowedContentTypes,
      allowsMultipleSelection: false
    ) { result in
      viewModel.handleImport(result: result)
    }
    .alert(
      "Import Failed",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { viewModel.errorMessage = nil }
    } message: {
      Text(viewModel.errorMessage ?? "")
    }
    .onAppear { viewModel.refresh() }
  }

  /// UI-1: a real empty state instead of a `Text` that reads as a disabled row.
  private var emptyState: some View {
    let title = "No Imported Books"
    let description = "Tap \"Import File…\" above to add an EPUB, PDF, or audiobook."
    return ContentUnavailableView(
      title,
      systemImage: "arrow.down.doc",
      description: Text(description)
    )
  }
}
