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
    @Query(filter: #Predicate<Article> { !$0.isRead }) private var unreadArticles: [Article]

    @State private var pendingFeedDeletion: Feed?
    @State private var pendingCategoryDeletion: FeedCategory?
    @State private var isImportingOPML = false
    @State private var pendingOPMLImport: PreparedOPMLImport?
    @State private var expandedFolderIDs: Set<String> = []

    let onAddFeed: () -> Void
    let onAddCategory: () -> Void

    var body: some View {
        feedList
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityHint("Opens app settings")
            }

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
                Label("Add Feed", systemImage: "dot.radiowaves.up.forward")
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
            Label("No Subscriptions", systemImage: "dot.radiowaves.up.forward")
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
        ScrollView {
            LazyVStack(spacing: 0) {
                timelineRow

                builtInHeader
                    .padding(.top, 28)
                    .padding(.bottom, 12)

                LazyVStack(spacing: 8) {
                    ForEach(BuiltInFeedItem.allCases) { item in
                        builtInRow(item)
                    }
                }

                if feeds.isEmpty && categories.isEmpty {
                    emptyState
                        .padding(.top, 32)
                } else {
                    libraryHeader
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 18) {
                        ForEach(feedFolders) { folder in
                            folderGroup(folder)
                        }
                    }
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await feedStore.refreshAll(modelContext: modelContext)
        }
    }

    private var timelineRow: some View {
        NavigationLink {
            TimelineView(onAddFeed: onAddFeed)
        } label: {
            TimelineHeroRow(unreadCount: timelineUnreadCount)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens articles from feeds shown in the timeline")
    }

    private var builtInHeader: some View {
        HStack(spacing: 10) {
            Text("Built-in")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private func builtInRow(_ item: BuiltInFeedItem) -> some View {
        NavigationLink {
            BuiltInArticlesView(item: item)
        } label: {
            BuiltInFeedRow(item: item)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(item.title)")
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            Text("Library")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private var timelineUnreadCount: Int {
        unreadArticles.lazy.filter(\.isVisibleInTimeline).count
    }

    @ViewBuilder
    private func folderGroup(_ folder: FeedFolderItem) -> some View {
        let folderFeeds = feeds(in: folder)
        let isExpanded = expandedFolderIDs.contains(folder.id)

        VStack(alignment: .leading, spacing: 8) {
            folderRow(folder, feeds: folderFeeds, isExpanded: isExpanded)

            if isExpanded {
                LazyVStack(spacing: 4) {
                    ForEach(folderFeeds) { feed in
                        feedRow(feed)
                    }
                }
                .padding(.leading, 20)
                .transition(.verticalSquash)
            }
        }
    }

    @ViewBuilder
    private func folderRow(
        _ folder: FeedFolderItem,
        feeds folderFeeds: [Feed],
        isExpanded: Bool
    ) -> some View {
        switch folder {
        case .category(let category):
            FeedFolderRow(
                title: category.name,
                icon: .folder,
                unreadCount: unreadArticleCount(in: folderFeeds),
                isExpanded: isExpanded,
                onToggle: { toggleExpansion(of: folder) },
                onDelete: { pendingCategoryDeletion = category }
            )
            .feedDropTarget { identifier in
                moveFeed(identifiedBy: identifier, to: category)
            }
        case .uncategorized:
            FeedFolderRow(
                title: "Uncategorized",
                icon: .uncategorized,
                unreadCount: unreadArticleCount(in: folderFeeds),
                isExpanded: isExpanded,
                onToggle: { toggleExpansion(of: folder) }
            )
            .feedDropTarget { identifier in
                moveFeed(identifiedBy: identifier, to: nil)
            }
        }
    }

    private func feedRow(_ feed: Feed) -> some View {
        NavigationLink {
            FeedArticlesView(feed: feed)
        } label: {
            FeedLibraryRowLabel(
                title: feed.title,
                icon: .feed(feed.iconURL.flatMap(URL.init(string:)))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Feed", systemImage: "trash", role: .destructive) {
                pendingFeedDeletion = feed
            }
        }
        .onDrag {
            NSItemProvider(object: feed.id.uuidString as NSString)
        } preview: {
            Label(feed.title, systemImage: "dot.radiowaves.up.forward")
                .font(.headline)
                .padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
        .feedDropTarget { identifier in
            moveFeed(identifiedBy: identifier, to: feed.category)
        }
    }

    private var feedFolders: [FeedFolderItem] {
        var folders = categories.map(FeedFolderItem.category)
        if !feeds.isEmpty {
            folders.append(.uncategorized)
        }

        return folders.sorted { lhs, rhs in
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedAscending
        }
    }

    private func feeds(in folder: FeedFolderItem) -> [Feed] {
        switch folder {
        case .category(let category):
            feeds.filter { $0.category?.id == category.id }
        case .uncategorized:
            feeds.filter { $0.category == nil }
        }
    }

    private func toggleExpansion(of folder: FeedFolderItem) {
        withAnimation(.snappy(duration: 0.25)) {
            if expandedFolderIDs.contains(folder.id) {
                expandedFolderIDs.remove(folder.id)
            } else {
                expandedFolderIDs.insert(folder.id)
            }
        }
    }

    private func unreadArticleCount(in feeds: [Feed]) -> Int {
        feeds.reduce(into: 0) { count, feed in
            count += feed.articles.lazy.filter { !$0.isRead }.count
        }
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

private enum FeedFolderItem: Identifiable {
    case category(FeedCategory)
    case uncategorized

    var id: String {
        switch self {
        case .category(let category):
            "category-\(category.id.uuidString)"
        case .uncategorized:
            "category-uncategorized"
        }
    }

    var title: String {
        switch self {
        case .category(let category):
            category.name
        case .uncategorized:
            "Uncategorized"
        }
    }
}

private enum FeedLibraryIcon {
    case folder
    case uncategorized
    case feed(URL?)
}

private struct BuiltInFeedRow: View {
    let item: BuiltInFeedItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 34, height: 34)
                .background(item.tint.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)

            Text(item.title)
                .font(.body.weight(.medium))

            Spacer(minLength: 12)

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct TimelineHeroRow: View {
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Capsule()
                .fill(.tint)
                .frame(width: 3, height: 46)
                .accessibilityHidden(true)

            Image(systemName: "newspaper.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Your reading")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                Text("Timeline")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.serif)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 0) {
                Text(unreadCount.formatted())
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()

                Text("unread")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct FeedFolderRow: View {
    let title: String
    let icon: FeedLibraryIcon
    let unreadCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    var onDelete: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let onDelete {
            row
                .contextMenu {
                    Button("Delete Category", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            FeedLibraryIconView(icon: icon)

            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 12)

            Text("\(unreadCount.formatted()) unread")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
        }
        .padding(.leading, 4)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
    }
}

private struct FeedLibraryRowLabel: View {
    let title: String
    let icon: FeedLibraryIcon

    var body: some View {
        HStack(spacing: 10) {
            FeedLibraryIconView(icon: icon)

            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct FeedLibraryIconView: View {
    let icon: FeedLibraryIcon

    @ViewBuilder
    var body: some View {
        switch icon {
        case .folder:
            systemIcon("folder.fill")
        case .uncategorized:
            systemIcon("tray.full.fill")
        case .feed(let url):
            FeedIconView(url: url, size: 30, cornerRadius: 15)
        }
    }

    private func systemIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 30, height: 30)
            .background(Color.accentColor.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
    }
}

private struct VerticalSquashModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: progress, anchor: .top)
            .opacity(progress)
            .clipped()
    }
}

private extension AnyTransition {
    static var verticalSquash: AnyTransition {
        .modifier(
            active: VerticalSquashModifier(progress: 0),
            identity: VerticalSquashModifier(progress: 1)
        )
    }
}
