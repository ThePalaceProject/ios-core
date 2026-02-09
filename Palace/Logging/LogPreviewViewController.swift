//
//  LogPreviewViewController.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// A simple view controller for previewing collected log data locally.
/// Provides a segmented control to switch between log sources and
/// share/copy functionality for debugging.
final class LogPreviewViewController: UIViewController {

  private let logData: ErrorLogData

  private let segmentedControl = UISegmentedControl()
  private let textView = UITextView()
  private let statsLabel = UILabel()

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
    view.addSubview(statsLabel)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

      statsLabel.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 6),
      statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      statsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

      textView.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 6),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  // MARK: - Tab Switching

  @objc private func segmentChanged() {
    guard let tab = LogTab(rawValue: segmentedControl.selectedSegmentIndex) else { return }
    showTab(tab)
  }

  private func showTab(_ tab: LogTab) {
    let (text, size) = contentForTab(tab)
    textView.text = text
    textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

    let sizeString = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    let lineCount = text.components(separatedBy: "\n").count
    statsLabel.text = "\(sizeString) · \(lineCount.formatted()) lines"
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

  // MARK: - Actions

  @objc private func copyCurrentTab() {
    UIPasteboard.general.string = textView.text

    let alert = UIAlertController(title: "Copied", message: "Log content copied to clipboard.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  @objc private func shareLogs() {
    // Build a combined text of all logs for sharing
    var combined = "=== Palace Log Export ===\n"
    combined += "Exported: \(Date())\n\n"

    for tab in LogTab.allCases {
      let (text, _) = contentForTab(tab)
      combined += "━━━ \(tab.title.uppercased()) ━━━\n"
      combined += text
      combined += "\n\n"
    }

    let activityVC = UIActivityViewController(activityItems: [combined], applicationActivities: nil)
    activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
    present(activityVC, animated: true)
  }
}
