//
//  FeedIconCache.swift
//  flux
//
//  Created by Codex on 2026/8/11.
//

import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

struct FeedIconCacheLookup {
    let image: UIImage?
    let isStale: Bool
}

typealias FeedIconFetcher = @Sendable (URL) async throws -> Data

enum FeedIconCacheError: Error, Equatable {
    case unsupportedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case responseTooLarge
    case undecodableImage
}

@MainActor
final class FeedIconCache: Observable {
    nonisolated static let defaultFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let defaultRetryInterval: TimeInterval = 15 * 60
    nonisolated static let defaultDiskLimit = 25 * 1_024 * 1_024
    nonisolated static let defaultMaximumResponseSize = 5 * 1_024 * 1_024
    nonisolated static let defaultMaximumPixelSize = 192
    nonisolated static let systemNow: @Sendable () -> Date = { Date() }

    private let memoryCache = NSCache<NSURL, FeedIconMemoryEntry>()
    private let repository: FeedIconRepository
    private let freshnessInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let maximumResponseSize: Int
    private let maximumPixelSize: Int
    private let now: @Sendable () -> Date
    private var failedRefreshes: [URL: Date] = [:]

    init(
        directoryURL: URL = FeedIconCache.defaultDirectoryURL(),
        freshnessInterval: TimeInterval = FeedIconCache.defaultFreshnessInterval,
        retryInterval: TimeInterval = FeedIconCache.defaultRetryInterval,
        diskLimit: Int = FeedIconCache.defaultDiskLimit,
        maximumResponseSize: Int = FeedIconCache.defaultMaximumResponseSize,
        maximumPixelSize: Int = FeedIconCache.defaultMaximumPixelSize,
        memoryCountLimit: Int = 128,
        memoryCostLimit: Int = 16 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = FeedIconCache.systemNow,
        fetcher: FeedIconFetcher? = nil
    ) {
        self.freshnessInterval = freshnessInterval
        self.retryInterval = retryInterval
        self.maximumResponseSize = maximumResponseSize
        self.maximumPixelSize = maximumPixelSize
        self.now = now
        self.repository = FeedIconRepository(
            directoryURL: directoryURL,
            diskLimit: diskLimit,
            fetcher: fetcher ?? FeedIconCache.liveFetcher(maximumResponseSize: maximumResponseSize)
        )
        memoryCache.countLimit = memoryCountLimit
        memoryCache.totalCostLimit = memoryCostLimit
    }

    func lookup(for url: URL) async -> FeedIconCacheLookup {
        if let entry = memoryCache.object(forKey: url as NSURL) {
            return FeedIconCacheLookup(
                image: entry.image,
                isStale: isStale(entry.storedAt)
            )
        }

        guard let record = await repository.record(for: url) else {
            return FeedIconCacheLookup(image: nil, isStale: true)
        }

        guard let image = FeedIconImageDecoder.decode(
            record.data,
            maximumPixelSize: maximumPixelSize
        ) else {
            await repository.removeRecord(for: url)
            return FeedIconCacheLookup(image: nil, isStale: true)
        }

        storeInMemory(image, for: url, storedAt: record.storedAt)
        return FeedIconCacheLookup(
            image: image,
            isStale: isStale(record.storedAt)
        )
    }

    func refresh(for url: URL) async -> UIImage? {
        guard shouldAttemptRefresh(for: url) else { return nil }

        do {
            let data = try await repository.fetch(for: url)
            guard !data.isEmpty else {
                throw FeedIconCacheError.emptyResponse
            }
            guard data.count <= maximumResponseSize else {
                throw FeedIconCacheError.responseTooLarge
            }
            guard let image = FeedIconImageDecoder.decode(
                data,
                maximumPixelSize: maximumPixelSize
            ) else {
                throw FeedIconCacheError.undecodableImage
            }

            let storedAt = now()
            await repository.store(data, for: url, storedAt: storedAt)
            storeInMemory(image, for: url, storedAt: storedAt)
            failedRefreshes[url] = nil
            return image
        } catch {
            failedRefreshes[url] = now()
            return nil
        }
    }

