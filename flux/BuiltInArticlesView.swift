//
//  BuiltInArticlesView.swift
//  flux
//
//  Created by Codex on 2026/8/14.
//

import SwiftData
import SwiftUI

enum BuiltInFeedItem: String, CaseIterable, Identifiable {
    case readLater
    case bookmarks
    case starred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readLater:
            "Read Later"
        case .bookmarks:
            "Bookmarks"
        case .starred:
            "Starred"
        }
    }

    var systemImage: String {
        switch self {
        case .readLater:
            "clock.fill"
        case .bookmarks:
            "bookmark.fill"
        case .starred:
            "star.fill"
        }
    }

    var tint: Color {
        switch self {
        case .readLater:
            .blue
        case .bookmarks:
            .orange
        case .starred:
            .yellow
        }
    }

    func contains(_ article: Article) -> Bool {
        switch self {
        case .readLater:
            article.isSavedForLater
        case .bookmarks:
            article.isBookmarked
        case .starred:
            article.isStarred
        }
    }

    var emptyTitle: String {
        switch self {
        case .readLater:
            "No Read Later Articles"
        case .bookmarks:
            "No Bookmarked Articles"
        case .starred:
            "No Starred Articles"
        }
    }

    var emptyDescription: String {
        switch self {
        case .readLater:
            "Articles you save for later will appear here."
        case .bookmarks:
            "Articles you bookmark will appear here."
        case .starred:
            "Articles you star will appear here."
        }
    }
}

struct BuiltInArticlesView: View {
    @Query(sort: \Article.publishedAt, order: .reverse) private var allArticles: [Article]

    @State private var navigationArticle: Article?

    let item: BuiltInFeedItem

    private var articles: [Article] {
        allArticles.filter(item.contains)
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
        .navigationTitle(item.title)
        .navigationDestination(item: $navigationArticle) { article in
            ArticleDetailView(article: article)
        }
    }

    private var articleList: some View {
        List {
            ForEach(articles) { article in
                Button {
                    navigationArticle = article
                } label: {
                    ArticleRowView(article: article)
                }
                .buttonStyle(.plain)
                .articleListRowStyle()
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(item.emptyTitle, systemImage: item.systemImage)
        } description: {
            Text(item.emptyDescription)
        }
    }
}
