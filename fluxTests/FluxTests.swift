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
        XCTAssertEqual(parsed.iconURL?.absoluteString, "https://example.com/images/rss-icon.png")
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
        XCTAssertEqual(parsed.iconURL?.absoluteString, "https://example.com/images/atom-icon.png")
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
        XCTAssertEqual(parsed.iconURL?.absoluteString, "https://example.com/images/json-icon.png")
        XCTAssertEqual(parsed.articles.count, 1)
        XCTAssertEqual(parsed.articles[0].title, "JSON & HTML")
        XCTAssertEqual(parsed.articles[0].content, "Readable JSON Feed content.")
        XCTAssertNotNil(parsed.articles[0].publishedAt)
    }

    func testPlainTextExtractionPreservesLiteralSymbols() {
        XCTAssertEqual(
            HTMLTextExtractor.singleLine("  Research < development & safety  "),
            "Research < development & safety"
        )
        XCTAssertEqual(
            HTMLTextExtractor.body("First paragraph\n\nR&D > guesswork"),
            "First paragraph\n\nR&D > guesswork"
        )
        XCTAssertEqual(
            HTMLTextExtractor.body("<p>Hello <strong>world</strong> &amp; friends.</p>"),
            "Hello world & friends."
        )
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
            iconURL: try XCTUnwrap(URL(string: "https://example.com/icon-v1.png")),
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
            iconURL: try XCTUnwrap(URL(string: "https://example.com/icon-v2.png")),
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
        XCTAssertEqual(feeds[0].iconURL, "https://example.com/icon-v2.png")
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

    func testMarkMultipleArticlesAsRead() throws {
        let (container, context) = try makeContainer()
        _ = container
        let unreadArticle = Article(
            title: "Unread",
            link: "https://example.com/unread",
            publishedAt: Date(timeIntervalSince1970: 100)
        )
        let readArticle = Article(
            title: "Already read",
            link: "https://example.com/read",
            publishedAt: Date(timeIntervalSince1970: 200),
            isRead: true
        )
        let unselectedArticle = Article(
            title: "Not selected",
            link: "https://example.com/unselected",
            publishedAt: Date(timeIntervalSince1970: 300)
        )
        context.insert(unreadArticle)
        context.insert(readArticle)
        context.insert(unselectedArticle)
        try context.save()

        let store = FeedStore(client: .preview)
        XCTAssertTrue(store.markRead([unreadArticle, readArticle], modelContext: context))

        XCTAssertTrue(unreadArticle.isRead)
        XCTAssertTrue(readArticle.isRead)
        XCTAssertFalse(unselectedArticle.isRead)
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

    func testCreateAssignAndDeleteCategoryKeepsFeed() throws {
        let (container, context) = try makeContainer()
        _ = container
        let feed = Feed(title: "Design Notes", url: "https://example.com/design.xml")
        context.insert(feed)
        try context.save()

        let store = FeedStore(client: .preview)
        let category = try store.createCategory(named: "  Design  ", modelContext: context)

        XCTAssertEqual(category.name, "Design")
        XCTAssertTrue(store.assign(feed, to: category, modelContext: context))
        XCTAssertEqual(feed.category?.id, category.id)
        XCTAssertEqual(category.feeds.map(\.id), [feed.id])

        XCTAssertTrue(store.delete(category, modelContext: context))
        XCTAssertNil(feed.category)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Feed>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FeedCategory>()).isEmpty)
    }

    func testCategoryNamesMustBeNonemptyAndUniqueIgnoringCase() throws {
        let (container, context) = try makeContainer()
        _ = container
        let store = FeedStore(client: .preview)

        XCTAssertThrowsError(try store.createCategory(named: "   ", modelContext: context)) { error in
            XCTAssertEqual(error as? FeedCategoryError, .emptyName)
        }

        _ = try store.createCategory(named: "Technology", modelContext: context)
        XCTAssertThrowsError(try store.createCategory(named: "technology", modelContext: context)) { error in
            XCTAssertEqual(error as? FeedCategoryError, .duplicateName)
        }
    }

    func testOPMLParsingFlattensFoldersAndSkipsUnsupportedEntries() throws {
        let data = Data(
            #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="1.1">
              <head><title>Subscriptions</title></head>
              <body>
                <outline text="Technology">
                  <outline text="Apple &amp; Swift">
                    <outline text="Fallback title" title="  Swift   News  " type="rss" xmlUrl="HTTPS://Example.COM:443/feed#fragment"/>
                  </outline>
                </outline>
                <outline text="Uncategorized" xmlUrl="https://example.org/rss"/>
                <outline text="Broken" type="rss" xmlUrl="ftp://example.net/feed"/>
                <outline text="Missing URL" type="rss"/>
                <outline text="Comment" isComment="true">
                  <outline text="Ignored" type="rss" xmlUrl="https://ignored.example/feed"/>
                </outline>
                <outline text="Remote" type="include" url="https://example.com/list.opml">
                  <outline text="Also ignored" type="rss" xmlUrl="https://ignored.example/child"/>
                </outline>
              </body>
            </opml>
            """#.utf8
        )

        let result = try OPMLCodec.parse(data: data)

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.invalidEntryCount, 2)
        XCTAssertEqual(result.entries[0].title, "Swift News")
        XCTAssertEqual(result.entries[0].url.absoluteString, "https://example.com/feed")
        XCTAssertEqual(result.entries[0].categoryName, "Technology / Apple & Swift")
        XCTAssertEqual(result.entries[1].categoryName, nil)
    }

    func testMalformedAndEmptyOPMLAreRejected() {
        XCTAssertThrowsError(try OPMLCodec.parse(data: Data())) { error in
            XCTAssertEqual(error as? OPMLError, .emptyDocument)
        }
        XCTAssertThrowsError(try OPMLCodec.parse(data: Data("<opml><body>".utf8))) { error in
            XCTAssertEqual(error as? OPMLError, .invalidDocument)
        }
        XCTAssertThrowsError(try OPMLCodec.parse(data: Data("<rss/>".utf8))) { error in
            XCTAssertEqual(error as? OPMLError, .invalidDocument)
        }
    }

    func testOPMLImportPreservesExistingFeedsAndImportsValidEntries() throws {
        let (container, context) = try makeContainer()
        _ = container
        let originalCategory = FeedCategory(name: "Original")
        let existingFeed = Feed(
            title: "Keep This Title",
            url: "https://example.com/existing",
            category: originalCategory
        )
        let cachedArticle = Article(
            title: "Cached",
            link: "https://example.com/article",
            publishedAt: Date(timeIntervalSince1970: 100)
        )
        existingFeed.articles.append(cachedArticle)
        context.insert(originalCategory)
        context.insert(existingFeed)
        context.insert(cachedArticle)
        try context.save()

        let data = Data(
            #"""
            <opml version="2.0"><head><title>Test</title></head><body>
              <outline text="New"><outline text="Inner">
                <outline text="Imported title" type="rss" xmlUrl="https://example.com/existing"/>
                <outline text="New feed" type="rss" xmlUrl="https://example.com/new"/>
                <outline text="Duplicate new feed" type="rss" xmlUrl="https://example.com/new"/>
                <outline text="Invalid" type="rss" xmlUrl="file:///tmp/feed"/>
              </outline></outline>
            </body></opml>
            """#.utf8
        )
        let store = FeedStore(client: .preview)
        let prepared = try store.prepareOPMLImport(data: data, modelContext: context)

        XCTAssertEqual(prepared.entries.count, 2)
        XCTAssertEqual(prepared.existingDuplicateCount, 1)
        XCTAssertEqual(prepared.duplicateEntryCount, 1)
        XCTAssertEqual(prepared.invalidEntryCount, 1)

        let result = try store.importOPML(
            prepared,
            duplicatePolicy: .preserveExistingCategories,
            modelContext: context
        )

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(result.reassignedCount, 0)
        XCTAssertEqual(result.invalidEntryCount, 1)
        XCTAssertEqual(existingFeed.title, "Keep This Title")
        XCTAssertEqual(existingFeed.category?.name, "Original")
        XCTAssertEqual(existingFeed.articles.map(\.title), ["Cached"])

        let importedFeed = try XCTUnwrap(
            context.fetch(FetchDescriptor<Feed>()).first { $0.url == "https://example.com/new" }
        )
        XCTAssertEqual(importedFeed.title, "New feed")
        XCTAssertEqual(importedFeed.category?.name, "New / Inner")
    }

    func testOPMLImportCanApplyCategoriesToExistingFeeds() throws {
        let (container, context) = try makeContainer()
        _ = container
        let originalCategory = FeedCategory(name: "Original")
        let existingTargetCategory = FeedCategory(name: "technology")
        let categorizedFeed = Feed(
            title: "Categorized",
            url: "https://example.com/categorized",
            category: originalCategory
        )
        let feedMovingToUncategorized = Feed(
            title: "Top Level",
            url: "https://example.com/top",
            category: originalCategory
        )
        context.insert(originalCategory)
        context.insert(existingTargetCategory)
        context.insert(categorizedFeed)
        context.insert(feedMovingToUncategorized)
        try context.save()

        let data = Data(
            #"""
            <opml version="2.0"><head><title>Test</title></head><body>
              <outline text="Technology">
                <outline text="Imported title" type="rss" xmlUrl="https://example.com/categorized"/>
              </outline>
              <outline text="Top title" type="rss" xmlUrl="https://example.com/top"/>
            </body></opml>
            """#.utf8
        )
        let store = FeedStore(client: .preview)
        let prepared = try store.prepareOPMLImport(data: data, modelContext: context)
        let result = try store.importOPML(
            prepared,
            duplicatePolicy: .applyImportedCategories,
            modelContext: context
        )

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(result.reassignedCount, 2)
        XCTAssertEqual(categorizedFeed.category?.id, existingTargetCategory.id)
        XCTAssertNil(feedMovingToUncategorized.category)
        XCTAssertEqual(categorizedFeed.title, "Categorized")
        XCTAssertEqual(feedMovingToUncategorized.title, "Top Level")
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedCategory>()).count, 2)
    }

    func testOPMLExportIsStableEscapedAndRoundTrips() throws {
        let exported = OPMLCodec.encode(entries: [
            OPMLExportEntry(
                title: "Swift & Design",
                url: "https://example.com/feed?a=1&b=2",
                categoryName: "Technology / Apple"
            ),
            OPMLExportEntry(
                title: "Uncategorized <News>",
                url: "https://example.org/rss",
                categoryName: nil
            ),
            OPMLExportEntry(
                title: "Alpha",
                url: "https://alpha.example/feed",
                categoryName: "Design"
            ),
        ])
        let xml = try XCTUnwrap(String(data: exported, encoding: .utf8))

        XCTAssertTrue(xml.contains("Swift &amp; Design"))
        XCTAssertTrue(xml.contains("Uncategorized &lt;News&gt;"))
        XCTAssertTrue(xml.contains("a=1&amp;b=2"))
        XCTAssertLessThan(
            try XCTUnwrap(xml.range(of: #"<outline text="Design""#)?.lowerBound),
            try XCTUnwrap(xml.range(of: #"<outline text="Technology / Apple""#)?.lowerBound)
        )

        let parsed = try OPMLCodec.parse(data: exported)
        XCTAssertEqual(parsed.invalidEntryCount, 0)
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertEqual(
            parsed.entries.first { $0.title == "Swift & Design" }?.categoryName,
            "Technology / Apple"
        )
        XCTAssertEqual(
            parsed.entries.first { $0.title == "Uncategorized <News>" }?.categoryName,
            nil
        )
    }

    func testImportedFeedRefreshQueuesBehindActiveRefresh() async throws {
        let (container, context) = try makeContainer()
        _ = container
        let existingFeed = Feed(title: "Existing", url: "https://existing.example/feed")
        context.insert(existingFeed)
        try context.save()

        let probe = URLCallProbe()
        let store = FeedStore(client: FeedClient { url in
            await probe.record(url)
            if url.host == "existing.example" {
                try await Task.sleep(for: .milliseconds(120))
            }
            return ParsedFeed(
                title: url.host ?? "Feed",
                sourceURL: url,
                format: .rss,
                fetchedAt: Date(),
                articles: []
            )
        })

        let activeRefresh = Task { @MainActor in
            await store.refreshAll(modelContext: context)
        }
        while !store.isRefreshing {
            await Task.yield()
        }

        let importedFeed = Feed(title: "Imported", url: "https://imported.example/feed")
        context.insert(importedFeed)
        try context.save()
        await store.refreshImportedFeeds(withIDs: [importedFeed.id], modelContext: context)
        await activeRefresh.value

        let calls = await probe.urls()
        XCTAssertEqual(calls.filter { $0.host == "existing.example" }.count, 1)
        XCTAssertEqual(calls.filter { $0.host == "imported.example" }.count, 1)
        XCTAssertNotNil(importedFeed.lastFetched)
    }

    private func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
        let bundle = Bundle(for: FluxTests.self)
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        return try Data(contentsOf: XCTUnwrap(url, "Missing fixture \(name).\(fileExtension)"))
    }

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Feed.self, FeedCategory.self, Article.self])
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

private actor URLCallProbe {
    private var recordedURLs: [URL] = []

    func record(_ url: URL) {
        recordedURLs.append(url)
    }

    func urls() -> [URL] {
        recordedURLs
    }
}
