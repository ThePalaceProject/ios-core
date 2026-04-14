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
    // dataProvider() should also be usable after init
    let cgProvider = provider.dataProvider()
    XCTAssertNotNil(cgProvider, "dataProvider() should return a valid CGDataProvider for 1024-byte input")
  }

  func test_initWithEmptyData_succeeds() {
    let emptyData = Data()
    let decryptor: (Data, UInt, UInt) -> Data = { _, _, _ in
      return Data()
    }
    let provider = TPPEncryptedPDFDataProvider(data: emptyData, decryptor: decryptor)
    XCTAssertNotNil(provider, "Should initialize even with empty data")
    // Empty data produces a data provider (may produce an empty/nil PDF, but must not crash)
    _ = provider.dataProvider()
  }

  // MARK: - Data Provider

  func test_dataProvider_returnsValidCGDataProvider() {
    let testData = Data(repeating: 0xFF, count: 256)
    var decryptorCallCount = 0
    let decryptor: (Data, UInt, UInt) -> Data = { data, start, end in
      decryptorCallCount += 1
      return data.subdata(in: Int(start)..<Int(end))
    }
    let provider = TPPEncryptedPDFDataProvider(data: testData, decryptor: decryptor)
    let cgProvider = provider.dataProvider()
    XCTAssertNotNil(cgProvider, "dataProvider() should return a valid CGDataProvider")
    // Two separate calls should each return a non-nil provider
    let cgProvider2 = provider.dataProvider()
    XCTAssertNotNil(cgProvider2, "Second call to dataProvider() should also succeed")
  }
}
