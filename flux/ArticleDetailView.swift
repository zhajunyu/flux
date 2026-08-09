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
    @Environment(FeedStore.self) private var feedStore

    let article: Article

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title)
                        .font(.largeTitle.bold())
                        .fontDesign(.serif)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(article.feed?.title ?? "Unknown Source")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                article.publishedAt,
                                format: .dateTime
                                    .year()
                                    .month(.wide)
                                    .day()
                                    .hour()
                                    .minute()
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                if let content = article.content {
                    Text(content)
                        .font(.body)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This feed did not include article content. Open the original page to continue reading.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if let articleURL = URL(string: article.link) {
                    Link(destination: articleURL) {
                        Label("Open in Safari", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Article")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    feedStore.toggleRead(article, modelContext: modelContext)
                } label: {
                    Label(
                        article.isRead ? "Mark Unread" : "Mark Read",
                        systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                    )
                }
            }
        }
    }
}
