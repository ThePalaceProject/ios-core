import Foundation
import CoreGraphics

@objc class TPPEncryptedPDFDataProvider: NSObject {

  private let encryptedData: Data
  private let decryptor: (Data, UInt, UInt) -> Data

  @objc init(data: Data, decryptor: @escaping (Data, UInt, UInt) -> Data) {
    self.encryptedData = data
    self.decryptor = decryptor
    super.init()
  }

  @objc func dataProvider() -> CGDataProvider? {
    let dataLength = encryptedData.count

    // We need to capture encryptedData and decryptor in a context that
    // CGDataProvider can use via its callback-based API.
    // Using a class to hold reference-counted context.
    class ProviderContext {
      let data: Data
      let decryptor: (Data, UInt, UInt) -> Data
      init(data: Data, decryptor: @escaping (Data, UInt, UInt) -> Data) {
        self.data = data
        self.decryptor = decryptor
      }
    }

    let context = ProviderContext(data: encryptedData, decryptor: decryptor)
    let info = Unmanaged.passRetained(context).toOpaque()

    var callbacks = CGDataProviderDirectCallbacks(
      version: 0,
      getBytePointer: nil,
      releaseBytePointer: nil,
      getBytesAtPosition: { infoPtr, buffer, position, count in
        guard let infoPtr = infoPtr else { return 0 }
        let ctx = Unmanaged<ProviderContext>.fromOpaque(infoPtr).takeUnretainedValue()
        let start = UInt(position)
        let end = UInt(position) + UInt(count)
        let decryptedData = ctx.decryptor(ctx.data, start, end)
        decryptedData.withUnsafeBytes { rawBuffer in
          if let baseAddress = rawBuffer.baseAddress {
            buffer.copyMemory(from: baseAddress, byteCount: count)
          }
        }
        return count
      },
      releaseInfo: { infoPtr in
        guard let infoPtr = infoPtr else { return }
        Unmanaged<ProviderContext>.fromOpaque(infoPtr).release()
      }
    )

    return CGDataProvider(directInfo: info, size: Int64(dataLength), callbacks: &callbacks)
  }
}
