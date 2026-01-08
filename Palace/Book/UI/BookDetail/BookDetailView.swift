import SwiftUI
import UIKit

struct BookDetailView: View {
  @Environment(\.presentationMode) var presentationMode
  @Environment(\.colorScheme) private var colorScheme
  
  private var coordinator: NavigationCoordinator? {
    NavigationCoordinatorHub.shared.coordinator
  }

  typealias DisplayStrings = Strings.BookDetailView
  @State private var selectedBook: TPPBook?
  @State private var descriptionText = ""

  @ObservedObject var viewModel: BookDetailViewModel
  @State private var isExpanded: Bool = false
  @State private var headerHeight: CGFloat = UIDevice.current.isIpad ? 300 : 225
  @State private var showCompactHeader: Bool = false
  @State private var lastOffset: CGFloat = 0
  @State private var imageScale: CGFloat = 1.0
  @State private var imageOpacity: CGFloat = 1.0
  @State private var titleOpacity: CGFloat = 1.0
  @State private var dragOffset: CGFloat = 0
  @State private var imageBottomPosition: CGFloat = 400
  @State private var pulseSkeleton: Bool = false
  @State private var lastBookIdentifier: String? = nil
  @State private var initialLayoutComplete: Bool = false
  @State private var currentOrientation: UIDeviceOrientation = UIDevice.current.orientation
  
  private let scaleAnimation = Animation.linear(duration: 0.35)

  @State private var headerColor: Color = Color(UIColor.systemBackground)

  private let maxHeaderHeight: CGFloat = 225
  private let minHeaderHeight: CGFloat = 80
  private let imageTopPadding: CGFloat = 80
  private let dampingFactor: CGFloat = 0.95
  
  init(book: TPPBook) {
    self.viewModel = BookDetailViewModel(book: book)
  }
  
