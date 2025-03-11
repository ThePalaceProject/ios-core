import SwiftUI
import UIKit

struct BookDetailView: View {
  @Environment(\.presentationMode) var presentationMode

  typealias DisplayStrings = Strings.BookDetailView
  @State private var selectedBook: TPPBook?
  @State private var showBookDetail = false
  @State private var descriptionText = ""

  @ObservedObject var viewModel: BookDetailViewModel
  @State private var isExpanded: Bool = false
  @State private var headerBackgroundColor: Color = .gray
  @State private var showHalfSheet = false
  @State private var headerHeight: CGFloat = 250
  @State private var showCompactHeader: Bool = false
  @State private var lastOffset: CGFloat = 0
  @State private var lastTimestamp: TimeInterval = 0
  @State private var animationDuration: CGFloat = 0.4
  @State private var imageScale: CGFloat = 1.0
  @State private var imageOpacity: CGFloat = 1.0
  @State private var sampleToolbar: AudiobookSampleToolbar? = nil
  @State private var dragOffset: CGFloat = 0
  @State private var imageBottomPosition: CGFloat = 400

  init(book: TPPBook) {
    self.viewModel = BookDetailViewModel(book: book)
  }

  var body: some View {
    ZStack(alignment: .top) {
      ScrollView(showsIndicators: false) {
        mainView
          .padding(.bottom, 100)
          .background(GeometryReader { proxy in
            Color.clear
              .onChange(of: proxy.frame(in: .global).minY) { newValue in
                updateHeaderHeight(for: newValue)
              }
          })
      }
      .edgesIgnoringSafeArea(.all)
      .onChange(of: viewModel.book) { newValue in
        loadCoverImage()
        viewModel.showSampleToolbar = false
        sampleToolbar?.player.state = .paused
        sampleToolbar = nil
        self.descriptionText = newValue.summary ?? ""
      }
      .onAppear {
        loadCoverImage()
        viewModel.fetchRelatedBooks()
        self.descriptionText = viewModel.book.summary ?? ""
      }
      .onDisappear {
        showHalfSheet = false
      }
      .fullScreenCover(item: $selectedBook) { book in
        BookDetailView(book: book)
      }
      .sheet(isPresented: $showHalfSheet) {
        HalfSheetView(viewModel: viewModel, backgroundColor: headerBackgroundColor, coverImage: $viewModel.book.coverImage)
      }
      .presentationDetents([.medium])

      backgroundView
        .frame(height: headerHeight)

      imageView
        .padding(.top, 50)

      if showCompactHeader {
        compactHeaderContent
          .opacity(showCompactHeader ? 1 : 0)
          .offset(y: showCompactHeader ? 0 : -20)
          .animation(.easeInOut(duration: animationDuration), value: showCompactHeader)
      }

      backbutton
      sampleToolbarView
    }
    .background(.white)
    .offset(x: dragOffset)
    .animation(.interactiveSpring(), value: dragOffset)
    .gesture(edgeSwipeGesture)
  }

  @ViewBuilder private var backbutton: some View {
    if !showCompactHeader {
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
      .animation(.easeInOut(duration: animationDuration), value: imageScale)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 50)
      .padding(.top, UIDevice.current.isIpad ? 40 : 50)
      .padding(.leading)
      .zIndex(10)
      .edgesIgnoringSafeArea(.top)
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
        .padding(.top, 85)

        descriptionView
        informationView
        Spacer()
      }
      .padding(30)

