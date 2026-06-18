//
//  TPPReaderPositionsVC.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 4/23/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit
import PureLayout

/// A protocol describing callbacks for the possible user actions related
/// to TOC items and bookmarks (aka positions).
/// - See: `TPPReaderPositionsVC`
protocol TPPReaderPositionsDelegate: AnyObject {
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectTOCLocation loc: Any)
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectBookmark bookmark: TPPReadiumBookmark)
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didDeleteBookmark bookmark: TPPReadiumBookmark)
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didRequestSyncBookmarksWithCompletion completion: @escaping (_ success: Bool, _ bookmarks: [TPPReadiumBookmark]) -> Void)
    /// The patron picked a print page to navigate to (from the Pages tab or the
    /// "Go to Page" prompt). `location` is a `Locator`; `pageLabel` is the page's
    /// display label, used for the VoiceOver arrival announcement.
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectPageLocation location: Any, pageLabel: String)
}

// MARK: -

/// A view controller for displaying "positions" inside a publication,
/// where a position is either an element inside the Table of Contents or
/// a Bookmarks saved by the user.
///
/// See `TPPReaderTOCBusinessLogic` for anything related to actual TOC product
/// business logic, and `TPPReaderBookmarksBusinessLogic` for bookmarks logic.
class TPPReaderPositionsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    typealias DisplayStrings = Strings.TPPReaderPositionsVC
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var segmentedControl: UISegmentedControl!
    @IBOutlet weak var noBookmarksLabel: UILabel!
    private var bookmarksRefreshControl: UIRefreshControl?

    private let reuseIdentifierTOC = "contentCell"
    private let reuseIdentifierBookmark = "bookmarkCell"

    weak var delegate: TPPReaderPositionsDelegate?

    var tocBusinessLogic: TPPReaderTOCBusinessLogic?
    var bookmarksBusinessLogic: TPPReaderBookmarksBusinessLogic?
    /// Print page-list (DAISY nav-110). Optional: titles with no `page-list`
    /// leave this nil/empty and the Pages tab is never shown.
    var pageListBusinessLogic: TPPReaderPageListBusinessLogic?
    var retryTracker: UserRetryTracker = .shared

    private enum Tab: Int, CaseIterable {
        case toc = 0
        case bookmarks
        /// Shown only when the publication exposes a print page-list.
        case pages

        var title: String {
            switch self {
            case .toc:
                return DisplayStrings.contents
            case .bookmarks:
                return DisplayStrings.bookmarks
            case .pages:
                return DisplayStrings.pages
            }
        }
    }

    /// True when the publication exposes a print page-list and the Pages tab
    /// should be inserted.
    private var hasPagesTab: Bool {
        pageListBusinessLogic?.hasPageList ?? false
    }

    private var currentTab: Tab {
        return Tab(rawValue: segmentedControl.selectedSegmentIndex) ?? .toc
    }

    /// "Go to Page" prompt entry point, shown as the Pages-tab table header so
    /// it works in both pushed and popover presentations (no nav-bar dependency).
    private lazy var goToPageButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(DisplayStrings.goToPage, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = DisplayStrings.goToPage
        button.addTarget(self, action: #selector(promptGoToPage), for: .touchUpInside)
        button.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44)
        return button
    }()

    /// Uses default storyboard.
    static func newInstance() -> TPPReaderPositionsVC {
        let storyboard = UIStoryboard(name: "TPPReaderPositions", bundle: nil)
        guard let vc = storyboard.instantiateViewController(withIdentifier: "TPPReaderPositionsVC") as? TPPReaderPositionsVC else {
            fatalError("Could not instantiate TPPReaderPositionsVC from storyboard")
        }
        return vc
    }

    @objc func didSelectSegment(_ segmentedControl: UISegmentedControl) {
        tableView.reloadData()

        configRefreshControl()
        updateTableHeader()

        switch currentTab {
        case .toc:
            if tableView.isHidden {
                tableView.isHidden = false
            }
        case .bookmarks:
            tableView.isHidden = (bookmarksBusinessLogic?.bookmarks.count == 0)
        case .pages:
            tableView.isHidden = false
        }
    }

    /// Shows the "Go to Page" prompt as the table header only on the Pages tab.
    private func updateTableHeader() {
        tableView.tableHeaderView = (currentTab == .pages) ? goToPageButton : nil
    }

    // MARK: - UIViewController overrides

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tocBusinessLogic?.tocDisplayTitle

        tableView.dataSource = self
        tableView.delegate = self

        noBookmarksLabel.text = bookmarksBusinessLogic?.noBookmarksText
        view.insertSubview(noBookmarksLabel, belowSubview: tableView)
        noBookmarksLabel.autoCenterInSuperview()
        noBookmarksLabel.autoSetDimension(.width, toSize: 250)

        let readerColors = TPPAssociatedColors.shared.appearanceColors

        tableView.separatorColor = .gray
        view.backgroundColor = readerColors.backgroundColor
        tableView.backgroundColor = view.backgroundColor
        noBookmarksLabel.textColor = readerColors.foregroundColor

        // The storyboard ships Contents + Bookmarks. Insert the Pages segment
        // only when the title has a print page-list (nav-110 AC: titles without
        // one show no Pages tab at all).
        if hasPagesTab, segmentedControl.numberOfSegments <= Tab.pages.rawValue {
            segmentedControl.insertSegment(withTitle: Tab.pages.title,
                                           at: Tab.pages.rawValue,
                                           animated: false)
        }
        for index in 0..<segmentedControl.numberOfSegments {
            if let tab = Tab(rawValue: index) {
                segmentedControl.setTitle(tab.title, forSegmentAt: index)
            }
        }

        if #available(iOS 13, *) {
            segmentedControl.selectedSegmentTintColor = readerColors.tintColor
            segmentedControl.setTitleTextAttributes(
                [NSAttributedString.Key.foregroundColor: readerColors.tintColor],
                for: .normal)
            segmentedControl.setTitleTextAttributes(
                [NSAttributedString.Key.foregroundColor: readerColors.selectedForegroundColor],
                for: .selected)
        } else {
            segmentedControl.tintColor = readerColors.tintColor
        }

        configRefreshControl()
        updateTableHeader()

        navigationController?.navigationBar.barStyle = .default
        navigationController?.navigationBar.isTranslucent = true
        navigationController?.navigationBar.barTintColor = nil
        navigationController?.navigationBar.tintColor = readerColors.tintColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch currentTab {
        case .toc:
            return tocBusinessLogic?.tocElements.count ?? 0
        case .bookmarks:
            return bookmarksBusinessLogic?.bookmarks.count ?? 0
        case .pages:
            return pageListBusinessLogic?.pageCount ?? 0
        }
    }

    @objc func tableView(_ tableView: UITableView,
                         cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch currentTab {

        case .toc:
            let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifierTOC,
                                                     for: indexPath)
            if let cell = cell as? TPPReaderTOCCell,
               let (title, level) = tocBusinessLogic?.titleAndLevel(forItemAt: indexPath.row) {

                cell.config(withTitle: title,
                            nestingLevel: level,
                            isForCurrentChapter: tocBusinessLogic?.isCurrentChapterTitled(title) ?? false)
            }
            return cell

        case .bookmarks:
            let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifierBookmark,
                                                     for: indexPath)
            let bookmark = self.bookmarksBusinessLogic?.bookmark(at: indexPath.row)
            let chapter = tocBusinessLogic?.title(for: bookmark?.href ?? "") ?? bookmark?.chapter

            if let cell = cell as? TPPReaderBookmarkCell, let bookmark = bookmark {
                cell.config(withChapterName: chapter ?? "",
                            percentInChapter: bookmark.percentInChapter,
                            rfc3339DateString: bookmark.time)
            }
            return cell

        case .pages:
            // Reuse the TOC cell to render each print-page label as a flat list.
            let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifierTOC,
                                                     for: indexPath)
            if let cell = cell as? TPPReaderTOCCell,
               let label = pageListBusinessLogic?.label(at: indexPath.row) {
                cell.config(withTitle: label, nestingLevel: 0, isForCurrentChapter: false)
                cell.accessibilityLabel = String(format: DisplayStrings.pageRowAccessibility, label)
            }
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView,
                   estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        switch currentTab {
        case .toc:
            return TPPConfiguration.defaultTOCRowHeight()
        case .bookmarks:
            return TPPConfiguration.defaultBookmarkRowHeight()
        case .pages:
            return TPPConfiguration.defaultTOCRowHeight()
        }
    }

    func tableView(_ tableView: UITableView,
                   heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tv: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch currentTab {
        case .toc:
            guard let bizLogic = tocBusinessLogic else {
                return nil
            }

            Task {
                let shouldSelect = await bizLogic.shouldSelectTOCItem(at: indexPath.row)
                DispatchQueue.main.async {
                    if shouldSelect {
                        tv.selectRow(at: indexPath, animated: true, scrollPosition: .none)
                    }
                }
            }
            return indexPath

        case .bookmarks:
            guard let bizLogic = bookmarksBusinessLogic else {
                return nil
            }

            if bizLogic.shouldSelectBookmark(at: indexPath.row) {
                return indexPath
            } else {
                return nil
            }

        case .pages:
            return pageListBusinessLogic?.label(at: indexPath.row) != nil ? indexPath : nil
        }
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer {
            tv.deselectRow(at: indexPath, animated: true)
        }

        switch currentTab {
        case .toc:
            guard let bizLogic = tocBusinessLogic else { return }

            Task {
                if let locator = await bizLogic.tocLocator(at: indexPath.row) {
                    DispatchQueue.main.async {
                        self.delegate?.positionsVC(self, didSelectTOCLocation: locator)
                    }
                }
            }

        case .bookmarks:
            guard let bizLogic = bookmarksBusinessLogic else { return }

            if let bookmark = bizLogic.bookmark(at: indexPath.row) {
                delegate?.positionsVC(self, didSelectBookmark: bookmark)
            }

        case .pages:
            guard let bizLogic = pageListBusinessLogic,
                  let label = bizLogic.label(at: indexPath.row) else { return }

            Task {
                if let locator = await bizLogic.locator(at: indexPath.row) {
                    DispatchQueue.main.async {
                        self.delegate?.positionsVC(self, didSelectPageLocation: locator, pageLabel: label)
                    }
                }
            }
        }
    }

    func tableView(_ tableView: UITableView,
                   editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        switch currentTab {
        case .toc:
            return .none
        case .bookmarks:
            return .delete
        case .pages:
            return .none
        }
    }

    func tableView(_ tv: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch currentTab {
        case .toc:
            return false
        case .bookmarks:
            return true
        case .pages:
            return false
        }
    }

    func tableView(_ tv: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        switch currentTab {
        case .toc:
            break
        case .pages:
            break
        case .bookmarks:
            guard editingStyle == .delete else {
                return
            }

            if let removedBookmark = bookmarksBusinessLogic?.deleteBookmark(at: indexPath.row) {
                delegate?.positionsVC(self, didDeleteBookmark: removedBookmark)
                tableView.deleteRows(at: [indexPath], with: .fade)
            }
        }
    }

    // MARK: - Helpers

    @objc(userDidRefreshBookmarksWith:)
    private func userDidRefreshBookmarks(with refreshControl: UIRefreshControl) {
        delegate?.positionsVC(self, didRequestSyncBookmarksWithCompletion: { [weak self] (success, _) in
            TPPMainThreadRun.asyncIfNeeded {
                self?.tableView.reloadData()
                self?.bookmarksRefreshControl?.endRefreshing()
                if !success {
                    // Offer retry for bookmark sync failures (likely transient network issue)
                    let operationId = "bookmark-sync"
                    let canRetry = self?.retryTracker.canRetry(operationId: operationId) ?? false

                    if canRetry {
                        let alert = UIAlertController(
                            title: Strings.MyDownloadCenter.errorSyncingBookmarks,
                            message: Strings.MyDownloadCenter.bookmarkSyncError,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { [weak self] _ in
                            self?.retryTracker.recordRetry(operationId: operationId)
                            if let rc = self?.bookmarksRefreshControl {
                                self?.userDidRefreshBookmarks(with: rc)
                            }
                        })
                        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))
                        self?.present(alert, animated: true)
                    } else {
                        let alert = TPPAlertUtils.alert(
                            title: Strings.MyDownloadCenter.errorSyncingBookmarks,
                            message: Strings.MyDownloadCenter.tryAgainLater
                        )
                        self?.present(alert, animated: true)
                    }
                }
            }
        })
    }

    private func configRefreshControl() {
        switch currentTab {
        case .toc, .pages:
            if let refreshControl = bookmarksRefreshControl, tableView.subviews.contains(refreshControl) {
                refreshControl.removeFromSuperview()
            }
        case .bookmarks:
            if bookmarksBusinessLogic?.shouldAllowRefresh() ?? false {
                let refreshCtrl = UIRefreshControl()
                bookmarksRefreshControl = refreshCtrl
                refreshCtrl.addTarget(self,
                                      action: #selector(userDidRefreshBookmarks(with:)),
                                      for: .valueChanged)
                tableView.addSubview(refreshCtrl)
            }
        }
    }

    // MARK: - Go to Page (nav-110)

    /// Prompts the patron for a print page label and navigates to it.
    @objc private func promptGoToPage() {
        let alert = UIAlertController(title: DisplayStrings.goToPage,
                                      message: DisplayStrings.goToPageMessage,
                                      preferredStyle: .alert)
        alert.addTextField { textField in
            textField.keyboardType = .numbersAndPunctuation
            textField.accessibilityLabel = DisplayStrings.goToPage
        }
        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: DisplayStrings.goToPage, style: .default) { [weak self, weak alert] _ in
            guard let self = self,
                  let request = alert?.textFields?.first?.text else { return }
            self.goToPage(labeled: request)
        })
        present(alert, animated: true)
    }

    /// Resolves an entered page label through the page-list and navigates, or
    /// reports not-found without erroring (nav-110 AC).
    private func goToPage(labeled request: String) {
        guard let bizLogic = pageListBusinessLogic,
              let index = bizLogic.indexForPage(labeled: request),
              let label = bizLogic.label(at: index) else {
            presentPageNotFound()
            return
        }

        Task {
            if let locator = await bizLogic.locator(at: index) {
                DispatchQueue.main.async {
                    self.delegate?.positionsVC(self, didSelectPageLocation: locator, pageLabel: label)
                }
            } else {
                DispatchQueue.main.async { self.presentPageNotFound() }
            }
        }
    }

    private func presentPageNotFound() {
        let alert = TPPAlertUtils.alert(title: DisplayStrings.pageNotFoundTitle,
                                        message: DisplayStrings.pageNotFoundMessage)
        present(alert, animated: true)
    }
}
