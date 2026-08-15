//
//  ArticleReaderViewModel.swift
//  flux
//
//  Created by Codex on 2026/8/15.
//

import Foundation
import Observation
import SwiftData

struct ArticleReaderFailure: Sendable, Equatable {
    let status: ContentStatus
    let message: String
}

enum ArticleReaderState: Sendable, Equatable {
    case idle
    case loading
    case loaded(ArticleContent, isRefreshing: Bool)
    case unavailable(ArticleReaderFailure)
}

@MainActor
@Observable
final class ArticleReaderViewModel {
    private(set) var state: ArticleReaderState = .idle

    var isWorking: Bool {
        switch state {
        case .loading, .loaded(_, isRefreshing: true):
            true
        default:
            false
        }
    }

    func load(
        url: URL,
        forceRefresh: Bool,
        store: ArticleContentStore,
        modelContext: ModelContext
    ) async {
        if forceRefresh {
            await fetch(
                url: url,
                store: store,
                modelContext: modelContext,
                preserving: loadedContent
            )
            return
        }

        do {
            switch try store.lookup(for: url, modelContext: modelContext) {
            case .missing:
                await fetch(url: url, store: store, modelContext: modelContext, preserving: nil)
            case .unavailable(let status, let message):
                state = .unavailable(ArticleReaderFailure(status: status, message: message))
            case .available(let cached):
                state = .loaded(cached.content, isRefreshing: cached.isStale)
                if cached.isStale {
                    await fetch(
                        url: url,
                        store: store,
                        modelContext: modelContext,
                        preserving: cached.content
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            state = .unavailable(
                ArticleReaderFailure(status: .failed, message: error.localizedDescription)
            )
        }
    }

    private var loadedContent: ArticleContent? {
        if case .loaded(let content, _) = state {
            return content
        }
        return nil
    }

    private func fetch(
        url: URL,
        store: ArticleContentStore,
        modelContext: ModelContext,
        preserving existingContent: ArticleContent?
    ) async {
        if let existingContent {
            state = .loaded(existingContent, isRefreshing: true)
        } else {
            state = .loading
        }

        do {
            let content = try await store.fetchAndCache(from: url, modelContext: modelContext)
            try Task.checkCancellation()
            state = .loaded(content, isRefreshing: false)
        } catch is CancellationError {
            if let existingContent {
                state = .loaded(existingContent, isRefreshing: false)
            }
        } catch let error as ArticleExtractionError {
            if let existingContent {
                state = .loaded(existingContent, isRefreshing: false)
            } else {
                state = .unavailable(
                    ArticleReaderFailure(
                        status: error.contentStatus,
                        message: error.localizedDescription
                    )
                )
            }
        } catch {
            if let existingContent {
                state = .loaded(existingContent, isRefreshing: false)
            } else {
                state = .unavailable(
                    ArticleReaderFailure(status: .failed, message: error.localizedDescription)
                )
            }
        }
    }
}
