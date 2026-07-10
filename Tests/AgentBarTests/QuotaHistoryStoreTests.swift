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
func quotaHistoryRecordsBalanceJumpsAsChangedAndScheduleEvents() async throws {
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
        // Balance jumped from 50% used to 0% used (a reset), but the store no
        // longer classifies this — it is recorded as a plain change. Reset
        // detection happens at display time via QuotaHistoryResetDetector.
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
    // Balance jumps are stored as `.changed`; reset/likelyReset no longer exist.
    // The reset is detected later by QuotaHistoryResetDetector at display time.
    #expect(events["balance-jump"] == .changed)
    #expect(events["schedule"] == .scheduleChanged)
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
    let samples = (0 ..< 2_000).map { index in
        QuotaHistorySample(
            windowID: 1,
            sampledAt: start.addingTimeInterval(Double(index * 60)),
            usedBasisPoints: index % 500,
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: nil,
            isUnlimited: false,
            eventKind: .interval
        )
    }

    let result = QuotaHistoryDownsampler.downsample(samples)
    #expect(result.count < samples.count)
    #expect(result.count <= 400)
    #expect(result.first?.sampledAt == samples.first?.sampledAt)
    #expect(result.last?.sampledAt == samples.last?.sampledAt)
}

@Test
func quotaHistoryResetDetectorMarksJumpsAboveThreshold() {
    let start = Date(timeIntervalSince1970: 1_800_300_000)
    // remaining% sequence: 20 -> 22 -> 18 -> 98 -> 50 -> 97 -> 96
    let percents: [Double] = [20, 22, 18, 98, 50, 97, 96]
    let samples = percents.enumerated().map { index, remaining in
        QuotaHistorySample(
            windowID: 1,
            sampledAt: start.addingTimeInterval(Double(index * 60)),
            usedBasisPoints: Int((100 - remaining) * 100),
            usedLabel: nil,
            remainingLabel: nil,
            resetsAt: nil,
            isUnlimited: false,
            eventKind: .interval
        )
    }

    let resets = QuotaHistoryResetDetector.resetDates(in: samples)
    // Two transitions: 18->98 (reset) and 50->97 (reset). The 97->96 step is a
    // sustained near-full plateau, not a fresh reset, so no third marker.
    #expect(resets.count == 2)
    #expect(resets == [samples[3].sampledAt, samples[5].sampledAt])
}

@Test
func quotaHistoryResetDetectorIgnoresUnlimitedSamples() {
    let start = Date(timeIntervalSince1970: 1_800_300_000)
    let samples: [QuotaHistorySample] = [
        .init(windowID: 1, sampledAt: start, usedBasisPoints: 8000,
              usedLabel: nil, remainingLabel: nil, resetsAt: nil,
              isUnlimited: false, eventKind: .interval),
        // Unlimited samples carry no numeric remaining and must be skipped.
        .init(windowID: 1, sampledAt: start.addingTimeInterval(60), usedBasisPoints: nil,
              usedLabel: nil, remainingLabel: nil, resetsAt: nil,
              isUnlimited: true, eventKind: .changed),
    ]

    let resets = QuotaHistoryResetDetector.resetDates(in: samples)
    #expect(resets.isEmpty)
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
