//
//  SettingsView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

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
    @AppStorage(AppPreferenceKey.appearance)
    private var appearance = AppAppearance.system.rawValue

    @AppStorage(AppPreferenceKey.refreshFeedsOnLaunch)
    private var refreshFeedsOnLaunch = true

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

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("Settings")
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
}
