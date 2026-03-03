//
//  TPPPDFViewController.swift
//  Palace
//
//  Created by Vladimir Fedorov on 31.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

/// Maximum file size the app can decrypt without crashing
fileprivate let supportedEncryptedDataSize = 200 * 1024 * 1024

class TPPPDFViewController: NSObject {

  @objc static func create(document: TPPPDFDocument, metadata: TPPPDFDocumentMetadata) -> UIViewController {
    var controller: UIViewController!
    if document.isEncrypted && document.data.count < supportedEncryptedDataSize {
      let data = document.decrypt(data: document.data, start: 0, end: UInt(document.data.count))
      controller = UIHostingController(rootView: TPPPDFReaderView(document: TPPPDFDocument(data: data)).environmentObject(metadata))
    } else {
      controller = UIHostingController(rootView: TPPPDFReaderView(document: document).environmentObject(metadata))
    }
    controller.title = ""
    controller.hidesBottomBarWhenPushed = true
    return controller
  }

}
