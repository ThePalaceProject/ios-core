import Foundation
import ZXingObjC

fileprivate let barcodeHeight: CGFloat = 100
fileprivate let maxBarcodeWidth: CGFloat = 414

@objc enum NYPLBarcodeType: Int {
  case codabar
  case code39
  case qrCode
  case code128
}

fileprivate func ZXBarcodeFormatFor(_ NYPLBarcodeType:NYPLBarcodeType) -> ZXBarcodeFormat {
  switch NYPLBarcodeType {
  case .codabar:
    return kBarcodeFormatCodabar
  case .code39:
    return kBarcodeFormatCode39
  case .qrCode:
    return kBarcodeFormatQRCode
  case .code128:
    return kBarcodeFormatCode128
  }
}

/// Manage creation and scanning of barcodes on library cards.
/// Keep any third party dependency abstracted out of the main app.
@objcMembers final class TPPBarcode: NSObject {
  typealias DisplayStrings = Strings.TPPBarCode

  var libraryName: String?

  init (library: String) {
    self.libraryName = library
  }

  func image(fromString stringToEncode: String, superviewWidth: CGFloat, type: NYPLBarcodeType) -> UIImage?
  {
    let barcodeWidth = imageWidthFor(superviewWidth)
    let encodeHints = ZXEncodeHints.init()
    encodeHints.margin = 0
    if let image = TPPZXingEncoder.encode(with: stringToEncode,
                                           format: ZXBarcodeFormatFor(type),
                                           width: Int32(barcodeWidth),
                                           height: Int32(barcodeHeight),
                                           library: self.libraryName ?? "Unknown",
                                           encodeHints: encodeHints)
    {
      return image
    } else {
      Log.error(#file, "Failed to create barcode image.")
      return nil
    }
  }

  class func presentScanner(withCompletion completion: @escaping (String?) -> ())
  {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      DispatchQueue.main.async {
        if granted {
          guard let scannerVC = TPPBarcodeScanningViewController.init(completion: completion) else { return }
          let navController = UINavigationController.init(rootViewController: scannerVC)
          TPPRootTabBarController.shared().safelyPresentViewController(navController, animated: true, completion: nil)
        } else {
          presentCameraPrivacyAlert()
        }
      }
    }
  }

  private class func presentCameraPrivacyAlert()
  {
    let alertController = UIAlertController(
      title: DisplayStrings.cameraAccessDisabledTitle,
      message: DisplayStrings.cameraAccessDisabledBody,
      preferredStyle: .alert)

    alertController.addAction(UIAlertAction(
      title: DisplayStrings.openSettings,
      style: .default,
      handler: {_ in
        UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!)
    }))
    alertController.addAction(UIAlertAction(
      title: Strings.Generic.cancel,
      style: .cancel,
      handler: nil))

    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alertController, viewController: nil, animated: true, completion: nil)
  }

  private func imageWidthFor(_ superviewWidth: CGFloat) -> CGFloat
  {
    if superviewWidth > maxBarcodeWidth {
      return maxBarcodeWidth
    } else {
      return superviewWidth
    }
  }
}
