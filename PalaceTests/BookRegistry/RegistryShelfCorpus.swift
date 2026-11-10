//
//  RegistryShelfCorpus.swift
//  PalaceTests
//
//  `registry.json` files in the shapes older app versions left on disk, for the
//  per-book layout migration tests (PP-5507). The shapes follow the ones
//  TPPBookRegistryMigrationTests and TPPBookRegistryLargeCorpusTests plant.
//

import Foundation

enum RegistryShelfCorpus {

    struct Shelf {
        let name: String
        let json: String
    }

    static var all: [Shelf] { [unversioned, versioned, large(count: 250)] }

    /// No `schemaVersion`, the deprecated singular `acquisition` key, a
    /// `downloadSuccessful` EPUB with a Readium bookmark and a JSON-in-string
    /// location, explicit nulls, a duplicated identifier (load keeps the last)
    /// and a record with no identifier (load drops it).
    static let unversioned = Shelf(name: "unversioned", json: #"""
    {"records":[
      {"metadata":{"id":"urn:librarysimplified.org/terms/id/Overdrive%20ID/0a1b2c","title":"The Old Shelf","updated":"2023-04-02T10:00:00Z","acquisitions":[],"categories":["Fiction"],"authors":["A. Writer"],"author-links":[],"acquisition":{"type":"application/epub+zip","href":"https://example.com/legacy"},"available-copies":1,"holds-position":0,"summary":null,"publisher":null},
       "state":"download-successful",
       "location":{"locationString":"{\"href\":\"/OEBPS/ch03.xhtml\",\"progressWithinChapter\":0.42,\"progressWithinBook\":0.13}","renderer":"readium"},
       "bookmarks":[{"annotationId":"","href":"/OEBPS/ch02.xhtml","chapter":"Two","page":"","location":"","time":"2023-04-02T10:05:00Z","device":"","progressWithinChapter":0.5,"progressWithinBook":0.08,"readingOrderItem":"","readingOrderItemOffsetMilliseconds":0}]},
      {"metadata":{"id":"urn:isbn:9780000000001","title":"On Hold","updated":"2023-01-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"holding"},
      {"metadata":{"id":"urn:isbn:9780000000002","title":"Needs Download v1","updated":"2023-01-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"download-needed"},
      {"metadata":{"id":"urn:isbn:9780000000002","title":"Needs Download v2","updated":"2023-02-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"download-needed","fulfillmentId":"f-2"},
      {"metadata":{"title":"No Identifier","updated":"2023-01-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"holding"}
    ]}
    """#)

    /// `schemaVersion: 1`: an audiobook with generic bookmarks and a
    /// fulfillment id, a `used` book, a non-ASCII title and an identifier with
    /// path separators and a query string.
    static let versioned = Shelf(name: "versioned", json: #"""
    {"schemaVersion":1,"records":[
      {"metadata":{"id":"https://circulation.example.org/works/Axis%20360%20ID/0123/?a=1&b=2","title":"Ünïcödé — 書名","updated":"2025-09-10T08:30:00Z","acquisitions":[],"categories":[],"authors":["B. Narrator"],"author-links":[],"language":"de","audience":"Adult"},
       "state":"download-successful","fulfillmentId":"lcp-license-77",
       "location":{"locationString":"{\"@type\":\"LocatorAudioBookTime\",\"part\":1,\"chapter\":4,\"time\":1834000}","renderer":"PalaceAudiobookToolkit"},
       "genericBookmarks":[
         {"locationString":"{\"@type\":\"LocatorAudioBookTime\",\"part\":1,\"chapter\":2,\"time\":61000,\"annotationId\":\"https://example.org/annotations/1\"}","renderer":"PalaceAudiobookToolkit"},
         {"locationString":"{\"@type\":\"LocatorAudioBookTime\",\"part\":1,\"chapter\":3,\"time\":12000}","renderer":"PalaceAudiobookToolkit"}
       ]},
      {"metadata":{"id":"urn:isbn:9780000000003","title":"Read Before","updated":"2025-01-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"used","location":{"locationString":"{\"href\":\"ch1.xhtml\",\"progressWithinBook\":0.99}","renderer":"readium"},
       "bookmarks":[]},
      {"metadata":{"id":"urn:isbn:9780000000004","title":"Reserved","updated":"2025-01-01T00:00:00Z","acquisitions":[],"categories":[],"authors":[],"author-links":[]},
       "state":"holding"}
    ]}
    """#)

    /// A larger current-schema shelf in the shape TPPBookRegistryLargeCorpusTests uses,
    /// every third book with a position.
    static func large(count: Int) -> Shelf {
        var records: [[String: Any]] = []
        for index in 0..<count {
            var record: [String: Any] = [
                "metadata": [
                    "id": "urn:corpus:book-\(index)",
                    "title": "Corpus Book \(index)",
                    "updated": "2024-06-01T00:00:00Z",
                    "acquisitions": [Any](),
                    "categories": [Any](),
                    "authors": [Any](),
                    "author-links": [Any]()
                ],
                "state": index.isMultiple(of: 2) ? "holding" : "download-needed"
            ]
            if index.isMultiple(of: 3) {
                record["location"] = ["locationString": "{\"progressWithinBook\":0.\(index)}", "renderer": "readium"]
            }
            records.append(record)
        }
        let data = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": records])
        return Shelf(name: "large-\(count)", json: String(decoding: data, as: UTF8.self))
    }
}
