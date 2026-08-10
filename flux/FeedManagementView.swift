//
//  FeedManagementView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct FeedManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore
    @Query(sort: \Feed.title) private var feeds: [Feed]

    @State private var pendingDeletion: Feed?

    let onAddFeed: () -> Void

    var body: some View {
        Group {
            if feeds.isEmpty {
                ContentUnavailableView {
                    Label("No Subscriptions", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Add an RSS, Atom, or JSON feed to get started.")
                } actions: {
                    Button("Add Feed", action: onAddFeed)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(feeds) { feed in
                        NavigationLink {
                            FeedArticlesView(feed: feed)
                        } label: {
                            FeedRowView(feed: feed)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = feed
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await feedStore.refreshAll(modelContext: modelContext)
                }
            }
        }
        .navigationTitle("Feeds")
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
        .confirmationDialog(
            "Delete Feed?",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { feed in
            Button("Delete “\(feed.title)”", role: .destructive) {
                feedStore.delete(feed, modelContext: modelContext)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { feed in
            Text("This permanently deletes the subscription and all \(feed.articles.count) cached articles from this device.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }
}

private struct FeedRowView: View {
    let feed: Feed

    var body: some View {
        HStack(spacing: 14) {
            FeedIconView(
                url: feed.iconURL.flatMap(URL.init(string:)),
                size: 34,
                cornerRadius: 9
            )

            Text(feed.title)
                .font(.headline)
                .lineLimit(2)
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
