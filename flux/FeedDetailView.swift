//
//  FeedDetailView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftData
import SwiftUI

struct FeedDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore
    @Query(sort: \FeedCategory.name) private var categories: [FeedCategory]

    @State private var isConfirmingDeletion = false

    let feed: Feed

    private var unreadCount: Int {
        feed.articles.lazy.filter { !$0.isRead }.count
    }

    private var feedURL: URL? {
        URL(string: feed.url)
    }

    private var displayURL: String {
        guard let feedURL else { return feed.url }

        return feedURL.host(percentEncoded: false) ?? feed.url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                details
                deleteButton
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Feed Details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete Feed?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete “\(feed.title)”", role: .destructive) {
                deleteFeed()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the subscription and all \(feed.articles.count) cached articles from this device.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeedIconView(
                url: feed.iconURL.flatMap(URL.init(string:)),
                size: 58,
                cornerRadius: 16
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(feed.title)
                    .font(.largeTitle.bold())
                    .fontDesign(.serif)
                    .fixedSize(horizontal: false, vertical: true)

                if let feedURL {
                    Link(destination: feedURL) {
                        Label(displayURL, systemImage: "arrow.up.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Open feed URL, \(feed.url)")
                } else {
                    Text(feed.url)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            DetailRow(
                title: "Articles",
                value: feed.articles.count.formatted(),
                systemImage: "newspaper"
            )

            Divider()
                .padding(.leading, 46)

            DetailRow(
                title: "Unread",
                value: unreadCount.formatted(),
                systemImage: "envelope.badge"
            )

            Divider()
                .padding(.leading, 46)

            Toggle(isOn: timelineVisibility) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show in Timeline")
                        Text("Include articles from this feed in the main timeline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "newspaper")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .padding(.leading, 46)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "folder")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text("Category")

                Spacer(minLength: 18)

                categoryPicker
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            Divider()
                .padding(.leading, 46)

            StackedDetailRow(
                title: "Last Updated",
                value: lastUpdatedText,
                systemImage: "clock.arrow.circlepath"
            )

            Divider()
                .padding(.leading, 46)

            StackedDetailRow(
                title: "Feed URL",
                value: feed.url,
                systemImage: "link"
            )
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            isConfirmingDeletion = true
        } label: {
            Label("Delete Feed", systemImage: "trash")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .accessibilityHint("Deletes this subscription and its cached articles")
    }

    private var lastUpdatedText: String {
        guard let lastFetched = feed.lastFetched else { return "Never" }

        return lastFetched.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }

    private var categorySelection: Binding<UUID?> {
        Binding(
            get: { feed.category?.id },
            set: { selectedID in
                let category = categories.first { $0.id == selectedID }
                feedStore.assign(feed, to: category, modelContext: modelContext)
            }
        )
    }

    private var timelineVisibility: Binding<Bool> {
        Binding(
            get: { feed.isShownInTimeline },
            set: { isShown in
                feedStore.setTimelineVisibility(
                    isShown,
                    for: feed,
                    modelContext: modelContext
                )
            }
        )
    }

    private var categoryPicker: some View {
        Picker("Category", selection: categorySelection) {
            Text("Uncategorized")
                .tag(UUID?.none)

            ForEach(categories) { category in
                Text(category.name)
                    .tag(Optional(category.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.plain)
        .tint(.accentColor)
        .fixedSize()
        .accessibilityLabel("Feed category")
    }

    private func deleteFeed() {
        if feedStore.delete(feed, modelContext: modelContext) {
            dismiss()
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 18)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

private struct StackedDetailRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text(title)
                    .foregroundStyle(.primary)
            }

            Text(value)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}
