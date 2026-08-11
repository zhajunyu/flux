//
//  FeedIconCacheTests.swift
//  fluxTests
//
//  Created by Codex on 2026/8/11.
//

import UIKit
import XCTest
@testable import flux

final class FeedIconCacheTests: XCTestCase {
    @MainActor
    func testRepeatedLookupUsesMemoryWithoutAnotherFetch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = makePNG(color: .red)
        let probe = IconFetchProbe(results: [.success(data)])
        let cache = makeCache(directory: directory, probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.com/icon.png"))

        let missing = await cache.lookup(for: url)
        XCTAssertNil(missing.image)
        XCTAssertTrue(missing.isStale)
        let refreshed = await cache.refresh(for: url)
        XCTAssertNotNil(refreshed)

        let cached = await cache.lookup(for: url)
        XCTAssertNotNil(cached.image)
        XCTAssertFalse(cached.isStale)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testDiskCacheSurvivesCacheRecreationAndOfflineLookup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = makePNG(color: .green)
        let onlineProbe = IconFetchProbe(results: [.success(data)])
        let url = try XCTUnwrap(URL(string: "https://example.com/persistent.png"))

        var cache: FeedIconCache? = makeCache(directory: directory, probe: onlineProbe)
        let downloaded = await cache?.refresh(for: url)
        XCTAssertNotNil(downloaded)
        cache = nil

        let offlineProbe = IconFetchProbe(results: [.failure(.offline)])
        let recreatedCache = makeCache(directory: directory, probe: offlineProbe)
        let cached = await recreatedCache.lookup(for: url)

        XCTAssertNotNil(cached.image)
        XCTAssertFalse(cached.isStale)
        let offlineCallCount = await offlineProbe.callCount()
        XCTAssertEqual(offlineCallCount, 0)
    }

    @MainActor
    func testConcurrentRefreshesAreCoalesced() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconFetchProbe(
            results: [.success(makePNG(color: .blue))],
            delay: .milliseconds(100)
        )
        let cache = makeCache(directory: directory, probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.com/coalesced.png"))

        let first = Task { @MainActor in
            await cache.refresh(for: url) != nil
        }
        let second = Task { @MainActor in
            await cache.refresh(for: url) != nil
        }

        let firstResult = await first.value
        let secondResult = await second.value
        let callCount = await probe.callCount()
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testStaleLookupReturnsOldImageBeforeRefreshReplacesIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedTestClock(date: Date(timeIntervalSince1970: 1_000))
        let firstData = makePNG(color: .red)
        let secondData = makePNG(color: .blue)
        let probe = IconFetchProbe(results: [.success(firstData), .success(secondData)])
        let cache = makeCache(directory: directory, clock: clock, probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.com/stale.png"))

        let initialRefresh = await cache.refresh(for: url)
        let firstImage = try XCTUnwrap(initialRefresh)
        clock.advance(by: FeedIconCache.defaultFreshnessInterval + 1)

        let stale = await cache.lookup(for: url)
        XCTAssertNotNil(stale.image)
        XCTAssertTrue(stale.isStale)

        let refreshed = await cache.refresh(for: url)
        let refreshedImage = try XCTUnwrap(refreshed)
        let freshLookup = await cache.lookup(for: url)
        let callCount = await probe.callCount()
        XCTAssertNotEqual(firstImage.pngData(), refreshedImage.pngData())
        XCTAssertFalse(freshLookup.isStale)
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testFailedRefreshKeepsStaleImageAndUsesRetryCooldown() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedTestClock(date: Date(timeIntervalSince1970: 2_000))
        let probe = IconFetchProbe(results: [
            .success(makePNG(color: .orange)),
            .failure(.offline),
            .success(makePNG(color: .purple)),
        ])
        let cache = makeCache(directory: directory, clock: clock, probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.com/offline.png"))

        let initialRefresh = await cache.refresh(for: url)
        XCTAssertNotNil(initialRefresh)
        clock.advance(by: FeedIconCache.defaultFreshnessInterval + 1)
        let failedRefresh = await cache.refresh(for: url)
        let suppressedRefresh = await cache.refresh(for: url)
        XCTAssertNil(failedRefresh)
        XCTAssertNil(suppressedRefresh)

        let stale = await cache.lookup(for: url)
        XCTAssertNotNil(stale.image)
        XCTAssertTrue(stale.isStale)
        let callsDuringCooldown = await probe.callCount()
        XCTAssertEqual(callsDuringCooldown, 2)

        clock.advance(by: FeedIconCache.defaultRetryInterval + 1)
        let recoveredRefresh = await cache.refresh(for: url)
        let recoveredCallCount = await probe.callCount()
        XCTAssertNotNil(recoveredRefresh)
        XCTAssertEqual(recoveredCallCount, 3)
    }

    @MainActor
    func testInvalidAndOversizedImagesAreNotPersisted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconFetchProbe(results: [
            .success(Data("not an image".utf8)),
            .success(Data(repeating: 0, count: 33)),
        ])
        let clock = LockedTestClock(date: Date(timeIntervalSince1970: 3_000))
        let cache = makeCache(
            directory: directory,
            clock: clock,
            retryInterval: 0,
            maximumResponseSize: 32,
            probe: probe
        )
        let invalidURL = try XCTUnwrap(URL(string: "https://example.com/invalid.png"))
        let oversizedURL = try XCTUnwrap(URL(string: "https://example.com/large.png"))

        let invalidRefresh = await cache.refresh(for: invalidURL)
        let oversizedRefresh = await cache.refresh(for: oversizedURL)
        XCTAssertNil(invalidRefresh)
        XCTAssertNil(oversizedRefresh)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    @MainActor
    func testDiskLimitPrunesOldestIcon() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = LockedTestClock(date: Date(timeIntervalSince1970: 4_000))
        let firstData = makePNG(color: .cyan)
        let secondData = makePNG(color: .magenta)
        let probe = IconFetchProbe(results: [.success(firstData), .success(secondData)])
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.png"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.png"))
        let cache = makeCache(
            directory: directory,
            clock: clock,
            diskLimit: max(firstData.count, secondData.count),
            probe: probe
        )

