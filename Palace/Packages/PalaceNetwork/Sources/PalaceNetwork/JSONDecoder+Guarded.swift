//
//  JSONDecoder+Guarded.swift
//  PalaceNetwork
//
//  A decode that screens bytes the app did not write itself, on the runtimes
//  whose decoder traps on a malformed object key rather than throwing. It
//  closes the five measured key shapes there; it is not established as a
//  superset of every input that traps (PP-5412).
//

import Foundation

// PUBLIC_INTENT: contracted SPM API — the guarded decode sites are in the app target and in PalaceCatalog and PalaceAuth, so it crosses the package boundary; internal would force one copy per module, and a copy is how a site ends up unguarded.
public extension JSONDecoder {

    /// Whether this runtime needs external JSON screened before decoding.
    ///
    /// iOS 18.0 through 18.3 trap; 18.4 onwards throw, because the upstream fix
    /// (rdar://133742708) shipped in Swift 6.1. Where the decoder already
    /// throws, screening would only narrow what loads, so it is off.
    static let prescreensExternalJSON: Bool = {
        #if os(iOS)
        if #available(iOS 18.4, *) { return false }
        return true
        #else
        return false
        #endif
    }()

    /// Throws unless `data` is JSON the decoder can read without trapping.
    ///
    /// `JSONSerialization` parses the whole document and reports a malformed
    /// object key as an ordinary error, which is what `decodeGuarded` needs and
    /// `JSONDecoder` cannot do for itself.
    ///
    /// Exposed so the screen can be tested on a runtime where `decodeGuarded`
    /// does not invoke it. It is deliberately NOT a parameter on
    /// `decodeGuarded`: a per-call override would let a production site opt out
    /// of the guard on the one runtime it exists for, and nothing would catch
    /// that.
    static func screenExternalJSON(_ data: Data) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Malformed JSON rejected before decoding",
                    underlyingError: error
                )
            )
        }
    }

    /// Decode `data`, screening it first on runtimes whose decoder would trap.
    ///
    /// On iOS 18.0 through 18.3 `JSONDecoder` calls `try!` while building a
    /// keyed container's key set, so a malformed object KEY raises
    /// `swift_unexpectedError` rather than throwing: `try` and `try?` at the
    /// call site cannot catch it, and the process dies. It reaches that path for
    /// every container it opens, which for these models is the top level and
    /// most of a feed below it.
    ///
    /// The screen parses the whole document instead, so it is stricter than the
    /// decoder wherever the decoder never looks. Measured: a lone surrogate, an
    /// out-of-range exponent (`1e400`) and a leading-zero number (`01`) in a
    /// member no model reads, and a malformed KEY inside a sub-object no model
    /// opens, are each accepted by the decoder and refused by the screen. The
    /// decoder validates a value when a container asks for it and a key when it
    /// builds that container, so anything a model actually touches is already
    /// rejected today, screen or no screen.
    ///
    /// So the screen's benefit and its cost both fall on parts of a document the
    /// decoder would have skipped, and a whole-document parse cannot tell those
    /// two apart. On a trapping runtime the choice is therefore: the process
    /// dies on a malformed key in a container the model opens, or a feed is
    /// refused over bytes nobody reads. A refused feed is recoverable — the
    /// registry falls back to cached and bundled data — and a dead process is
    /// not, so the screen runs there. Where the decoder throws by itself the
    /// screen would buy nothing and could only narrow what loads, so this is a
    /// plain `decode`.
    ///
    /// Only the screen's own failure is rewritten; the decoder's `typeMismatch`,
    /// `keyNotFound` and `valueNotFound` reach the caller unchanged, because
    /// callers branch on them.
    func decodeGuarded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if Self.prescreensExternalJSON {
            try Self.screenExternalJSON(data)
        }
        return try decode(type, from: data)
    }
}
