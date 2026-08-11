//
//  ArticleRowView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftUI

struct ArticleRowView: View {
    let article: Article
    var selectionState: Bool?
    var showsFeedTitle = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let selectionState {
                Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionState ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if showsFeedTitle {
                        Text(article.feed?.title ?? "Unknown Source")
                            .lineLimit(1)
                        Text("•")
                            .accessibilityHidden(true)
                    }
                    Text(article.publishedAt, style: .relative)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(article.title)
                    .font(.headline)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if let content = article.content {
                    Text(content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if let selectionState {
            return selectionState ? "Selected" : "Not selected"
        }
        return article.isRead ? "Read" : "Unread"
    }
}

extension View {
    func articleListRowStyle() -> some View {
        listRowInsets(
            EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 16)
        )
        .listRowSeparator(.hidden)
    }
}
