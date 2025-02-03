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
  }

  @ViewBuilder private var mainView: some View {
    if UIDevice.current.isIpad {
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
    }
    .padding(30)
  }

  private var compactView: some View {
    Text("Empty View")
  }

  private var imageView: some View {
    Image(uiImage: viewModel.coverImage)
      .resizable()
      .scaledToFit()
      .frame(height: 280)
      .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
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

      HStack(spacing: 25) {
        Button("Borrow") {

        }
        .padding(10)
        .foregroundColor(.black)
        .background(.white)
        .cornerRadius(10)

        Button(DisplayStrings.preview) {

        }
        .buttonStyle(.plain)
      }
      .padding(.vertical)

      audiobookIndicator
        .padding(.top, 50)
    }
  }

  @ViewBuilder private var audiobookIndicator: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      HStack(alignment: .center, spacing: 5) {
        ImageProviders.MyBooksView.audiobookBadge
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
          .background(
            Circle()
              .fill(Color("PalaceBlueLight"))
          )
          .padding(8)
        Text(Strings.BookDetailView.audiobookAvailable)
          .foregroundColor(.black)
      }
      Divider()
    }
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
      HStack(spacing: 100) {
        VStack(alignment: .leading) {
          infoLabel(label: DisplayStrings.format)
          infoLabel(label: DisplayStrings.published)
          infoLabel(label: DisplayStrings.publisher)
          infoLabel(label: self.viewModel.book.categoryStrings?.count == 1 ? DisplayStrings.categories : DisplayStrings.category)
          infoLabel(label: DisplayStrings.distributor)
        }
        VStack(alignment: .leading) {
          infoValue(value: self.viewModel.book.format)
          infoValue(value: self.viewModel.book.published?.monthDayYearString ?? "")
          infoValue(value: self.viewModel.book.publisher ?? "")
          infoValue(value: self.viewModel.book.categories ?? "")
          infoValue(value: self.viewModel.book.distributor ?? "")
        }
      }
      Spacer()
    }
  }

  @ViewBuilder private func infoLabel(label: String) -> some View {
    Text(label)
      .font(Font.boldPalaceFont(size: 12))
      .foregroundColor(.gray)
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

