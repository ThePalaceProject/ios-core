import SwiftUI
import UIKit

struct BookDetailView: View {
  typealias DisplayStrings = Strings.BookDetailView
  @State private var selectedBook: TPPBook?
  @State private var showBookDetail = false
  @State private var descriptionText = ""

  @ObservedObject var viewModel: BookDetailViewModel
  @State private var isExpanded: Bool = false
  @State private var coverImage: UIImage = UIImage()
  @State private var headerBackgroundColor: Color = .gray
  @State private var showHalfSheet = false

  init(book: TPPBook) {
    self.viewModel = BookDetailViewModel(book: book)
  }

  var body: some View {
    ScrollView {
      ZStack(alignment: .top) {
        backgroundView
          .edgesIgnoringSafeArea(.all)

        mainView
      }
    }
    .onDisappear {
      showHalfSheet = false
    }
    .onAppear {
      loadCoverImage()
      setTransparentNavigationBar()
      self.descriptionText =  viewModel.book.summary ?? ""
    }
    .onChange(of: viewModel.book) { newValue in
      loadCoverImage()
      self.descriptionText =  newValue.summary ?? ""
    }
    .background(Color.white)
    .fullScreenCover(item: $selectedBook) { book in
      BookDetailView(book: book)
    }
    .sheet(isPresented: $showHalfSheet) {
      HalfSheetView(viewModel: viewModel, backgroundColor: headerBackgroundColor, coverImage: self.$coverImage.wrappedValue)
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
    ZStack {
      sampleToolbar

      VStack(alignment: .leading, spacing: 30) {
        HStack(alignment: .top, spacing: 25) {
          imageView
          titleView
        }
        .padding(.top, 85)

        descriptionView
        informationView
        relatedBooksSection
        Spacer()
      }
      .padding(30)
    }
    .onAppear {
      viewModel.fetchRelatedBooks()
    }
  }

  private var compactView: some View {
    ZStack {
      VStack {
        imageView
          .padding(.vertical, 25)
        titleView
        descriptionView
        informationView
        relatedBooksSection
      }
      VStack {
        Spacer()
        sampleToolbar
      }
    }
    .padding(30)
    .onAppear {
      viewModel.fetchRelatedBooks()
    }
  }

  private var imageView: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(uiImage: coverImage)
        .resizable()
        .scaledToFit()
        .frame(height: 280)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)

      if viewModel.book.isAudiobook {
        audiobookIndicator
          .padding(8)
      }
    }
  }

  private var titleView: some View {
    VStack(alignment: viewModel.isFullSize ? .leading : .center, spacing: 8) {
      Text(viewModel.book.title)
        .font(.title3)
        .lineLimit(0)
        .fixedSize(horizontal: false, vertical: true)

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
  }

  private func loadCoverImage() {
    viewModel.registry.coverImage(for: viewModel.book) { uiImage in
        guard let uiImage = uiImage else { return }
        self.coverImage = uiImage
        self.headerBackgroundColor = Color(uiImage.mainColor() ?? .gray)
    }
  }

  @ViewBuilder private var relatedBooksSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if viewModel.isLoadingRelatedBooks {
        Text("OTHER BOOKS BY THIS AUTHOR")
          .font(.headline)
          .foregroundColor(.black)

        Divider()

        ProgressView()
          .tint(.black)
          .frame(height: 100)
          .frame(maxWidth: .infinity)
          .padding()
          .foregroundColor(.black)
          .horizontallyCentered()

      } else if !viewModel.relatedBooks.isEmpty {
        
        Text("OTHER BOOKS BY THIS AUTHOR")
          .font(.headline)
          .foregroundColor(.black)

        Divider()

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(viewModel.relatedBooks, id: \.identifier) { book in
              Button(action: { viewModel.selectRelatedBook(book) }) {
                BookThumbnailView(book: book)
              }
            }
          }
          .padding(.horizontal)
        }
      }
    }
    .padding(.top, 10)
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

  @ViewBuilder private var sampleToolbar: some View {
    if viewModel.showSampleToolbar {
      VStack {
        Spacer()
        AudiobookSampleToolbar(book: viewModel.book)
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
      .frame(height: 280)
    }
    .edgesIgnoringSafeArea(.top)
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

  private func setTransparentNavigationBar() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

    UINavigationBar.appearance().setAppearance(appearance)
  }
}

struct BookDetailDownloadingView: View {
  let progress: Double
  let onCancel: () -> Void

  var body: some View {
    VStack {
      ProgressView(value: progress, total: 1.0)
        .progressViewStyle(LinearProgressViewStyle())
        .frame(maxWidth: .infinity)
    }
    .padding()
    .background(Color.primary.opacity(0.9))
    .cornerRadius(8)
    .shadow(radius: 10)
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
