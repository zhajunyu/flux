//
//  ArticleContentStore.swift
//  flux
//
//  Created by Codex on 2026/8/15.
//

import Foundation
import Observation
import SwiftData

struct CachedArticleContent: Sendable, Equatable {
    let content: ArticleContent
    let fetchedAt: Date
    let isStale: Bool
}

enum ArticleContentCacheLookup: Sendable, Equatable {
    case missing
    case available(CachedArticleContent)
    case unavailable(status: ContentStatus, message: String)
}

enum ArticleContentStoreError: LocalizedError, Sendable, Equatable {
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .persistence(let message):
            "The reader cache could not be updated: \(message)"
        }
    }
}

@MainActor
@Observable
final class ArticleContentStore {
    static let defaultFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60

    private let extractor: any ArticleExtracting
    private let freshnessInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        extractor: any ArticleExtracting = ArticleExtractor(),
        freshnessInterval: TimeInterval = ArticleContentStore.defaultFreshnessInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.extractor = extractor
        self.freshnessInterval = max(0, freshnessInterval)
        self.now = now
        encoder.outputFormatting = [.sortedKeys]
    }

    func lookup(
        for url: URL,
        modelContext: ModelContext
    ) throws -> ArticleContentCacheLookup {
        let canonicalURL = try canonicalString(for: url)
        guard let record = try record(for: canonicalURL, modelContext: modelContext) else {
            return .missing
        }

        if record.status == .fetching {
            record.status = .notFetched
            record.failureCode = nil
            record.failureMessage = nil
            try save(modelContext)
            return .missing
        }

        if record.status == .available,
           let data = record.contentData,
           let fetchedAt = record.fetchedAt {
            do {
                let content = try decoder.decode(ArticleContent.self, from: data)
                return .available(
                    CachedArticleContent(
                        content: content,
                        fetchedAt: fetchedAt,
                        isStale: now().timeIntervalSince(fetchedAt) >= freshnessInterval
                            || record.extractionVersion < ArticleContentCacheVersion.current
                    )
                )
            } catch {
                record.status = .notFetched
                record.contentData = nil
                record.fetchedAt = nil
                record.failureCode = nil
                record.failureMessage = nil
                record.extractionVersion = 0
                try save(modelContext)
                return .missing
            }
        }

        switch record.status {
        case .failed, .blocked, .paywalled:
            return .unavailable(
                status: record.status,
                message: record.failureMessage ?? defaultMessage(for: record.status)
            )
        case .notFetched, .fetching, .available:
            return .missing
        }
    }

    @discardableResult
    func fetchAndCache(
        from url: URL,
        modelContext: ModelContext
    ) async throws -> ArticleContent {
        let canonicalURL = try canonicalString(for: url)
        let existingRecord = try record(for: canonicalURL, modelContext: modelContext)
        let record = existingRecord ?? ArticleContentRecord(url: canonicalURL)
        if existingRecord == nil {
            modelContext.insert(record)
        }

        let snapshot = RecordSnapshot(record: record)
        let hadAvailableContent = record.status == .available
            && record.contentData != nil
            && record.fetchedAt != nil

        record.lastAttemptedAt = now()
        record.failureCode = nil
        record.failureMessage = nil
        if !hadAvailableContent {
            record.status = .fetching
        }
        try save(modelContext)

        do {
            let content = try await extractor.extract(from: url)
            try Task.checkCancellation()
            record.contentData = try encoder.encode(content)
            record.fetchedAt = now()
            record.lastAttemptedAt = record.fetchedAt
            record.status = .available
            record.failureCode = nil
            record.failureMessage = nil
            record.extractionVersion = ArticleContentCacheVersion.current
            try save(modelContext)
            return content
        } catch is CancellationError {
            snapshot.restore(record)
            try? save(modelContext)
            throw CancellationError()
        } catch let error as ArticleExtractionError {
            persistFailure(error, in: record, preservingAvailableContent: hadAvailableContent)
            try save(modelContext)
            throw error
        } catch let error as ArticleContentStoreError {
            throw error
        } catch {
            let extractionError = ArticleExtractionError.navigationFailed(
                code: nil,
                message: error.localizedDescription
            )
            persistFailure(
                extractionError,
                in: record,
                preservingAvailableContent: hadAvailableContent
            )
            try save(modelContext)
            throw extractionError
        }
    }

    private func persistFailure(
        _ error: ArticleExtractionError,
        in record: ArticleContentRecord,
        preservingAvailableContent: Bool
    ) {
        record.lastAttemptedAt = now()
        record.failureCode = error.persistenceCode
        record.failureMessage = error.localizedDescription
        if preservingAvailableContent {
            record.status = .available
        } else {
            record.status = error.contentStatus
            record.contentData = nil
            record.fetchedAt = nil
            record.extractionVersion = 0
        }
    }

    private func record(
        for canonicalURL: String,
        modelContext: ModelContext
    ) throws -> ArticleContentRecord? {
        var descriptor = FetchDescriptor<ArticleContentRecord>(
            predicate: #Predicate { record in
                record.url == canonicalURL
            }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw ArticleContentStoreError.persistence(error.localizedDescription)
        }
    }

    private func canonicalString(for url: URL) throws -> String {
        guard let canonicalURL = URLNormalizer.canonicalString(url) else {
            throw ArticleExtractionError.invalidURL
        }
        return canonicalURL
    }

    private func save(_ modelContext: ModelContext) throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw ArticleContentStoreError.persistence(error.localizedDescription)
        }
    }

    private func defaultMessage(for status: ContentStatus) -> String {
        switch status {
        case .blocked:
            ArticleExtractionError.blocked.localizedDescription
        case .paywalled:
            ArticleExtractionError.paywalled.localizedDescription
        default:
            "Reader Mode could not load this article."
        }
    }
}

private struct RecordSnapshot {
    let status: ContentStatus
    let contentData: Data?
    let fetchedAt: Date?
    let lastAttemptedAt: Date?
    let failureCode: String?
    let failureMessage: String?
    let extractionVersion: Int

    init(record: ArticleContentRecord) {
        status = record.status
        contentData = record.contentData
        fetchedAt = record.fetchedAt
        lastAttemptedAt = record.lastAttemptedAt
        failureCode = record.failureCode
        failureMessage = record.failureMessage
        extractionVersion = record.extractionVersion
    }

    func restore(_ record: ArticleContentRecord) {
        record.status = status
        record.contentData = contentData
        record.fetchedAt = fetchedAt
        record.lastAttemptedAt = lastAttemptedAt
        record.failureCode = failureCode
        record.failureMessage = failureMessage
        record.extractionVersion = extractionVersion
    }
}
