//
//  FeedClient.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import FeedKit
import Foundation
import UIKit
import XMLKit

struct ParsedFeed: Sendable, Equatable {
    enum Format: String, Sendable {
        case rss = "RSS"
        case atom = "Atom"
        case json = "JSON Feed"
    }

    let title: String
    let sourceURL: URL
    let websiteURL: URL?
    let iconURL: URL?
    let format: Format
    let fetchedAt: Date
    let articles: [ParsedArticle]

    init(
        title: String,
        sourceURL: URL,
        websiteURL: URL? = nil,
        iconURL: URL? = nil,
        format: Format,
        fetchedAt: Date,
        articles: [ParsedArticle]
    ) {
        self.title = title
        self.sourceURL = sourceURL
        self.websiteURL = websiteURL
        self.iconURL = iconURL
        self.format = format
        self.fetchedAt = fetchedAt
        self.articles = articles
    }

    func replacingIconURL(with iconURL: URL?) -> ParsedFeed {
        ParsedFeed(
            title: title,
            sourceURL: sourceURL,
            websiteURL: websiteURL,
            iconURL: iconURL,
            format: format,
            fetchedAt: fetchedAt,
            articles: articles
        )
    }
}

struct ParsedArticle: Sendable, Equatable {
    let title: String
    let content: String?
    let link: String
    let publishedAt: Date?
}

struct FeedClient: Sendable {
    var fetch: @Sendable (URL) async throws -> ParsedFeed

    static let live = FeedClient { requestedURL in
        var request = URLRequest(url: requestedURL)
        request.timeoutInterval = 30
        request.setValue(
            "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml, */*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Flux/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FeedClientError.invalidResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw FeedClientError.httpStatus(response.statusCode)
        }
        guard !data.isEmpty else {
            throw FeedClientError.emptyResponse
        }

        let responseURL = response.url ?? requestedURL
        guard let finalURL = URLNormalizer.canonicalURL(responseURL) else {
            throw FeedClientError.invalidURL
        }
        let fetchedAt = Date()

        let parsedFeed = try await Task.detached(priority: .userInitiated) {
            try FeedDocumentParser.parse(data: data, sourceURL: finalURL, fetchedAt: fetchedAt)
        }.value

        guard parsedFeed.iconURL == nil else { return parsedFeed }

        let websiteURL = parsedFeed.websiteURL ?? URLNormalizer.originURL(from: finalURL)
        let fallbackURL = URLNormalizer.faviconURL(
            from: websiteURL?.absoluteString,
            relativeTo: finalURL
        )
        guard let websiteURL else {
            return parsedFeed.replacingIconURL(with: fallbackURL)
        }

        do {
            let discoveredURL = try await FeedIconDiscovery.discoverIconURL(from: websiteURL)
            return parsedFeed.replacingIconURL(with: discoveredURL ?? fallbackURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return parsedFeed.replacingIconURL(with: fallbackURL)
        }
    }

    static let preview = FeedClient { url in
        ParsedFeed(
            title: url.host ?? "Preview Feed",
            sourceURL: url,
            format: .rss,
            fetchedAt: Date(),
            articles: []
        )
    }
}

enum FeedClientError: LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case unreadableFeed
    case duplicateFeed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid feed URL."
        case .unsupportedScheme:
            "Feed URLs must use HTTP or HTTPS."
        case .invalidResponse:
            "The server returned an invalid response."
        case .httpStatus(let statusCode):
            "The server returned HTTP status \(statusCode)."
        case .emptyResponse:
            "The server returned an empty feed."
        case .unreadableFeed:
            "This URL does not contain a readable RSS, Atom, or JSON feed."
        case .duplicateFeed:
            "You are already subscribed to this feed."
        }
    }
}

enum URLNormalizer {
    static func feedURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FeedClientError.invalidURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
            throw FeedClientError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw FeedClientError.unsupportedScheme
        }
        guard let canonicalURL = canonicalURL(url) else {
            throw FeedClientError.invalidURL
        }
        return canonicalURL
    }

    static func canonicalURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.fragment = nil

        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }

        return components.url
    }

    static func canonicalString(_ url: URL) -> String? {
        canonicalURL(url)?.absoluteString
    }

    static func articleLink(from rawValue: String?, relativeTo sourceURL: URL) -> String? {
        resourceURL(from: rawValue, relativeTo: sourceURL)?.absoluteString
    }

    static func resourceURL(from rawValue: String?, relativeTo sourceURL: URL) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL
        else {
            return nil
        }
        return canonicalURL(resolved)
    }

    static func faviconURL(from website: String?, relativeTo sourceURL: URL) -> URL? {
        let websiteURL = resourceURL(from: website, relativeTo: sourceURL) ?? sourceURL
        guard var components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url.flatMap(canonicalURL)
    }

    static func originURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url.flatMap(canonicalURL)
    }
}

