import SwiftUI
import UIKit

struct BookDetailView: View {
  typealias DisplayStrings = Strings.BookDetailView
  weak var delegate: BookDetailViewDelegate?
  @State private var selectedBook: TPPBook?
  @State private var showBookDetail = false
  @State private var descriptionText = ""

  @ObservedObject var viewModel: BookDetailViewModel
  @State private var isExpanded: Bool = false
  @State private var coverImage: UIImage = UIImage()
  @State private var headerBackgroundColor: Color = .gray
  @State private var showHalfSheet = false
  @State private var headerHeight: CGFloat = 280
  @State private var showCompactHeader: Bool = false
  @State private var lastOffset: CGFloat = 0
  @State private var lastTimestamp: TimeInterval = 0
  @State private var animationDuration: CGFloat = 0
  @State private var imageScale: CGFloat = 1.0
  @State private var imageOpacity: CGFloat = 1.0
  @State private var sampleToolbar: AudiobookSampleToolbar? = nil

  init(book: TPPBook) {
    self.viewModel = BookDetailViewModel(book: book)
  }

  var body: some View {
    ZStack {
      ScrollView {
        ZStack(alignment: .top) {
          backgroundView
            .frame(height: headerHeight)

          if showCompactHeader {
            compactHeaderContent
              .padding(.top, 75)
              .opacity(showCompactHeader ? 1 : 0)
              .offset(y: showCompactHeader ? 0 : -20)
              .animation(.easeInOut(duration: animationDuration), value: showCompactHeader)
          }

          mainView
            .padding(.bottom, 100)
        }
      }
      .edgesIgnoringSafeArea(.all)
      .background(Color.white)
      .onChange(of: headerBackgroundColor) { newColor in
        delegate?.didUpdateHeaderBackground(isDark: newColor.isDark)
      }
      .onChange(of: showCompactHeader) { newValue in
        self.delegate?.didChangeToCompactView(newValue)
      }
      .onChange(of: viewModel.book) { newValue in
        loadCoverImage()
        viewModel.showSampleToolbar = false
        sampleToolbar?.player.state = .paused
        self.descriptionText = newValue.summary ?? ""
      }
      .onAppear {
        viewModel.fetchRelatedBooks()
        loadCoverImage()
        self.descriptionText = viewModel.book.summary ?? ""
      }
      .onDisappear {
        showHalfSheet = false
      }
      .fullScreenCover(item: $selectedBook) { book in
        BookDetailView(book: book)
      }
      .sheet(isPresented: $showHalfSheet) {
        HalfSheetView(viewModel: viewModel, backgroundColor: headerBackgroundColor, coverImage: coverImage)
      }

      sampleToolbarView
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
      VStack(alignment: .leading, spacing: 30) {
        HStack(alignment: .top, spacing: 25) {
          imageView
          titleView
        }
        .padding(.top, 85)

        descriptionView
        informationView
        relatedBooksView
        Spacer()
      }
      .padding(30)
  }

  private var compactView: some View {
    ZStack {
      VStack(spacing: 10) {
        VStack {
          imageView
            .padding(.top, 110)
            .padding(.bottom, 25)

          titleView
            .opacity(showCompactHeader ? 0 : 1)

          VStack {
            descriptionView
            informationView
          }
          .padding(.top, showCompactHeader ? -115 : 0)
        }
        .padding(.horizontal, 30)

        relatedBooksView
      }
    }
  }

  private var imageView: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(uiImage: coverImage)
        .resizable()
        .scaledToFit()
        .frame(height: max(0, 280 * imageScale))
        .opacity(imageOpacity)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .animation(.easeInOut(duration: animationDuration), value: imageScale)
    }
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

      BookButtonsView(viewModel: viewModel, backgroundColor: viewModel.isFullSize ? headerBackgroundColor : .white) { type in
        switch type {
        case .sample, .audiobookSample:
          viewModel.handleAction(for: type)
        default:
          showHalfSheet.toggle()
        }
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
    viewModel.registry.coverImage(for: viewModel.book) { uiImage in
      guard let uiImage = uiImage else { return }
      self.coverImage = uiImage
      self.headerBackgroundColor = Color(uiImage.mainColor() ?? .gray)

      DispatchQueue.main.async {
          self.delegate?.didUpdateHeaderBackground(isDark: headerBackgroundColor.isDark)
      }
    }
  }

