import AgentBarCore
import Foundation
import Testing
@testable import AgentBar

@Test
func quotaHistoryRecordsInitialChangesAndFifteenMinuteHeartbeat() async throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let account = fixture.account(provider: .codex, name: "primary")
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    let initial = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(provider: .codex, usedPercent: 10, updatedAt: start),
        sampledAt: start
    )
    #expect(initial.insertedSampleCount == 1)

    let unchanged = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(provider: .codex, usedPercent: 10, updatedAt: start.addingTimeInterval(60)),
        sampledAt: start.addingTimeInterval(60)
    )
    #expect(unchanged.insertedSampleCount == 0)

    let jitter = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            usedPercent: 10.05,
            usedLabel: "10% used",
            remainingLabel: "90% left",
            updatedAt: start.addingTimeInterval(120)
        ),
        sampledAt: start.addingTimeInterval(120)
    )
    #expect(jitter.insertedSampleCount == 0)

    let changed = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            usedPercent: 10.1,
            usedLabel: "10% used",
            remainingLabel: "90% left",
            updatedAt: start.addingTimeInterval(180)
        ),
        sampledAt: start.addingTimeInterval(180)
    )
    #expect(changed.insertedSampleCount == 1)

    let heartbeatDate = start.addingTimeInterval(180 + QuotaHistoryStore.samplingInterval)
    let heartbeat = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            usedPercent: 10.1,
            usedLabel: "10% used",
            remainingLabel: "90% left",
            updatedAt: heartbeatDate
        ),
        sampledAt: heartbeatDate
    )
    #expect(heartbeat.insertedSampleCount == 1)

    let historyAccount = try #require(await fixture.store.accounts().first)
    let window = try #require(await fixture.store.windows(for: historyAccount.accountKey).first)
    let samples = try await fixture.store.samples(for: window.id, startingAt: nil)
    #expect(samples.map(\.eventKind) == [.initial, .changed, .interval])
    #expect(samples.last?.usedLabel == "10% used")
    #expect(samples.last?.remainingLabel == "90% left")
}

@Test
func quotaHistoryUsesScheduleChangesAsResetEvents() async throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let account = fixture.account(provider: .gemini, name: "events")
    let start = Date(timeIntervalSince1970: 1_800_100_000)

    let initialMetrics = [
        // No reset time, so a balance jump can't also trigger schedule change.
        historyMetric(id: "balance-jump", usedPercent: 50, resetsAt: nil),
        historyMetric(id: "schedule", usedPercent: 50, resetsAt: start.addingTimeInterval(60 * 60)),
    ]
    _ = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(provider: .gemini, metrics: initialMetrics, updatedAt: start),
        sampledAt: start
    )

    let next = start.addingTimeInterval(6 * 60)
    let updatedMetrics = [
        // A balance jump alone remains a plain change. Only a meaningful reset
        // schedule change identifies a reset.
        historyMetric(id: "balance-jump", usedPercent: 0, resetsAt: nil),
        historyMetric(id: "schedule", usedPercent: 50, resetsAt: next.addingTimeInterval(2 * 60 * 60)),
    ]
    _ = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(provider: .gemini, metrics: updatedMetrics, updatedAt: next),
        sampledAt: next
    )

    let historyAccount = try #require(await fixture.store.accounts().first)
    let windows = try await fixture.store.windows(for: historyAccount.accountKey)
    let events = Dictionary(uniqueKeysWithValues: windows.map { ($0.metricKey, $0.latestSample?.eventKind) })
    #expect(events["balance-jump"] == .changed)
    #expect(events["schedule"] == .reset)
}

@Test
func quotaHistoryTreatsRollingResetCountdownAsUnchanged() async throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let account = fixture.account(provider: .codex, name: "rolling-reset")
    let start = Date(timeIntervalSince1970: 1_800_150_000)

    _ = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            metrics: [
                historyMetric(id: "rolling", usedPercent: 0, resetsAt: start.addingTimeInterval(5 * 60 * 60)),
            ],
            updatedAt: start
        ),
        sampledAt: start
    )

    let fiveSecondsLater = start.addingTimeInterval(5)
    let rollingUpdate = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            metrics: [
                historyMetric(
                    id: "rolling",
                    usedPercent: 0,
                    resetsAt: fiveSecondsLater.addingTimeInterval(5 * 60 * 60)
                ),
            ],
            updatedAt: fiveSecondsLater
        ),
        sampledAt: fiveSecondsLater
    )
    #expect(rollingUpdate.insertedSampleCount == 0)

    let heartbeatDate = start.addingTimeInterval(QuotaHistoryStore.samplingInterval)
    let heartbeat = try await fixture.store.record(
        account: account,
        snapshot: historySnapshot(
            provider: .codex,
            metrics: [
                historyMetric(
                    id: "rolling",
                    usedPercent: 0,
                    resetsAt: heartbeatDate.addingTimeInterval(5 * 60 * 60)
                ),
            ],
            updatedAt: heartbeatDate
        ),
        sampledAt: heartbeatDate
    )
    #expect(heartbeat.insertedSampleCount == 1)

    let historyAccount = try #require(await fixture.store.accounts().first)
    let window = try #require(await fixture.store.windows(for: historyAccount.accountKey).first)
    let samples = try await fixture.store.samples(for: window.id, startingAt: nil)
    #expect(samples.map(\.eventKind) == [.initial, .interval])
}

