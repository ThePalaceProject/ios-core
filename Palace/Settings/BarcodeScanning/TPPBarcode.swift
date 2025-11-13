import Foundation
import AVFoundation

fileprivate let barcodeHeight: CGFloat = 100
fileprivate let maxBarcodeWidth: CGFloat = 414

/// Manage creation and scanning of barcodes on library cards.
/// Keep any third party dependency abstracted out of the main app.
@objcMembers final class TPPBarcode: NSObject {
  typealias DisplayStrings = Strings.TPPBarCode

  var libraryName: String?

  init (library: String) {
    self.libraryName = library
  }

  func image(fromString stringToEncode: String) -> UIImage?
  {
    let data = stringToEncode.data(using: String.Encoding.ascii)
    if let filter = CIFilter(name: "CICode128BarcodeGenerator") {
      filter.setValue(data, forKey: "inputMessage")
      let transform = CGAffineTransform(scaleX: 3, y: 3)
      
      if let output = filter.outputImage?.transformed(by: transform) {
        return UIImage(ciImage: output)
      }
    }
    return nil
  }

  class func presentScanner(withCompletion completion: @escaping (String?) -> ())
  {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      DispatchQueue.main.async {
        if granted {
          let scannerVC = BarcodeScanner(completion: completion)
          let navController = UINavigationController.init(rootViewController: scannerVC)
          TPPPresentationUtils.safelyPresent(navController, animated: true, completion: nil)
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
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(settingsURL)
        }
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
