import Foundation

struct TestCredentials {
  let barcode: String
  let pin: String
  let library: String

  static func load() -> TestCredentials? {
    guard let barcode = ProcessInfo.processInfo.environment["PALACE_TEST_BARCODE"],
          let pin = ProcessInfo.processInfo.environment["PALACE_TEST_PIN"],
          let library = ProcessInfo.processInfo.environment["PALACE_TEST_LIBRARY"] else {
      return nil
    }
    return TestCredentials(barcode: barcode, pin: pin, library: library)
  }
}
