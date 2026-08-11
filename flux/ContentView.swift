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
        case settings
    }

    private enum SheetDestination: String, Identifiable {
        case addFeed
        case addCategory

        var id: String { rawValue }
    }

    @Environment(FeedStore.self) private var feedStore
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Article> { !$0.isRead }) private var unreadArticles: [Article]

    @AppStorage(AppPreferenceKey.appearance)
    private var appearance = AppAppearance.system.rawValue

    @AppStorage(AppPreferenceKey.refreshFeedsOnLaunch)
    private var refreshFeedsOnLaunch = true

    @State private var selectedTab: AppTab = .timeline
    @State private var presentedSheet: SheetDestination?

    private var timelineUnreadCount: Int {
        unreadArticles.lazy.filter(\.isVisibleInTimeline).count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Timeline", systemImage: "newspaper", value: .timeline) {
                NavigationStack {
                    TimelineView(onAddFeed: presentAddFeed)
                }
            }
            .badge(timelineUnreadCount)

            Tab("Feeds", systemImage: "dot.radiowaves.up.forward", value: .feeds) {
                NavigationStack {
                    FeedManagementView(
                        onAddFeed: presentAddFeed,
                        onAddCategory: presentAddCategory
                    )
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .addFeed:
                AddFeedView()
            case .addCategory:
                AddCategoryView()
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
            if refreshFeedsOnLaunch {
                await feedStore.refreshOnceAfterLaunch(modelContext: modelContext)
            }
        }
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
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

    private func presentAddCategory() {
        presentedSheet = .addCategory
    }
}

#Preview("Empty Library") {
    ContentView()
        .environment(FeedStore(client: .preview))
        .modelContainer(for: [Feed.self, FeedCategory.self, Article.self], inMemory: true)
}
