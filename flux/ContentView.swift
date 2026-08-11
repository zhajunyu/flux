//
//  ContentView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    private enum SheetDestination: String, Identifiable {
        case addFeed
        case addCategory

        var id: String { rawValue }
    }

    @Environment(FeedStore.self) private var feedStore
    @Environment(\.modelContext) private var modelContext

    @AppStorage(AppPreferenceKey.appearance)
    private var appearance = AppAppearance.system.rawValue

    @AppStorage(AppPreferenceKey.refreshFeedsOnLaunch)
    private var refreshFeedsOnLaunch = true

    @State private var presentedSheet: SheetDestination?

    var body: some View {
        NavigationStack {
            FeedManagementView(
                onAddFeed: presentAddFeed,
                onAddCategory: presentAddCategory
            )
        }
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
        .environment(FeedIconCache())
        .modelContainer(for: [Feed.self, FeedCategory.self, Article.self], inMemory: true)
}
