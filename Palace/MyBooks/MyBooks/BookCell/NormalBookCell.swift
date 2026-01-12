//
//  NormalBookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//


import SwiftUI
import Combine
import PalaceUIKit

struct NormalBookCell: View {
  @Environment(\.colorScheme) var colorScheme
  @State var showHalfSheet: Bool = false

  @ObservedObject var model: BookCellModel
  var previewEnabled: Bool = true
  private let cellHeight: CGFloat = 180
  
  // Download progress tracking
  @State private var downloadProgress: Double = 0.0
  
  /// Check download state directly from stableButtonState (source of truth for SwiftUI)
  private var isDownloading: Bool {
    model.stableButtonState == .downloadInProgress
  }
  
  private var isDownloadFailed: Bool {
    model.stableButtonState == .downloadFailed
  }

  var body: some View {
    ZStack {
      HStack(alignment: .center, spacing: 15) {
        HStack(spacing: 5) {
          unreadImageView
          titleCoverImageView
        }
        .frame(alignment: .leading)

        VStack(alignment: .leading, spacing: 10) {
          infoView
          VStack(alignment: .leading, spacing: 4) {
            downloadProgressView
            buttons
            borrowedInfoView
          }
          .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showHalfSheet, onDismiss: { 
          model.showHalfSheet = false
          model.isManagingHold = false  // Reset managing hold state when sheet is dismissed
        }) {
          HalfSheetView(
            viewModel: model,
            backgroundColor: Color(model.book.dominantUIColor),
            coverImage: $model.book.coverImage
          )
        }
        .alert(item: $model.showAlert) { alert in
          Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            primaryButton: .default(Text(alert.buttonTitle ?? ""), action: alert.primaryAction),
            secondaryButton: .cancel(alert.secondaryAction)
          )
        }
      }
      
      // Gentle download overlay
      downloadOverlay
    }
    .multilineTextAlignment(.leading)
    .padding(5)
    .frame(minHeight: cellHeight)
    .onDisappear { model.isLoading = false }
    .onReceive(downloadProgressPublisher) { progress in
      withAnimation(.easeInOut(duration: 0.15)) {
        downloadProgress = progress
      }
    }
    .onAppear {
      // Initialize with current progress if downloading
      if isDownloading {
        downloadProgress = MyBooksDownloadCenter.shared.downloadProgress(for: model.book.identifier)
      }
    }
  }
  
  // MARK: - Download Progress Publisher
  
  private var downloadProgressPublisher: AnyPublisher<Double, Never> {
    MyBooksDownloadCenter.shared.downloadProgressPublisher
      .filter { [model] in $0.0 == model.book.identifier }
      .map { $0.1 }
      .receive(on: DispatchQueue.main)
      .eraseToAnyPublisher()
  }

  @ViewBuilder private var titleCoverImageView: some View {
    BookImageView(book: model.book, width: nil, height: cellHeight)
      .adaptiveShadowLight(radius: 1.5)
      .frame(width: cellHeight * 2.0 / 3.0)
  }
  
  // MARK: - Download Progress View
  
  /// Threshold below which we show "Requesting..." instead of progress bar
  /// This handles the checkout→download transition where progress resets
  private let progressThreshold: Double = 0.03
  
  /// Whether we have meaningful download progress (above threshold, below complete)
  private var hasMeaningfulProgress: Bool {
    downloadProgress >= progressThreshold && downloadProgress < 0.99
  }
  
  @ViewBuilder private var downloadProgressView: some View {
    if isDownloading {
      VStack(alignment: .leading, spacing: 2) {
        if hasMeaningfulProgress {
          // Show actual progress bar when we have meaningful progress
          HStack(spacing: 6) {
            Text(Strings.BookCell.downloading)
              .palaceFont(size: 11)
              .foregroundColor(.secondary)
            
            Spacer()
            
            Text("\(Int(downloadProgress * 100))%")
              .palaceFont(size: 11)
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
          
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              // Background track
              RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 4)
              
              // Progress fill
              RoundedRectangle(cornerRadius: 2)
                .fill(Color(TPPConfiguration.mainColor()))
                .frame(width: geometry.size.width * downloadProgress, height: 4)
            }
          }
          .frame(height: 4)
        } else {
          // Show "Requesting..." for initial checkout phase or when progress resets
          HStack(spacing: 6) {
            Text(Strings.BookCell.downloading)
              .palaceFont(size: 11)
              .foregroundColor(.secondary)
            
            Spacer()
            
            ProgressView()
              .scaleEffect(0.7)
          }
        }
      }
      .padding(.bottom, 4)
      .transition(.opacity.combined(with: .move(edge: .top)))
    } else if isDownloadFailed {
      Text(Strings.BookCell.downloadFailedMessage)
        .palaceFont(size: 11)
        .foregroundColor(.red)
        .padding(.bottom, 4)
        .transition(.opacity)
    }
  }
  
  // MARK: - Download Overlay
  
  @ViewBuilder private var downloadOverlay: some View {
    if isDownloading {
      Color.black.opacity(0.08)
        .allowsHitTesting(false)
        .transition(.opacity)
    } else if isDownloadFailed {
      Color.black.opacity(0.15)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading) {
      Text(model.title)
        .lineLimit(2)
        .palaceFont(size: 17)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(model.book.defaultBookContentType == .audiobook ? "\(model.book.title). Audiobook." : model.book.title)
      Text(model.authors)
        .palaceFont(size: 12)
    }
  }

  private var buttonSize: ButtonSize {
    UIDevice.current.isIpad && UIDevice.current.orientation != .portrait ? .small : .medium
  }

  @ViewBuilder private var buttons: some View {
      BookButtonsView(provider: model, previewEnabled: previewEnabled, size: buttonSize) { type in
        switch type {
        case .close:
          withAnimation(.spring()) { self.showHalfSheet = false }
        default:
          model.callDelegate(for: type)
          withAnimation(.spring()) { self.showHalfSheet = model.showHalfSheet }
        }
      }
  }

  @ViewBuilder private var unreadImageView: some View {
    VStack {
      ImageProviders.MyBooksView.unreadBadge
        .resizable()
        .frame(width: 10, height: 10)
        .foregroundColor(Color(TPPConfiguration.accentColor()))
      Spacer()
    }
    .opacity(model.showUnreadIndicator ? 1.0 : 0.0)
  }
  
  @ViewBuilder var borrowedInfoView: some View {
    if model.registryState == .holding {
      holdingInfoView
    } else {
      loanTermsInfoView
    }
  }
  
  @ViewBuilder var holdingInfoView: some View {
    let details = model.book.getReservationDetails()
    if details.holdPosition > 0 && details.copiesAvailable > 0 {
      Text(
        String(
          format: Strings.BookDetailView.holdStatus,
          details.holdPosition.ordinal(),
          details.copiesAvailable,
          details.copiesAvailable == 1 ? Strings.BookDetailView.copy : Strings.BookDetailView.copies
        )
      )
      .font(.footnote)
    }
  }

  @ViewBuilder var loanTermsInfoView: some View {
    if let expirationDate = model.book.getExpirationDate() {
      HStack(alignment: .bottom, spacing: 10) {
        Text("Due \(expirationDate.monthDayYearString)")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text("\(expirationDate.timeUntil().value) \(expirationDate.timeUntil().unit)")
          .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
      }
      .palaceFont(size: 12)
      .minimumScaleFactor(0.8)
      .padding(.trailing)
    }
  }
}