        let firstRefresh = await cache.refresh(for: firstURL)
        XCTAssertNotNil(firstRefresh)
        clock.advance(by: 1)
        let secondRefresh = await cache.refresh(for: secondURL)
        XCTAssertNotNil(secondRefresh)

        let offlineProbe = IconFetchProbe(results: [.failure(.offline)])
        let recreatedCache = makeCache(directory: directory, clock: clock, probe: offlineProbe)
        let firstLookup = await recreatedCache.lookup(for: firstURL)
        let secondLookup = await recreatedCache.lookup(for: secondURL)
        XCTAssertNil(firstLookup.image)
        XCTAssertNotNil(secondLookup.image)
    }

    @MainActor
    func testChangedURLUsesSeparateCacheEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconFetchProbe(results: [
            .success(makePNG(color: .brown)),
            .success(makePNG(color: .yellow)),
        ])
        let cache = makeCache(directory: directory, probe: probe)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/icon-v1.png"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/icon-v2.png"))

        let firstRefresh = await cache.refresh(for: firstURL)
        let secondRefresh = await cache.refresh(for: secondURL)
        let firstLookup = await cache.lookup(for: firstURL)
        let secondLookup = await cache.lookup(for: secondURL)
        let callCount = await probe.callCount()
        XCTAssertNotNil(firstRefresh)
        XCTAssertNotNil(secondRefresh)
        XCTAssertNotNil(firstLookup.image)
        XCTAssertNotNil(secondLookup.image)
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testCorruptDiskEntryIsRemovedAndTreatedAsMissing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconFetchProbe(results: [.success(makePNG(color: .systemPink))])
        let url = try XCTUnwrap(URL(string: "https://example.com/corrupt.png"))

        var cache: FeedIconCache? = makeCache(directory: directory, probe: probe)
        let downloaded = await cache?.refresh(for: url)
        XCTAssertNotNil(downloaded)
        cache = nil

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let cacheFile = try XCTUnwrap(files.first)
        try Data("corrupt".utf8).write(to: cacheFile, options: .atomic)

        let recreatedCache = makeCache(directory: directory, probe: probe)
        let lookup = await recreatedCache.lookup(for: url)
        XCTAssertNil(lookup.image)
        XCTAssertTrue(lookup.isStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @MainActor
    func testCancellingCallerDoesNotCancelSharedDownload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = IconFetchProbe(
            results: [.success(makePNG(color: .systemTeal))],
            delay: .milliseconds(100)
        )
        let cache = makeCache(directory: directory, probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.com/cancelled-view.png"))

        let loadTask = Task { @MainActor in
            await cache.refresh(for: url) != nil
        }
        while await probe.callCount() == 0 {
            await Task.yield()
        }
        loadTask.cancel()
        _ = await loadTask.value

        let cached = await cache.lookup(for: url)
        XCTAssertNotNil(cached.image)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    private func makeCache(
        directory: URL,
        clock: LockedTestClock = LockedTestClock(date: Date()),
        freshnessInterval: TimeInterval = FeedIconCache.defaultFreshnessInterval,
        retryInterval: TimeInterval = FeedIconCache.defaultRetryInterval,
        diskLimit: Int = FeedIconCache.defaultDiskLimit,
        maximumResponseSize: Int = FeedIconCache.defaultMaximumResponseSize,
        probe: IconFetchProbe
    ) -> FeedIconCache {
        FeedIconCache(
            directoryURL: directory,
            freshnessInterval: freshnessInterval,
            retryInterval: retryInterval,
            diskLimit: diskLimit,
            maximumResponseSize: maximumResponseSize,
            now: { clock.now() },
            fetcher: { url in try await probe.fetch(url) }
        )
    }

    @MainActor
    private func makePNG(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum IconFetchTestError: Error, Sendable {
    case offline
}

private actor IconFetchProbe {
    enum Result: Sendable {
        case success(Data)
        case failure(IconFetchTestError)
    }

    private let results: [Result]
    private let delay: Duration
    private var calls = 0

    init(results: [Result], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func fetch(_ url: URL) async throws -> Data {
        _ = url
        let result = results[min(calls, results.count - 1)]
        calls += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(interval)
        }
    }
}
