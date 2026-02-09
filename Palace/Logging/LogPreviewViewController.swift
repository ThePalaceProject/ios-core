//
//  LogPreviewViewController.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// A view controller for previewing collected log data locally.
/// Provides a segmented control to switch between log sources,
/// a search bar with match navigation, and share/copy functionality.
final class LogPreviewViewController: UIViewController {

  private let logData: ErrorLogData

  private let segmentedControl = UISegmentedControl()
  private let searchBar = UISearchBar()
  private let searchResultsLabel = UILabel()
  private let textView = UITextView()
  private let statsLabel = UILabel()

  /// The full (un-highlighted) text for the current tab.
  private var currentTabText: String = ""

  /// All match ranges for the active search query.
  private var searchMatches: [NSRange] = []

  /// Index into `searchMatches` for the currently focused match.
  private var currentMatchIndex: Int = -1

  private enum LogTab: Int, CaseIterable {
    case deviceLogs = 0
    case errorLogs
    case audiobookLogs
    case crashlytics
    case deviceInfo

    var title: String {
      switch self {
      case .deviceLogs: return "Device"
      case .errorLogs: return "Errors"
      case .audiobookLogs: return "Audio"
      case .crashlytics: return "Crash"
      case .deviceInfo: return "Info"
      }
    }
  }

  // MARK: - Init

  init(logData: ErrorLogData) {
    self.logData = logData
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    showTab(.deviceLogs)
  }

  // MARK: - UI Setup

