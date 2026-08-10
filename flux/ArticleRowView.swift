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
            } else {
                Circle()
                    .fill(article.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(article.title)
                    .font(.headline)
                    .fontWeight(article.isRead ? .regular : .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

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

                if let content = article.content {
                    Text(content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 7)
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
