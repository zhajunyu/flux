//
//  SettingsView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftData
import SwiftUI

enum AppPreferenceKey {
    static let appearance = "appearance"
    static let refreshFeedsOnLaunch = "refreshFeedsOnLaunch"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct SettingsView: View {
    @Environment(FeedStore.self) private var feedStore
    @Query(sort: \Feed.title) private var feeds: [Feed]

    @AppStorage(AppPreferenceKey.appearance)
    private var appearance = AppAppearance.system.rawValue

    @AppStorage(AppPreferenceKey.refreshFeedsOnLaunch)
    private var refreshFeedsOnLaunch = true

    @State private var isExportingOPML = false
    @State private var exportDocument = OPMLFileDocument()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title)
                            .tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Appearance")
            }

            Section {
                Toggle("Refresh Feeds on Launch", isOn: $refreshFeedsOnLaunch)
            } header: {
                Text("Feeds")
            } footer: {
                Text("When enabled, Flux checks every subscription for new articles after the app opens.")
            }

            Section {
                Button {
                    prepareOPMLExport()
                } label: {
                    Label("Export OPML", systemImage: "square.and.arrow.up")
                }
                .disabled(feeds.isEmpty)
            } header: {
                Text("Data")
            } footer: {
                Text("Export your subscriptions and categories for another feed reader or as a backup.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("Settings")
        .fileExporter(
            isPresented: $isExportingOPML,
            document: exportDocument,
            contentType: .opml,
            defaultFilename: "Flux Subscriptions.opml"
        ) { result in
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError {
                feedStore.notice = UserNotice(
                    title: "Export Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func prepareOPMLExport() {
        exportDocument = OPMLFileDocument(
            entries: feeds.map { feed in
                OPMLExportEntry(
                    title: feed.title,
                    url: feed.url,
                    categoryName: feed.category?.name
                )
            }
        )
        isExportingOPML = true
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(FeedStore(client: .preview))
    .modelContainer(for: [Feed.self, FeedCategory.self, Article.self], inMemory: true)
}
