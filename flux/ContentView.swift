//
//  ContentView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case timeline
        case feeds
    }

    private enum SheetDestination: String, Identifiable {
        case addFeed

        var id: String { rawValue }
    }

    @Environment(FeedStore.self) private var feedStore
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Article> { !$0.isRead }) private var unreadArticles: [Article]

    @State private var selectedTab: AppTab = .timeline
    @State private var presentedSheet: SheetDestination?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Timeline", systemImage: "newspaper", value: .timeline) {
                NavigationStack {
                    TimelineView(onAddFeed: presentAddFeed)
                }
            }
            .badge(unreadArticles.count)

            Tab("Feeds", systemImage: "dot.radiowaves.left.and.right", value: .feeds) {
                NavigationStack {
                    FeedManagementView(onAddFeed: presentAddFeed)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .addFeed:
                AddFeedView()
            }
        }
        .alert(item: noticeBinding) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            await feedStore.refreshOnceAfterLaunch(modelContext: modelContext)
        }
    }

    private var noticeBinding: Binding<UserNotice?> {
        Binding(
            get: { feedStore.notice },
            set: { feedStore.notice = $0 }
        )
    }

    private func presentAddFeed() {
        presentedSheet = .addFeed
    }
}

#Preview("Empty Library") {
    ContentView()
        .environment(FeedStore(client: .preview))
        .modelContainer(for: [Feed.self, Article.self], inMemory: true)
}
