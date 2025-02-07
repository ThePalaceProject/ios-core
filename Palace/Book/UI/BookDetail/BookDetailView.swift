import SwiftUI
import UIKit

struct BookDetailView: View {
  typealias DisplayStrings = Strings.BookDetailView

  @StateObject var viewModel: BookDetailViewModel
  @State private var isExpanded: Bool = false

  var body: some View {
    ZStack(alignment: .top) {
      backgroundView
        .edgesIgnoringSafeArea(.all)

      mainView
      Spacer()
    }
    .overlay(
      VStack {
        if viewModel.state == .downloading {
          BookDetailDownloadingView(
            progress: viewModel.downloadProgress,
            onCancel: { viewModel.handleAction(for: .cancel) }
          )
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom))
        }
      },
      alignment: .bottom
    )
  }

  @ViewBuilder private var mainView: some View {
    if UIDevice.current.isIpad {
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
      }
      .padding(30)
    }
  }

  private var compactView: some View {
    Text("Empty View")
  }

  private var imageView: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(uiImage: viewModel.coverImage)
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
    VStack(alignment: .leading, spacing: 8) {
      Text(viewModel.book.title)
        .font(.title3)

      if let authors = viewModel.book.authors, !authors.isEmpty {
        Text(authors)
          .font(.footnote)
          .foregroundColor(.secondary)
      }

      BookButtonsView(viewModel: BookDetailViewModel(book: viewModel.book))

      if !viewModel.book.isAudiobook && viewModel.book.hasAudiobookSample {
        audiobookAvailable
          .padding(.top)
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
          viewModel.backgroundColor.opacity(1.0),
          viewModel.backgroundColor.opacity(0.5)
        ]),
        startPoint: .bottom,
        endPoint: .top
      )
      .frame(height: 340)
    }
    .edgesIgnoringSafeArea(.top)
  }

  @ViewBuilder private var descriptionView: some View {
    if let htmlSummary = viewModel.book.summary {
      VStack(alignment: .leading, spacing: 5) {
        Text(DisplayStrings.description)
          .font(.headline)
          .foregroundColor(.black)
        Divider()
          AttributedTextView(htmlContent: htmlSummary)
            .foregroundColor(.black)
            .font(.body)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        Button(isExpanded ? DisplayStrings.less.capitalized : DisplayStrings.more.capitalized) {
          isExpanded.toggle()
        }
        .foregroundColor(.black)
        .bottomrRightJustified()
      }
      .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : 150)
    } else {
      ProgressView()
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
