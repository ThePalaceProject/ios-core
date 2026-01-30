//
//  EPUBReaderView.swift
//  Palace
//
//

import SwiftUI
import ReadiumShared
import UIKit

/// SwiftUI view for presenting EPUB publications
struct EPUBReaderView: View {
  let book: TPPBook
  let publication: Publication
  let forSample: Bool
  
  @EnvironmentObject private var coordinator: NavigationCoordinator
  @State private var readerViewController: UIViewController?
  @State private var isLoading = true
  @State private var error: Error?
  
  var body: some View {
    ZStack {
      if let readerVC = readerViewController {
        EPUBViewControllerWrapper(viewController: readerVC, forSample: forSample)
          .ignoresSafeArea()
          .overlay(alignment: .topLeading) {
            if forSample {
              closeButton
            }
          }
      } else if isLoading {
        ProgressView()
          .scaleEffect(1.5)
      } else if let error = error {
        VStack(spacing: 16) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundColor(.red)
          Text("Failed to open book")
            .font(.headline)
          Text(error.localizedDescription)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
      }
    }
    .applyIf(!forSample) { view in
      view
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }
    .onAppear {
      Log.debug(#file, "🟢 EPUBReaderView.onAppear() - EPUB view appearing (forSample: \(forSample))")
    }
    .onDisappear {
      Log.debug(#file, "🔴 EPUBReaderView.onDisappear() - EPUB view disappearing (forSample: \(forSample))")
    }
    .task {
      await loadReader()
    }
  }
  
  @ViewBuilder
  private var closeButton: some View {
    Button(action: {
      Log.debug(#file, "📕 EPUB sample close button tapped")
      coordinator.dismissEPUBSample()
    }) {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 28))
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        .padding(16)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Strings.Generic.closeSample)
  }
  
  @MainActor
  private func loadReader() async {
    do {
      let readerVC = try await ReaderService.shared.makeEPUBViewController(
        for: publication,
        book: book,
        forSample: forSample
      )
      
      self.readerViewController = readerVC
      self.isLoading = false
      
    } catch {
      self.error = error
      self.isLoading = false
    }
  }
}

// MARK: - View Extension for Conditional Modifiers

extension View {
  @ViewBuilder
  func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

// MARK: - UIViewController Wrapper

/// UIViewControllerRepresentable wrapper for EPUB reader view controller
private struct EPUBViewControllerWrapper: UIViewControllerRepresentable {
  let viewController: UIViewController
  let forSample: Bool
  
  func makeUIViewController(context: Context) -> UIViewController {
    // Always wrap in UINavigationController so EPUB VC can show its native back button
    let navController = UINavigationController(rootViewController: viewController)
    navController.navigationBar.isTranslucent = true
    return navController
  }
  
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // No updates needed
  }
}

