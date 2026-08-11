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

    @State private var loadFailure: ArticleWebViewFailure?
    @State private var retryURL: URL?
    @State private var reloadID = 0

    let article: Article

    var body: some View {
        Group {
            if let articleURL {
                ZStack {
                    ArticleWebView(
                        url: retryURL ?? articleURL,
                        reloadID: reloadID,
                        onNavigationFailure: { failure in
                            loadFailure = failure
                        }
                    )

                    if let loadFailure {
                        loadFailureView(loadFailure)
                    }
                }
            } else {
                invalidURLView
            }
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

    private var articleURL: URL? {
        URL(string: article.link).flatMap(URLNormalizer.canonicalURL)
    }

    private func loadFailureView(_ failure: ArticleWebViewFailure) -> some View {
        ContentUnavailableView {
            Label("Unable to Load Article", systemImage: "wifi.exclamationmark")
        } description: {
            Text(failure.message)
        } actions: {
            Button("Retry") {
                retryURL = failure.url
                loadFailure = nil
                reloadID &+= 1
            }
            .buttonStyle(.borderedProminent)

            Link(destination: failure.url) {
                Label("Open in Safari", systemImage: "safari")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var invalidURLView: some View {
        ContentUnavailableView {
            Label("Unable to Load Article", systemImage: "link.badge.plus")
        } description: {
            Text("This article does not have a valid web address.")
        }
    }
}
