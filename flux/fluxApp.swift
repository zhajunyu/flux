//
//  fluxApp.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftUI
import SwiftData

@main
struct fluxApp: App {
    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Feed.self,
            FeedCategory.self,
            Article.self,
            ArticleContentRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var feedStore = FeedStore()
    @State private var feedIconCache = FeedIconCache()
    @State private var articleContentStore = ArticleContentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(feedStore)
                .environment(feedIconCache)
                .environment(articleContentStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
