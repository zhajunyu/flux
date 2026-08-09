//
//  FluxTests.swift
//  fluxTests
//
//  Created by Junyu Zha on 2026/8/9.
//

import Foundation
import SwiftData
import XCTest
@testable import flux

@MainActor
final class FluxTests: XCTestCase {
    func testRSSAutoDetectionAndSanitization() throws {
        let parsed = try FeedDocumentParser.parse(
            data: fixtureData(named: "SampleRSS", extension: "xml"),
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/feed.xml")),
            fetchedAt: Date(timeIntervalSince1970: 1_786_276_800)
        )

        XCTAssertEqual(parsed.format, .rss)
        XCTAssertEqual(parsed.title, "Tech & Design")
        XCTAssertEqual(parsed.articles.count, 1)
        XCTAssertEqual(parsed.articles[0].title, "First & Best")
        XCTAssertEqual(parsed.articles[0].link, "https://example.com/story-one")
        XCTAssertTrue(parsed.articles[0].content?.contains("Hello world & friends.") == true)
        XCTAssertFalse(parsed.articles[0].content?.contains("<strong>") == true)
        XCTAssertNotNil(parsed.articles[0].publishedAt)
    }

    func testAtomAutoDetectionAndRelativeLinkResolution() throws {
        let parsed = try FeedDocumentParser.parse(
            data: fixtureData(named: "SampleAtom", extension: "xml"),
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/feeds/atom.xml"))
        )

        XCTAssertEqual(parsed.format, .atom)
        XCTAssertEqual(parsed.title, "Atom Notes")
        XCTAssertEqual(parsed.articles.count, 1)
        XCTAssertEqual(parsed.articles[0].link, "https://example.com/atom-entry")
        XCTAssertEqual(parsed.articles[0].content, "Adaptive interfaces.")
    }

    func testJSONFeedAutoDetectionAndHTMLCleanup() throws {
        let parsed = try FeedDocumentParser.parse(
            data: fixtureData(named: "SampleJSON", extension: "json"),
            sourceURL: try XCTUnwrap(URL(string: "https://example.com/feed.json"))
        )

        XCTAssertEqual(parsed.format, .json)
        XCTAssertEqual(parsed.title, "JSON Journal")
        XCTAssertEqual(parsed.articles.count, 1)
        XCTAssertEqual(parsed.articles[0].title, "JSON & HTML")
        XCTAssertEqual(parsed.articles[0].content, "Readable JSON Feed content.")
        XCTAssertNotNil(parsed.articles[0].publishedAt)
    }

    func testURLNormalizationAndValidation() throws {
        XCTAssertEqual(
            try URLNormalizer.feedURL(from: "Example.COM/feed#section").absoluteString,
            "https://example.com/feed"
        )
        XCTAssertEqual(
            try URLNormalizer.feedURL(from: "https://example.com:443").absoluteString,
            "https://example.com/"
        )
        XCTAssertThrowsError(try URLNormalizer.feedURL(from: "ftp://example.com/feed"))
        XCTAssertThrowsError(try URLNormalizer.feedURL(from: "   "))
    }

