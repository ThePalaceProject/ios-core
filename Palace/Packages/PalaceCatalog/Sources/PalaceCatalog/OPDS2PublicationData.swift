import Foundation

public struct OPDS2FullPublication: Codable, Equatable, Sendable, Identifiable {
    public let metadata: OPDS2FullMetadata
    public let links: [OPDS2Link]
    public let images: [OPDS2Link]?

    public var id: String { metadata.identifier }

    // MARK: - Image URLs

    public var imageURL: URL? {
        images?.first { $0.rel == nil || $0.rel == "http://opds-spec.org/image" }?.hrefURL
    }

    public var thumbnailURL: URL? {
        images?.first { $0.rel?.contains("thumbnail") == true }?.hrefURL ??
            images?.first { ($0.width ?? 0) < 200 && $0.width != nil }?.hrefURL
    }

    public var coverURL: URL? {
        images?.first { $0.rel?.contains("cover") == true }?.hrefURL ??
            images?.first { ($0.width ?? 0) >= 200 }?.hrefURL
    }

    // MARK: - Acquisition Links

    public var acquisitionLinks: [OPDS2Link] {
        links.filter { link in
            link.rel?.contains("acquisition") == true
        }
    }

    public var borrowLink: OPDS2Link? {
        links.first { $0.rel == "http://opds-spec.org/acquisition/borrow" }
    }

    public var openAccessLink: OPDS2Link? {
        links.first { $0.rel == "http://opds-spec.org/acquisition/open-access" }
    }

    public var sampleLink: OPDS2Link? {
        links.first { $0.rel == "http://opds-spec.org/acquisition/sample" ||
            $0.rel == "preview" }
    }

    // MARK: - Content Type

    public var isAudiobook: Bool {
        acquisitionLinks.contains { link in
            link.type?.contains("audiobook") == true
        }
    }

    public var isEPUB: Bool {
        acquisitionLinks.contains { link in
            link.type?.contains("epub") == true
        }
    }

    public var isPDF: Bool {
        acquisitionLinks.contains { link in
            link.type?.contains("pdf") == true
        }
    }

}

// MARK: - Full Metadata

public struct OPDS2FullMetadata: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let sortAs: String?
    public let subtitle: String?
    public let modified: Date?
    public let published: Date?
    public let language: String?
    public let description: String?
    public let author: [OPDS2Contributor]?
    public let translator: [OPDS2Contributor]?
    public let editor: [OPDS2Contributor]?
    public let narrator: [OPDS2Contributor]?
    public let contributor: [OPDS2Contributor]?
    public let publisher: String?
    public let imprint: String?
    public let subject: [OPDS2Subject]?
    public let duration: Double?
    public let numberOfPages: Int?
    public let belongsTo: OPDS2BelongsTo?

    // MARK: - Memberwise Init

    public init(
        identifier: String,
        title: String,
        sortAs: String? = nil,
        subtitle: String? = nil,
        modified: Date? = nil,
        published: Date? = nil,
        language: String? = nil,
        description: String? = nil,
        author: [OPDS2Contributor]? = nil,
        translator: [OPDS2Contributor]? = nil,
        editor: [OPDS2Contributor]? = nil,
        narrator: [OPDS2Contributor]? = nil,
        contributor: [OPDS2Contributor]? = nil,
        publisher: String? = nil,
        imprint: String? = nil,
        subject: [OPDS2Subject]? = nil,
        duration: Double? = nil,
        numberOfPages: Int? = nil,
        belongsTo: OPDS2BelongsTo? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.sortAs = sortAs
        self.subtitle = subtitle
        self.modified = modified
        self.published = published
        self.language = language
        self.description = description
        self.author = author
        self.translator = translator
        self.editor = editor
        self.narrator = narrator
        self.contributor = contributor
        self.publisher = publisher
        self.imprint = imprint
        self.subject = subject
        self.duration = duration
        self.numberOfPages = numberOfPages
        self.belongsTo = belongsTo
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case identifier = "@id"
        case title
        case sortAs
        case subtitle
        case modified
        case published
        case language
        case description
        case author
        case translator
        case editor
        case narrator
        case contributor
        case publisher
        case imprint
        case subject
        case duration
        case numberOfPages
        case belongsTo
    }

    // Alternate decoding for different JSON structures
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle identifier with multiple possible keys
        if let id = try? container.decode(String.self, forKey: .identifier) {
            identifier = id
        } else if let altContainer = try? decoder.container(keyedBy: AlternateCodingKeys.self),
                  let id = try? altContainer.decode(String.self, forKey: .id) {
            identifier = id
        } else {
            identifier = UUID().uuidString
        }

        title = try container.decode(String.self, forKey: .title)
        sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified)
        published = try container.decodeIfPresent(Date.self, forKey: .published)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .author)
        translator = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .translator)
        editor = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .editor)
        narrator = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .narrator)
        contributor = try container.decodeIfPresent([OPDS2Contributor].self, forKey: .contributor)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        imprint = try container.decodeIfPresent(String.self, forKey: .imprint)
        subject = try container.decodeIfPresent([OPDS2Subject].self, forKey: .subject)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        numberOfPages = try container.decodeIfPresent(Int.self, forKey: .numberOfPages)
        belongsTo = try container.decodeIfPresent(OPDS2BelongsTo.self, forKey: .belongsTo)
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(sortAs, forKey: .sortAs)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(modified, forKey: .modified)
        try container.encodeIfPresent(published, forKey: .published)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(translator, forKey: .translator)
        try container.encodeIfPresent(editor, forKey: .editor)
        try container.encodeIfPresent(narrator, forKey: .narrator)
        try container.encodeIfPresent(contributor, forKey: .contributor)
        try container.encodeIfPresent(publisher, forKey: .publisher)
        try container.encodeIfPresent(imprint, forKey: .imprint)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(numberOfPages, forKey: .numberOfPages)
        try container.encodeIfPresent(belongsTo, forKey: .belongsTo)
    }
}

