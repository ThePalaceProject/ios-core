//
//  LintSourceText.swift
//
//  Shared text handling for the MetaTests lints: a comment stripper that keeps
//  byte offsets, and a Swift-file walker. A lint predicate that reads comments
//  fails in both directions — it reports prose as a violation, and a guard that
//  only ever matches commented-out text goes green over live code.
//

import Foundation

enum LintSourceText {

    /// Replaces every comment byte with a space and keeps newlines, so offsets
    /// and line numbers match the original file. String literals are tracked,
    /// so `"https://x"` keeps its slashes and a literal containing `/*` is not
    /// read as a comment opener.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var inString = false
        var inLine = false
        var inBlock = false
        var escaped = false
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            let nextIndex = source.index(after: i)
            let next: Character? = nextIndex < source.endIndex ? source[nextIndex] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) } else { out.append(" ") }
                i = nextIndex; continue
            }
            if inBlock {
                if c == "*" && next == "/" {
                    inBlock = false; out.append("  "); i = source.index(i, offsetBy: 2); continue
                }
                out.append(c == "\n" ? "\n" : " ")
                i = nextIndex; continue
            }
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i = nextIndex; continue
            }
            if c == "\"" { inString = true; out.append(c); i = nextIndex; continue }
            if c == "/" && next == "/" { inLine = true; out.append("  "); i = source.index(i, offsetBy: 2); continue }
            if c == "/" && next == "*" { inBlock = true; out.append("  "); i = source.index(i, offsetBy: 2); continue }
            out.append(c)
            i = nextIndex
        }
        return out
    }

    /// The repo root, derived from this file's location in `PalaceTests/MetaTests`.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests
            .deletingLastPathComponent()   // PalaceTests
            .deletingLastPathComponent()   // repo root
    }

    /// Every `.swift` file under `<repoRoot>/<directory>`, sorted so a failure
    /// list is stable between runs.
    static func swiftFiles(under directory: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        var files: [URL] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return files
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The body of the brace block that opens at or after `from`, excluding the
    /// outer braces. Comments must already be stripped; string literals are
    /// tracked so a `{` inside a literal does not shift the depth.
    static func braceBody(in source: String, from: String.Index) -> String? {
        var i = from
        while i < source.endIndex, source[i] != "{" { i = source.index(after: i) }
        guard i < source.endIndex else { return nil }
        let bodyStart = source.index(after: i)
        var depth = 1
        var j = bodyStart
        var inString = false
        var escaped = false
        while j < source.endIndex {
            let c = source[j]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(source[bodyStart..<j]) }
            }
            j = source.index(after: j)
        }
        return nil
    }
}
