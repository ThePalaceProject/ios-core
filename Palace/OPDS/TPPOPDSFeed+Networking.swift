import Compression
import Foundation
import PalaceCatalog
import PalaceLogging

private enum TPPOPDSFeedDataInspection {
  /// Raw bytes of the gzip magic (RFC 1952, section 2.3.1).
  static let gzipMagic: [UInt8] = [0x1f, 0x8b]

  static func startsWithGzipMagic(_ data: Data) -> Bool {
    guard data.count >= gzipMagic.count else { return false }
    return data[data.startIndex] == gzipMagic[0]
      && data[data.startIndex.advanced(by: 1)] == gzipMagic[1]
  }

  /// Decompress a gzip-framed payload using Compression.COMPRESSION_ZLIB.
  /// Returns nil if the framing is malformed (truncated header, bad flags, etc.)
  /// or the inflate itself fails.
  ///
  /// Why: iOS URLSession normally decompresses `Content-Encoding: gzip` responses
  /// automatically and strips the header. When it occasionally doesn't (seen with
  /// retried-after-401 requests via CloudFront), the raw gzip stream reaches the
  /// XML parser and parsing fails. This helper lets us salvage those responses.
  static func gunzip(_ data: Data) -> Data? {
    guard startsWithGzipMagic(data), data.count > 18 else { return nil }
    let bytes = [UInt8](data)
    // Parse the 10-byte fixed header per RFC 1952 to find where the deflate stream starts.
    let flags = bytes[3]
    var cursor = 10
    // FEXTRA (0x04): skip 2-byte XLEN + XLEN bytes.
    if flags & 0x04 != 0 {
      guard cursor + 2 <= bytes.count else { return nil }
      let xlen = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
      cursor += 2 + xlen
    }
    // FNAME (0x08): skip NUL-terminated string.
    if flags & 0x08 != 0 {
      while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
      cursor += 1
    }
    // FCOMMENT (0x10): skip NUL-terminated string.
    if flags & 0x10 != 0 {
      while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
      cursor += 1
    }
    // FHCRC (0x02): skip 2-byte CRC16.
    if flags & 0x02 != 0 {
      cursor += 2
    }
    // The gzip trailer (last 8 bytes) holds CRC32 + ISIZE; exclude it from the deflate stream.
    let deflateEnd = bytes.count - 8
    guard cursor < deflateEnd else { return nil }

    let deflate = Array(bytes[cursor..<deflateEnd])
    // Most OPDS feeds decompress ~20×; bound the buffer generously but cap to avoid
    // runaway allocations on malformed input.
    let capacity = max(deflate.count * 24, 64 * 1024)
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { destination.deallocate() }
    let written = deflate.withUnsafeBufferPointer { src -> Int in
      guard let base = src.baseAddress else { return 0 }
      return compression_decode_buffer(
        destination, capacity,
        base, deflate.count,
        nil, COMPRESSION_ZLIB
      )
    }
    guard written > 0 else { return nil }
    return Data(bytes: destination, count: written)
  }

  /// First N bytes of `data` as a UTF-8 (lossy) string, for metadata/logging.
  static func preview(_ data: Data, limit: Int = 256) -> String {
    let slice = data.prefix(limit)
    if let s = String(data: slice, encoding: .utf8) { return s }
    return slice.map { String(format: "%02x", $0) }.joined()
  }
}

