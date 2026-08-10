//
//  FeedManagementView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FeedManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query(sort: \FeedCategory.name) private var categories: [FeedCategory]

    @State private var pendingFeedDeletion: Feed?
    @State private var pendingCategoryDeletion: FeedCategory?
    @State private var isImportingOPML = false
    @State private var pendingOPMLImport: PreparedOPMLImport?

    let onAddFeed: () -> Void
    let onAddCategory: () -> Void

    var body: some View {
        Group {
            if feeds.isEmpty && categories.isEmpty {
                emptyState
            } else {
                feedList
            }
        }
        .navigationTitle("Feeds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
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
            isPresented: feedDeletionBinding,
            titleVisibility: .visible,
            presenting: pendingFeedDeletion
        ) { feed in
            Button("Delete “\(feed.title)”", role: .destructive) {
                feedStore.delete(feed, modelContext: modelContext)
                pendingFeedDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFeedDeletion = nil
            }
        } message: { feed in
            Text("This permanently deletes the subscription and all \(feed.articles.count) cached articles from this device.")
        }
        .confirmationDialog(
            "Delete Category?",
            isPresented: categoryDeletionBinding,
            titleVisibility: .visible,
            presenting: pendingCategoryDeletion
        ) { category in
            Button("Delete “\(category.name)”", role: .destructive) {
                feedStore.delete(category, modelContext: modelContext)
                pendingCategoryDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCategoryDeletion = nil
            }
        } message: { category in
            Text("Feeds in this category will move to Uncategorized. No subscriptions will be deleted.")
        }
        .confirmationDialog(
            "Existing Subscriptions Found",
            isPresented: duplicateImportBinding,
            titleVisibility: .visible,
            presenting: pendingOPMLImport
        ) { preparedImport in
            Button("Keep Existing Categories") {
                completeImport(preparedImport, duplicatePolicy: .preserveExistingCategories)
            }
            Button("Apply OPML Categories") {
                completeImport(preparedImport, duplicatePolicy: .applyImportedCategories)
            }
            Button("Cancel", role: .cancel) {
                pendingOPMLImport = nil
            }
        } message: { preparedImport in
            Text(
                "\(preparedImport.existingDuplicateCount) existing "
                    + (preparedImport.existingDuplicateCount == 1 ? "subscription matches" : "subscriptions match")
                    + " this file. Choose whether their current categories should be preserved."
            )
        }
        .fileImporter(
            isPresented: $isImportingOPML,
            allowedContentTypes: [.opml, .xml],
            allowsMultipleSelection: false,
            onCompletion: handleOPMLSelection
        )
    }

    private var addMenu: some View {
        Menu {
            Button(action: onAddFeed) {
                Label("Add Feed", systemImage: "dot.radiowaves.left.and.right")
            }

            Button(action: onAddCategory) {
                Label("New Category", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                isImportingOPML = true
            } label: {
                Label("Import OPML", systemImage: "square.and.arrow.down")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityHint("Add a feed or category, or import subscriptions")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Subscriptions", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Add an RSS, Atom, or JSON feed, then organize it with your own categories.")
        } actions: {
            Button("Add Feed", action: onAddFeed)
                .buttonStyle(.borderedProminent)

            Button("New Category", action: onAddCategory)
                .buttonStyle(.bordered)
        }
    }

    private var feedList: some View {
        List {
            if feeds.isEmpty {
                ContentUnavailableView {
                    Label("No Subscriptions", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Your categories are ready. Add a feed to start organizing subscriptions.")
                } actions: {
                    Button("Add Feed", action: onAddFeed)
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }

            ForEach(categories) { category in
                categorySection(category)
            }

            if !feeds.isEmpty {
                Section {
                    if uncategorizedFeeds.isEmpty {
                        emptyDropTarget(for: nil)
                    } else {
                        ForEach(uncategorizedFeeds) { feed in
                            feedRow(feed, dropTarget: nil)
                        }
                    }
                } header: {
                    FeedCategoryHeader(
                        title: "Uncategorized",
                        count: uncategorizedFeeds.count,
                        systemImage: "tray"
                    )
                    .feedDropTarget { identifier in
                        moveFeed(identifiedBy: identifier, to: nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await feedStore.refreshAll(modelContext: modelContext)
        }
    }

    private func categorySection(_ category: FeedCategory) -> some View {
        let categoryFeeds = feeds.filter { $0.category?.id == category.id }

        return Section {
            if categoryFeeds.isEmpty {
                emptyDropTarget(for: category)
            } else {
                ForEach(categoryFeeds) { feed in
                    feedRow(feed, dropTarget: category)
                }
            }
        } header: {
            FeedCategoryHeader(
                title: category.name,
                count: categoryFeeds.count,
                systemImage: "folder",
                onDelete: { pendingCategoryDeletion = category }
            )
            .feedDropTarget { identifier in
                moveFeed(identifiedBy: identifier, to: category)
            }
        }
    }

    private func feedRow(_ feed: Feed, dropTarget category: FeedCategory?) -> some View {
        NavigationLink {
            FeedArticlesView(feed: feed)
        } label: {
            FeedRowView(feed: feed)
                .onDrag {
                    NSItemProvider(object: feed.id.uuidString as NSString)
                } preview: {
                    Label(feed.title, systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingFeedDeletion = feed
            }
        }
        .feedDropTarget { identifier in
            moveFeed(identifiedBy: identifier, to: category)
        }
    }

    private func emptyDropTarget(for category: FeedCategory?) -> some View {
        Label("Drop feeds here", systemImage: "arrow.down")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .feedDropTarget { identifier in
                moveFeed(identifiedBy: identifier, to: category)
            }
    }

    private var uncategorizedFeeds: [Feed] {
        feeds.filter { $0.category == nil }
    }

    private func moveFeed(identifiedBy identifier: String, to category: FeedCategory?) {
        guard let feedID = UUID(uuidString: identifier),
              let feed = feeds.first(where: { $0.id == feedID })
        else {
            return
        }

        feedStore.assign(feed, to: category, modelContext: modelContext)
    }

    private var feedDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingFeedDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingFeedDeletion = nil
                }
            }
        )
    }

    private var categoryDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingCategoryDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCategoryDeletion = nil
                }
            }
        )
    }

    private var duplicateImportBinding: Binding<Bool> {
        Binding(
            get: { pendingOPMLImport != nil },
            set: { isPresented in
                if !isPresented {
                    pendingOPMLImport = nil
                }
            }
        )
    }

    private func handleOPMLSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let preparedImport = try feedStore.prepareOPMLImport(
                    data: data,
                    modelContext: modelContext
                )
                if preparedImport.existingDuplicateCount > 0 {
                    pendingOPMLImport = preparedImport
                } else {
                    completeImport(
                        preparedImport,
                        duplicatePolicy: .preserveExistingCategories
                    )
                }
            } catch {
                feedStore.notice = UserNotice(
                    title: "Import Failed",
                    message: error.localizedDescription
                )
            }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            feedStore.notice = UserNotice(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func completeImport(
        _ preparedImport: PreparedOPMLImport,
        duplicatePolicy: OPMLDuplicatePolicy
    ) {
        pendingOPMLImport = nil
        do {
            let result = try feedStore.importOPML(
                preparedImport,
                duplicatePolicy: duplicatePolicy,
                modelContext: modelContext
            )
            feedStore.notice = UserNotice(
                title: "OPML Import Complete",
                message: result.summary
            )

            let addedFeedIDs = result.addedFeedIDs
            Task {
                await feedStore.refreshImportedFeeds(
                    withIDs: addedFeedIDs,
                    modelContext: modelContext
                )
            }
        } catch {
            feedStore.notice = UserNotice(
                title: "Import Failed",
                message: "The subscriptions could not be saved to this device."
            )
        }
    }
}

private extension View {
    func feedDropTarget(perform action: @escaping (String) -> Void) -> some View {
        modifier(FeedDropTargetModifier(action: action))
    }
}

private struct FeedDropTargetModifier: ViewModifier {
    @State private var isTargeted = false

    let action: (String) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.12))
                        .stroke(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [UTType.plainText],
                isTargeted: $isTargeted,
                perform: receiveFeed
            )
    }

    private func receiveFeed(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let identifier = item as? NSString else { return }
            let identifierValue = String(identifier)

            Task { @MainActor in
                action(identifierValue)
            }
        }
        return true
    }
}

private struct FeedCategoryHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Label(title, systemImage: systemImage)

            Text(count.formatted())
                .foregroundStyle(.tertiary)

            Spacer()

            if let onDelete {
                Menu {
                    Button("Delete Category", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 28)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Category options for \(title)")
            }
        }
        .contentShape(.rect)
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
