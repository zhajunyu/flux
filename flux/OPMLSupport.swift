//
//  OPMLSupport.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var opml: UTType {
        UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml
    }
}

struct OPMLEntry: Sendable, Equatable {
    let title: String
    let url: URL
    let categoryName: String?
}

struct OPMLParseResult: Sendable, Equatable {
    let entries: [OPMLEntry]
    let invalidEntryCount: Int
}

struct OPMLExportEntry: Sendable, Equatable {
    let title: String
    let url: String
    let categoryName: String?
}

enum OPMLError: LocalizedError, Equatable {
    case emptyDocument
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The selected OPML file is empty."
        case .invalidDocument:
            "The selected file is not a readable OPML document."
        }
    }
}

enum OPMLCodec {
    static func parse(data: Data) throws -> OPMLParseResult {
        guard !data.isEmpty else { throw OPMLError.emptyDocument }

        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), delegate.sawOPML, delegate.sawBody else {
            throw OPMLError.invalidDocument
        }

        return OPMLParseResult(
            entries: delegate.entries,
            invalidEntryCount: delegate.invalidEntryCount
        )
    }

    static func encode(entries: [OPMLExportEntry]) -> Data {
        let sortedEntries = entries.sorted(by: compareEntries)
        let categorized = Dictionary(grouping: sortedEntries.compactMap { entry -> OPMLExportEntry? in
            guard normalizedText(entry.categoryName) != nil else { return nil }
            return entry
        }) { normalizedText($0.categoryName)! }
        let uncategorized = sortedEntries.filter { normalizedText($0.categoryName) == nil }

        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>Flux Subscriptions</title>",
            "  </head>",
            "  <body>",
        ]

        for categoryName in categorized.keys.sorted(by: compareText) {
            let escapedCategory = escape(categoryName)
            lines.append("    <outline text=\"\(escapedCategory)\" title=\"\(escapedCategory)\">")
            for entry in categorized[categoryName, default: []] {
                lines.append(feedOutline(for: entry, indentation: "      "))
            }
            lines.append("    </outline>")
        }

        for entry in uncategorized {
            lines.append(feedOutline(for: entry, indentation: "    "))
        }

        lines.append("  </body>")
        lines.append("</opml>")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func feedOutline(for entry: OPMLExportEntry, indentation: String) -> String {
        let title = escape(normalizedText(entry.title) ?? entry.url)
        let url = escape(entry.url)
        return "\(indentation)<outline text=\"\(title)\" title=\"\(title)\" type=\"rss\" xmlUrl=\"\(url)\"/>"
    }

    private static func compareEntries(_ lhs: OPMLExportEntry, _ rhs: OPMLExportEntry) -> Bool {
        if compareText(lhs.title, rhs.title) { return true }
        if compareText(rhs.title, lhs.title) { return false }
        return lhs.url < rhs.url
    }

    private static func compareText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive, .numeric],
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedAscending
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct OPMLFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.opml, .xml]
    static let writableContentTypes: [UTType] = [.opml]

    var data: Data

    init(entries: [OPMLExportEntry] = []) {
        data = OPMLCodec.encode(entries: entries)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw OPMLError.invalidDocument
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private struct OutlineContext {
        let categoryPath: [String]
        let isIgnored: Bool
    }

    private(set) var entries: [OPMLEntry] = []
    private(set) var invalidEntryCount = 0
    private(set) var sawOPML = false
    private(set) var sawBody = false

    private var isInsideBody = false
    private var outlineStack: [OutlineContext] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        if element == "opml" {
            sawOPML = true
            return
        }
        if element == "body", sawOPML {
            sawBody = true
            isInsideBody = true
            return
        }
        guard element == "outline", isInsideBody else { return }

        let attributes = attributeDict.reduce(into: [String: String]()) { result, attribute in
            result[attribute.key.lowercased()] = attribute.value
        }
        let parent = outlineStack.last
        let isComment = attributes["iscomment"]?.lowercased() == "true"
        let isInclude = attributes["type"]?.lowercased() == "include"
        let isIgnored = parent?.isIgnored == true || isComment || isInclude
        let parentPath = parent?.categoryPath ?? []
        let rawXMLURL = attributes["xmlurl"]

        if !isIgnored, let rawXMLURL {
            do {
                let url = try URLNormalizer.feedURL(from: rawXMLURL)
                let title = normalizedText(attributes["title"])
                    ?? normalizedText(attributes["text"])
                    ?? url.host
                    ?? url.absoluteString
                entries.append(
                    OPMLEntry(
                        title: title,
                        url: url,
                        categoryName: parentPath.isEmpty ? nil : parentPath.joined(separator: " / ")
                    )
                )
            } catch {
                invalidEntryCount += 1
            }
            outlineStack.append(OutlineContext(categoryPath: parentPath, isIgnored: false))
            return
        }

        if !isIgnored, attributes["type"]?.lowercased() == "rss" {
            invalidEntryCount += 1
        }

        var categoryPath = parentPath
        if !isIgnored,
           let folderName = normalizedText(attributes["title"])
            ?? normalizedText(attributes["text"]) {
            categoryPath.append(folderName)
        }
        outlineStack.append(OutlineContext(categoryPath: categoryPath, isIgnored: isIgnored))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        if element == "outline", isInsideBody {
            _ = outlineStack.popLast()
        } else if element == "body" {
            isInsideBody = false
        }
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
