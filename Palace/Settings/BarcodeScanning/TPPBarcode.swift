import Foundation
//import ZXingObjC
import AVFoundation

fileprivate let barcodeHeight: CGFloat = 100
fileprivate let maxBarcodeWidth: CGFloat = 414

//@objc enum NYPLBarcodeType: Int {
//  case codabar
//  case code39
//  case qrCode
//  case code128
//}
//
//fileprivate func ZXBarcodeFormatFor(_ NYPLBarcodeType:NYPLBarcodeType) -> ZXBarcodeFormat {
//  switch NYPLBarcodeType {
//  case .codabar:
//    return kBarcodeFormatCodabar
//  case .code39:
//    return kBarcodeFormatCode39
//  case .qrCode:
//    return kBarcodeFormatQRCode
//  case .code128:
//    return kBarcodeFormatCode128
//  }
//}
//
/// Manage creation and scanning of barcodes on library cards.
/// Keep any third party dependency abstracted out of the main app.
@objcMembers final class TPPBarcode: NSObject {
  typealias DisplayStrings = Strings.TPPBarCode

  var libraryName: String?

  init (library: String) {
    self.libraryName = library
  }

  class func presentScanner(withCompletion completion: @escaping (String?) -> ())
  {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      DispatchQueue.main.async {
        if granted {
          let scannerVC = BarcodeScanner(completion: completion)
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
