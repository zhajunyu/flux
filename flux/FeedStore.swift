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

@MainActor
@Observable
final class FeedStore {
    private(set) var isRefreshing = false
    var notice: UserNotice?

    private let client: FeedClient
    private var didAutoRefresh = false

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

        let subscribedFeeds: [Feed]
        do {
            subscribedFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
        } catch {
            if reportErrors {
                notice = UserNotice(
                    title: "Refresh Failed",
                    message: "The subscriptions could not be loaded from this device."
                )
            }
            return
        }

        guard !subscribedFeeds.isEmpty else { return }

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

        if Task.isCancelled { return }

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

        if reportErrors, !failures.isEmpty {
            let details = failures.sorted().joined(separator: "\n")
            notice = UserNotice(
                title: failures.count == 1 ? "One Feed Couldn’t Refresh" : "Some Feeds Couldn’t Refresh",
                message: "Cached articles remain available.\n\n\(details)"
            )
        }
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
        feed.title = parsedFeed.title
        feed.url = parsedFeed.sourceURL.absoluteString
        if let iconURL = parsedFeed.iconURL {
            feed.iconURL = iconURL.absoluteString
        }

        var articlesByLink = Dictionary(uniqueKeysWithValues: feed.articles.map { ($0.link, $0) })
        for parsedArticle in uniqueArticles(from: parsedFeed.articles) {
            if let article = articlesByLink[parsedArticle.link] {
                article.title = parsedArticle.title
                article.content = parsedArticle.content
                if let publishedAt = parsedArticle.publishedAt {
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
