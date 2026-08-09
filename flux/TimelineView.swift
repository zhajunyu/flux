//
//  TimelineView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore
    @Query(sort: \Article.publishedAt, order: .reverse) private var articles: [Article]
    @Query private var feeds: [Feed]

    let onAddFeed: () -> Void

    var body: some View {
        Group {
            if articles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
        .navigationTitle("Timeline")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddFeed) {
                    Label("Add Feed", systemImage: "plus")
                }
            }

            if feedStore.isRefreshing {
                ToolbarItem(placement: .status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing feeds")
                }
            }
        }
    }

    private var articleList: some View {
        List {
            ForEach(articles) { article in
                NavigationLink {
                    ArticleDetailView(article: article)
                } label: {
                    ArticleRowView(article: article)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    readToggleButton(for: article)
                }
                .contextMenu {
                    readToggleButton(for: article)
                    if let articleURL = URL(string: article.link) {
                        Link(destination: articleURL) {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await feedStore.refreshAll(modelContext: modelContext)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                feeds.isEmpty ? "No Feeds Yet" : "No Articles Yet",
                systemImage: feeds.isEmpty ? "dot.radiowaves.left.and.right" : "newspaper"
            )
        } description: {
            Text(
                feeds.isEmpty
                    ? "Subscribe to a feed to build your timeline."
                    : "Refresh to check your subscriptions for new articles."
            )
        } actions: {
            if feeds.isEmpty {
                Button("Add Feed", action: onAddFeed)
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task {
                        await feedStore.refreshAll(modelContext: modelContext)
                    }
                } label: {
                    if feedStore.isRefreshing {
                        ProgressView()
                    } else {
                        Text("Refresh")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(feedStore.isRefreshing)
            }
        }
    }

    private func readToggleButton(for article: Article) -> some View {
        Button {
            feedStore.toggleRead(article, modelContext: modelContext)
        } label: {
            Label(
                article.isRead ? "Mark Unread" : "Mark Read",
                systemImage: article.isRead ? "envelope.badge" : "envelope.open"
            )
        }
        .tint(article.isRead ? .orange : .blue)
    }
}

private struct ArticleRowView: View {
    let article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if article.isRead {
                        Circle().stroke(.quaternary, lineWidth: 1)
                    }
                }
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(article.title)
                    .font(.headline)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Text(article.feed?.title ?? "Unknown Source")
                        .lineLimit(1)
                    Text("•")
                        .accessibilityHidden(true)
                    Text(article.publishedAt, style: .relative)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let content = article.content {
                    Text(content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(article.isRead ? "Read" : "Unread")
    }
}