@Test
func quotaHistoryKeepsAccountsAndDynamicWindowsIndependent() async throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let start = Date(timeIntervalSince1970: 1_800_200_000)
    let first = fixture.account(provider: .gemini, name: "one")
    let second = fixture.account(provider: .gemini, name: "two")

    _ = try await fixture.store.record(
        account: first,
        snapshot: historySnapshot(
            provider: .gemini,
            accountLabel: "one@example.com",
            metrics: [
                historyMetric(id: "flash", title: "Gemini Flash", usedPercent: 20),
                historyMetric(id: "pro", title: "Gemini Pro", usedPercent: 80),
            ],
            updatedAt: start
        ),
        sampledAt: start
    )
    _ = try await fixture.store.record(
        account: second,
        snapshot: historySnapshot(
            provider: .gemini,
            accountLabel: "two@example.com",
            metrics: [historyMetric(id: "flash", title: "Gemini Flash", usedPercent: 30)],
            updatedAt: start
        ),
        sampledAt: start
    )

    let accounts = try await fixture.store.accounts()
    #expect(accounts.count == 2)
    let firstAccount = try #require(accounts.first { $0.displayLabel == "one@example.com" })
    let secondAccount = try #require(accounts.first { $0.displayLabel == "two@example.com" })
    let firstWindows = try await fixture.store.windows(for: firstAccount.accountKey)
    let secondWindows = try await fixture.store.windows(for: secondAccount.accountKey)
    #expect(firstWindows.count == 2)
    #expect(secondWindows.count == 1)

    // Removing an account configuration does not call the history store, so its rows remain.
    #expect(try await fixture.store.accounts().contains { $0.accountKey == firstAccount.accountKey })
}

@Test
func quotaHistoryHandlesUnlimitedAndDeletesByCutoff() async throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let recentDate = oldDate.addingTimeInterval(100 * 24 * 60 * 60)
    let oldAccount = fixture.account(provider: .githubCopilot, name: "old")
    let recentAccount = fixture.account(provider: .githubCopilot, name: "recent")

    _ = try await fixture.store.record(
        account: oldAccount,
        snapshot: historySnapshot(
            provider: .githubCopilot,
            accountLabel: "old@example.com",
            usedPercent: 0,
            usedLabel: "Unlimited",
            remainingLabel: "Unlimited",
            updatedAt: oldDate
        ),
        sampledAt: oldDate
    )
    _ = try await fixture.store.record(
        account: recentAccount,
        snapshot: historySnapshot(
            provider: .githubCopilot,
            accountLabel: "recent@example.com",
            usedPercent: 25,
            updatedAt: recentDate
        ),
        sampledAt: recentDate
    )

    let oldHistoryAccount = try #require(
        await fixture.store.accounts().first { $0.displayLabel == "old@example.com" }
    )
    let oldWindow = try #require(await fixture.store.windows(for: oldHistoryAccount.accountKey).first)
    #expect(oldWindow.latestSample?.isUnlimited == true)
    #expect(oldWindow.latestSample?.remainingPercent == nil)

    let deleted = try await fixture.store.deleteSamples(olderThan: oldDate.addingTimeInterval(50 * 24 * 60 * 60))
    #expect(deleted == 1)
    let remainingAccounts = try await fixture.store.accounts()
    #expect(remainingAccounts.map(\.displayLabel) == ["recent@example.com"])
    #expect(try await fixture.store.stats().sampleCount == 1)
}

