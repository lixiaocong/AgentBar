import Foundation
import Observation

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@MainActor
@Observable
final class QuotaHistoryManager: QuotaHistoryRecording {
    static let shared = QuotaHistoryManager()
    static let recordingEnabledDefaultsKey = "quotaHistoryRecordingEnabled"

    let store: QuotaHistoryStore

    private let userDefaults: UserDefaults
    private var hasStarted = false

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            userDefaults.set(isEnabled, forKey: Self.recordingEnabledDefaultsKey)
        }
    }

    private(set) var stats = QuotaHistoryStats.empty
    private(set) var lastError: String?
    private(set) var revision = 0
    private(set) var isMaintaining = false

    init(
        store: QuotaHistoryStore = QuotaHistoryStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Self.recordingEnabledDefaultsKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.recordingEnabledDefaultsKey)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshStats()
    }

    func record(account: ConfiguredAgentAccount, snapshot: AgentQuotaSnapshot) {
        guard isEnabled, !snapshot.metrics.isEmpty else { return }
        let store = store

        Task { [weak self] in
            do {
                let result = try await store.record(account: account, snapshot: snapshot)
                guard let self else { return }
                lastError = nil
                if result.didWriteSamples {
                    revision &+= 1
                    await reloadStats()
                }
            } catch {
                guard let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastError = message
                logError("[History] \(message)")
            }
        }
    }

    func accounts() async throws -> [QuotaHistoryAccount] {
        try await store.accounts()
    }

    func windows(for accountKey: String) async throws -> [QuotaHistoryWindow] {
        try await store.windows(for: accountKey)
    }

    func samples(for windowID: Int64, range: QuotaHistoryRange, now: Date = Date()) async throws -> [QuotaHistorySample] {
        let samples = try await store.samples(
            for: windowID,
            startingAt: range.startDate(relativeTo: now)
        )
        let normalizedSamples = QuotaHistoryResetSchedule.normalizeEvents(in: samples)
        return QuotaHistoryDownsampler.downsample(normalizedSamples)
    }

    func refreshStats() {
        Task { [weak self] in
            await self?.reloadStats()
        }
    }

    @discardableResult
    func clearHistory(olderThanDays days: Int, now: Date = Date()) async -> Bool {
        guard days > 0 else { return false }
        return await performMaintenance {
            let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
            _ = try await self.store.deleteSamples(olderThan: cutoff)
        }
    }

    @discardableResult
    func clearAllHistory() async -> Bool {
        await performMaintenance {
            _ = try await self.store.deleteAllSamples()
        }
    }

    @discardableResult
    func rebuildDatabase() async -> Bool {
        await performMaintenance {
            try await self.store.rebuildDatabase()
        }
    }

    private func performMaintenance(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        guard !isMaintaining else { return false }
        isMaintaining = true
        defer { isMaintaining = false }

        do {
            try await operation()
            lastError = nil
            revision &+= 1
            await reloadStats()
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            logError("[History] \(message)")
            return false
        }
    }

    private func reloadStats() async {
        do {
            stats = try await store.stats()
            lastError = nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            logError("[History] \(message)")
        }
    }
}
