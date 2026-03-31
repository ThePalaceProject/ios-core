import UIKit

extension NSURLRequest {

  @objc static func postRequest(withProblemDocument problemDocument: NSDictionary, url: URL) -> NSURLRequest {
    let request = NSMutableURLRequest()
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 30
    request.httpMethod = "POST"

    let contentType = "application/problem+json"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")

    let data = try? JSONSerialization.data(withJSONObject: problemDocument, options: [])
    request.httpBody = data

    if let data = data {
      request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
    }

    request.url = url
    return request
  }

  @objc static func postRequest(withParams params: NSDictionary, imageOrNil image: UIImage?, url: URL) -> NSURLRequest {
    let boundaryConstant = "----------V2ymHFg03ehbqgZCaKO6jy"
    let fileParamConstant = "file"

    let request = NSMutableURLRequest()
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 30
    request.httpMethod = "POST"

    let contentType = "multipart/form-data; boundary=\(boundaryConstant)"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")

    let body = NSMutableData()

    for case let param as String in params.allKeys {
      body.append("--\(boundaryConstant)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(param)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(params[param] ?? "")\r\n".data(using: .utf8)!)
    }

    if let image = image, let imageData = image.jpegData(compressionQuality: 0.7) {
      body.append("--\(boundaryConstant)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(fileParamConstant)\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
      body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
      body.append(imageData)
      body.append("\r\n".data(using: .utf8)!)
    }

    body.append("--\(boundaryConstant)--\r\n".data(using: .utf8)!)

    request.httpBody = body as Data
    request.setValue("\(body.length)", forHTTPHeaderField: "Content-Length")
    request.url = url

    return request
  }
}
