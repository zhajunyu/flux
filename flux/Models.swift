//
//  Models.swift
//  flux
//
//  Created by Junyu Zha on 2026/8/9.
//

import Foundation
import SwiftData

@Model
final class Feed {
    @Attribute(.unique) var id: UUID
    var title: String
    var url: String
    var lastFetched: Date?

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]

    init(
        id: UUID = UUID(),
        title: String,
        url: String,
        lastFetched: Date? = nil,
        articles: [Article] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.lastFetched = lastFetched
        self.articles = articles
    }
}

@Model
final class Article {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String?
    var link: String
    var publishedAt: Date
    var isRead: Bool
    var feed: Feed?

    init(
        id: UUID = UUID(),
        title: String,
        content: String? = nil,
        link: String,
        publishedAt: Date,
        isRead: Bool = false,
        feed: Feed? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.link = link
        self.publishedAt = publishedAt
        self.isRead = isRead
        self.feed = feed
    }
}
