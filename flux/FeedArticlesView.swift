//
//  FeedArticlesView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftData
import SwiftUI

struct FeedArticlesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore

    @State private var isEditing = false
    @State private var navigationArticle: Article?
    @State private var selectedArticleIDs: Set<UUID> = []

    let feed: Feed

    private var articles: [Article] {
        feed.articles.sorted { lhs, rhs in
            lhs.publishedAt > rhs.publishedAt
        }
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
        .navigationTitle(feed.title)
        .navigationDestination(item: $navigationArticle) { article in
            ArticleDetailView(article: article)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isEditing {
                    NavigationLink {
                        FeedDetailView(feed: feed)
                    } label: {
                        Label("Feed Details", systemImage: "info.circle")
                    }
                    .accessibilityHint("Shows subscription information and feed controls")
                }

                Button(action: toggleEditing) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .accessibilityLabel(isEditing ? "Done" : "Edit")
                .disabled(articles.isEmpty)
            }

            if feedStore.isRefreshing {
                ToolbarItem(placement: .status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing feeds")
                }
            }

            if isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(allArticlesAreSelected ? "Deselect All" : "Select All") {
                        toggleSelectAll()
                    }

                    Spacer()

                    Button {
                        markSelectedArticlesAsRead()
                    } label: {
                        Label("Mark as Read", systemImage: "envelope.open")
                    }
                    .disabled(selectedArticleIDs.isEmpty)
                }
            }
        }
        .onChange(of: articles.map(\.id)) { _, articleIDs in
            selectedArticleIDs.formIntersection(articleIDs)
        }
    }

    private var articleList: some View {
        List {
            ForEach(articles) { article in
                if isEditing {
                    Button {
                        toggleSelection(of: article)
                    } label: {
                        ArticleRowView(
                            article: article,
                            selectionState: selectedArticleIDs.contains(article.id),
                            showsFeedTitle: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(article.title)
                    .accessibilityValue(
                        selectedArticleIDs.contains(article.id) ? "Selected" : "Not selected"
                    )
                    .accessibilityHint("Double tap to toggle selection")
                    .articleListRowStyle()
                } else {
                    Button {
                        navigationArticle = article
                    } label: {
                        ArticleRowView(article: article, showsFeedTitle: false)
                    }
                    .buttonStyle(.plain)
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
                    .articleListRowStyle()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable {
            await feedStore.refreshAll(modelContext: modelContext)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Articles Yet", systemImage: "newspaper")
        } description: {
            Text("Refresh to check this subscription for new articles.")
        } actions: {
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

    private var allArticlesAreSelected: Bool {
        !articles.isEmpty && selectedArticleIDs.count == articles.count
    }

    private func toggleEditing() {
        withAnimation {
            isEditing.toggle()
            if !isEditing {
                selectedArticleIDs.removeAll()
            }
        }
    }

    private func toggleSelection(of article: Article) {
        if selectedArticleIDs.contains(article.id) {
            selectedArticleIDs.remove(article.id)
        } else {
            selectedArticleIDs.insert(article.id)
        }
    }

    private func toggleSelectAll() {
        if allArticlesAreSelected {
            selectedArticleIDs.removeAll()
        } else {
            selectedArticleIDs = Set(articles.map(\.id))
        }
    }

    private func markSelectedArticlesAsRead() {
        let selectedArticles = articles.filter { selectedArticleIDs.contains($0.id) }
        if feedStore.markRead(selectedArticles, modelContext: modelContext) {
            selectedArticleIDs.removeAll()
        }
    }
}