    func removeAll() async {
        memoryCache.removeAllObjects()
        failedRefreshes.removeAll()
        await repository.removeAll()
    }

    private func isStale(_ storedAt: Date) -> Bool {
        now().timeIntervalSince(storedAt) >= freshnessInterval
    }

    private func shouldAttemptRefresh(for url: URL) -> Bool {
        guard let failedAt = failedRefreshes[url] else { return true }
        return now().timeIntervalSince(failedAt) >= retryInterval
    }

    private func storeInMemory(_ image: UIImage, for url: URL, storedAt: Date) {
        let entry = FeedIconMemoryEntry(image: image, storedAt: storedAt)
        memoryCache.setObject(entry, forKey: url as NSURL, cost: image.memoryCost)
    }

    nonisolated static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return cachesURL
            .appendingPathComponent("FeedIcons", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    nonisolated static func liveFetcher(maximumResponseSize: Int) -> FeedIconFetcher {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        return { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw FeedIconCacheError.unsupportedURL
            }

            var request = URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 15
            )
            request.setValue("image/*, */*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Flux/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw FeedIconCacheError.invalidResponse
            }
            guard (200 ... 299).contains(response.statusCode) else {
                throw FeedIconCacheError.httpStatus(response.statusCode)
            }
            if response.expectedContentLength > Int64(maximumResponseSize) {
                throw FeedIconCacheError.responseTooLarge
            }
            guard !data.isEmpty else {
                throw FeedIconCacheError.emptyResponse
            }
            guard data.count <= maximumResponseSize else {
                throw FeedIconCacheError.responseTooLarge
            }
            return data
        }
    }
}

private final class FeedIconMemoryEntry: NSObject {
    let image: UIImage
    let storedAt: Date

    init(image: UIImage, storedAt: Date) {
        self.image = image
        self.storedAt = storedAt
    }
}

private struct FeedIconDiskRecord: Sendable {
    let data: Data
    let storedAt: Date
}

private actor FeedIconRepository {
    private let directoryURL: URL
    private let diskLimit: Int
    private let fetcher: FeedIconFetcher
    private var inFlightFetches: [URL: Task<Data, Error>] = [:]

    init(
        directoryURL: URL,
        diskLimit: Int,
        fetcher: @escaping FeedIconFetcher
    ) {
        self.directoryURL = directoryURL
        self.diskLimit = max(0, diskLimit)
        self.fetcher = fetcher
    }

    func record(for url: URL) -> FeedIconDiskRecord? {
        let fileURL = fileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let storedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FeedIconDiskRecord(data: data, storedAt: storedAt)
    }

    func fetch(for url: URL) async throws -> Data {
        if let existing = inFlightFetches[url] {
            return try await existing.value
        }

        let fetcher = fetcher
        let task = Task { try await fetcher(url) }
        inFlightFetches[url] = task
        defer { inFlightFetches[url] = nil }
        return try await task.value
    }

    func store(_ data: Data, for url: URL, storedAt: Date) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = fileURL(for: url)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: storedAt],
                ofItemAtPath: fileURL.path
            )
            pruneIfNeeded()
        } catch {
            // The memory cache remains usable when disk persistence is unavailable.
        }
    }

    func removeRecord(for url: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: url))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var entries: [(url: URL, size: Int, storedAt: Date)] = []
        var totalSize = 0
        for fileURL in fileURLs {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            let size = values.fileSize ?? 0
            entries.append((fileURL, size, values.contentModificationDate ?? .distantPast))
            totalSize += size
        }

        guard totalSize > diskLimit else { return }
        for entry in entries.sorted(by: { $0.storedAt < $1.storedAt }) {
            try? FileManager.default.removeItem(at: entry.url)
            totalSize -= entry.size
            if totalSize <= diskLimit { break }
        }
    }
}

private enum FeedIconImageDecoder {
    static func decode(_ data: Data, maximumPixelSize: Int) -> UIImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

private extension UIImage {
    var memoryCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