    func testSubscribeMergePreservesReadStateAndCascadeDelete() async throws {
        let (container, context) = try makeContainer()
        _ = container
        let feedURL = try XCTUnwrap(URL(string: "https://example.com/feed"))
        let firstFetch = Date(timeIntervalSince1970: 1_786_276_800)
        let initial = ParsedFeed(
            title: "Example Feed",
            sourceURL: feedURL,
            format: .rss,
            fetchedAt: firstFetch,
            articles: [
                ParsedArticle(
                    title: "Original title",
                    content: "Original body",
                    link: "https://example.com/article",
                    publishedAt: Date(timeIntervalSince1970: 100)
                ),
                ParsedArticle(
                    title: "Duplicate",
                    content: nil,
                    link: "https://example.com/article",
                    publishedAt: nil
                ),
            ]
        )

        let initialStore = FeedStore(client: .preview)
        try initialStore.subscribe(to: initial, modelContext: context)

        let originalArticle = try XCTUnwrap(context.fetch(FetchDescriptor<Article>()).first)
        originalArticle.isRead = true
        try context.save()

        let secondFetch = firstFetch.addingTimeInterval(600)
        let updated = ParsedFeed(
            title: "Renamed Feed",
            sourceURL: feedURL,
            format: .rss,
            fetchedAt: secondFetch,
            articles: [
                ParsedArticle(
                    title: "Updated title",
                    content: "Updated body",
                    link: "https://example.com/article",
                    publishedAt: Date(timeIntervalSince1970: 200)
                ),
                ParsedArticle(
                    title: "New article",
                    content: nil,
                    link: "https://example.com/new",
                    publishedAt: nil
                ),
            ]
        )
        let refreshStore = FeedStore(client: FeedClient { _ in updated })
        await refreshStore.refreshAll(modelContext: context)

        let feeds = try context.fetch(FetchDescriptor<Feed>())
        let articles = try context.fetch(
            FetchDescriptor<Article>(sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)])
        )
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds[0].title, "Renamed Feed")
        XCTAssertEqual(feeds[0].lastFetched, secondFetch)
        XCTAssertEqual(articles.count, 2)

        let mergedArticle = try XCTUnwrap(articles.first { $0.link == "https://example.com/article" })
        XCTAssertEqual(mergedArticle.title, "Updated title")
        XCTAssertEqual(mergedArticle.content, "Updated body")
        XCTAssertTrue(mergedArticle.isRead)

        let newArticle = try XCTUnwrap(articles.first { $0.link == "https://example.com/new" })
        XCTAssertEqual(newArticle.publishedAt, secondFetch)
        XCTAssertFalse(newArticle.isRead)

        refreshStore.toggleRead(newArticle, modelContext: context)
        XCTAssertTrue(newArticle.isRead)

        refreshStore.delete(feeds[0], modelContext: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Feed>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Article>()).isEmpty)
    }

    func testDuplicateSubscriptionIsRejectedBeforeFetching() async throws {
        let (container, context) = try makeContainer()
        _ = container
        let url = try XCTUnwrap(URL(string: "https://example.com/feed"))
        let parsed = ParsedFeed(
            title: "Example",
            sourceURL: url,
            format: .rss,
            fetchedAt: Date(),
            articles: []
        )
        let store = FeedStore(client: FeedClient { _ in
            XCTFail("The duplicate should be detected before a network fetch")
            return parsed
        })
        try store.subscribe(to: parsed, modelContext: context)

        do {
            _ = try await store.previewFeed(from: "example.com/feed", modelContext: context)
            XCTFail("Expected duplicate-feed validation to fail")
        } catch FeedClientError.duplicateFeed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPartialRefreshKeepsCachedArticlesAndReportsFailure() async throws {
        let (container, context) = try makeContainer()
        _ = container
        let successfulFeed = Feed(title: "Available", url: "https://available.example/feed")
        let offlineFeed = Feed(title: "Offline", url: "https://offline.example/feed")
        let cached = Article(
            title: "Cached article",
            content: "Available offline",
            link: "https://offline.example/cached",
            publishedAt: Date(timeIntervalSince1970: 50)
        )
        offlineFeed.articles.append(cached)
        context.insert(successfulFeed)
        context.insert(offlineFeed)
        context.insert(cached)
        try context.save()

        let store = FeedStore(client: FeedClient { url in
            if url.host == "offline.example" {
                throw TestError.offline
            }
            return ParsedFeed(
                title: "Available",
                sourceURL: url,
                format: .json,
                fetchedAt: Date(timeIntervalSince1970: 500),
                articles: [
                    ParsedArticle(
                        title: "Fresh article",
                        content: nil,
                        link: "https://available.example/fresh",
                        publishedAt: nil
                    ),
                ]
            )
        })

        await store.refreshAll(modelContext: context)

        let articles = try context.fetch(FetchDescriptor<Article>())
        XCTAssertTrue(articles.contains { $0.title == "Cached article" })
        XCTAssertTrue(articles.contains { $0.title == "Fresh article" })
        XCTAssertEqual(store.notice?.title, "One Feed Couldn’t Refresh")
        XCTAssertTrue(store.notice?.message.contains("Cached articles remain available") == true)
    }

    func testRefreshesRunInParallelAndOverlappingRefreshIsCoalesced() async throws {
        let (container, context) = try makeContainer()
        _ = container
        for index in 0 ..< 3 {
            context.insert(Feed(title: "Feed \(index)", url: "https://feed\(index).example/rss"))
        }
        try context.save()

        let probe = ConcurrencyProbe()
        let store = FeedStore(client: FeedClient { url in
            await probe.enter()
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                await probe.leave()
                throw error
            }
            await probe.leave()
            return ParsedFeed(
                title: url.host ?? "Feed",
                sourceURL: url,
                format: .rss,
                fetchedAt: Date(),
                articles: []
            )
        })

        let firstRefresh = Task { @MainActor in
            await store.refreshAll(modelContext: context)
        }
        while !store.isRefreshing {
            await Task.yield()
        }
        await store.refreshAll(modelContext: context)
        await firstRefresh.value

        let snapshot = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.peak, 2)
        XCTAssertEqual(snapshot.calls, 3)
    }

    private func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
        let bundle = Bundle(for: FluxTests.self)
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        return try Data(contentsOf: XCTUnwrap(url, "Missing fixture \(name).\(fileExtension)"))
    }

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Feed.self, Article.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, ModelContext(container))
    }
}

private enum TestError: LocalizedError {
    case offline

    var errorDescription: String? { "The network is offline." }
}

private actor ConcurrencyProbe {
    private var active = 0
    private var peak = 0
    private var calls = 0

    func enter() {
        active += 1
        calls += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (peak: Int, calls: Int) {
        (peak, calls)
    }
}
