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
    var iconURL: String?
    var lastFetched: Date?
    var isShownInTimeline: Bool = true
    var category: FeedCategory?

    @Relationship(deleteRule: .cascade, inverse: \Article.feed)
    var articles: [Article]

    init(
        id: UUID = UUID(),
        title: String,
        url: String,
        iconURL: String? = nil,
        lastFetched: Date? = nil,
        isShownInTimeline: Bool = true,
        category: FeedCategory? = nil,
        articles: [Article] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.iconURL = iconURL
        self.lastFetched = lastFetched
        self.isShownInTimeline = isShownInTimeline
        self.category = category
        self.articles = articles
    }
}

@Model
final class FeedCategory {
    @Attribute(.unique) var id: UUID
    var name: String

    @Relationship(deleteRule: .nullify, inverse: \Feed.category)
    var feeds: [Feed]

    init(
        id: UUID = UUID(),
        name: String,
        feeds: [Feed] = []
    ) {
        self.id = id
        self.name = name
        self.feeds = feeds
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

    var isVisibleInTimeline: Bool {
        feed?.isShownInTimeline ?? true
    }
}