enum FeedIconDiscovery {
    private static let maximumHTMLSize = 2 * 1_024 * 1_024

    static func discoverIconURL(from websiteURL: URL) async throws -> URL? {
        var request = URLRequest(url: websiteURL)
        request.timeoutInterval = 15
        request.setValue(
            "text/html, application/xhtml+xml;q=0.9, */*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Flux/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode),
              response.expectedContentLength <= Int64(maximumHTMLSize),
              !data.isEmpty,
              data.count <= maximumHTMLSize else {
            return nil
        }

        return iconURL(in: data, relativeTo: response.url ?? websiteURL)
    }

    static func iconURL(in data: Data, relativeTo baseURL: URL) -> URL? {
        let html = String(decoding: data, as: UTF8.self)
        guard let linkExpression = try? NSRegularExpression(
            pattern: #"<link\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in linkExpression.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[tagRange]))
            guard let relation = attributes["rel"]?.lowercased() else { continue }
            let relations = Set(relation.split(whereSeparator: \.isWhitespace).map(String.init))
            guard relations.contains("icon")
                    || relations.contains("apple-touch-icon")
                    || relations.contains("apple-touch-icon-precomposed"),
                  let href = attributes["href"] else {
                continue
            }

            if let iconURL = URLNormalizer.resourceURL(
                from: decodeHTMLEntities(in: href),
                relativeTo: baseURL
            ) {
                return iconURL
            }
        }
        return nil
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let attributeExpression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        ) else {
            return [:]
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        return attributeExpression.matches(in: tag, range: range).reduce(into: [:]) { result, match in
            guard let nameRange = Range(match.range(at: 1), in: tag) else { return }
            let valueRange = (2 ... 4)
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
                .flatMap { Range($0, in: tag) }
            guard let valueRange else { return }
            result[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
        }
    }

    private static func decodeHTMLEntities(in value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum FeedDocumentParser {
    static func parse(data: Data, sourceURL: URL, fetchedAt: Date = Date()) throws -> ParsedFeed {
        let feed: FeedKit.Feed
        do {
            feed = try FeedKit.Feed(data: data)
        } catch {
            throw FeedClientError.unreadableFeed
        }

        switch feed {
        case .rss(let rss):
            return parse(rss: rss, sourceURL: sourceURL, fetchedAt: fetchedAt)
        case .atom(let atom):
            return parse(atom: atom, sourceURL: sourceURL, fetchedAt: fetchedAt)
        case .json(let json):
            return parse(json: json, sourceURL: sourceURL, fetchedAt: fetchedAt)
        }
    }

    private static func parse(rss: RSSFeed, sourceURL: URL, fetchedAt: Date) -> ParsedFeed {
        let channel = rss.channel
        let title = HTMLTextExtractor.singleLine(channel?.title)
            ?? sourceURL.host
            ?? "Untitled Feed"
        let websiteURL = URLNormalizer.resourceURL(from: channel?.link, relativeTo: sourceURL)
        let iconURL = URLNormalizer.resourceURL(
            from: channel?.image?.url,
            relativeTo: sourceURL
        )
        let articles = (channel?.items ?? []).compactMap { item -> ParsedArticle? in
            guard let link = URLNormalizer.articleLink(from: item.link, relativeTo: sourceURL) else {
                return nil
            }
            let rawContent = item.content?.encoded ?? item.markdown ?? item.description
            return ParsedArticle(
                title: HTMLTextExtractor.singleLine(item.title) ?? "Untitled Article",
                content: HTMLTextExtractor.body(rawContent),
                link: link,
                publishedAt: item.pubDate
            )
        }

        return ParsedFeed(
            title: title,
            sourceURL: sourceURL,
            websiteURL: websiteURL,
            iconURL: iconURL,
            format: .rss,
            fetchedAt: fetchedAt,
            articles: articles
        )
    }

    private static func parse(atom: AtomFeed, sourceURL: URL, fetchedAt: Date) -> ParsedFeed {
        let title = HTMLTextExtractor.singleLine(atom.title?.text)
            ?? sourceURL.host
            ?? "Untitled Feed"
        let website = atom.links?.first(where: {
            guard let relation = $0.attributes?.rel?.lowercased() else { return true }
            return relation == "alternate"
        })?.attributes?.href
        let websiteURL = URLNormalizer.resourceURL(from: website, relativeTo: sourceURL)
        let iconURL = URLNormalizer.resourceURL(
            from: atom.icon ?? atom.logo,
            relativeTo: sourceURL
        )
        let articles = (atom.entries ?? []).compactMap { entry -> ParsedArticle? in
            let preferredLink = entry.links?.first(where: {
                guard let relation = $0.attributes?.rel?.lowercased() else { return true }
                return relation == "alternate"
            })?.attributes?.href
            let fallbackLink = entry.links?.compactMap(\.attributes?.href).first
            guard let link = URLNormalizer.articleLink(
                from: preferredLink ?? fallbackLink,
                relativeTo: sourceURL
            ) else {
                return nil
            }
            let rawContent = entry.content?.text ?? entry.summary?.text
            return ParsedArticle(
                title: HTMLTextExtractor.singleLine(entry.title) ?? "Untitled Article",
                content: HTMLTextExtractor.body(rawContent),
                link: link,
                publishedAt: entry.published ?? entry.updated
            )
        }

        return ParsedFeed(
            title: title,
            sourceURL: sourceURL,
            websiteURL: websiteURL,
            iconURL: iconURL,
            format: .atom,
            fetchedAt: fetchedAt,
            articles: articles
        )
    }

    private static func parse(json: JSONFeed, sourceURL: URL, fetchedAt: Date) -> ParsedFeed {
        let title = HTMLTextExtractor.singleLine(json.title)
            ?? sourceURL.host
            ?? "Untitled Feed"
        let websiteURL = URLNormalizer.resourceURL(from: json.homePageURL, relativeTo: sourceURL)
        let iconURL = URLNormalizer.resourceURL(
            from: json.icon ?? json.favicon,
            relativeTo: sourceURL
        )
        let articles = (json.items ?? []).compactMap { item -> ParsedArticle? in
            guard let link = URLNormalizer.articleLink(
                from: item.url ?? item.externalURL,
                relativeTo: sourceURL
            ) else {
                return nil
            }
            let rawContent = item.contentHtml ?? item.contentText ?? item.summary
            return ParsedArticle(
                title: HTMLTextExtractor.singleLine(item.title) ?? "Untitled Article",
                content: HTMLTextExtractor.body(rawContent),
                link: link,
                publishedAt: item.datePublished ?? item.dateModified
            )
        }

        return ParsedFeed(
            title: title,
            sourceURL: sourceURL,
            websiteURL: websiteURL,
            iconURL: iconURL,
            format: .json,
            fetchedAt: fetchedAt,
            articles: articles
        )
    }
}

enum HTMLTextExtractor {
    static func singleLine(_ source: String?) -> String? {
        guard let text = plainText(from: source) else { return nil }
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    static func body(_ source: String?) -> String? {
        guard let text = plainText(from: source) else { return nil }
        let lines = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { line in
                line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: "\n\n")
        return normalized.isEmpty ? nil : normalized
    }

    private static func plainText(from source: String?) -> String? {
        guard let source else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // NSAttributedString's HTML importer is comparatively expensive. Most
        // feeds, including large feeds whose summaries are wrapped only in
        // CDATA, have already been decoded to plain text by FeedKit. Avoid
        // spinning up the importer for every article in those feeds.
        guard containsHTML(in: trimmed) else {
            return trimmed
        }

        if let data = trimmed.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            return attributed.string
        }

        return trimmed
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func containsHTML(in source: String) -> Bool {
        var searchStart = source.startIndex
        while let opening = source[searchStart...].firstIndex(of: "<") {
            let marker = source.index(after: opening)
            guard marker < source.endIndex else { break }

            let character = source[marker]
            if (character.isLetter || character == "/" || character == "!" || character == "?"),
               source[marker...].contains(">") {
                return true
            }
            searchStart = marker
        }

        searchStart = source.startIndex
        while let ampersand = source[searchStart...].firstIndex(of: "&") {
            let entityStart = source.index(after: ampersand)
            let entityLimit = source.index(entityStart, offsetBy: 12, limitedBy: source.endIndex)
                ?? source.endIndex

            if let semicolon = source[entityStart ..< entityLimit].firstIndex(of: ";") {
                let entity = source[entityStart ..< semicolon]
                if isHTMLEntityName(entity) {
                    return true
                }
            }
            searchStart = entityStart
        }

        return false
    }

    private static func isHTMLEntityName(_ value: Substring) -> Bool {
        guard let first = value.first else { return false }
        if first == "#" {
            let number = value.dropFirst()
            guard !number.isEmpty else { return false }
            if number.first == "x" || number.first == "X" {
                let hexadecimal = number.dropFirst()
                return !hexadecimal.isEmpty && hexadecimal.allSatisfy(\.isHexDigit)
            }
            return number.allSatisfy(\.isNumber)
        }

        return first.isLetter && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
