//
//  PalacePDFView.swift
//  Palace
//
//  PP-4297: PDFKit PDFView subclass that gates the system text-selection
//  edit menu on a per-instance `allowsCopy` flag. The PDF reader sets the
//  flag based on `TPPBook.isDRMProtected` before user interaction can
//  reach the view, so DRM-protected titles never expose Copy/Cut/Paste/
//  Look Up/Share on long-press.
//

import PDFKit
import UIKit

class PalacePDFView: PDFView {

    /// When false, suppresses Copy, Cut, Paste, Look Up, Share, and the
    /// Define/Translate menu items on long-press text selection. Defaults
    /// to true so the existing non-DRM behavior is preserved.
    var allowsCopy: Bool = true

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if !allowsCopy, PalacePDFView.blockedEditingSelectors.contains(action) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        // Defer to super first, then strip — defends against future PDFKit
        // versions that insert items late in their buildMenu pass.
        super.buildMenu(with: builder)
        if !allowsCopy {
            builder.remove(menu: .standardEdit)
            builder.remove(menu: .share)
            builder.remove(menu: .lookup)
            builder.remove(menu: .learn)
        }
    }

    /// Standard-edit selectors that long-press surfaces on a PDF text
    /// selection. Matches what `UIResponderStandardEditActions` declares
    /// plus the system-private Look Up / Share entry points that
    /// PDFView's selection menu uses.
    static let blockedEditingSelectors: Set<Selector> = [
        #selector(UIResponderStandardEditActions.copy(_:)),
        #selector(UIResponderStandardEditActions.cut(_:)),
        #selector(UIResponderStandardEditActions.paste(_:)),
        #selector(UIResponderStandardEditActions.select(_:)),
        #selector(UIResponderStandardEditActions.selectAll(_:)),
        Selector(("_share:")),
        Selector(("_lookup:")),
        Selector(("_define:")),
        Selector(("_translate:"))
    ]
}