extension TPPOPDSFeed {
  public static func withURL(
    _ url: URL?,
    shouldResetCache: Bool,
    useTokenIfAvailable: Bool,
    completionHandler handler: @escaping (TPPOPDSFeed?, NSDictionary?) -> Void
  ) {
    guard let url = url else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "NYPLOPDSFeed: nil URL",
        metadata: ["shouldResetCache": shouldResetCache]
      )
      TPPAsyncDispatch { handler(nil, nil) }
      return
    }

    let cachePolicy: NSURLRequest.CachePolicy = shouldResetCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

    var request: URLRequest?

    let task = AppContainer.production().networkExecutor.GET(
      url,
      cachePolicy: cachePolicy,
      useTokenIfAvailable: useTokenIfAvailable
    ) { data, response, error in

      if let error = error {
        TPPAsyncDispatch { handler(nil, (error as NSError).problemDocument?.dictionaryValue as NSDictionary?) }
        return
      }

      guard let data = data else {
        TPPErrorLogger.logError(
          withCode: .opdsFeedNoData,
          summary: "NYPLOPDSFeed: no data from server",
          metadata: [
            "Request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "Response": response ?? "N/A"
          ]
        )
        TPPAsyncDispatch { handler(nil, nil) }
        return
      }

      if let httpResp = response as? HTTPURLResponse,
         httpResp.statusCode < 200 || httpResp.statusCode > 299 {
        let dataString = String(data: data, encoding: .utf8)

        var problemDocDict: NSDictionary?
        if response?.isProblemDocument() == true {
          problemDocDict = try? JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary
          if problemDocDict == nil {
            problemDocDict = TPPProblemDocument.fromProblemResponseData(data)?.dictionaryValue as NSDictionary?
          }
        }

        TPPErrorLogger.logNetworkError(
          error,
          code: .apiCall,
          summary: "NYPLOPDSFeed: HTTP response error",
          request: request,
          response: response,
          metadata: [
            "receivedData": dataString ?? "N/A",
            "receivedDataLength (bytes)": data.count,
            "problemDoc": problemDocDict ?? "N/A",
            "context": "Got \(httpResp.statusCode) HTTP status with no error object."
          ]
        )

        // When the server returns an error without a problem document,
        // synthesize one from the HTTP status so the error detail
        // propagates to the UI instead of being swallowed as nil.
        let errorDict: NSDictionary? = problemDocDict ?? {
          let body = dataString?.prefix(500) ?? "No response body"
          return [
            "type": "http-error",
            "title": HTTPURLResponse.localizedString(forStatusCode: httpResp.statusCode),
            "status": httpResp.statusCode,
            "detail": "Server returned HTTP \(httpResp.statusCode). \(body)"
          ] as NSDictionary
        }()

        let errorBox = SendableOPDSErrorDictionary(value: errorDict)
        TPPAsyncDispatch { handler(nil, errorBox.value) }
        return
      }

      // Attempt to parse the bytes as XML directly. If that fails and the body
      // is still gzip-framed (rare — URLSession usually strips it, but seen on
      // retried-after-401 requests via CloudFront for Lyrasis Reads /loans/),
      // decompress and retry before declaring the feed invalid.
      var feedXML = TPPXML.xml(withData: data)
      var recoveredViaGunzip = false
      if feedXML == nil, let decompressed = TPPOPDSFeedDataInspection.gunzip(data) {
        if let retryXML = TPPXML.xml(withData: decompressed) {
          feedXML = retryXML
          recoveredViaGunzip = true
        }
      }

      guard let feedXML else {
        Log.log("Failed to parse data as XML.")
        TPPErrorLogger.logError(
          withCode: .feedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse data as XML",
          metadata: [
            "request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "response": response ?? "N/A",
            "receivedDataLength (bytes)": data.count,
            "receivedDataPreview": TPPOPDSFeedDataInspection.preview(data),
            "startsWithGzipMagic": TPPOPDSFeedDataInspection.startsWithGzipMagic(data)
          ]
        )
        let errorDict = try? JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary
        let errorBox = SendableOPDSErrorDictionary(value: errorDict)
        TPPAsyncDispatch { handler(nil, errorBox.value) }
        return
      }

      if recoveredViaGunzip {
        Log.info(#file, "Recovered OPDS feed via client-side gunzip fallback (URLSession left Content-Encoding: gzip undecoded).")
      }

      guard let feed = TPPOPDSFeed(xml: feedXML) else {
        Log.log("Could not interpret XML as OPDS.")
        TPPErrorLogger.logError(
          withCode: .opdsFeedParseFail,
          summary: "NYPLOPDSFeed: Failed to parse XML as OPDS",
          metadata: [
            "request": (request as NSURLRequest?)?.loggableString ?? "N/A",
            "response": response ?? "N/A"
          ]
        )
        TPPAsyncDispatch { handler(nil, nil) }
        return
      }

      TPPAsyncDispatch { handler(feed, nil) }
    }

    request = task?.originalRequest
  }
}

// MARK: - Sendable carrier for the `@Sendable` TPPAsyncDispatch capture

/// Sendable carrier for the OPDS feed error dictionary (`NSDictionary?`, whose
/// element values are not Sendable). It is built once — either synthesized from
/// the HTTP status or parsed from the response body — and only ever read
/// thereafter (forwarded to `handler`), so moving it across the
/// `TPPAsyncDispatch` boundary is race-free. `@unchecked` documents that
/// write-once-then-read confinement. Mirrors `SendableErrorDocument` in
/// `BookRegistrySync`.
private struct SendableOPDSErrorDictionary: @unchecked Sendable {
  let value: NSDictionary?
}
