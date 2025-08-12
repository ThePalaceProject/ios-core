import Foundation
import AVFoundation
import ReadiumShared
import UniformTypeIdentifiers

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    var publication: Publication?
    private let httpRangeRetriever = HTTPRangeRetriever()

    init(publication: Publication? = nil) {
        self.publication = publication
        super.init()
        ATLog(.debug, "🎵 [LCPResourceLoader] ✅ Delegate initialized with publication: \(publication != nil)")
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {

         guard
             let pub = publication,
             let url = loadingRequest.request.url,
             url.scheme == "fake",
             url.host == "lcp-streaming"
         else {
             loadingRequest.finishLoading(with: NSError(
                 domain: "LCPResourceLoader",
                 code: -1,
                 userInfo: [NSLocalizedDescriptionKey: "Invalid URL or missing publication"]
             ))
            return false
        }
        
         let comps = url.pathComponents  // ["/", "track", "{index}"]
         let index = (comps.count >= 3 && comps[1] == "track") ? Int(comps[2]) ?? 0 : 0
         guard (0..<pub.readingOrder.count).contains(index) else {
             loadingRequest.finishLoading(with: NSError(
                 domain: "LCPResourceLoader",
                 code: 2,
                 userInfo: [NSLocalizedDescriptionKey: "Track index out of range"]
             ))
             return false
         }

        let link = pub.readingOrder[index]
        let href = link.href

        // Resolve Publication Resource and AbsoluteURL to support remote HTTP streaming fallback
        let resource = Self.resource(for: pub, href: href)
        let absoluteHTTPURL: HTTPURL? = {
            // Prefer resolving against the publication self link
            if let base = pub.linkWithRel(.self)?.href,
               let baseURL = URL(string: base),
               let resolved = URL(string: href, relativeTo: baseURL),
               let http = HTTPURL(url: resolved) {
                return http
            }
            // Fallback: try interpreting href directly as absolute HTTP(S)
            if let direct = URL(string: href), let http = HTTPURL(url: direct) {
                return http
            }
            return nil
        }()

         // Guard against FailureResource
         if resource is FailureResource {
             loadingRequest.finishLoading(with: NSError(
                 domain: "LCPResourceLoader",
                 code: 3,
                 userInfo: [NSLocalizedDescriptionKey: "FailureResource for href: \(href)"]
             ))
             return false
         }

        // Content info
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.utiIdentifier(forHref: href, fallbackMime: link.mediaType?.string)
            info.isByteRangeAccessSupported = true

            Task {
                // Prefer Publication-provided length; fallback to HTTP HEAD, even on failure
                var setLength = false
                if let res = resource {
                    if let maybeLength = try? await res.estimatedLength().get(), let totalLength = maybeLength {
                        DispatchQueue.main.async { info.contentLength = Int64(totalLength) }
                        setLength = true
                    }
                }
                if !setLength, let httpURL = absoluteHTTPURL {
                    httpRangeRetriever.getContentLength(for: httpURL) { result in
                        if case .success(let length) = result {
                            DispatchQueue.main.async { info.contentLength = Int64(length) }
                        }
                    }
                }
            }
        }

         // Serve bytes
         guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
             return true
         }

        let start = UInt64(max(0, dataRequest.requestedOffset))  // inclusive
         let count = UInt64(dataRequest.requestedLength)
         let endExcl = start &+ count
         let range: Range<UInt64> = start..<endExcl
                
        Task {
            // Try Publication-backed read first; on error, fall back to HTTP range if possible
            if let res = resource {
                do {
                    let data = try await res.read(range: range).get()
                    DispatchQueue.main.async {
                        dataRequest.respond(with: data)
                        loadingRequest.finishLoading()
                    }
                    return
                } catch {
                    // fall through to HTTP fallback
                }
            }
            if let httpURL = absoluteHTTPURL {
                let byteRange = Int(start)..<Int(endExcl)
                httpRangeRetriever.fetchRange(from: httpURL, range: byteRange) { result in
                    switch result {
                    case .success(let data):
                        dataRequest.respond(with: data)
                        loadingRequest.finishLoading()
                    case .failure(let error):
                        loadingRequest.finishLoading(with: error)
                    }
                }
            } else {
                loadingRequest.finishLoading(with: NSError(
                    domain: "LCPResourceLoader", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "No resource or URL available for streaming"]
                ))
            }
        }

         return true
     }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        ATLog(.debug, "LCP: Resource loading request cancelled")
    }
}

// MARK: - Helpers
private extension LCPResourceLoaderDelegate {
    static func resource(for publication: Publication, href: String) -> Resource? {
        // Try exact
        if let res = publication.get(Link(href: href)), type(of: res) != FailureResource.self {
            return res
        }
        // Try leading slash
        if let res = publication.get(Link(href: "/" + href)), type(of: res) != FailureResource.self {
            return res
        }
        // Try resolving against baseURL if available
        if let base = publication.linkWithRel(.self)?.href, let absolute = URL(string: href, relativeTo: URL(string: base)!)?.absoluteString {
            if let res = publication.get(Link(href: absolute)), type(of: res) != FailureResource.self {
                return res
            }
        }
        return nil
    }
    static func utiIdentifier(forHref href: String, fallbackMime: String?) -> String {
        let ext = URL(fileURLWithPath: href).pathExtension.lowercased()

        // Try modern UTType first
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }

        // Minimal manual mapping for common audio types
        switch ext {
        case "mp3":
            return "public.mp3"              // MP3
        case "m4a":
            return "com.apple.m4a-audio"     // M4A
        case "mp4":
            return "public.mpeg-4"           // MP4 container (audio)
        default:
                break
        }

        // Fallback to MIME-derived guesses
        if let mime = fallbackMime?.lowercased() {
            if mime.contains("mpeg") || mime.contains("mp3") { return "public.mp3" }
            if mime.contains("m4a") || mime.contains("mp4") { return "com.apple.m4a-audio" }
        }

        // Last resort
        return "public.audio"
    }
}
