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

    @State private var isEditing = false
    @State private var selectedArticleIDs: Set<UUID> = []

    let onAddFeed: () -> Void

    private var timelineArticles: [Article] {
        articles.filter(\.isVisibleInTimeline)
    }

    var body: some View {
        Group {
            if timelineArticles.isEmpty {
                emptyState
            } else {
                articleList
            }
        }
        .navigationTitle("Timeline")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleEditing) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .accessibilityLabel(isEditing ? "Done" : "Edit")
                .disabled(timelineArticles.isEmpty)
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
        .toolbar(isEditing ? .hidden : .visible, for: .tabBar)
        .onChange(of: timelineArticles.map(\.id)) { _, articleIDs in
            selectedArticleIDs.formIntersection(articleIDs)
        }
    }

    private var articleList: some View {
        List {
            ForEach(timelineArticles) { article in
                if isEditing {
                    Button {
                        toggleSelection(of: article)
                    } label: {
                        ArticleRowView(
                            article: article,
                            selectionState: selectedArticleIDs.contains(article.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(article.title)
                    .accessibilityValue(
                        selectedArticleIDs.contains(article.id) ? "Selected" : "Not selected"
                    )
                    .accessibilityHint("Double tap to toggle selection")
                } else {
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
        }
        .listStyle(.plain)
        .refreshable {
            await feedStore.refreshAll(modelContext: modelContext)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyStateTitle,
                systemImage: feeds.isEmpty ? "dot.radiowaves.left.and.right" : "newspaper"
            )
        } description: {
            Text(emptyStateDescription)
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

    private var allFeedsAreHiddenFromTimeline: Bool {
        !feeds.isEmpty && feeds.allSatisfy { !$0.isShownInTimeline }
    }

    private var emptyStateTitle: String {
        if feeds.isEmpty {
            "No Feeds Yet"
        } else if allFeedsAreHiddenFromTimeline {
            "No Feeds in Timeline"
        } else {
            "No Articles Yet"
        }
    }

    private var emptyStateDescription: String {
        if feeds.isEmpty {
            "Subscribe to a feed to build your timeline."
        } else if allFeedsAreHiddenFromTimeline {
            "Turn on Show in Timeline from a feed’s detail view to see its articles here."
        } else {
            "Refresh to check your visible subscriptions for new articles."
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
        !timelineArticles.isEmpty && selectedArticleIDs.count == timelineArticles.count
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
            selectedArticleIDs = Set(timelineArticles.map(\.id))
        }
    }

    private func markSelectedArticlesAsRead() {
        let selectedArticles = timelineArticles.filter { selectedArticleIDs.contains($0.id) }
        if feedStore.markRead(selectedArticles, modelContext: modelContext) {
            selectedArticleIDs.removeAll()
        }
    }
}
