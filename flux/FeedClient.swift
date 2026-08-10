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
    let iconURL: URL?
    let format: Format
    let fetchedAt: Date
    let articles: [ParsedArticle]

    init(
        title: String,
        sourceURL: URL,
        iconURL: URL? = nil,
        format: Format,
        fetchedAt: Date,
        articles: [ParsedArticle]
    ) {
        self.title = title
        self.sourceURL = sourceURL
        self.iconURL = iconURL
        self.format = format
        self.fetchedAt = fetchedAt
        self.articles = articles
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

        return try await Task.detached(priority: .userInitiated) {
            try FeedDocumentParser.parse(data: data, sourceURL: finalURL, fetchedAt: fetchedAt)
        }.value
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
        let iconURL = URLNormalizer.resourceURL(
            from: channel?.image?.url,
            relativeTo: sourceURL
        ) ?? URLNormalizer.faviconURL(from: channel?.link, relativeTo: sourceURL)
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
        let iconURL = URLNormalizer.resourceURL(
            from: atom.icon ?? atom.logo,
            relativeTo: sourceURL
        ) ?? URLNormalizer.faviconURL(from: website, relativeTo: sourceURL)
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
        let iconURL = URLNormalizer.resourceURL(
            from: json.icon ?? json.favicon,
            relativeTo: sourceURL
        ) ?? URLNormalizer.faviconURL(from: json.homePageURL, relativeTo: sourceURL)
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
}