// MARK: - Contributor

public struct OPDS2Contributor: Codable, Equatable, Sendable {
    public let name: String
    public let sortAs: String?
    public let identifier: String?
    public let links: [OPDS2Link]?

    public init(name: String, sortAs: String? = nil, identifier: String? = nil, links: [OPDS2Link]? = nil) {
        self.name = name
        self.sortAs = sortAs
        self.identifier = identifier
        self.links = links
    }

    // Handle both string and object representations
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let nameString = try? container.decode(String.self) {
            name = nameString
            sortAs = nil
            identifier = nil
            links = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            links = try container.decodeIfPresent([OPDS2Link].self, forKey: .links)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, sortAs, identifier, links
    }
}

// MARK: - Subject

public struct OPDS2Subject: Codable, Equatable, Sendable {
    public let name: String
    public let sortAs: String?
    public let scheme: String?
    public let code: String?

    public init(name: String, sortAs: String? = nil, scheme: String? = nil, code: String? = nil) {
        self.name = name
        self.sortAs = sortAs
        self.scheme = scheme
        self.code = code
    }

    // Handle both string and object representations
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let nameString = try? container.decode(String.self) {
            name = nameString
            sortAs = nil
            scheme = nil
            code = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            sortAs = try container.decodeIfPresent(String.self, forKey: .sortAs)
            scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
            code = try container.decodeIfPresent(String.self, forKey: .code)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, sortAs, scheme, code
    }
}

// MARK: - BelongsTo (Series/Collection)

public struct OPDS2BelongsTo: Codable, Equatable, Sendable {
    public let series: [OPDS2Collection]?
    public let collection: [OPDS2Collection]?

    public init(series: [OPDS2Collection]? = nil, collection: [OPDS2Collection]? = nil) {
        self.series = series
        self.collection = collection
    }
}

public struct OPDS2Collection: Codable, Equatable, Sendable {
    public let name: String
    public let sortAs: String?
    public let identifier: String?
    public let position: Double?
    public let links: [OPDS2Link]?

    public init(
        name: String,
        sortAs: String? = nil,
        identifier: String? = nil,
        position: Double? = nil,
        links: [OPDS2Link]? = nil
    ) {
        self.name = name
        self.sortAs = sortAs
        self.identifier = identifier
        self.position = position
        self.links = links
    }
}
