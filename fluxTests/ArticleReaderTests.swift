import Foundation
import SwiftData
import WebKit
import XCTest
@testable import flux

@MainActor
final class ArticleReaderTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com/articles/night/")!

    func testArticleContentDecodesExtractionResult() throws {
        let data = Data(
            #"{"title":"A title","byline":"An author","siteName":"A site","excerpt":"An excerpt","publishedTime":"2026-08-15T10:00:00Z","contentHTML":"<p>Body</p>","textContent":"Body","length":4,"language":"en","direction":"ltr"}"#.utf8
        )

        let content = try JSONDecoder().decode(ArticleContent.self, from: data)

        XCTAssertEqual(content.title, "A title")
        XCTAssertEqual(content.byline, "An author")
        XCTAssertEqual(content.siteName, "A site")
        XCTAssertEqual(content.contentHTML, "<p>Body</p>")
        XCTAssertEqual(content.length, 4)
        XCTAssertEqual(content.language, "en")
        XCTAssertEqual(content.direction, "ltr")
    }

    func testNormalArticleExtractionUsesReadability() async throws {
        let content = try await extractFixture("NormalArticle")

        XCTAssertEqual(content.title, "How a Small Garden Changed a City Block")
        XCTAssertEqual(content.byline, "Open Graph Author")
        XCTAssertGreaterThan(content.length, 700)
        XCTAssertTrue(content.contentHTML.contains("<h2"))
        XCTAssertTrue(content.textContent.contains("ordinary cooperation"))
        XCTAssertFalse(content.contentHTML.contains("site-navigation"))
    }

    func testStructuredMetadataSupplementsReadabilityInPriorityOrder() async throws {
        let content = try await extractFixture("StructuredArticle")

        XCTAssertEqual(content.title, "Open Graph Title")
        XCTAssertEqual(content.byline, "Morgan Lee")
        XCTAssertEqual(content.siteName, "Open Graph Journal")
        XCTAssertEqual(content.publishedTime, "2025-01-02T03:04:05Z")
        XCTAssertEqual(content.language, "fr")
        XCTAssertNotEqual(content.byline, "Open Graph Author")
    }

    func testChromeRemovalPreservesArticleBody() async throws {
        let content = try await extractFixture("ChromeHeavyArticle")
        let html = content.contentHTML.lowercased()

        XCTAssertTrue(content.textContent.contains("one bend, one flood season"))
        XCTAssertFalse(html.contains("advertisement"))
        XCTAssertFalse(html.contains("cookie-banner"))
        XCTAssertFalse(html.contains("share-buttons"))
        XCTAssertFalse(html.contains("newsletter-signup"))
        XCTAssertFalse(html.contains("recommended stories"))
        XCTAssertFalse(html.contains("comments"))
        XCTAssertFalse(html.contains("<form"))
    }

    func testMediaMarkupAndAbsoluteURLsArePreserved() async throws {
        let content = try await extractFixture("MediaArticle")
        let html = content.contentHTML

        XCTAssertTrue(html.contains("<figure"))
        XCTAssertTrue(html.contains("<figcaption"))
        XCTAssertTrue(html.contains("<blockquote"))
        XCTAssertTrue(html.contains("<pre"))
        XCTAssertTrue(html.contains("<code"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("https://example.com/articles/images/night-harbor.jpg"))
        XCTAssertTrue(html.contains("loading=\"lazy\""))
        XCTAssertTrue(html.contains("referrerpolicy=\"no-referrer\""))
    }

    func testDelayedClientRenderedArticleIsExtracted() async throws {
        let content = try await extractFixture("DynamicArticle")

        XCTAssertEqual(content.title, "A Delayed Dispatch")
        XCTAssertTrue(content.textContent.contains("observed the changing DOM"))
        XCTAssertGreaterThan(content.length, 500)
    }

    func testUnreadableAndRestrictedPagesAreClassified() async throws {
        await assertExtractionError(.insufficientContent(15), fixture: "Unreadable")
        await assertExtractionError(.paywalled, fixture: "Paywalled")
        await assertExtractionError(.blocked, fixture: "Blocked")
    }

    func testInvalidURLsAndStableFailureClassification() async throws {
        let extractor = ArticleExtractor()

        do {
            _ = try await extractor.extract(from: URL(string: "ftp://example.com/article.html")!)
            XCTFail("Expected an unsupported scheme")
        } catch let error as ArticleExtractionError {
            XCTAssertEqual(error, .unsupportedScheme)
            XCTAssertEqual(error.persistenceCode, "unsupportedScheme")
            XCTAssertEqual(error.contentStatus, .failed)
        }

        let navigationError = ArticleExtractionError.navigationFailed(
            code: -1009,
            message: "Offline"
        )
        XCTAssertEqual(navigationError.persistenceCode, "navigationFailed")
        XCTAssertEqual(navigationError.contentStatus, .failed)
        XCTAssertEqual(
            ArticleExtractionError.javaScriptFailed("Bad result").persistenceCode,
            "javaScriptFailed"
        )
    }

    func testMaliciousHTMLIsSanitizedWithoutFlatteningSemantics() async throws {
        let content = try await extractFixture("MaliciousArticle")
        let html = content.contentHTML.lowercased()

        for forbidden in [
            "<script", "<style", "<form", "<input", "<button", "<iframe", "<embed",
            "<svg", "onclick", "onerror", "onmouseover", "javascript:", "data-track=",
            " style=", " class=", " id=", "srcdoc",
        ] {
            XCTAssertFalse(html.contains(forbidden), "Sanitized HTML retained \(forbidden)")
        }
        XCTAssertTrue(html.contains("<figure"))
        XCTAssertTrue(html.contains("<figcaption"))
        XCTAssertTrue(html.contains("<blockquote"))
        XCTAssertTrue(html.contains("href=\"https://example.com/safe-path\""))
        XCTAssertTrue(html.contains("src=\"https://example.com/images/secure-reader.jpg\""))
    }

    func testExtractionHonorsTotalTimeout() async throws {
        let configuration = ArticleExtractionConfiguration(
            totalTimeout: .milliseconds(1),
            readinessTimeout: .seconds(3),
            readinessPollInterval: .milliseconds(250),
            minimumBodyLength: 500,
            minimumArticleLength: 200
        )
        let extractor = ArticleExtractor(configuration: configuration)

        do {
            _ = try await extractor.extract(
                html: try fixtureHTML("DynamicArticle"),
                baseURL: baseURL
            )
            XCTFail("Expected the extraction to time out")
        } catch let error as ArticleExtractionError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testExtractionCancellationSurfacesCancellationError() async throws {
        let extractor = ArticleExtractor()
        let html = try fixtureHTML("Unreadable")
        let task = Task {
            try await extractor.extract(html: html, baseURL: baseURL)
        }

        try await Task.sleep(for: .milliseconds(40))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCacheMissExtractsAndPersistsAvailableContent() async throws {
        let (_, context) = try makeContainer()
        let expected = sampleContent(title: "Fetched")
        let probe = ScriptedArticleExtractor([.success(expected)])
        let store = ArticleContentStore(extractor: probe)

        let value = try await store.fetchAndCache(from: baseURL, modelContext: context)
        let lookup = try store.lookup(for: baseURL, modelContext: context)

        XCTAssertEqual(value, expected)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
        guard case .available(let cached) = lookup else {
            return XCTFail("Expected cached content")
        }
        XCTAssertEqual(cached.content, expected)
        XCTAssertFalse(cached.isStale)
    }

    func testFreshCacheHitAvoidsExtractorInvocation() async throws {
        let (_, context) = try makeContainer()
        try insertRecord(
            sampleContent(title: "Fresh"),
            status: .available,
            fetchedAt: Date(),
            into: context
        )
        let probe = ScriptedArticleExtractor([.failure(.blocked)])
        let store = ArticleContentStore(extractor: probe)
        let viewModel = ArticleReaderViewModel()

        await viewModel.load(url: baseURL, forceRefresh: false, store: store, modelContext: context)

        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 0)
        guard case .loaded(let content, let isRefreshing) = viewModel.state else {
            return XCTFail("Expected loaded state")
        }
        XCTAssertEqual(content.title, "Fresh")
        XCTAssertFalse(isRefreshing)
    }

    func testStaleCacheDisplaysImmediatelyThenRefreshes() async throws {
        let (_, context) = try makeContainer()
        let old = sampleContent(title: "Cached")
        let refreshed = sampleContent(title: "Refreshed")
        try insertRecord(
            old,
            status: .available,
            fetchedAt: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60),
            into: context
        )
        let probe = GatedArticleExtractor()
        let store = ArticleContentStore(extractor: probe)
        let viewModel = ArticleReaderViewModel()
        let loadTask = Task { @MainActor in
            await viewModel.load(
                url: baseURL,
                forceRefresh: false,
                store: store,
                modelContext: context
            )
        }

        await probe.waitUntilCalled()
        guard case .loaded(let visible, let isRefreshing) = viewModel.state else {
            loadTask.cancel()
            return XCTFail("Expected stale content to remain visible")
        }
        XCTAssertEqual(visible, old)
        XCTAssertTrue(isRefreshing)

        await probe.succeed(with: refreshed)
        await loadTask.value
        XCTAssertEqual(viewModel.state, .loaded(refreshed, isRefreshing: false))
    }

    func testStaleRefreshFailureRetainsCachedArticle() async throws {
        let (_, context) = try makeContainer()
        let old = sampleContent(title: "Keep me")
        try insertRecord(
            old,
            status: .available,
            fetchedAt: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60),
            into: context
        )
        let store = ArticleContentStore(
            extractor: ScriptedArticleExtractor([.failure(.blocked)])
        )
        let viewModel = ArticleReaderViewModel()

        await viewModel.load(url: baseURL, forceRefresh: false, store: store, modelContext: context)

        XCTAssertEqual(viewModel.state, .loaded(old, isRefreshing: false))
        guard case .available(let cached) = try store.lookup(for: baseURL, modelContext: context) else {
            return XCTFail("Expected cached content after failed refresh")
        }
        XCTAssertEqual(cached.content, old)
    }

    func testPersistedFailureRequiresExplicitRetry() async throws {
        let (_, context) = try makeContainer()
        let failed = ArticleContentRecord(
            url: URLNormalizer.canonicalString(baseURL)!,
            status: .paywalled,
            lastAttemptedAt: Date(),
            failureCode: "paywalled",
            failureMessage: "Subscription required"
        )
        context.insert(failed)
        try context.save()
        let recovered = sampleContent(title: "Recovered")
        let probe = ScriptedArticleExtractor([.success(recovered)])
        let store = ArticleContentStore(extractor: probe)
        let viewModel = ArticleReaderViewModel()

        await viewModel.load(url: baseURL, forceRefresh: false, store: store, modelContext: context)
        XCTAssertEqual(
            viewModel.state,
            .unavailable(ArticleReaderFailure(status: .paywalled, message: "Subscription required"))
        )
        let initialCallCount = await probe.callCount()
        XCTAssertEqual(initialCallCount, 0)

        await viewModel.load(url: baseURL, forceRefresh: true, store: store, modelContext: context)
        XCTAssertEqual(viewModel.state, .loaded(recovered, isRefreshing: false))
        let retryCallCount = await probe.callCount()
        XCTAssertEqual(retryCallCount, 1)
    }

    func testCorruptAndInterruptedRecordsRecoverAsCacheMisses() throws {
        let (_, context) = try makeContainer()
        let corrupt = ArticleContentRecord(
            url: URLNormalizer.canonicalString(baseURL)!,
            status: .available,
            contentData: Data("not-json".utf8),
            fetchedAt: Date()
        )
        context.insert(corrupt)
        try context.save()
        let store = ArticleContentStore(extractor: ScriptedArticleExtractor([]))

        XCTAssertEqual(try store.lookup(for: baseURL, modelContext: context), .missing)
        XCTAssertEqual(corrupt.status, .notFetched)
        XCTAssertNil(corrupt.contentData)

        corrupt.status = .fetching
        try context.save()
        XCTAssertEqual(try store.lookup(for: baseURL, modelContext: context), .missing)
        XCTAssertEqual(corrupt.status, .notFetched)
    }

    func testCancelledFetchRestoresNotFetchedState() async throws {
        let (_, context) = try makeContainer()
        let store = ArticleContentStore(extractor: SuspendingArticleExtractor())
        let task = Task { @MainActor in
            try await store.fetchAndCache(from: baseURL, modelContext: context)
        }

        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try store.lookup(for: baseURL, modelContext: context), .missing)
        let records = try context.fetch(FetchDescriptor<ArticleContentRecord>())
        XCTAssertEqual(records.first?.status, .notFetched)
        XCTAssertNil(records.first?.failureMessage)
    }

    func testReaderDocumentEscapesMetadataAndInstallsSecurityPolicy() {
        let content = sampleContent(
            title: #"<img src=x onerror=alert(1)> & \"Headline\""#,
            html: "<p>Trusted sanitized body.</p>"
        )
        let document = ArticleReaderDocument(
            content: content,
            fallbackTitle: "Fallback",
            fallbackSiteName: "Site <script>",
            fallbackPublishedAt: Date(timeIntervalSince1970: 0),
            textScale: 1.4
        )

        XCTAssertTrue(document.html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertFalse(document.html.contains("<h1 class=\"reader-title\"><img"))
        XCTAssertTrue(document.html.contains("Content-Security-Policy"))
        XCTAssertTrue(document.html.contains("default-src 'none'"))
        XCTAssertTrue(document.html.contains("form-action 'none'"))
        XCTAssertTrue(document.html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        XCTAssertTrue(document.html.contains("--font-size: 25.20px"))
    }

    func testReaderTextScaleClampsAndPreferenceCanPersist() throws {
        XCTAssertEqual(ReaderTextScale.clamped(0.1), 0.85)
        XCTAssertEqual(ReaderTextScale.clamped(2), 1.4)
        XCTAssertEqual(ReaderTextScale.smaller(than: 0.85), 0.85)
        XCTAssertEqual(ReaderTextScale.larger(than: 1.4), 1.4)

        let suite = try XCTUnwrap(UserDefaults(suiteName: "ArticleReaderTests"))
        suite.removePersistentDomain(forName: "ArticleReaderTests")
        suite.set(1.3, forKey: AppPreferenceKey.readerTextScale)
        XCTAssertEqual(suite.double(forKey: AppPreferenceKey.readerTextScale), 1.3)
        suite.removePersistentDomain(forName: "ArticleReaderTests")
    }

    func testReaderNavigationAllowsOnlyDocumentAndActivatedExternalLinks() throws {
        XCTAssertEqual(
            ReaderNavigationPolicy.destination(
                for: URL(string: "about:blank#section"),
                navigationType: .linkActivated
            ),
            .document
        )
        for scheme in ["https://example.com", "http://example.com", "mailto:a@example.com", "tel:+1"] {
            XCTAssertEqual(
                ReaderNavigationPolicy.destination(
                    for: URL(string: scheme),
                    navigationType: .linkActivated
                ),
                .external
            )
        }
        XCTAssertEqual(
            ReaderNavigationPolicy.destination(
                for: URL(string: "https://example.com"),
                navigationType: .other
            ),
            .unsupported
        )
        XCTAssertEqual(
            ReaderNavigationPolicy.destination(
                for: URL(string: "file:///tmp/article"),
                navigationType: .linkActivated
            ),
            .unsupported
        )
    }

    private func extractFixture(_ name: String) async throws -> ArticleContent {
        try await ArticleExtractor().extract(html: fixtureHTML(name), baseURL: baseURL)
    }

    private func assertExtractionError(
        _ expected: ArticleExtractionError,
        fixture name: String
    ) async {
        do {
            _ = try await extractFixture(name)
            XCTFail("Expected \(expected) for \(name)")
        } catch let error as ArticleExtractionError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected ArticleExtractionError, got \(error)")
        }
    }

    private func fixtureHTML(_ name: String) throws -> String {
        let bundle = Bundle(for: ArticleReaderTests.self)
        let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/Articles")
            ?? bundle.url(forResource: name, withExtension: "html", subdirectory: "Articles")
            ?? bundle.url(forResource: name, withExtension: "html")
        return try String(
            contentsOf: XCTUnwrap(url, "Missing fixture \(name).html"),
            encoding: .utf8
        )
    }

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            Feed.self,
            FeedCategory.self,
            Article.self,
            ArticleContentRecord.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, ModelContext(container))
    }

    private func insertRecord(
        _ content: ArticleContent,
        status: ContentStatus,
        fetchedAt: Date,
        into context: ModelContext
    ) throws {
        let record = ArticleContentRecord(
            url: URLNormalizer.canonicalString(baseURL)!,
            status: status,
            contentData: try JSONEncoder().encode(content),
            fetchedAt: fetchedAt
        )
        context.insert(record)
        try context.save()
    }

    private func sampleContent(
        title: String,
        html: String = "<p>Sample article body.</p>"
    ) -> ArticleContent {
        ArticleContent(
            title: title,
            byline: "Taylor Example",
            siteName: "Fixture Daily",
            excerpt: "A fixture article",
            publishedTime: "2026-08-15T10:00:00Z",
            contentHTML: html,
            textContent: "Sample article body.",
            length: 20,
            language: "en",
            direction: "ltr"
        )
    }
}

private enum ScriptedOutcome: Sendable {
    case success(ArticleContent)
    case failure(ArticleExtractionError)
}

private actor ScriptedArticleExtractor: ArticleExtracting {
    private var outcomes: [ScriptedOutcome]
    private var calls = 0

    init(_ outcomes: [ScriptedOutcome]) {
        self.outcomes = outcomes
    }

    func extract(from url: URL) async throws -> ArticleContent {
        calls += 1
        guard !outcomes.isEmpty else {
            throw ArticleExtractionError.readabilityReturnedNil
        }
        switch outcomes.removeFirst() {
        case .success(let content):
            return content
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor GatedArticleExtractor: ArticleExtracting {
    private var wasCalled = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var extractionContinuation: CheckedContinuation<ArticleContent, any Error>?

    func extract(from url: URL) async throws -> ArticleContent {
        wasCalled = true
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            extractionContinuation = continuation
        }
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func succeed(with content: ArticleContent) {
        extractionContinuation?.resume(returning: content)
        extractionContinuation = nil
    }
}

private struct SuspendingArticleExtractor: ArticleExtracting {
    func extract(from url: URL) async throws -> ArticleContent {
        try await Task.sleep(for: .seconds(30))
        throw ArticleExtractionError.timedOut
    }
}