  @ViewBuilder private var relatedBooksView: some View {
    VStack(alignment: .leading, spacing: 10) {
      if viewModel.isLoadingRelatedBooks {
        ProgressView()
          .frame(height: 100)
          .frame(maxWidth: .infinity)
      } else if !viewModel.relatedBooks.isEmpty {
        Text(DisplayStrings.otherBooks)
          .font(.headline)
          .foregroundColor(.black)
          .padding(.horizontal, 30)

        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 12) {
            ForEach(viewModel.relatedBooks, id: \.identifier) { book in
              Button(action: { viewModel.selectRelatedBook(book) }) {
                BookThumbnailView(book: book)
                  .frame(width: 100)
              }
            }
          }
          .padding(.horizontal, 30)
        }
        .frame(height: 180)
      }
    }
    .animation(nil, value: viewModel.relatedBooks)
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
      .background(
        Circle()
          .fill(Color("PalaceBlueLight"))
      )
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
      .background(GeometryReader { proxy in
        Color.clear
          .onAppear { updateHeaderHeight(for: proxy.frame(in: .global).minY) }
          .onChange(of: proxy.frame(in: .global).minY) { newValue in
            updateHeaderHeight(for: newValue)
          }
      })

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
      BookButtonsView(viewModel: viewModel, backgroundColor: headerBackgroundColor, size: .small) { type in
        switch type {
        case .sample, .audiobookSample:
          viewModel.handleAction(for: type)
        default:
          showHalfSheet.toggle()
        }
      }
    }
    .frame(height: 50)
    .padding(.horizontal, 20)
    .padding(.bottom, 10)
  }

  @ViewBuilder private var descriptionView: some View {
    if let _ = viewModel.book.summary {
      VStack(alignment: .leading, spacing: 5) {
        Text(DisplayStrings.description)
          .font(.headline)
          .foregroundColor(.black)
        Divider()

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
        .padding(.top, 5)
      }
    }
  }

  @ViewBuilder private var informationView: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(DisplayStrings.information)
        .font(.headline)
        .foregroundColor(.black)
      Divider()
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.format)
        infoValue(value: self.viewModel.book.format)
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.published)
        infoValue(value: self.viewModel.book.published?.monthDayYearString ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.publisher)
        infoValue(value: self.viewModel.book.publisher ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: self.viewModel.book.categoryStrings?.count == 1 ? DisplayStrings.categories : DisplayStrings.category)
        infoValue(value: self.viewModel.book.categories ?? "")
      }
      HStack(alignment: .bottom) {
        infoLabel(label: DisplayStrings.distributor)
        infoValue(value: self.viewModel.book.distributor ?? "")
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

    let maxHeight: CGFloat = 280
    let compactThreshold: CGFloat = 150
    let expandThreshold: CGFloat = 280
    let now = Date().timeIntervalSince1970
    let timeDelta = now - lastTimestamp
    let offsetDelta = abs(offset) - lastOffset

    let scrollSpeed = abs(offsetDelta / (timeDelta > 0 ? timeDelta : 0.01))
    animationDuration = max(0.2, min(0.3, 0.3 - (scrollSpeed / 10)))

    let newHeight = headerHeight + offset
    let adjustedHeight = max(0, min(newHeight, maxHeight))

    let progress = max(0, min(1, (adjustedHeight - compactThreshold) / (maxHeight - compactThreshold)))
    let scaleFactor = progress
    let opacityFactor = progress

    withAnimation(.interactiveSpring(duration: animationDuration, extraBounce: 0.1, blendDuration: animationDuration)) {
      headerHeight = max(compactThreshold, adjustedHeight)

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
}


struct BookThumbnailView: View {
  let book: TPPBook

  @State private var image: UIImage? = nil


  var body: some View {
    VStack {
      if let uiImage = image {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFit()
          .frame(width: 90, height: 160)
      } else {
        ProgressView()
          .frame(width: 90, height: 160)
          .tint(.primary)
          .onAppear {
            loadImage()
          }
      }

    }
    .frame(width: 100)
  }

  private func loadImage() {
    guard let url = book.imageThumbnailURL ?? book.imageURL else { return }

    DispatchQueue.global(qos: .background).async {
      if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
        DispatchQueue.main.async {
          self.image = uiImage
        }
      }
    }
  }
}
