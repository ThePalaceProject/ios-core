//
//  ErrorDetailViewController.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// Presents detailed error information including the activity trail,
/// server response, and device context. Accessible from the "View Error Details"
/// button on error alerts.
final class ErrorDetailViewController: UIViewController {

    private let errorDetail: ErrorDetail
    private let textView = UITextView()

    // MARK: - Init

    init(errorDetail: ErrorDetail) {
        self.errorDetail = errorDetail
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
        renderContent()
    }

    // MARK: - UI Setup

    private func setupUI() {
        title = "Error Details"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .action, target: self, action: #selector(shareReport)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "doc.on.doc"), style: .plain,
                target: self, action: #selector(copyReport)
            )
        ]

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .secondarySystemBackground
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Rendering

    private func renderContent() {
        let attributed = NSMutableAttributedString()
        let mono = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let monoBold = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let sectionFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)

        func addSection(_ title: String) {
            attributed.append(NSAttributedString(
                string: "\n\(title)\n",
                attributes: [.font: sectionFont, .foregroundColor: UIColor.systemBlue]
            ))
        }

        func addField(_ label: String, _ value: String) {
            attributed.append(NSAttributedString(
                string: "\(label): ",
                attributes: [.font: monoBold, .foregroundColor: UIColor.label]
            ))
            attributed.append(NSAttributedString(
                string: "\(value)\n",
                attributes: [.font: mono, .foregroundColor: UIColor.label]
            ))
        }

        func addLine(_ text: String, color: UIColor = .label) {
            attributed.append(NSAttributedString(
                string: "\(text)\n",
                attributes: [.font: mono, .foregroundColor: color]
            ))
        }

        // ── Error Summary ──
        addSection("Error")
        addField("Title", errorDetail.title)
        addField("Message", errorDetail.message)

        if let error = errorDetail.underlyingError {
            let nsError = error as NSError
            addField("Domain", nsError.domain)
            addField("Code", "\(nsError.code)")
            if let recovery = nsError.localizedRecoverySuggestion {
                addField("Recovery", recovery)
            }
        }

        // ── Server Response ──
        if let doc = errorDetail.problemDocument {
            addSection("Server Response (Problem Document)")
            if let type = doc.type { addField("Type", type) }
            if let title = doc.title { addField("Title", title) }
            if let status = doc.status { addField("Status", "\(status)") }
            if let detail = doc.detail { addField("Detail", detail) }
            if let instance = doc.instance { addField("Instance", instance) }
        }

        // ── Book Info ──
        if let book = errorDetail.bookInfo {
            addSection("Book")
            addField("ID", book.identifier)
            if let title = book.title { addField("Title", title) }
        }

        // ── Activity Trail ──
        addSection("Activity Trail (\(errorDetail.activityTrail.count) steps)")
        if errorDetail.activityTrail.isEmpty {
            addLine("(no recent activity recorded)", color: .secondaryLabel)
        } else {
            for activity in errorDetail.activityTrail {
                let color: UIColor
                switch activity.category {
                case .network: color = .systemCyan
                case .borrow: color = .systemGreen
                case .download: color = .systemIndigo
                case .auth: color = .systemOrange
                case .drm: color = .systemPurple
                case .ui: color = .secondaryLabel
                case .general: color = .label
                }
                addLine(activity.displayString, color: color)
            }
        }

        // ── Device Context ──
        let ctx = errorDetail.deviceContext
        addSection("Device")
        addField("App Version", "\(ctx.appVersion) (\(ctx.buildNumber))")
        addField("iOS", ctx.iosVersion)
        addField("Device", ctx.deviceModel)
        addField("Library", ctx.libraryName)
        addField("Storage", ctx.availableStorage)
        addField("Memory", ctx.memoryUsage)

        textView.attributedText = attributed
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    // MARK: - Actions

    @objc override func dismissSelf() {
        dismiss(animated: true)
    }

    @objc private func copyReport() {
        UIPasteboard.general.string = errorDetail.formattedReport()
        let alert = UIAlertController(title: "Copied", message: "Error details copied to clipboard.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func shareReport() {
        let report = errorDetail.formattedReport()
        let activityVC = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        activityVC.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(activityVC, animated: true)
    }
}
