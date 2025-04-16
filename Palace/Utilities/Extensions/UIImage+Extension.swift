import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

extension UIImage {
  func mainColor() -> UIColor? {
    let ciImage = CIImage(image: self)
    let filter = CIFilter.areaAverage()
    filter.inputImage = ciImage
    filter.extent = ciImage?.extent ?? .zero

    guard let outputImage = filter.outputImage else { return nil }

    var bitmap = [UInt8](repeating: 0, count: 4)
    let context = CIContext()
    context.render(
      outputImage,
      toBitmap: &bitmap,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: nil
    )

    return UIColor(red: CGFloat(bitmap[0]) / 255.0,
                   green: CGFloat(bitmap[1]) / 255.0,
                   blue: CGFloat(bitmap[2]) / 255.0,
                   alpha: CGFloat(bitmap[3]) / 255.0)
  }
}
