import UIKit

@objc class TPPReaderBookmarkCell: UITableViewCell {
    @IBOutlet weak var chapterLabel: UILabel!
    @IBOutlet weak var pageNumberLabel: UILabel!

    /// `.medium` time, not `.short`: `.short` has no seconds, so two bookmarks
    /// saved in the same minute rendered the same subtitle and a patron could
    /// not tell which passage was which (PP-5395).
    private static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .short
        return formatter
    }()

    @objc
    func config(withChapterName chapterName: String,
                percentInChapter: String,
                percentInBook: String?,
                rfc3339DateString: String) {
        backgroundColor = .clear
        chapterLabel.text = chapterName

        // The subtitle now carries a time with seconds and two percentages, so
        // it no longer fits one line on a narrow screen. The storyboard label
        // is single-line with tail truncation; the table already sizes rows
        // with `automaticDimension`, so letting it wrap costs nothing and
        // truncating would hide the very fields that tell two bookmarks apart.
        pageNumberLabel.numberOfLines = 0
        pageNumberLabel.text = Self.subtitle(
            forDate: NSDate.date(withRFC3339String: rfc3339DateString) as Date?,
            percentInChapter: percentInChapter,
            percentInBook: percentInBook
        )

        let textColor = TPPAssociatedColors.shared.appearanceColors.textColor
        chapterLabel.textColor = textColor
        pageNumberLabel.textColor = textColor
    }

    /// The row's second line: when it was saved, and where it sits.
    ///
    /// Pure and `static` so the composition can be tested without a storyboard
    /// or a table view. Each part is dropped when it is absent rather than
    /// rendered empty, because a bookmark that arrived from another device can
    /// be missing fields and a dangling separator reads as a defect.
    static func subtitle(forDate date: Date?,
                         percentInChapter: String,
                         percentInBook: String?) -> String {
        var parts: [String] = []

        if let date {
            parts.append(dateFormatter.string(from: date))
        }

        parts.append(String.localizedStringWithFormat(
            NSLocalizedString("%@ through chapter",
                              comment: "A concise string that expreses the percent progress, where %@ is the percentage"),
            percentInChapter
        ))

        if let percentInBook, !percentInBook.isEmpty {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("%@ through book",
                                  comment: "A concise string that expresses progress through the whole book, where %@ is the percentage"),
                percentInBook
            ))
        }

        return parts.joined(separator: " - ")
    }
}