      relatedBooksView
    }
  }

  private var compactView: some View {
    withAnimation {
      VStack(spacing: 10) {
        VStack {
          titleView
            .scaleEffect(imageScale)
            .opacity(showCompactHeader ? 0 : 1)
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
    }
  }

  private var imageView: some View {
    BookImageView(book: viewModel.book, height: 280 * imageScale, showShimmer: true, shimmerDuration: 0.8)
      .opacity(imageOpacity)
      .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
      .animation(.easeInOut(duration: animationDuration), value: imageScale)
      .background(GeometryReader { geo in
        Color.clear
          .onAppear {
            let imageHeight = max(280 * imageScale, 100)
            let imageTopPadding: CGFloat = 80
            imageBottomPosition = imageTopPadding + imageHeight + 70
          }
          .onChange(of: imageScale) { newScale in
            let imageHeight = max(280 * imageScale, 80)
            let imageTopPadding: CGFloat = 80
            imageBottomPosition = imageTopPadding + imageHeight + 70
          }
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

      BookButtonsView(provider: viewModel, backgroundColor: viewModel.isFullSize ? headerBackgroundColor : .white) { type in
        handleButtonAction(type)
      }

      if !viewModel.book.isAudiobook && viewModel.book.hasAudiobookSample {
        audiobookAvailable
          .padding(.top)
      }
    }
    .foregroundColor(headerBackgroundColor.isDark && viewModel.isFullSize ? .white : .black)
    .animation(.easeInOut(duration: animationDuration), value: imageScale)
  }

  private func loadCoverImage() {
    self.headerBackgroundColor = Color(viewModel.book.coverImage?.mainColor() ?? .gray)
  }

  private func handleButtonAction(_ buttonType: BookButtonType) {
    switch buttonType {
    case .sample, .audiobookSample:
      viewModel.handleAction(for: buttonType)
    case .download, .get:
      showHalfSheet.toggle()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
        viewModel.handleAction(for: buttonType)
      }
    default:
      showHalfSheet.toggle()
    }
  }

  @ViewBuilder private var relatedBooksView: some View {
    VStack(alignment: .leading, spacing: 20) {
      if !viewModel.relatedBooks.isEmpty {
        Text(DisplayStrings.otherBooks.uppercased())
          .font(.headline)
          .foregroundColor(.black)
          .padding(.horizontal, 30)

        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 12) {
            ForEach(viewModel.relatedBooks.indices, id: \.self) { index in
              if let book = viewModel.relatedBooks[safe: index], let book {
                Button(action: { viewModel.selectRelatedBook(book) }) {
                  BookImageView(book: book, height: 160, showShimmer: true)
                    .transition(.opacity.combined(with: .scale))
                }
              } else {
                ShimmerView(width: 100, height: 160)
              }
            }
          }
          .padding(.horizontal, 30)
        }
        .frame(height: 180)
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
          .foregroundColor(.black)
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

  private func setupSampleToolbarIfNeeded() {
    let bookID = viewModel.book.identifier

    if sampleToolbar == nil || bookID != currentBookID {
      if let newToolbar = AudiobookSampleToolbar(book: viewModel.book) {
        sampleToolbar = newToolbar
        currentBookID = bookID
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

  private var backgroundView: some View {
    ZStack(alignment: .top) {
      Color.white
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
    if let _ = viewModel.book.summary {
      VStack(alignment: .leading, spacing: 10) {
        Text(DisplayStrings.description.uppercased())
          .font(.headline)
          .foregroundColor(.black)
        Divider()
          .padding(.vertical)

        VStack {
          AttributedTextView(htmlContent: $descriptionText)
            .foregroundColor(.black)
            .font(.body)
            .lineLimit(nil)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: isExpanded ? 200 : 50)
        .clipped()

        Button(isExpanded ? DisplayStrings.less.capitalized : DisplayStrings.more.capitalized) {
          withAnimation {
            isExpanded.toggle()
          }
        }
        .bottomrRightJustified()
        .foregroundColor(.black)
        .padding(.bottom)
      }
    }
  }

  @ViewBuilder private var informationView: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(DisplayStrings.information.uppercased())
        .font(.headline)
        .foregroundColor(.black)
      Divider()
        .padding(.vertical)
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.format.uppercased())
        infoValue(value: self.viewModel.book.format)
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.published.uppercased())
        infoValue(value: self.viewModel.book.published?.monthDayYearString ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.publisher.uppercased())
        infoValue(value: self.viewModel.book.publisher ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: self.viewModel.book.categoryStrings?.count == 1 ? DisplayStrings.categories.uppercased() : DisplayStrings.category.uppercased())
        infoValue(value: self.viewModel.book.categories ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.distributor.uppercased())
        infoValue(value: self.viewModel.book.distributor ?? "")
      }
      if viewModel.book.isAudiobook {
        HStack(alignment: .bottom) {
          infoLabel(label: DisplayStrings.narrators.uppercased())
          infoValue(value: self.viewModel.book.narrators ?? "")
        }
        HStack(alignment: .bottom) {
          infoLabel(label: DisplayStrings.duration.uppercased())
          infoValue(value: self.viewModel.book.bookDuration ?? "")
        }
      }
      Spacer()
    }
  }

  @ViewBuilder private func infoLabel(label: String) -> some View {
    Text(label)
      .font(Font.boldPalaceFont(size: 12))
      .foregroundColor(.gray)
      .frame(width: 100, alignment: .leading)
  }

  @ViewBuilder private func infoValue(value: String) -> some View {
    if let url = URL(string: value), UIApplication.shared.canOpenURL(url) {
      Link(value, destination: url)
        .font(.subheadline)
        .underline()
        .foregroundColor(.black)
    } else {
      Text(value)
        .font(.subheadline)
        .foregroundColor(.black)
    }
  }

  private func updateHeaderHeight(for offset: CGFloat) {
    guard !viewModel.isFullSize else { return }

    let maxHeight: CGFloat = 250
    let minHeight: CGFloat = 80

    let compactThreshold: CGFloat = 80
    let expandThreshold: CGFloat = 220
    let now = Date().timeIntervalSince1970

    let newHeight = headerHeight + offset
    let adjustedHeight = max(0, min(newHeight, maxHeight))

    let progress = max(0, min(1, (adjustedHeight - minHeight) / (maxHeight - minHeight)))
    let scaleFactor = progress
    let opacityFactor = progress

    withAnimation(.interactiveSpring(duration: animationDuration, extraBounce: 0.2, blendDuration: animationDuration)) {
      headerHeight = max(minHeight, adjustedHeight)

      if adjustedHeight <= compactThreshold {
        showCompactHeader = true
      } else if adjustedHeight >= expandThreshold {
        showCompactHeader = false
      }

      imageScale = scaleFactor
      imageOpacity = opacityFactor
    }

    lastOffset = abs(offset)
    lastTimestamp = now
  }

  private var edgeSwipeGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        if value.startLocation.x < 40 {
          if value.translation.width > 0 {
            dragOffset = value.translation.width
          }
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