  var body: some View {
    ZStack(alignment: .top) {
      ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
          ZStack {
            if viewModel.isFullSize {
              VStack {
                backgroundView
                  .frame(height: headerHeight)
                Spacer()
              }
            }
            
            mainView
              .padding(.bottom, 100)
              .background(GeometryReader { proxy in
                Color.clear
                  .onChange(of: proxy.frame(in: .global).minY) { newValue in
                    updateHeaderHeight(for: newValue)
                  }
              })
          }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .onChange(of: viewModel.book.identifier) { newIdentifier in
          if lastBookIdentifier != newIdentifier {
            lastBookIdentifier = newIdentifier
            resetSampleToolbar()
            let newSummary = viewModel.book.summary ?? ""
            if self.descriptionText != newSummary { self.descriptionText = newSummary }
            proxy.scrollTo(0, anchor: .top)
          } else {
            let newSummary = viewModel.book.summary ?? self.descriptionText
            if self.descriptionText != newSummary { self.descriptionText = newSummary }
          }
        }
      }
      .onAppear {
        headerColor = Color(viewModel.book.dominantUIColor)
        lastBookIdentifier = viewModel.book.identifier

        showCompactHeader = false
        headerHeight = viewModel.isFullSize ? 300 : 225
        imageScale = 1.0
        imageOpacity = 1.0
        titleOpacity = 1.0
        lastOffset = 0
        
        viewModel.fetchRelatedBooks()
        self.descriptionText = viewModel.book.summary ?? ""
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          pulseSkeleton = true
        }
      }
      .onDisappear {
        viewModel.showHalfSheet = false
      }
      .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
        handleOrientationChange()
      }
      .onReceive(viewModel.book.$dominantUIColor) { newColor in
        // Don't update while half sheet is showing to prevent unnecessary re-renders
        guard !viewModel.showHalfSheet else { return }
        
        withAnimation(.easeInOut(duration: 0.2)) {
          headerColor = Color(newColor)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange).receive(on: RunLoop.main)) { note in
        guard
          let info = note.userInfo as? [String: Any],
          let identifier = info["bookIdentifier"] as? String,
          identifier == viewModel.book.identifier,
          let raw = info["state"] as? Int,
          let newState = TPPBookState(rawValue: raw)
        else { return }

        // Only handle critical state changes that require navigation
        if newState == .unregistered {
          if let coordinator = coordinator {
            coordinator.pop()
          } else {
            presentationMode.wrappedValue.dismiss()
          }
        }
        // Ignore other state changes - they're handled by the ViewModel's publishers
      }
      .fullScreenCover(item: $selectedBook) { book in
        BookDetailView(book: book)
      }
      .sheet(isPresented: $viewModel.showHalfSheet) {
        HalfSheetView(viewModel: viewModel, backgroundColor: headerColor, coverImage: $viewModel.book.coverImage)
          .onDisappear {
            viewModel.isManagingHold = false
            viewModel.processingButtons.removeAll()
          }
      }
      .presentationDetents([.height(0), .height(300)])
      
      if !viewModel.isFullSize {
        backgroundView
          .frame(height: headerHeight)
          .animation(scaleAnimation, value: headerHeight)
        
        imageView
          .padding(.top, 50)
      }
      
      compactHeaderContent
        .opacity(showCompactHeader ? 1 : 0)
        .animation(scaleAnimation, value: -headerHeight)

      SamplePreviewBarView()
    }
    .offset(x: dragOffset)
    .animation(.interactiveSpring(), value: dragOffset)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: {
          if let coordinator = coordinator {
            coordinator.pop()
          } else {
            presentationMode.wrappedValue.dismiss()
          }
        }) {
          HStack(spacing: 6) {
            Image(systemName: "chevron.left")
              .font(.system(size: 17, weight: .semibold))
            Text(Strings.Generic.back)
              .font(.system(size: 17))
          }
          .foregroundColor(headerColor.isDark ? .white : .black)
        }
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .modifier(BookStateModifier(viewModel: viewModel, showHalfSheet: $viewModel.showHalfSheet))
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleSampleNotification")).receive(on: RunLoop.main)) { note in
      guard let info = note.userInfo as? [String: Any], let identifier = info["bookIdentifier"] as? String else { return }
      let action = (info["action"] as? String) ?? "toggle"
      if action == "close" {
        SamplePreviewManager.shared.close()
        return
      }
      if let book = TPPBookRegistry.shared.book(forIdentifier: identifier) ?? (viewModel.relatedBooksByLane.values.flatMap { $0.books }).first(where: { $0.identifier == identifier }) {
        SamplePreviewManager.shared.toggle(for: book)
      } else if viewModel.book.identifier == identifier {
        SamplePreviewManager.shared.toggle(for: viewModel.book)
      }
    }
    .onDisappear { SamplePreviewManager.shared.close() }
  }
  
  // MARK: - View Components
  
  private func dynamicTopPadding() -> CGFloat {
    let basePadding: CGFloat = 20
    let iPadPadding: CGFloat = 40
    let notchPadding: CGFloat = 60
    
    if UIDevice.current.userInterfaceIdiom == .pad {
      return iPadPadding
    } else {
      let topInset: CGFloat
      if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
         let win = windowScene.windows.first {
        topInset = win.safeAreaInsets.top
      } else {
        topInset = 0
      }
      return topInset > 20 ? notchPadding : basePadding
    }
  }
  
  @ViewBuilder private var mainView: some View {
    if viewModel.isFullSize {
      fullView
    } else {
      compactView
    }
  }
  
  private var fullView: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 30) {
        HStack(alignment: .top, spacing: 25) {
          imageView
          titleView
            .padding(.top, 20)
        }
        .padding(.top, 110)
        
        descriptionView
        informationView
        Spacer()
      }
      .padding(30)
      
      relatedBooksView
    }
  }
  
  private var compactView: some View {
    VStack(spacing: 10) {
      VStack {
        titleView
          .opacity(titleOpacity)
          .scaleEffect(max(0.8, titleOpacity))
          .offset(y: (1 - titleOpacity) * -10)
          .animation(scaleAnimation, value: titleOpacity)
        
        VStack(spacing: 20) {
          descriptionView
          informationView
        }
      }
      .padding(.horizontal, 30)
      
      relatedBooksView
        .padding(.top)
      
      Spacer(minLength: 50)
    }
    .padding(.top, imageBottomPosition + 10)
    .animation(scaleAnimation, value: imageBottomPosition)
  }
  
  private var imageView: some View {
    BookImageView(book: viewModel.book, height: 280 * imageScale)
      .accessibilityIdentifier(AccessibilityID.BookDetail.coverImage)
      .opacity(imageOpacity)
      .adaptiveShadow()
      .animation(scaleAnimation, value: imageScale)
      .animation(scaleAnimation, value: imageOpacity)
      .background(GeometryReader { _ in
        Color.clear
          .onAppear { updateImageBottomPosition() }
          .onChange(of: imageScale) { _ in updateImageBottomPosition() }
      })
  }
  
  private var titleView: some View {
    VStack(alignment: viewModel.isFullSize ? .leading : .center, spacing: 8) {
      Text(viewModel.book.title)
        .font(.title3)
        .lineLimit(nil)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: viewModel.isFullSize ? .leading : .center)
        .accessibilityIdentifier(AccessibilityID.BookDetail.title)
      
      if let authors = viewModel.book.authors, !authors.isEmpty {
        Text(authors)
          .font(.footnote)
          .accessibilityIdentifier(AccessibilityID.BookDetail.author)
      }
      
      BookButtonsView(
        provider: viewModel,
        backgroundColor: viewModel.isFullSize ? headerColor : (colorScheme == .dark ? .black : .white)
      ) { type in
        handleButtonAction(type)
      }
      
      if !viewModel.book.isAudiobook && viewModel.book.hasAudiobookSample {
        audiobookAvailable
          .padding(.top)
      }
    }
    .foregroundColor(viewModel.isFullSize ? (headerColor.isDark ? .white : .black) : Color(UIColor.label))
    .animation(scaleAnimation, value: imageScale)
  }
  
  private var backgroundView: some View {
    ZStack(alignment: .top) {
      Color.primary
        .ignoresSafeArea()
      
      LinearGradient(
        gradient: Gradient(colors: [
          headerColor.opacity(1.0),
          headerColor.opacity(0.5)
        ]),
        startPoint: .bottom,
        endPoint: .top
      )
      .ignoresSafeArea()
    }
  }
  
  private var compactHeaderContent: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading) {
        Spacer()
        Text(viewModel.book.title)
          .lineLimit(nil)
          .multilineTextAlignment(.center)
          .font(.subheadline)
          .foregroundColor(headerColor.isDark ? .white : .black)
        
        if let authors = viewModel.book.authors, !authors.isEmpty {
          Text(authors)
            .font(.caption)
            .foregroundColor(headerColor.isDark ? .white.opacity(0.8) : .black.opacity(0.8))
        }
      }
      Spacer()
      BookButtonsView(provider: viewModel, backgroundColor: headerColor, size: .small) { type in
        handleButtonAction(type)
      }
    }
    .frame(height: 50)
    .padding(.horizontal, 20)
    .padding(.top, 20)
    .padding(.bottom, 10)
  }
  
  @ViewBuilder private var descriptionView: some View {
    if !self.descriptionText.isEmpty {
      ZStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 10) {
          Text(DisplayStrings.description.uppercased())
            .font(.headline)
          
          Divider()
            .padding(.vertical)
          
          VStack {
            HTMLTextView(htmlContent: self.descriptionText)
              .lineLimit(nil)
              .frame(maxWidth: .infinity)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.bottom, 60)
          .frame(maxHeight: isExpanded ? .infinity : 100, alignment: .top)
          .clipped()
        }
        
        if !isExpanded {
          LinearGradient(
            gradient: Gradient(stops: [
              .init(color: Color.colorInverseLabel.opacity(0.0), location: 0.0),
              .init(color: Color.colorInverseLabel.opacity(0.5), location: 0.7),
              .init(color: Color.colorInverseLabel, location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 60)
        }
        
        Button(isExpanded ? DisplayStrings.less.capitalized : DisplayStrings.more.capitalized) {
          withAnimation {
            isExpanded.toggle()
          }
        }
        .foregroundColor(.primary)
        .bottomrRightJustified()
      }
      .padding(.bottom)
    }
  }
  
  @ViewBuilder private var relatedBooksView: some View {
    if viewModel.relatedBooksByLane.count > 0 {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 0) {
          Text(DisplayStrings.otherBooks.uppercased())
            .font(.headline)
          
          Divider()
            .padding(.vertical, 20)
        }
        .padding(.horizontal, 30)
        
        ForEach(viewModel.relatedBooksByLane.keys.sorted(), id: \.self) { laneTitle in
          if laneTitle != viewModel.relatedBooksByLane.keys.sorted().first {
            Divider()
          }
          
          if let lane = viewModel.relatedBooksByLane[laneTitle] {
            VStack(alignment: .leading, spacing: 20) {
              HStack {
                Text(lane.title)
                  .font(.headline)
                Spacer()
                if let url = lane.subsectionURL {
                  NavigationLink(destination: CatalogLaneMoreView(url: url)) {
                    Text(DisplayStrings.more.capitalized)
                      .foregroundColor(.primary)
                  }
                }
              }
              .padding(.horizontal, 30)
              
              ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                  ForEach(lane.books.indices, id: \.self) { index in
                    if let book = lane.books[safe: index] {
                      Button(action: {
                        viewModel.selectRelatedBook(book)
                      }) {
                        BookImageView(book: book, height: 160)
                          .padding()
                          .adaptiveShadow(radius: 5)
                          .transition(.opacity.combined(with: .scale))
                      }
                      .accessibilityLabel(bookAccessibilityLabel(for: book))
                      .accessibilityHint(Strings.Generic.doubleTapToOpen)
                    } else {
                      RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 100, height: 160)
                        .opacity(pulseSkeleton ? 0.6 : 1.0)
                    }
                  }
                }
                .padding(.horizontal, 30)
                
              }
            }
          }
        }
      }
    }
  }
  
  @ViewBuilder private var audiobookAvailable: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      HStack(alignment: .center, spacing: 5) {
        audiobookIndicator
          .padding(8)
        Text(Strings.BookDetailView.audiobookAvailable)
      }
      Divider()
    }
  }
  
  @State private var currentBookID: String? = nil
  
  @ViewBuilder private var audiobookIndicator: some View {
    ImageProviders.MyBooksView.audiobookBadge
      .resizable()
      .scaledToFit()
      .frame(width: 28, height: 28)
      .background(Circle().fill(Color.colorAudiobookBackground))
      .clipped()
  }
  
  @ViewBuilder private var informationView: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(DisplayStrings.information.uppercased())
        .font(.headline)
      Divider()
        .padding(.vertical)
      
      infoRow(label: DisplayStrings.format.uppercased(), value: self.viewModel.book.format)
      infoRow(label: DisplayStrings.published.uppercased(), value: self.viewModel.book.published?.monthDayYearString ?? "")
      infoRow(label: DisplayStrings.publisher.uppercased(), value: self.viewModel.book.publisher ?? "")
      
      let categoryLabel = self.viewModel.book.categoryStrings?.count == 1 ? DisplayStrings.categories.uppercased() : DisplayStrings.category.uppercased()
      infoRow(label: categoryLabel, value: self.viewModel.book.categories ?? "")
      
      infoRow(label: DisplayStrings.distributor.uppercased(), value: self.viewModel.book.distributor ?? "")
      
      if viewModel.book.isAudiobook {
        if let narrators = self.viewModel.book.narrators {
          infoRow(label: DisplayStrings.narrators.uppercased(), value: narrators)
        }
        
        if let duration = self.viewModel.book.bookDuration {
          infoRow(label: DisplayStrings.duration.uppercased(), value: formatDuration(duration))
        }
      }
      
      Spacer()
    }
  }
  
  // MARK: - Helper Functions
  
  private func infoRow(label: String, value: String) -> some View {
    HStack(alignment: .bottom, spacing: 10) {
      infoLabel(label: label)
        .frame(width: 100, alignment: .leading)
      infoValue(value: value)
    }
  }
  
  @ViewBuilder private func infoLabel(label: String) -> some View {
    Text(label)
      .font(Font.boldPalaceFont(size: 12))
      .lineLimit(nil)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
  }
  
  @ViewBuilder private func infoValue(value: String) -> some View {
    if let url = URL(string: value), UIApplication.shared.canOpenURL(url) {
      Link(value, destination: url)
        .font(.subheadline)
        .underline()
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text(value)
        .font(.subheadline)
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  
  private func formatDuration(_ durationInSeconds: String) -> String {
    guard let totalSeconds = Double(durationInSeconds) else {
      return "Invalid input"
    }
    
    let hours = Int(totalSeconds / 3600)
    let minutes = Int((totalSeconds - Double(hours * 3600)) / 60)
    
    return String(format: "%d hours, %d minutes", hours, minutes)
  }
  
  private func bookAccessibilityLabel(for book: TPPBook) -> String {
    var label = book.title
    if book.isAudiobook {
      label += ". \(Strings.Generic.audiobook)."
    }
    if let authors = book.authors, !authors.isEmpty {
      label += " \(Strings.Generic.by) \(authors)"
    }
    return label
  }
  
  private func updateImageBottomPosition() {
    let imageHeight = max(280 * imageScale, 80)
    imageBottomPosition = imageTopPadding + imageHeight + 70
  }
  
  private func handleOrientationChange() {
    let newOrientation = UIDevice.current.orientation
    guard newOrientation.isValidInterfaceOrientation,
          newOrientation != currentOrientation else { return }
    
    currentOrientation = newOrientation
    viewModel.orientationChanged.toggle()
    
    withAnimation(.easeInOut(duration: 0.3)) {
      headerHeight = viewModel.isFullSize ? 300 : 225
      imageScale = viewModel.isFullSize ? 1.0 : imageScale
      imageOpacity = viewModel.isFullSize ? 1.0 : imageOpacity
      titleOpacity = viewModel.isFullSize ? 1.0 : titleOpacity
      showCompactHeader = false
      lastOffset = 0
    }
  }
 
  private func resetSampleToolbar() {
    viewModel.showSampleToolbar = false
    SamplePreviewManager.shared.close()
  }
  
  private func setupSampleToolbarIfNeeded() {
    let bookID = viewModel.book.identifier
    
    if !SamplePreviewManager.shared.isShowingPreview(for: viewModel.book) || bookID != currentBookID {
      currentBookID = bookID
    }
  }
  
  private func handleButtonAction(_ buttonType: BookButtonType) {
    let account = TPPUserAccount.sharedAccount()
    let needsAuth = account.needsAuth && !account.hasCredentials()
    
    switch buttonType {
    case .sample, .audiobookSample:
      viewModel.handleAction(for: buttonType)
      
    case .download, .get:
      if needsAuth {
        // Present sign-in directly; don't show half sheet first
        viewModel.handleAction(for: buttonType)
      } else {
        viewModel.showHalfSheet = true
        viewModel.handleAction(for: buttonType)
      }
      
    case .reserve:
      if needsAuth {
        // Present sign-in directly for placing holds
        viewModel.handleAction(for: buttonType)
      } else {
        viewModel.showHalfSheet = true
        viewModel.handleAction(for: buttonType)
      }
      
    case .manageHold:
      viewModel.isManagingHold = true
      withAnimation(.spring()) {
        viewModel.showHalfSheet.toggle()
      }
      
    case .return, .remove, .cancelHold:
      if needsAuth {
        // Present sign-in for return/cancel actions
        viewModel.handleAction(for: buttonType)
      } else {
        if buttonType == .return {
          viewModel.bookState = .returning
        }
        withAnimation(.spring()) {
          viewModel.showHalfSheet = true
        }
        if buttonType != .return {
          viewModel.handleAction(for: buttonType)
        }
      }
      
    default:
      withAnimation(.spring()) {
        viewModel.showHalfSheet.toggle()
      }
    }
  }
  
  private func updateHeaderHeight(for offset: CGFloat) {
    guard !viewModel.isFullSize else { return }
    
    let dampedOffset = offset * dampingFactor
    let newHeight = headerHeight + dampedOffset
    let adjustedHeight = max(minHeaderHeight, min(newHeight, maxHeaderHeight))
    let progress = (adjustedHeight - minHeaderHeight) / (maxHeaderHeight - minHeaderHeight)
    
    headerHeight = adjustedHeight
    imageScale = progress
    imageOpacity = progress
    titleOpacity = showCompactHeader ? 0 : progress
    
    let compactThreshold = minHeaderHeight + (maxHeaderHeight - minHeaderHeight) * 0.3
    let expandThreshold = minHeaderHeight + (maxHeaderHeight - minHeaderHeight) * 0.6
    
    if offset < lastOffset {
      if adjustedHeight <= compactThreshold && !showCompactHeader {
        showCompactHeader = true
      }
    } else if offset > lastOffset {
      if adjustedHeight >= expandThreshold && showCompactHeader {
        showCompactHeader = false
      }
    }
    
    lastOffset = offset
  }
  
  private var customBackButton: some View {
    VStack {
      HStack {
        Button(action: {
          if let coordinator = coordinator {
            coordinator.pop()
          } else {
            presentationMode.wrappedValue.dismiss()
          }
        }) {
          HStack(spacing: 6) {
            Image(systemName: "chevron.left")
              .font(.system(size: 17, weight: .semibold))
            Text("Back")
              .font(.system(size: 17))
          }
          .foregroundColor(headerColor.isDark ? .white : .black)
        }
        .padding(.leading, 8)
        .padding(.top, UIDevice.current.isIpad ? 8 : 0)
        
        Spacer()
      }
      
      Spacer()
    }
  }
}

private struct BookStateModifier: ViewModifier {
  @ObservedObject var viewModel: BookDetailViewModel
  @Binding var showHalfSheet: Bool
  @Environment(\.presentationMode) var presentationMode
  
  private var coordinator: NavigationCoordinator? {
    NavigationCoordinatorHub.shared.coordinator
  }
  
  func body(content: Content) -> some View {
    content
      .onChange(of: viewModel.bookState) { newState in
      }
  }
}
