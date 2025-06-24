
import SwiftUI
import UIKit

struct BookDetailView: View {
  @Environment(\.presentationMode) var presentationMode

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
  @State private var sampleToolbar: AudiobookSampleToolbar? = nil
  @State private var dragOffset: CGFloat = 0
  @State private var imageBottomPosition: CGFloat = 400
  
  private let scaleAnimation = Animation.linear(duration: 0.35)
  @MainActor private var headerBackgroundColor: Color { Color(viewModel.book.dominantUIColor) }

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
        .edgesIgnoringSafeArea(.all)
        .onChange(of: viewModel.book) { newValue in
          resetSampleToolbar()
          self.descriptionText = newValue.summary ?? ""
          proxy.scrollTo(0, anchor: .top)
          
        }
      }
      .onAppear {
        UITabBarController.hideFloatingTabBar()
        headerHeight = viewModel.isFullSize ? 300 : 225
        viewModel.fetchRelatedBooks()
        self.descriptionText = viewModel.book.summary ?? ""
      }
      .onDisappear {
        UITabBarController.showFloatingTabBar()
        viewModel.showHalfSheet = false
      }
      .fullScreenCover(item: $selectedBook) { book in
        BookDetailView(book: book)
      }
      .sheet(isPresented: $viewModel.showHalfSheet) {
        HalfSheetView(viewModel: viewModel, backgroundColor: headerBackgroundColor, coverImage: $viewModel.book.coverImage)
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
      
      backbutton
      sampleToolbarView
    }
    .offset(x: dragOffset)
    .animation(.interactiveSpring(), value: dragOffset)
    .gesture(edgeSwipeGesture)
    .modifier(BookStateModifier(viewModel: viewModel, showHalfSheet: $viewModel.showHalfSheet))
  }
  
  // MARK: - View Components
  
  @ViewBuilder private var backbutton: some View {
    Button(action: {
      presentationMode.wrappedValue.dismiss()
    }) {
      HStack {
        Image(systemName: "chevron.left")
        Text("Back")
      }
      .font(.title3)
      .foregroundColor(headerBackgroundColor.isDark ? .white : .black)
      .opacity(0.8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 50)
    .padding(.top, dynamicTopPadding())
    .padding(.leading)
    .zIndex(10)
    .edgesIgnoringSafeArea(.top)
    .opacity(showCompactHeader ? 0 : 1)
    .animation(scaleAnimation, value: headerHeight)
  }
  
  private func dynamicTopPadding() -> CGFloat {
    let basePadding: CGFloat = 20
    let iPadPadding: CGFloat = 40
    let notchPadding: CGFloat = 60
    
    if UIDevice.current.userInterfaceIdiom == .pad {
      return iPadPadding
    } else {
      return UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0 > 20 ? notchPadding : basePadding
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
    .padding(.top, imageBottomPosition)
    .animation(scaleAnimation, value: imageBottomPosition)
  }
  
  private var imageView: some View {
    BookImageView(book: viewModel.book, height: 280 * imageScale, showShimmer: true, shimmerDuration: 0.8)
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
      
      if let authors = viewModel.book.authors, !authors.isEmpty {
        Text(authors)
          .font(.footnote)
      }
      
      BookButtonsView(
        provider: viewModel,
        backgroundColor: viewModel.isFullSize ? headerBackgroundColor : Color(.systemBackground)
      ) { type in
        handleButtonAction(type)
      }
      
      if !viewModel.book.isAudiobook && viewModel.book.hasAudiobookSample {
        audiobookAvailable
          .padding(.top)
      }
    }
    .foregroundColor(viewModel.isFullSize ? (headerBackgroundColor.isDark ? .white : .black) : Color(UIColor.label))
    .animation(scaleAnimation, value: imageScale)
  }
  
  private var backgroundView: some View {
    ZStack(alignment: .top) {
      Color.primary
        .edgesIgnoringSafeArea(.all)
      
      LinearGradient(
        gradient: Gradient(colors: [
          headerBackgroundColor.opacity(1.0),
          headerBackgroundColor.opacity(0.5)
        ]),
        startPoint: .bottom,
        endPoint: .top
      )
    }
    .edgesIgnoringSafeArea(.top)
  }
  
  private var compactHeaderContent: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading) {
        Spacer()
        Text(viewModel.book.title)
          .lineLimit(nil)
          .multilineTextAlignment(.center)
          .font(.subheadline)
          .foregroundColor(headerBackgroundColor.isDark ? .white : .black)
        
        if let authors = viewModel.book.authors, !authors.isEmpty {
          Text(authors)
            .font(.caption)
            .foregroundColor(headerBackgroundColor.isDark ? .white.opacity(0.8) : .black.opacity(0.8))
        }
      }
      Spacer()
      BookButtonsView(provider: viewModel, backgroundColor: headerBackgroundColor, size: .small) { type in
        handleButtonAction(type)
      }
    }
    .frame(height: 50)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
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
                  NavigationLink(destination: TPPCatalogFeedView(url: url)) {
                    Text(DisplayStrings.more.capitalized)
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
                        BookImageView(book: book, height: 160, showShimmer: true)
                          .padding()
                          .adaptiveShadow(radius: 5)
                          .transition(.opacity.combined(with: .scale))
                      }
                    } else {
                      ShimmerView(width: 100, height: 160)
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
  @ViewBuilder private var sampleToolbarView: some View {
    if viewModel.showSampleToolbar {
      VStack {
        Spacer()
        if let toolbar = sampleToolbar {
          toolbar
        } else {
          AudiobookSampleToolbar(book: viewModel.book)
            .onAppear {
              setupSampleToolbarIfNeeded()
            }
        }
      }
    }
  }
  
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
  
  private func updateImageBottomPosition() {
    let imageHeight = max(280 * imageScale, 80)
    imageBottomPosition = imageTopPadding + imageHeight + 70
  }
 
  private func resetSampleToolbar() {
    viewModel.showSampleToolbar = false
    sampleToolbar?.player.state = .paused
    sampleToolbar = nil
  }
  
  private func setupSampleToolbarIfNeeded() {
    let bookID = viewModel.book.identifier
    
    if sampleToolbar == nil || bookID != currentBookID {
      if let newToolbar = AudiobookSampleToolbar(book: viewModel.book) {
        sampleToolbar = newToolbar
        currentBookID = bookID
      }
    }
  }
  
  private func handleButtonAction(_ buttonType: BookButtonType) {
    switch buttonType {
    case .sample, .audiobookSample:
      viewModel.handleAction(for: buttonType)
    case .download, .get:
      viewModel.showHalfSheet.toggle()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
        viewModel.handleAction(for: buttonType)
      }
    case .manageHold:
      viewModel.isManagingHold = true
      viewModel.showHalfSheet.toggle()
    case .return:
      viewModel.bookState = .returning
      viewModel.showHalfSheet.toggle()
    default:
      viewModel.showHalfSheet.toggle()
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
  
  private var edgeSwipeGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        if value.startLocation.x < 40 && value.translation.width > 0 {
          dragOffset = value.translation.width
        }
      }
      .onEnded { value in
        if value.translation.width > 150 {
          presentationMode.wrappedValue.dismiss()
        } else {
          dragOffset = 0
        }
      }
  }
}

private struct BookStateModifier: ViewModifier {
  @ObservedObject var viewModel: BookDetailViewModel
  @Binding var showHalfSheet: Bool
  @Environment(\.presentationMode) var presentationMode
  
  func body(content: Content) -> some View {
    content
      .onChange(of: viewModel.bookState) { newState in
        if newState == .downloadSuccessful {
          showHalfSheet = false
        }
      }
  }
}

struct TPPCatalogFeedView: UIViewControllerRepresentable {
  var url: URL
  
  func makeUIViewController(context: Context) -> TPPCatalogFeedViewController {
    return TPPCatalogFeedViewController(url: url)
  }
  
  func updateUIViewController(_ uiViewController: TPPCatalogFeedViewController, context: Context) {
  }
}
