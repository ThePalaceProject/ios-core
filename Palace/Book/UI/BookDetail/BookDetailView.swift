import SwiftUI
import UIKit

struct BookDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appContainer) private var appContainer

    private var coordinator: NavigationCoordinator? {
        appContainer.navigationCoordinatorHub.coordinator
    }

    typealias DisplayStrings = Strings.BookDetailView
    @State private var selectedBook: TPPBook?
    @State private var descriptionText = ""

    /// Use @StateObject to ensure the ViewModel survives view recreation.
    /// This prevents related books from disappearing after dismissing
    /// the preview fullScreenCover (which can cause SwiftUI to recreate the view).
    @StateObject var viewModel: BookDetailViewModel
    @State private var isExpanded: Bool = false
    @State private var headerHeight: CGFloat = UIDevice.current.isIpad ? 300 : 225
    @State private var showCompactHeader: Bool = false
    @State private var lastOffset: CGFloat = 0
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOpacity: CGFloat = 1.0
    @State private var titleOpacity: CGFloat = 1.0
    @State private var dragOffset: CGFloat = 0
    @State private var imageBottomPosition: CGFloat = 400
    @State private var lastBookIdentifier: String?
    @AccessibilityFocusState private var isTitleFocused: Bool
    @State private var initialLayoutComplete: Bool = false
    @State private var currentOrientation: UIDeviceOrientation = UIDevice.current.orientation
    /// Tracks whether this view instance has already laid out its collapsing
    /// header. `.onAppear` fires again on back-navigation (e.g. returning from
    /// the series list), but the ScrollView keeps its scrolled-down position —
    /// so re-running the expand reset would leave an expanded header stranded
    /// over scrolled content. Reset the header only on the first appearance and
    /// preserve the collapsed/expanded state on subsequent re-appearances.
    @State private var hasAppeared: Bool = false

    private let scaleAnimation = Animation.linear(duration: 0.35)

    @State private var headerColor: Color = Color(UIColor.systemBackground)

    private let maxHeaderHeight: CGFloat = 225
    private let minHeaderHeight: CGFloat = 80
    private let imageTopPadding: CGFloat = 80
    private let dampingFactor: CGFloat = 0.95

    init(book: TPPBook) {
        // Use _viewModel to initialize @StateObject with a parameter
        // This ensures SwiftUI only creates the ViewModel once per view identity
        _viewModel = StateObject(wrappedValue: BookDetailViewModel(book: book))
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
                                    .onChange(of: proxy.frame(in: .global).minY) { _, newValue in
                                        updateHeaderHeight(for: newValue)
                                    }
                            })
                    }
                }
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .onChange(of: viewModel.book.identifier) { _, newIdentifier in
                    if lastBookIdentifier != newIdentifier {
                        lastBookIdentifier = newIdentifier
                        resetSampleToolbar()
                        let newSummary = viewModel.book.summary ?? ""
                        if self.descriptionText != newSummary { self.descriptionText = newSummary }
                        proxy.scrollTo(0, anchor: .top)
                        // A genuinely new book scrolls back to the top, so the
                        // collapsing header must expand to match (see hasAppeared).
                        expandHeader()
                    } else {
                        let newSummary = viewModel.book.summary ?? self.descriptionText
                        if self.descriptionText != newSummary { self.descriptionText = newSummary }
                    }
                }
            }
            .onAppear {
                headerColor = Color(viewModel.book.dominantUIColor)
                lastBookIdentifier = viewModel.book.identifier

                // Only reset the collapsing header on the first appearance.
                // On back-navigation the ScrollView retains its offset, so
                // preserving the header state keeps it in sync with the
                // scroll position instead of snapping back to fully expanded.
                if !hasAppeared {
                    hasAppeared = true
                    expandHeader()
                }

                viewModel.fetchRelatedBooks()
                Task { await viewModel.hydrateMetadataIfNeeded() }
                self.descriptionText = viewModel.book.summary ?? ""

                NotificationCenter.default.post(name: .TPPAccessibilityScreenTransition, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isTitleFocused = true
                }
            }
            .onDisappear {
                viewModel.showHalfSheet = false
                viewModel.processingButtons.removeAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                handleOrientationChange()
            }
            .onReceive(viewModel.book.$dominantUIColor) { newColor in
                // Don't update while half sheet is showing to prevent unnecessary re-renders
                guard !viewModel.showHalfSheet else { return }

                accessibleWithAnimation(.easeInOut(duration: 0.2)) {
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
                        dismiss()
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
            .alert(item: $viewModel.confirmationAlert) { alert in
                if let secondaryTitle = alert.secondaryButtonTitle {
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        primaryButton: .destructive(
                            Text(alert.buttonTitle ?? Strings.Generic.ok),
                            action: alert.primaryAction
                        ),
                        secondaryButton: .cancel(
                            Text(secondaryTitle),
                            action: alert.secondaryAction
                        )
                    )
                } else {
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(
                            Text(alert.buttonTitle ?? Strings.Generic.ok),
                            action: alert.primaryAction
                        )
                    )
                }
            }

            if !viewModel.isFullSize {
                backgroundView
                    .frame(height: headerHeight)
                    .accessibleAnimation(scaleAnimation, value: headerHeight)

                imageView
                    .padding(.top, 50)
            }

            compactHeaderContent
                .opacity(showCompactHeader ? 1 : 0)
                .accessibleAnimation(scaleAnimation, value: -headerHeight)

            SamplePreviewBarView()
        }
        .offset(x: dragOffset)
        .accessibleAnimation(.interactiveSpring(), value: dragOffset)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    if let coordinator = coordinator {
                        coordinator.pop()
                    } else {
                        dismiss()
                    }
                }, label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(Strings.Generic.back)
                            .palaceFont(.body)
                    }
                    .foregroundStyle(headerColor.isDark ? .white : .black)
                })
                .accessibilityLabel(Strings.Generic.goBack)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .modifier(BookStateModifier(viewModel: viewModel, showHalfSheet: $viewModel.showHalfSheet))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ToggleSampleNotification")).receive(on: RunLoop.main)) { note in
            guard let info = note.userInfo as? [String: Any], let identifier = info["bookIdentifier"] as? String else { return }
            let action = (info["action"] as? String) ?? "toggle"
            if action == "close" {
                appContainer.samplePreviewManager.close()
                return
            }
            if let book = viewModel.registry.book(forIdentifier: identifier) ?? (viewModel.relatedBooksByLane.values.flatMap { $0.books }).first(where: { $0.identifier == identifier }) {
                appContainer.samplePreviewManager.toggle(for: book)
            } else if viewModel.book.identifier == identifier {
                appContainer.samplePreviewManager.toggle(for: viewModel.book)
            }
        }
        .onDisappear { appContainer.samplePreviewManager.close() }
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
            if let win = UIApplication.shared.mainKeyWindow {
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
                    .accessibleAnimation(scaleAnimation, value: titleOpacity)

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
        .accessibleAnimation(scaleAnimation, value: imageBottomPosition)
    }

    private var imageView: some View {
        BookImageView(book: viewModel.book, height: 280 * imageScale, treatImageAsDecorativeInLists: true)
            .accessibilityIdentifier(AccessibilityID.BookDetail.coverImage)
            .opacity(imageOpacity)
            .adaptiveShadow()
            .accessibleAnimation(scaleAnimation, value: imageScale)
            .accessibleAnimation(scaleAnimation, value: imageOpacity)
            .background(GeometryReader { _ in
                Color.clear
                    .onAppear { updateImageBottomPosition() }
                    .onChange(of: imageScale) { _, _ in updateImageBottomPosition() }
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
                .accessibilityFocused($isTitleFocused)

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
        .foregroundStyle(viewModel.isFullSize ? (headerColor.isDark ? .white : .black) : Color(UIColor.label))
        .accessibleAnimation(scaleAnimation, value: imageScale)
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
                    .foregroundStyle(headerColor.isDark ? .white : .black)

                if let authors = viewModel.book.authors, !authors.isEmpty {
                    Text(authors)
                        .font(.caption)
                        .foregroundStyle(headerColor.isDark ? .white.opacity(0.8) : .black.opacity(0.8))
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
            VStack(alignment: .leading, spacing: 10) {
                Text(DisplayStrings.description.uppercased())
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Divider()
                    .padding(.vertical)

                VStack {
                    HTMLTextView(htmlContent: self.descriptionText)
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: isExpanded ? .infinity : 150, alignment: .top)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        Color.white
                        LinearGradient(
                            stops: [
                                .init(color: .white,                location: 0.0),
                                .init(color: .white.opacity(0.85), location: 0.25),
                                .init(color: .white.opacity(0.45), location: 0.55),
                                .init(color: .white.opacity(0.10), location: 0.80),
                                .init(color: .clear,               location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: isExpanded ? 0 : 70)
                    }
                )

                Button(isExpanded ? DisplayStrings.less.capitalized : DisplayStrings.more.capitalized) {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) {
                        isExpanded.toggle()
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                        .accessibilityAddTraits(.isHeader)

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
                                    NavigationLink(destination: CatalogLaneMoreView(url: url, appContainer: appContainer)) {
                                        Text(DisplayStrings.more.capitalized)
                                            .foregroundStyle(.primary)
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
                                            }, label: {
                                                BookImageView(book: book, height: 160, treatImageAsDecorativeInLists: true)
                                                    .padding()
                                                    .adaptiveShadow(radius: 5)
                                                    .transition(.opacity.combined(with: .scale))
                                            })
                                            .accessibilityLabel(bookAccessibilityLabel(for: book))
                                        } else {
                                            SkeletonCover(width: 100, height: 160)
                                        }
                                    }
                                }
                                .padding(.horizontal, 30)

                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(lane.title)
                            .accessibilityValue(Strings.SearchAnnouncements.searchResultsListValue(bookCount: lane.books.count))
                            .accessibilityHint(Strings.Generic.horizontalLaneHint)
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

    @State private var currentBookID: String?

    @ViewBuilder private var audiobookIndicator: some View {
        ImageProviders.MyBooksView.audiobookBadge
            .scaledToFit()
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.colorAudiobookBackground))
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var informationView: some View {
        // ordered by patron decision-making priority Format/Audience/
        // Category/Language up top ("what is this?"), Narrators/Duration next
        // ("what's the listening experience like?" — audiobooks only),
        // publication metadata last. Empty fields are omitted entirely
        // (AC #5) so we don't ship rows like "PUBLISHED  —" anymore.
        let book = self.viewModel.book
        VStack(alignment: .leading, spacing: 5) {
            Text(DisplayStrings.information.uppercased())
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Divider()
                .padding(.vertical)

            infoRow(label: DisplayStrings.format.uppercased(),
                    value: book.format,
                    accessibilityID: AccessibilityID.BookDetail.formatLabel)

            infoRow(label: DisplayStrings.audience.uppercased(),
                    value: book.audience,
                    accessibilityID: AccessibilityID.BookDetail.audienceLabel)

            let categoryLabel = book.categoryStrings?.count == 1
                ? DisplayStrings.categories.uppercased()
                : DisplayStrings.category.uppercased()
            infoRow(label: categoryLabel,
                    value: book.categories,
                    accessibilityID: AccessibilityID.BookDetail.categoriesLabel)

            infoRow(label: DisplayStrings.language.uppercased(),
                    value: book.displayLanguage,
                    accessibilityID: AccessibilityID.BookDetail.languageLabel)

            if book.isAudiobook {
                infoRow(label: DisplayStrings.narrators.uppercased(),
                        value: book.narrators,
                        accessibilityID: AccessibilityID.BookDetail.narratorsLabel)
                infoRow(label: DisplayStrings.duration.uppercased(),
                        value: book.bookDuration.flatMap { formatDuration($0) },
                        accessibilityID: AccessibilityID.BookDetail.durationLabel)
            }

            infoRow(label: DisplayStrings.published.uppercased(),
                    value: book.published?.monthDayYearString,
                    accessibilityID: AccessibilityID.BookDetail.publishedLabel)

            // PP-4463: series row links to the same destination as the bottom
            // series carousel — CatalogLaneMoreView keyed on book.seriesURL.
            // Hidden entirely when either the name or the URL is missing so
            // the Information block stays free of empty rows (AC #2).
            // Positioned right after PUBLISHED per design.
            seriesRow(book: book)

            infoRow(label: DisplayStrings.publisher.uppercased(),
                    value: book.publisher,
                    accessibilityID: AccessibilityID.BookDetail.publisherLabel)
            infoRow(label: DisplayStrings.distributor.uppercased(),
                    value: book.distributor,
                    accessibilityID: AccessibilityID.BookDetail.distributorLabel)

            Spacer()
        }
    }

    // MARK: - Helper Functions

    /// Renders an INFORMATION row, but only when `value` is non-nil and non-empty
    /// (AC #5 — fields with no available data are omitted).
    @ViewBuilder
    private func infoRow(label: String, value: String?, accessibilityID: String) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                infoLabel(label: label)
                    .frame(minWidth: 100, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                infoValue(value: value)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityID)
        }
    }

    @ViewBuilder private func infoLabel(label: String) -> some View {
        Text(label)
            .palaceFont(.caption, weight: .bold)
            .lineLimit(1)
    }

    /// PP-4463: SERIES information row. Renders only when the book carries
    /// both a series name and series URL (AC #2). The series name is wrapped
    /// in a NavigationLink whose destination matches the existing series-lane
    /// "More" affordance at the bottom of the screen — `CatalogLaneMoreView`
    /// keyed on `book.seriesURL` — so the row is an alternate path to the
    /// same list, not a new navigation paradigm (AC #4).
    @ViewBuilder
    private func seriesRow(book: TPPBook) -> some View {
        if let seriesName = book.seriesName, !seriesName.isEmpty,
           let seriesURL = book.seriesURL {
            HStack(alignment: .top, spacing: 10) {
                infoLabel(label: DisplayStrings.series.uppercased())
                    .frame(minWidth: 100, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                NavigationLink(destination: CatalogLaneMoreView(url: seriesURL, appContainer: appContainer)) {
                    Text(seriesName)
                        .font(.subheadline)
                        .underline()
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier(AccessibilityID.BookDetail.seriesLink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(DisplayStrings.series): \(seriesName)")
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier(AccessibilityID.BookDetail.seriesLabel)
        }
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
        var components = [book.title]
        if book.isAudiobook {
            components.append(Strings.Generic.audiobook)
        }
        if let authors = book.authors, !authors.isEmpty {
            components.append(authors)
        }
        return components.joined(separator: ", ")
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

        accessibleWithAnimation(.easeInOut(duration: 0.3)) {
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
        appContainer.samplePreviewManager.close()
    }

    private func setupSampleToolbarIfNeeded() {
        let bookID = viewModel.book.identifier

        if !appContainer.samplePreviewManager.isShowingPreview(for: viewModel.book) || bookID != currentBookID {
            currentBookID = bookID
        }
    }

    private func handleButtonAction(_ buttonType: BookButtonType) {
        let account = appContainer.accountsManager.currentUserAccount
        let needsAuth = account.needsAuth && !account.hasCredentials()

        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // now flags this if BookButtonType gains a new case, so a button
        // can't be silently funneled into the half-sheet-toggle fallback.
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
            accessibleWithAnimation(.spring()) {
                viewModel.showHalfSheet.toggle()
            }

        case .readStreaming:
            // PP-4161: route straight through the view model — no half-sheet,
            // no sign-in detour. The reader is presented by
            // NavigationCoordinator's streamingHTML route; if the user isn't
            // signed in they wouldn't have a borrowed streaming-HTML book in
            // the first place (the button only surfaces post-borrow).
            viewModel.handleAction(for: buttonType)

        case .return, .remove, .cancelHold:
            if needsAuth {
                // Present sign-in for return/cancel actions
                viewModel.handleAction(for: buttonType)
            } else if buttonType == .cancelHold {
                // Guard hold cancellations with a confirmation alert — the action
                // fires a server-side revoke with no other confirmation gate here.
                viewModel.confirmationAlert = AlertModel(
                    title: Strings.BookCell.removeHold,
                    message: String(format: Strings.BookCell.removeHoldMessage, viewModel.book.title),
                    buttonTitle: Strings.BookCell.removeHold,
                    primaryAction: { [weak viewModel] in
                        viewModel?.showHalfSheet = true
                        viewModel?.handleAction(for: .cancelHold)
                    },
                    secondaryButtonTitle: Strings.Generic.cancel,
                    secondaryAction: {}
                )
            } else {
                if buttonType == .return {
                    viewModel.bookState = .returning
                }
                accessibleWithAnimation(.spring()) {
                    viewModel.showHalfSheet = true
                }
                if buttonType != .return {
                    viewModel.handleAction(for: buttonType)
                }
            }

        case .read, .listen, .retry, .cancel, .returning, .close:
            // read/listen open the reader, retry/cancel/returning/close are
            // half-sheet-local actions — all share the same "toggle half-sheet"
            // fallback. Listed explicitly to preserve exhaustive matching.
            accessibleWithAnimation(.spring()) {
                viewModel.showHalfSheet.toggle()
            }
        }
    }

    /// Resets the collapsing header to fully expanded. Shared by the
    /// first-appearance path and the new-book path (both land the scroll at
    /// the top, so the header must match).
    private func expandHeader() {
        showCompactHeader = false
        headerHeight = viewModel.isFullSize ? 300 : 225
        imageScale = 1.0
        imageOpacity = 1.0
        titleOpacity = 1.0
        lastOffset = 0
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
                        dismiss()
                    }
                }, label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                        Text("Back")
                            .palaceFont(.body)
                    }
                    .foregroundStyle(headerColor.isDark ? .white : .black)
                })
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
    @Environment(\.dismiss) var dismiss
    @Environment(\.appContainer) private var appContainer

    private var coordinator: NavigationCoordinator? {
        appContainer.navigationCoordinatorHub.coordinator
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.bookState) { _, _ in
            }
    }
}
