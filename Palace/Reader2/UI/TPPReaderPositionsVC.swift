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
protocol TPPReaderPositionsDelegate: class {
  func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectTOCLocation loc: Any)
  func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectBookmark bookmark: TPPReadiumBookmark)
  func positionsVC(_ positionsVC: TPPReaderPositionsVC, didDeleteBookmark bookmark: TPPReadiumBookmark)
  func positionsVC(_ positionsVC: TPPReaderPositionsVC, didRequestSyncBookmarksWithCompletion completion: @escaping (_ success: Bool, _ bookmarks: [TPPReadiumBookmark]) -> Void)
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

  private enum Tab: Int, CaseIterable {
    case toc = 0
    case bookmarks
    
    var title: String {
      switch self {
      case .toc:
        return DisplayStrings.contents
      case .bookmarks:
        return DisplayStrings.bookmarks
      }
    }
  }

  private var currentTab: Tab {
    return Tab(rawValue: segmentedControl.selectedSegmentIndex) ?? .toc
  }

  /// Uses default storyboard.
  static func newInstance() -> TPPReaderPositionsVC {
    let storyboard = UIStoryboard(name: "TPPReaderPositions", bundle: nil)
    return storyboard.instantiateViewController(withIdentifier: "TPPReaderPositionsVC") as! TPPReaderPositionsVC
  }

  @objc func didSelectSegment(_ segmentedControl: UISegmentedControl) {
    tableView.reloadData()

    configRefreshControl()

    switch currentTab {
    case .toc:
      if tableView.isHidden {
        tableView.isHidden = false
      }
    case .bookmarks:
      tableView.isHidden = (bookmarksBusinessLogic?.bookmarks.count == 0)
    }
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

    Tab.allCases.forEach {
      segmentedControl.setTitle($0.title, forSegmentAt: $0.rawValue)
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

      if let cell = cell as? TPPReaderBookmarkCell, let bookmark = bookmark {
        cell.config(withChapterName: bookmark.chapter ?? "",
                    percentInChapter: bookmark.percentInChapter,
                    rfc3339DateString: bookmark.time)
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
      return bizLogic.shouldSelectTOCItem(at: indexPath.row) ? indexPath : nil
    case .bookmarks:
      guard let bizLogic = bookmarksBusinessLogic else {
        return nil
      }
      return bizLogic.shouldSelectBookmark(at: indexPath.row) ? indexPath : nil
    }
  }

  func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer {
      tv.deselectRow(at: indexPath, animated: true)
    }

    switch currentTab {
    case .toc:
      if let locator = tocBusinessLogic?.tocLocator(at: indexPath.row) {
        delegate?.positionsVC(self, didSelectTOCLocation: locator)
      }
    case .bookmarks:
      if let bookmark = bookmarksBusinessLogic?.bookmark(at: indexPath.row) {
        delegate?.positionsVC(self, didSelectBookmark: bookmark)
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
    }
  }

  func tableView(_ tv: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    switch currentTab {
    case .toc:
      return false
    case .bookmarks:
      return true
    }
  }

  func tableView(_ tv: UITableView,
                 commit editingStyle: UITableViewCell.EditingStyle,
                 forRowAt indexPath: IndexPath) {
    switch currentTab {
    case .toc:
      break;
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
    delegate?.positionsVC(self, didRequestSyncBookmarksWithCompletion: { (success, bookmarks) in
      TPPMainThreadRun.asyncIfNeeded { [weak self] in
        self?.tableView.reloadData()
        self?.bookmarksRefreshControl?.endRefreshing()
        if !success {
          let alert = TPPAlertUtils.alert(title: "Error Syncing Bookmarks",
                                           message: "There was an error syncing bookmarks to the server. Ensure your device is connected to the internet or try again later.")
          self?.present(alert, animated: true)
        }
      }
    })
  }

  private func configRefreshControl() {
    switch currentTab {
    case .toc:
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
}
