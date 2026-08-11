//
//  FeedStore.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import Foundation
import Observation
import SwiftData

struct UserNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum FeedCategoryError: LocalizedError, Equatable {
    case emptyName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name for the category."
        case .duplicateName:
            "A category with this name already exists."
        }
    }
}

enum OPMLDuplicatePolicy: Sendable, Equatable {
    case preserveExistingCategories
    case applyImportedCategories
}

struct PreparedOPMLImport: Sendable, Equatable {
    let entries: [OPMLEntry]
    let invalidEntryCount: Int
    let duplicateEntryCount: Int
    let existingDuplicateCount: Int
}

struct OPMLImportResult: Sendable, Equatable {
    let addedCount: Int
    let duplicateCount: Int
    let reassignedCount: Int
    let invalidEntryCount: Int
    let addedFeedIDs: Set<UUID>

    var summary: String {
        var parts = ["\(addedCount) added", "\(duplicateCount) duplicate"]
        if duplicateCount != 1 {
            parts[1] += "s"
        }
        if reassignedCount > 0 {
            parts.append("\(reassignedCount) reassigned")
        }
        if invalidEntryCount > 0 {
            parts.append("\(invalidEntryCount) invalid")
        }
        return parts.joined(separator: ", ") + "."
    }
}

@MainActor
@Observable
final class FeedStore {
    private(set) var isRefreshing = false
    var notice: UserNotice?

    private let client: FeedClient
    private var didAutoRefresh = false
    private var pendingTargetedRefreshIDs = Set<UUID>()

    init(client: FeedClient = .live) {
        self.client = client
    }

    func refreshOnceAfterLaunch(modelContext: ModelContext) async {
        guard !didAutoRefresh else { return }
        didAutoRefresh = true
        await refreshAll(modelContext: modelContext, reportErrors: false)
    }

    func refreshAll(modelContext: ModelContext, reportErrors: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let failures = await refreshBatch(feedIDs: nil, modelContext: modelContext)
        if reportErrors {
            reportRefreshFailures(failures)
        }

        await drainTargetedRefreshes(modelContext: modelContext)
    }

    func refreshImportedFeeds(withIDs feedIDs: Set<UUID>, modelContext: ModelContext) async {
        guard !feedIDs.isEmpty else { return }
        pendingTargetedRefreshIDs.formUnion(feedIDs)
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        await drainTargetedRefreshes(modelContext: modelContext)
    }