  private func setupUI() {
    title = "Log Preview"
    view.backgroundColor = .systemBackground

    // Navigation bar buttons
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareLogs)),
      UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(copyCurrentTab))
    ]

    // Segmented control
    for tab in LogTab.allCases {
      segmentedControl.insertSegment(withTitle: tab.title, at: tab.rawValue, animated: false)
    }
    segmentedControl.selectedSegmentIndex = 0
    segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    segmentedControl.translatesAutoresizingMaskIntoConstraints = false

    // Search bar
    searchBar.placeholder = "Search logs..."
    searchBar.delegate = self
    searchBar.returnKeyType = .search
    searchBar.searchBarStyle = .minimal
    searchBar.showsCancelButton = false
    searchBar.translatesAutoresizingMaskIntoConstraints = false

    // Search results bar (match count + prev/next)
    searchResultsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    searchResultsLabel.textColor = .secondaryLabel
    searchResultsLabel.textAlignment = .center
    searchResultsLabel.isHidden = true
    searchResultsLabel.translatesAutoresizingMaskIntoConstraints = false

    // Stats label
    statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statsLabel.textColor = .secondaryLabel
    statsLabel.textAlignment = .center
    statsLabel.translatesAutoresizingMaskIntoConstraints = false

    // Text view
    textView.isEditable = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.backgroundColor = .secondarySystemBackground
    textView.textColor = .label
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.alwaysBounceVertical = true

    view.addSubview(segmentedControl)
    view.addSubview(searchBar)
    view.addSubview(searchResultsLabel)
    view.addSubview(statsLabel)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

      searchBar.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 4),
      searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      searchResultsLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
      searchResultsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      searchResultsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

      statsLabel.topAnchor.constraint(equalTo: searchResultsLabel.bottomAnchor, constant: 2),
      statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      statsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

      textView.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 4),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    // Toolbar for search navigation
    let prevButton = UIBarButtonItem(image: UIImage(systemName: "chevron.up"), style: .plain, target: self, action: #selector(previousMatch))
    let nextButton = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: self, action: #selector(nextMatch))
    let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    let doneButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard))
    toolbarItems = [prevButton, nextButton, flex, doneButton]
    navigationController?.isToolbarHidden = false
  }

  // MARK: - Tab Switching

  @objc private func segmentChanged() {
    guard let tab = LogTab(rawValue: segmentedControl.selectedSegmentIndex) else { return }
    showTab(tab)
  }

  private func showTab(_ tab: LogTab) {
    let (text, size) = contentForTab(tab)
    currentTabText = text
    textView.text = text
    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

    let sizeString = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    let lineCount = text.components(separatedBy: "\n").count
    statsLabel.text = "\(sizeString) \u{00B7} \(lineCount.formatted()) lines"

    // Re-run search on the new tab content
    if let query = searchBar.text, !query.isEmpty {
      performSearch(query: query)
    } else {
      clearSearchHighlights()
    }
  }

  private func contentForTab(_ tab: LogTab) -> (String, Int) {
    switch tab {
    case .deviceLogs:
      let text = String(data: logData.deviceLogs, encoding: .utf8) ?? "(unable to decode)"
      return (text, logData.deviceLogs.count)
    case .errorLogs:
      let text = String(data: logData.errorLogs, encoding: .utf8) ?? "(unable to decode)"
      return (text, logData.errorLogs.count)
    case .audiobookLogs:
      let text = String(data: logData.audiobookLogs, encoding: .utf8) ?? "(unable to decode)"
      return (text, logData.audiobookLogs.count)
    case .crashlytics:
      let text = String(data: logData.crashlyticsBreadcrumbs, encoding: .utf8) ?? "(unable to decode)"
      return (text, logData.crashlyticsBreadcrumbs.count)
    case .deviceInfo:
      return (logData.deviceInfo, logData.deviceInfo.utf8.count)
    }
  }

  // MARK: - Search

  private func performSearch(query: String) {
    guard !query.isEmpty else {
      clearSearchHighlights()
      return
    }

    let text = currentTabText
    let nsText = text as NSString
    var matches: [NSRange] = []
    var searchRange = NSRange(location: 0, length: nsText.length)

    let lowercaseQuery = query.lowercased()
    let lowercaseText = text.lowercased() as NSString

    while searchRange.location < nsText.length {
      let range = lowercaseText.range(of: lowercaseQuery, range: searchRange)
      if range.location == NSNotFound { break }
      matches.append(range)
      searchRange.location = range.location + range.length
      searchRange.length = nsText.length - searchRange.location
    }

    searchMatches = matches

    if matches.isEmpty {
      searchResultsLabel.text = "No matches"
      searchResultsLabel.isHidden = false
      currentMatchIndex = -1
      applyHighlighting(matches: [], focused: -1)
    } else {
      currentMatchIndex = 0
      searchResultsLabel.isHidden = false
      updateMatchLabel()
      applyHighlighting(matches: matches, focused: 0)
      scrollToMatch(at: 0)
    }
  }

  private func applyHighlighting(matches: [NSRange], focused: Int) {
    let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let attributed = NSMutableAttributedString(
      string: currentTabText,
      attributes: [
        .font: mono,
        .foregroundColor: UIColor.label,
        .backgroundColor: UIColor.clear
      ]
    )

    let highlightColor = UIColor.systemYellow.withAlphaComponent(0.35)
    let focusedColor = UIColor.systemOrange.withAlphaComponent(0.6)

    for (i, range) in matches.enumerated() {
      let color = (i == focused) ? focusedColor : highlightColor
      attributed.addAttribute(.backgroundColor, value: color, range: range)
    }

    textView.attributedText = attributed
  }

  private func scrollToMatch(at index: Int) {
    guard index >= 0, index < searchMatches.count else { return }
    let range = searchMatches[index]

    // Scroll so the match is visible with some context
    textView.scrollRangeToVisible(range)

    // Brief flash to draw the eye
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.textView.selectedRange = range
    }
  }

  private func updateMatchLabel() {
    if searchMatches.isEmpty {
      searchResultsLabel.text = "No matches"
    } else {
      searchResultsLabel.text = "Match \(currentMatchIndex + 1) of \(searchMatches.count)"
    }
  }

  private func clearSearchHighlights() {
    searchMatches = []
    currentMatchIndex = -1
    searchResultsLabel.isHidden = true

    // Restore plain text (no attributed highlights)
    let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.attributedText = NSAttributedString(
      string: currentTabText,
      attributes: [.font: mono, .foregroundColor: UIColor.label]
    )
  }

  // MARK: - Search Navigation

  @objc private func previousMatch() {
    guard !searchMatches.isEmpty else { return }
    currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
    updateMatchLabel()
    applyHighlighting(matches: searchMatches, focused: currentMatchIndex)
    scrollToMatch(at: currentMatchIndex)
  }

  @objc private func nextMatch() {
    guard !searchMatches.isEmpty else { return }
    currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
    updateMatchLabel()
    applyHighlighting(matches: searchMatches, focused: currentMatchIndex)
    scrollToMatch(at: currentMatchIndex)
  }

  @objc private func dismissKeyboard() {
    searchBar.resignFirstResponder()
  }

  // MARK: - Actions

  @objc private func copyCurrentTab() {
    UIPasteboard.general.string = currentTabText

    let alert = UIAlertController(title: "Copied", message: "Log content copied to clipboard.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  @objc private func shareLogs() {
    var combined = "=== Palace Log Export ===\n"
    combined += "Exported: \(Date())\n\n"

    for tab in LogTab.allCases {
      let (text, _) = contentForTab(tab)
      combined += "\u{2501}\u{2501}\u{2501} \(tab.title.uppercased()) \u{2501}\u{2501}\u{2501}\n"
      combined += text
      combined += "\n\n"
    }

    let activityVC = UIActivityViewController(activityItems: [combined], applicationActivities: nil)
    activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
    present(activityVC, animated: true)
  }
}

// MARK: - UISearchBarDelegate

extension LogPreviewViewController: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    performSearch(query: searchText)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    // Jump to next match on "Search" tap
    if !searchMatches.isEmpty {
      nextMatch()
    }
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    searchBar.text = ""
    searchBar.resignFirstResponder()
    clearSearchHighlights()
  }
}
