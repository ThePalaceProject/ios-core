import Foundation
import PDFRendererProvider

@objc final class TPPPDFViewControllerDelegate: NSObject, MinitexPDFViewControllerDelegate {

  let bookIdentifier: String

  @objc init(bookIdentifier: String) {
    self.bookIdentifier = bookIdentifier
    TPPBookRegistry.shared.setState(.Used, for: bookIdentifier)
  }

  func userDidNavigate(toPage page: MinitexPDFPage) {

    Log.debug(#file, "User did navigate to page: \(page)")

    let data = page.toData()
    if let string = String(data: data, encoding: .utf8),
      let bookLocation = TPPBookLocation(locationString: string, renderer: "PDFRendererProvider") {
      TPPBookRegistry.shared.setLocation(bookLocation, forIdentifier: self.bookIdentifier)
    } else {
      Log.error(#file, "Error creating and saving PDF Page Location")
    }
  }

  func userDidCreate(bookmark: MinitexPDFPage) {

    Log.debug(#file, "User did add bookmark: \(bookmark)")

    let data = bookmark.toData()
    if let string = String(data: data, encoding: .utf8),
      let bookLocation = TPPBookLocation(locationString: string, renderer: "PDFRendererProvider") {
      TPPBookRegistry.shared.addGenericBookmark(bookLocation, forIdentifier: self.bookIdentifier)
    } else {
      Log.error(#file, "Error adding PDF Page Location")
    }
  }

  func userDidDelete(bookmark: MinitexPDFPage) {

    Log.debug(#file, "User did delete bookmark: \(bookmark)")

    let data = bookmark.toData()
    if let string = String(data: data, encoding: .utf8),
      let bookLocation = TPPBookLocation(locationString: string, renderer: "PDFRendererProvider") {
      TPPBookRegistry.shared.deleteGenericBookmark(bookLocation, forIdentifier: self.bookIdentifier)
    } else {
      Log.error(#file, "Error deleting PDF Page Location")
    }
  }

  func userDidCreate(annotation: MinitexPDFAnnotation) { }
  func userDidDelete(annotation: MinitexPDFAnnotation) { }
}
