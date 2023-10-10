//
//  SearchResultView.swift
//  Palace
//
//  Created by Maurice Carrier on 10/10/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

struct HighlightedTextView: UIViewRepresentable {
  var before: String
  var highlight: String
  var after: String
  
  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.maximumNumberOfLines = 0
    textView.textContainer.lineBreakMode = .byWordWrapping

    return textView
  }
  
  func updateUIView(_ uiView: UITextView, context: Context) {
    let attributedText = NSMutableAttributedString(string: before + highlight + after)
    
    let highlightRange = (attributedText.string as NSString).range(of: highlight)
    attributedText.addAttribute(.backgroundColor, value: UIColor.yellow, range: highlightRange)
    
    let mediumFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    attributedText.addAttribute(.font, value: mediumFont, range: highlightRange)
    
    uiView.attributedText = attributedText
  }
}
