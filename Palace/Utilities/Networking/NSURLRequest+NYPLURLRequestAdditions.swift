import Foundation
import UIKit

extension URLRequest {

  /// Creates a POST request with a JSON problem document body.
  static func postRequest(withProblemDocument problemDocument: [String: Any], url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 30
    request.httpMethod = "POST"

    request.setValue("application/problem+json", forHTTPHeaderField: "Content-Type")

    if let data = try? JSONSerialization.data(withJSONObject: problemDocument, options: []) {
      request.httpBody = data
      request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
    }

    return request
  }

  /// Creates a multipart POST request with form parameters and an optional image.
  static func postRequest(
    withParams params: [String: Any],
    image: UIImage?,
    url: URL
  ) -> URLRequest {
    let boundary = "----------V2ymHFg03ehbqgZCaKO6jy"
    let fileParamName = "file"

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 30
    request.httpMethod = "POST"

    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()

    // Add params (all values converted to strings)
    for (key, value) in params {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(value)\r\n".data(using: .utf8)!)
    }

    // Add image data
    if let image = image, let imageData = image.jpegData(compressionQuality: 0.7) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(fileParamName)\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
      body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
      body.append(imageData)
      body.append("\r\n".data(using: .utf8)!)
    }

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body
    request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

    return request
  }
}

// COEXISTENCE: ObjC originals provide these. Uncomment when ObjC files are removed.
//// MARK: - ObjC compatibility on NSURLRequest
//
//extension NSURLRequest {
//
//  @objc static func postRequest(
//    withProblemDocument problemDocument: NSDictionary,
//    url: URL
//  ) -> NSURLRequest {
//    URLRequest.postRequest(
//      withProblemDocument: problemDocument as! [String: Any],
//      url: url
//    ) as NSURLRequest
//  }
//
//  @objc static func postRequest(
//    withParams params: NSDictionary,
//    imageOrNil image: UIImage?,
//    url: URL
//  ) -> NSURLRequest {
//    URLRequest.postRequest(
//      withParams: params as! [String: Any],
//      image: image,
//      url: url
//    ) as NSURLRequest
//  }
//}