    private func refreshBatch(feedIDs: Set<UUID>?, modelContext: ModelContext) async -> [String] {
        let subscribedFeeds: [Feed]
        do {
            let allFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
            if let feedIDs {
                subscribedFeeds = allFeeds.filter { feedIDs.contains($0.id) }
            } else {
                subscribedFeeds = allFeeds
            }
        } catch {
            return ["Local database: The subscriptions could not be loaded from this device."]
        }

        guard !subscribedFeeds.isEmpty else { return [] }

        let targets = subscribedFeeds.compactMap { feed -> RefreshTarget? in
            guard let url = URL(string: feed.url) else { return nil }
            return RefreshTarget(id: feed.id, title: feed.title, url: url)
        }
        let invalidTargetNames = subscribedFeeds
            .filter { URL(string: $0.url) == nil }
            .map(\.title)
        let client = client

        let outcomes = await withTaskGroup(of: RefreshOutcome.self, returning: [RefreshOutcome].self) { group in
            for target in targets {
                group.addTask {
                    do {
                        return .success(target.id, try await client.fetch(target.url))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failure(target.title, error.localizedDescription)
                    }
                }
            }

            var outcomes: [RefreshOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        if Task.isCancelled { return [] }

        var failures = invalidTargetNames.map { "\($0): Invalid feed URL" }
        do {
            let currentFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
            let feedsByID = Dictionary(uniqueKeysWithValues: currentFeeds.map { ($0.id, $0) })

            for outcome in outcomes {
                switch outcome {
                case .success(let id, let parsedFeed):
                    guard let feed = feedsByID[id] else { continue }
                    merge(parsedFeed, into: feed, modelContext: modelContext)
                case .failure(let title, let message):
                    failures.append("\(title): \(message)")
                case .cancelled:
                    break
                }
            }

            try modelContext.save()
        } catch {
            modelContext.rollback()
            failures.append("Local database: \(error.localizedDescription)")
        }

        return failures
    }

    func previewFeed(from input: String, modelContext: ModelContext) async throws -> ParsedFeed {
        let requestedURL = try URLNormalizer.feedURL(from: input)
        guard !containsFeed(with: requestedURL, modelContext: modelContext) else {
            throw FeedClientError.duplicateFeed
        }

        let parsedFeed = try await client.fetch(requestedURL)
        guard !containsFeed(with: parsedFeed.sourceURL, modelContext: modelContext) else {
            throw FeedClientError.duplicateFeed
        }
        return parsedFeed
    }

    func subscribe(to parsedFeed: ParsedFeed, modelContext: ModelContext) throws {
        guard !containsFeed(with: parsedFeed.sourceURL, modelContext: modelContext) else {
            throw FeedClientError.duplicateFeed
        }

        let feed = Feed(
            title: parsedFeed.title,
            url: parsedFeed.sourceURL.absoluteString,
            iconURL: parsedFeed.iconURL?.absoluteString,
            lastFetched: parsedFeed.fetchedAt
        )
        modelContext.insert(feed)

        for parsedArticle in uniqueArticles(from: parsedFeed.articles) {
            let article = Article(
                title: parsedArticle.title,
                content: parsedArticle.content,
                link: parsedArticle.link,
                publishedAt: parsedArticle.publishedAt ?? parsedFeed.fetchedAt
            )
            feed.articles.append(article)
            modelContext.insert(article)
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func prepareOPMLImport(data: Data, modelContext: ModelContext) throws -> PreparedOPMLImport {
        let parsed = try OPMLCodec.parse(data: data)
        let existingFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
        let existingURLs = Set(existingFeeds.compactMap { feed -> String? in
            guard let url = URL(string: feed.url) else { return nil }
            return URLNormalizer.canonicalString(url)
        })

        var seenURLs = Set<String>()
        var uniqueEntries: [OPMLEntry] = []
        var duplicateEntryCount = 0

        for entry in parsed.entries {
            guard let canonicalURL = URLNormalizer.canonicalURL(entry.url) else { continue }
            let canonicalString = canonicalURL.absoluteString
            guard seenURLs.insert(canonicalString).inserted else {
                duplicateEntryCount += 1
                continue
            }
            uniqueEntries.append(
                OPMLEntry(
                    title: entry.title,
                    url: canonicalURL,
                    categoryName: entry.categoryName
                )
            )
        }

        let existingDuplicateCount = uniqueEntries.reduce(into: 0) { count, entry in
            if existingURLs.contains(entry.url.absoluteString) {
                count += 1
            }
        }

        return PreparedOPMLImport(
            entries: uniqueEntries,
            invalidEntryCount: parsed.invalidEntryCount,
            duplicateEntryCount: duplicateEntryCount,
            existingDuplicateCount: existingDuplicateCount
        )
    }

    func importOPML(
        _ preparedImport: PreparedOPMLImport,
        duplicatePolicy: OPMLDuplicatePolicy,
        modelContext: ModelContext
    ) throws -> OPMLImportResult {
        let existingFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
        let existingCategories = try modelContext.fetch(FetchDescriptor<FeedCategory>())

        var feedsByURL: [String: Feed] = [:]
        for feed in existingFeeds {
            guard let url = URL(string: feed.url),
                  let canonicalURL = URLNormalizer.canonicalString(url)
            else {
                continue
            }
            feedsByURL[canonicalURL] = feed
        }

        var categoriesByName: [String: FeedCategory] = [:]
        for category in existingCategories {
            categoriesByName[categoryLookupKey(category.name)] = category
        }

        var addedFeedIDs = Set<UUID>()
        var existingDuplicateCount = 0
        var reassignedCount = 0

        func category(named name: String?) -> FeedCategory? {
            guard let name = normalizedCategoryName(name) else { return nil }
            let key = categoryLookupKey(name)
            if let existing = categoriesByName[key] {
                return existing
            }

            let newCategory = FeedCategory(name: name)
            modelContext.insert(newCategory)
            categoriesByName[key] = newCategory
            return newCategory
        }

        for entry in preparedImport.entries {
            let canonicalURL = entry.url.absoluteString
            if let existingFeed = feedsByURL[canonicalURL] {
                existingDuplicateCount += 1
                if duplicatePolicy == .applyImportedCategories {
                    let importedCategory = category(named: entry.categoryName)
                    if existingFeed.category?.id != importedCategory?.id {
                        existingFeed.category = importedCategory
                        reassignedCount += 1
                    }
                }
                continue
            }

            let feed = Feed(
                title: entry.title,
                url: canonicalURL,
                category: category(named: entry.categoryName)
            )
            modelContext.insert(feed)
            feedsByURL[canonicalURL] = feed
            addedFeedIDs.insert(feed.id)
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        return OPMLImportResult(
            addedCount: addedFeedIDs.count,
            duplicateCount: preparedImport.duplicateEntryCount + existingDuplicateCount,
            reassignedCount: reassignedCount,
            invalidEntryCount: preparedImport.invalidEntryCount,
            addedFeedIDs: addedFeedIDs
        )
    }

    func toggleRead(_ article: Article, modelContext: ModelContext) {
        article.isRead.toggle()
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Update Article",
                message: "The read status could not be saved."
            )
        }
    }

    @discardableResult
    func createCategory(named name: String, modelContext: ModelContext) throws -> FeedCategory {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw FeedCategoryError.emptyName
        }

        let categories = try modelContext.fetch(FetchDescriptor<FeedCategory>())
        guard !categories.contains(where: {
            $0.name.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw FeedCategoryError.duplicateName
        }

        let category = FeedCategory(name: normalizedName)
        modelContext.insert(category)

        do {
            try modelContext.save()
            return category
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    func assign(_ feed: Feed, to category: FeedCategory?, modelContext: ModelContext) -> Bool {
        guard feed.category?.id != category?.id else { return true }
        feed.category = category

        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Move Feed",
                message: "The category assignment could not be saved."
            )
            return false
        }
    }

    @discardableResult
    func setTimelineVisibility(
        _ isShownInTimeline: Bool,
        for feed: Feed,
        modelContext: ModelContext
    ) -> Bool {
        guard feed.isShownInTimeline != isShownInTimeline else { return true }
        feed.isShownInTimeline = isShownInTimeline

        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Update Feed",
                message: "The timeline setting could not be saved."
            )
            return false
        }
    }

    @discardableResult
    func delete(_ category: FeedCategory, modelContext: ModelContext) -> Bool {
        modelContext.delete(category)
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Delete Category",
                message: "The category could not be deleted."
            )
            return false
        }
    }

    @discardableResult
    func markRead(_ articles: [Article], modelContext: ModelContext) -> Bool {
        guard articles.contains(where: { !$0.isRead }) else { return true }

        for article in articles {
            article.isRead = true
        }

        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Update Articles",
                message: "The selected articles could not be marked as read."
            )
            return false
        }
    }

    @discardableResult
    func delete(_ feed: Feed, modelContext: ModelContext) -> Bool {
        modelContext.delete(feed)
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            notice = UserNotice(
                title: "Couldn’t Delete Feed",
                message: "The subscription and its cached articles could not be deleted."
            )
            return false
        }
    }

    private func drainTargetedRefreshes(modelContext: ModelContext) async {
        while !pendingTargetedRefreshIDs.isEmpty {
            let feedIDs = pendingTargetedRefreshIDs
            pendingTargetedRefreshIDs.removeAll()
            let failures = await refreshBatch(feedIDs: feedIDs, modelContext: modelContext)
            reportRefreshFailures(failures)
        }
    }

    private func reportRefreshFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let details = failures.sorted().joined(separator: "\n")
        notice = UserNotice(
            title: failures.count == 1 ? "One Feed Couldn’t Refresh" : "Some Feeds Couldn’t Refresh",
            message: "Cached articles remain available.\n\n\(details)"
        )
    }

    private func normalizedCategoryName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private func categoryLookupKey(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func containsFeed(with url: URL, modelContext: ModelContext) -> Bool {
        guard let candidate = URLNormalizer.canonicalString(url),
              let feeds = try? modelContext.fetch(FetchDescriptor<Feed>())
        else {
            return false
        }

        return feeds.contains { feed in
            guard let storedURL = URL(string: feed.url) else { return false }
            return URLNormalizer.canonicalString(storedURL) == candidate
        }
    }

    private func merge(_ parsedFeed: ParsedFeed, into feed: Feed, modelContext: ModelContext) {
        if feed.title != parsedFeed.title {
            feed.title = parsedFeed.title
        }

        let sourceURL = parsedFeed.sourceURL.absoluteString
        if feed.url != sourceURL {
            feed.url = sourceURL
        }

        if let iconURL = parsedFeed.iconURL?.absoluteString,
           feed.iconURL != iconURL {
            feed.iconURL = iconURL
        }

        var articlesByLink = Dictionary(uniqueKeysWithValues: feed.articles.map { ($0.link, $0) })
        for parsedArticle in uniqueArticles(from: parsedFeed.articles) {
            if let article = articlesByLink[parsedArticle.link] {
                if article.title != parsedArticle.title {
                    article.title = parsedArticle.title
                }
                if article.content != parsedArticle.content {
                    article.content = parsedArticle.content
                }
                if let publishedAt = parsedArticle.publishedAt,
                   article.publishedAt != publishedAt {
                    article.publishedAt = publishedAt
                }
            } else {
                let article = Article(
                    title: parsedArticle.title,
                    content: parsedArticle.content,
                    link: parsedArticle.link,
                    publishedAt: parsedArticle.publishedAt ?? parsedFeed.fetchedAt
                )
                feed.articles.append(article)
                modelContext.insert(article)
                articlesByLink[parsedArticle.link] = article
            }
        }

        feed.lastFetched = parsedFeed.fetchedAt
    }

    private func uniqueArticles(from articles: [ParsedArticle]) -> [ParsedArticle] {
        var seenLinks = Set<String>()
        return articles.filter { seenLinks.insert($0.link).inserted }
    }
}

private struct RefreshTarget: Sendable {
    let id: UUID
    let title: String
    let url: URL
}

private enum RefreshOutcome: Sendable {
    case success(UUID, ParsedFeed)
    case failure(String, String)
    case cancelled
}
