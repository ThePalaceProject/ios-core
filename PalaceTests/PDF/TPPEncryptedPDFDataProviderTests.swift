import XCTest
@testable import Palace

final class TPPEncryptedPDFDataProviderTests: XCTestCase {

  // MARK: - Initialization

  func test_initWithValidData_succeeds() {
    let testData = Data(repeating: 0xAB, count: 1024)
    let decryptor: (Data, UInt, UInt) -> Data = { data, start, end in
      return data.subdata(in: Int(start)..<Int(end))
    }
    let provider = TPPEncryptedPDFDataProvider(data: testData, decryptor: decryptor)
    XCTAssertNotNil(provider, "Should initialize with valid data and decryptor")
  }

  func test_initWithEmptyData_succeeds() {
    let emptyData = Data()
    let decryptor: (Data, UInt, UInt) -> Data = { _, _, _ in
      return Data()
    }
    let provider = TPPEncryptedPDFDataProvider(data: emptyData, decryptor: decryptor)
    XCTAssertNotNil(provider, "Should initialize even with empty data")
  }

  // MARK: - Data Provider

  func test_dataProvider_returnsValidCGDataProvider() {
    let testData = Data(repeating: 0xFF, count: 256)
    let decryptor: (Data, UInt, UInt) -> Data = { data, start, end in
      return data.subdata(in: Int(start)..<Int(end))
    }
    let provider = TPPEncryptedPDFDataProvider(data: testData, decryptor: decryptor)
    let unmanagedProvider = provider.dataProvider()

    // The method returns an Unmanaged<CGDataProvider>; take the value to verify it exists
    let cgProvider = unmanagedProvider.takeUnretainedValue()
    XCTAssertNotNil(cgProvider, "dataProvider() should return a valid CGDataProvider")
  }
}
