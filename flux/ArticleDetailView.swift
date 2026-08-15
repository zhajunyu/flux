//
//  ArticleDetailView.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import SwiftData
import SwiftUI

struct ArticleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(FeedStore.self) private var feedStore
    @Environment(ArticleContentStore.self) private var articleContentStore

    @AppStorage(AppPreferenceKey.readerTextScale)
    private var readerTextScale = ReaderTextScale.defaultValue

    @State private var readerViewModel = ArticleReaderViewModel()
    @State private var loadGeneration = 0

    let article: Article

    var body: some View {
        Group {
            if let articleURL {
                readerContent(articleURL: articleURL)
            } else {
                invalidURLView
            }
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if readerViewModel.isWorking {
                ToolbarItem(placement: .status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading Reader Mode")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                readerSettingsMenu
                articleActionsMenu
            }
        }
    }

    @ViewBuilder
    private func readerContent(articleURL: URL) -> some View {
        Group {
            switch readerViewModel.state {
            case .idle, .loading:
                loadingView
            case .loaded(let content, _):
                ReaderHTMLWebView(
                    document: ArticleReaderDocument(
                        content: content,
                        fallbackTitle: article.title,
                        fallbackSiteName: article.feed?.title,
                        fallbackPublishedAt: article.publishedAt,
                        textScale: readerTextScale
                    ),
                    onOpenURL: { url in
                        openURL(url)
                    }
                )
            case .unavailable(let failure):
                unavailableView(failure, articleURL: articleURL)
            }
        }
        .task(id: taskID) {
            await readerViewModel.load(
                url: articleURL,
                forceRefresh: loadGeneration > 0,
                store: articleContentStore,
                modelContext: modelContext
            )
        }
    }

    private var taskID: String {
        "\(article.id.uuidString)-\(loadGeneration)"
    }

    private var articleURL: URL? {
        URL(string: article.link).flatMap(URLNormalizer.canonicalURL)
    }

    private var hasLoadedContent: Bool {
        if case .loaded = readerViewModel.state {
            return true
        }
        return false
    }

    private var readerSettingsMenu: some View {
        Menu {
            Section("Text Size") {
                Button {
                    readerTextScale = ReaderTextScale.smaller(than: readerTextScale)
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(
                    !hasLoadedContent
                        || ReaderTextScale.clamped(readerTextScale) <= ReaderTextScale.minimum
                )

                Button("Reset Text Size") {
                    readerTextScale = ReaderTextScale.defaultValue
                }
                .disabled(
                    !hasLoadedContent
                        || abs(readerTextScale - ReaderTextScale.defaultValue) < 0.001
                )

                Button {
                    readerTextScale = ReaderTextScale.larger(than: readerTextScale)
                } label: {
                    Label("Larger", systemImage: "textformat.size.larger")
                }
                .disabled(
                    !hasLoadedContent
                        || ReaderTextScale.clamped(readerTextScale) >= ReaderTextScale.maximum
                )
            }

            Divider()

            Button {
                loadGeneration &+= 1
            } label: {
                Label("Refresh Article", systemImage: "arrow.clockwise")
            }
            .disabled(articleURL == nil || readerViewModel.isWorking)

            if let articleURL {
                Link(destination: articleURL) {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
        } label: {
            Label("Reader Settings", systemImage: "textformat.size")
        }
        .accessibilityHint("Changes reader text size or refreshes the article")
    }

    private var articleActionsMenu: some View {
        Menu {
            Button {
                feedStore.toggleRead(article, modelContext: modelContext)
            } label: {
                Label(
                    article.isRead ? "Mark Unread" : "Mark Read",
                    systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                )
            }

            Divider()

            Button {
                feedStore.toggleReadLater(article, modelContext: modelContext)
            } label: {
                Label(
                    article.isSavedForLater ? "Remove from Read Later" : "Read Later",
                    systemImage: article.isSavedForLater ? "clock.fill" : "clock"
                )
            }

            Button {
                feedStore.toggleBookmark(article, modelContext: modelContext)
            } label: {
                Label(
                    article.isBookmarked ? "Remove Bookmark" : "Add to Bookmark",
                    systemImage: article.isBookmarked ? "bookmark.fill" : "bookmark"
                )
            }

            Button {
                feedStore.toggleStarred(article, modelContext: modelContext)
            } label: {
                Label(
                    article.isStarred ? "Unstar" : "Star",
                    systemImage: article.isStarred ? "star.fill" : "star"
                )
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityHint("Shows article actions")
    }

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(article.title)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(article.feed?.title ?? "Unknown Source")
                    Text("•")
                        .accessibilityHidden(true)
                    Text(article.publishedAt, style: .date)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach([0.95, 0.82, 0.90, 0.68, 0.88, 0.76], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.22))
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length * width
                            }
                    }
                }
                .padding(.top, 12)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 30)
        }
        .overlay(alignment: .bottom) {
            ProgressView("Preparing Reader Mode…")
                .padding()
        }
    }

    private func unavailableView(
        _ failure: ArticleReaderFailure,
        articleURL: URL
    ) -> some View {
        ContentUnavailableView {
            Label(failureTitle(failure.status), systemImage: failureIcon(failure.status))
        } description: {
            VStack(spacing: 14) {
                Text(failure.message)
                if let summary = article.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Feed Summary")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.top, 8)
                }
            }
        } actions: {
            Button("Retry") {
                loadGeneration &+= 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(readerViewModel.isWorking)

            Link(destination: articleURL) {
                Label("Open in Safari", systemImage: "safari")
            }
            .buttonStyle(.bordered)
        }
    }

    private func failureTitle(_ status: ContentStatus) -> String {
        switch status {
        case .blocked:
            "Website Blocked Reader Mode"
        case .paywalled:
            "Subscription Required"
        default:
            "Unable to Extract Article"
        }
    }

    private func failureIcon(_ status: ContentStatus) -> String {
        switch status {
        case .blocked:
            "hand.raised.fill"
        case .paywalled:
            "lock.fill"
        default:
            "doc.text.magnifyingglass"
        }
    }

    private var invalidURLView: some View {
        ContentUnavailableView {
            Label("Unable to Load Article", systemImage: "link.badge.plus")
        } description: {
            Text("This article does not have a valid web address.")
        }
    }
}

#if DEBUG
private struct ArticlePreviewExtractor: ArticleExtracting {
    func extract(from url: URL) async throws -> ArticleContent {
        ArticleContent(
            title: "A Clean, Native Reader",
            byline: "Example Author",
            siteName: "Example Journal",
            contentHTML: "<p>This preview uses only extracted, sanitized article markup.</p><blockquote>Reader Mode keeps the words and leaves the website chrome behind.</blockquote>",
            textContent: "This preview uses only extracted, sanitized article markup. Reader Mode keeps the words and leaves the website chrome behind.",
            length: 124,
            language: "en",
            direction: "ltr"
        )
    }
}

#Preview("Reader") {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Feed.self,
        FeedCategory.self,
        Article.self,
        ArticleContentRecord.self,
        configurations: configuration
    )
    let article = Article(
        title: "A Clean, Native Reader",
        content: "A short summary from the feed.",
        link: "https://example.com/article",
        publishedAt: Date()
    )
    container.mainContext.insert(article)

    return NavigationStack {
        ArticleDetailView(article: article)
    }
    .environment(FeedStore(client: .preview))
    .environment(ArticleContentStore(extractor: ArticlePreviewExtractor()))
    .modelContainer(container)
}
#endif
