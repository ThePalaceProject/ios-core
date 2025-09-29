import UIKit

@objc class TPPReaderBookmarkCell: UITableViewCell {
  @IBOutlet var chapterLabel: UILabel!
  @IBOutlet var pageNumberLabel: UILabel!

  private static var dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .short
    return formatter
  }()

  @objc
  func config(
    withChapterName chapterName: String,
    percentInChapter: String,
    rfc3339DateString: String
  ) {
    backgroundColor = .clear
    chapterLabel.text = chapterName

    let formattedBookmarkDate = prettyDate(forRFC3339String: rfc3339DateString)
    let progress = String.localizedStringWithFormat(
      NSLocalizedString(
        "%@ through chapter",
        comment: "A concise string that expreses the percent progress, where %@ is the percentage"
      ),
      percentInChapter
    )
    pageNumberLabel.text = "\(formattedBookmarkDate) - \(progress)"

    let textColor = TPPAssociatedColors.shared.appearanceColors.textColor
    chapterLabel.textColor = textColor
    pageNumberLabel.textColor = textColor
  }

  private func prettyDate(forRFC3339String dateStr: String) -> String {
    guard let date = (NSDate(rfc3339String: dateStr) as Date?) else {
      return ""
    }

    return TPPReaderBookmarkCell.dateFormatter.string(from: date)
  }
}