@Test
func quotaHistoryDownsamplingPreservesEndpointsAndExtremes() {
    let start = Date(timeIntervalSince1970: 1_800_300_000)
    let resetIndex = 1_111
    let samples = (0 ..< 2_000).map { index in
        QuotaHistorySample(
            windowID: 1,
            sampledAt: start.addingTimeInterval(Double(index * 60)),
            usedBasisPoints: index % 500,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: nil,
            isUnlimited: false,
            eventKind: index == resetIndex ? .reset : .interval
        )
    }

    let result = QuotaHistoryDownsampler.downsample(samples)
    #expect(result.count < samples.count)
    #expect(result.count <= 400)
    #expect(result.first?.sampledAt == samples.first?.sampledAt)
    #expect(result.last?.sampledAt == samples.last?.sampledAt)
    #expect(result.contains { $0.eventKind == .reset && $0.sampledAt == samples[resetIndex].sampledAt })
}

@Test
func quotaHistoryNormalizesLegacyRollingScheduleEvents() {
    let start = Date(timeIntervalSince1970: 1_800_300_000)
    let fiveHours: TimeInterval = 5 * 60 * 60
    let samples: [QuotaHistorySample] = [
        .init(
            windowID: 1,
            sampledAt: start,
            usedBasisPoints: 2_000,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: start.addingTimeInterval(fiveHours),
            isUnlimited: false,
            eventKind: .initial
        ),
        .init(
            windowID: 1,
            sampledAt: start.addingTimeInterval(5),
            usedBasisPoints: 2_000,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: start.addingTimeInterval(fiveHours + 5),
            isUnlimited: false,
            eventKind: .reset
        ),
        .init(
            windowID: 1,
            sampledAt: start.addingTimeInterval(10),
            usedBasisPoints: 2_000,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: start.addingTimeInterval(fiveHours + 10),
            isUnlimited: false,
            eventKind: .reset
        ),
        .init(
            windowID: 1,
            sampledAt: start.addingTimeInterval(15),
            usedBasisPoints: 0,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: start.addingTimeInterval((2 * fiveHours) + 10),
            isUnlimited: false,
            eventKind: .reset
        ),
    ]

    let normalized = QuotaHistoryResetSchedule.normalizeEvents(in: samples)
    #expect(normalized.map(\.eventKind) == [.initial, .changed, .changed, .reset])
}

@Test
@MainActor
func quotaHistoryManagerDefaultsEnabledAndPersistsPreference() throws {
    let fixture = try HistoryStoreFixture(name: #function)
    defer { fixture.cleanup() }
    let suiteName = "AgentBarHistoryTests.\(#function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = QuotaHistoryManager(store: fixture.store, userDefaults: defaults)
    #expect(first.isEnabled)
    first.isEnabled = false

    let second = QuotaHistoryManager(store: fixture.store, userDefaults: defaults)
    #expect(!second.isEnabled)
}

private struct HistoryStoreFixture {
    let directory: URL
    let store: QuotaHistoryStore

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentBarHistoryTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = QuotaHistoryStore(databaseURL: directory.appending(path: "history.sqlite3"))
    }

    func account(provider: AgentProviderKind, name: String) -> ConfiguredAgentAccount {
        ConfiguredAgentAccount(
            provider: provider,
            directory: ConfiguredAccountDirectory(path: directory.appending(path: name).path)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func historySnapshot(
    provider: AgentProviderKind,
    accountLabel: String = "history@example.com",
    usedPercent: Double,
    usedLabel: String? = nil,
    remainingLabel: String? = nil,
    updatedAt: Date
) -> AgentQuotaSnapshot {
    historySnapshot(
        provider: provider,
        accountLabel: accountLabel,
        metrics: [
            historyMetric(
                id: "primary",
                usedPercent: usedPercent,
                usedLabel: usedLabel,
                remainingLabel: remainingLabel
            ),
        ],
        updatedAt: updatedAt
    )
}

private func historySnapshot(
    provider: AgentProviderKind,
    accountLabel: String = "history@example.com",
    metrics: [AgentQuotaMetric],
    updatedAt: Date
) -> AgentQuotaSnapshot {
    AgentQuotaSnapshot(
        provider: provider,
        accountLabel: accountLabel,
        planType: "Test",
        modelName: nil,
        sourceSummary: "History test",
        metrics: metrics,
        updatedAt: updatedAt
    )
}

private func historyMetric(
    id: String,
    title: String = "Quota window",
    usedPercent: Double,
    usedLabel: String? = nil,
    remainingLabel: String? = nil,
    resetsAt: Date? = nil
) -> AgentQuotaMetric {
    AgentQuotaMetric(
        id: id,
        title: title,
        usedPercent: usedPercent,
        usedLabel: usedLabel ?? "\(Int(usedPercent.rounded()))% used",
        remainingLabel: remainingLabel ?? "\(Int((100 - usedPercent).rounded()))% left",
        resetsAt: resetsAt
    )
}
