//
//  ArticleContent.swift
//  flux
//
//  Created by Codex on 2026/8/15.
//

import Foundation
import SwiftData

struct ArticleContent: Codable, Sendable, Equatable {
    let title: String?
    let byline: String?
    let siteName: String?
    let excerpt: String?
    let publishedTime: String?
    let contentHTML: String
    let textContent: String
    let length: Int
    let language: String?
    let direction: String?

    init(
        title: String? = nil,
        byline: String? = nil,
        siteName: String? = nil,
        excerpt: String? = nil,
        publishedTime: String? = nil,
        contentHTML: String,
        textContent: String,
        length: Int,
        language: String? = nil,
        direction: String? = nil
    ) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.excerpt = excerpt
        self.publishedTime = publishedTime
        self.contentHTML = contentHTML
        self.textContent = textContent
        self.length = length
        self.language = language
        self.direction = direction
    }
}

enum ContentStatus: String, Codable, Sendable, CaseIterable {
    case notFetched
    case fetching
    case available
    case failed
    case blocked
    case paywalled
}

@Model
final class ArticleContentRecord {
    @Attribute(.unique) var url: String
    var statusRawValue: String = ContentStatus.notFetched.rawValue
    @Attribute(.externalStorage) var contentData: Data?
    var fetchedAt: Date?
    var lastAttemptedAt: Date?
    var failureCode: String?
    var failureMessage: String?

    init(
        url: String,
        status: ContentStatus = .notFetched,
        contentData: Data? = nil,
        fetchedAt: Date? = nil,
        lastAttemptedAt: Date? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil
    ) {
        self.url = url
        statusRawValue = status.rawValue
        self.contentData = contentData
        self.fetchedAt = fetchedAt
        self.lastAttemptedAt = lastAttemptedAt
        self.failureCode = failureCode
        self.failureMessage = failureMessage
    }

    var status: ContentStatus {
        get { ContentStatus(rawValue: statusRawValue) ?? .notFetched }
        set { statusRawValue = newValue.rawValue }
    }
}

enum ArticleExtractionError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingScriptResource(String)
    case navigationFailed(code: Int?, message: String)
    case httpStatus(Int)
    case timedOut
    case javaScriptFailed(String)
    case readabilityReturnedNil
    case insufficientContent(Int)
    case blocked
    case paywalled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "This article does not have a valid web address."
        case .unsupportedScheme:
            "Only HTTP and HTTPS article links can be extracted."
        case .missingScriptResource:
            "The reader extraction resources are unavailable."
        case .navigationFailed(_, let message):
            message
        case .httpStatus(let status):
            "The website returned HTTP status \(status)."
        case .timedOut:
            "The website took too long to provide readable content."
        case .javaScriptFailed:
            "The webpage could not be processed by Reader Mode."
        case .readabilityReturnedNil:
            "Reader Mode could not identify an article on this page."
        case .insufficientContent:
            "The page did not contain enough readable article text."
        case .blocked:
            "The website blocked automated article loading."
        case .paywalled:
            "This article requires a subscription or sign-in."
        }
    }

    var persistenceCode: String {
        switch self {
        case .invalidURL: "invalidURL"
        case .unsupportedScheme: "unsupportedScheme"
        case .missingScriptResource: "missingScriptResource"
        case .navigationFailed: "navigationFailed"
        case .httpStatus: "httpStatus"
        case .timedOut: "timedOut"
        case .javaScriptFailed: "javaScriptFailed"
        case .readabilityReturnedNil: "readabilityReturnedNil"
        case .insufficientContent: "insufficientContent"
        case .blocked: "blocked"
        case .paywalled: "paywalled"
        }
    }

    var contentStatus: ContentStatus {
        switch self {
        case .blocked:
            .blocked
        case .paywalled:
            .paywalled
        default:
            .failed
        }
    }
}
