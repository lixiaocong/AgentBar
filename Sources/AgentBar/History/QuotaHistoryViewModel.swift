import Foundation
import Observation

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@MainActor
@Observable
final class QuotaHistoryViewModel {
    private let model: AppModel
    private let manager: QuotaHistoryManager
    private var loadGeneration = 0

    var accounts: [QuotaHistoryAccount] = []
    var selectedAccountKey: String?
    var windows: [QuotaHistoryWindow] = []
    var samplesByWindowID: [Int64: [QuotaHistorySample]] = [:]
    var range: QuotaHistoryRange = .week
    var isLoading = false
    var errorMessage: String?

    init(model: AppModel, manager: QuotaHistoryManager) {
        self.model = model
        self.manager = manager
    }

    var selectedAccount: QuotaHistoryAccount? {
        accounts.first { $0.accountKey == selectedAccountKey }
    }

    func isConfigured(_ account: QuotaHistoryAccount) -> Bool {
        model.isHistoryAccountConfigured(account.accountKey)
    }

    func isCurrent(_ window: QuotaHistoryWindow) -> Bool {
        guard let selectedAccountKey else { return false }
        return model.currentHistoryMetricIDs(for: selectedAccountKey).contains(window.metricKey)
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        do {
            let loadedAccounts = try await manager.accounts()
                .sorted(by: Self.accountSort)
            guard generation == loadGeneration else { return }

            accounts = loadedAccounts
            if selectedAccountKey == nil || !loadedAccounts.contains(where: { $0.accountKey == selectedAccountKey }) {
                selectedAccountKey = loadedAccounts.first?.accountKey
            }
            try await loadSelectedAccount(generation: generation)
            guard generation == loadGeneration else { return }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            windows = []
            samplesByWindowID = [:]
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    func loadSelection() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        do {
            try await loadSelectedAccount(generation: generation)
            guard generation == loadGeneration else { return }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            windows = []
            samplesByWindowID = [:]
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    func loadRange() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        do {
            try await loadSamples(for: windows, generation: generation)
            guard generation == loadGeneration else { return }
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            samplesByWindowID = [:]
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    private func loadSelectedAccount(generation: Int) async throws {
        guard let selectedAccountKey else {
            windows = []
            samplesByWindowID = [:]
            return
        }

        let loadedWindows = try await manager.windows(for: selectedAccountKey)
        guard generation == loadGeneration else { return }
        windows = loadedWindows.sorted(by: Self.windowSort)
        try await loadSamples(for: windows, generation: generation)
    }

    private func loadSamples(
        for windows: [QuotaHistoryWindow],
        generation: Int
    ) async throws {
        var loadedSamples: [Int64: [QuotaHistorySample]] = [:]
        for window in windows {
            let samples = try await manager.samples(for: window.id, range: range)
            guard generation == loadGeneration else { return }
            loadedSamples[window.id] = samples
        }
        samplesByWindowID = loadedSamples
    }

    private static func accountSort(_ lhs: QuotaHistoryAccount, _ rhs: QuotaHistoryAccount) -> Bool {
        let leftProviderIndex = AgentProviderKind.allCases.firstIndex(of: lhs.provider) ?? .max
        let rightProviderIndex = AgentProviderKind.allCases.firstIndex(of: rhs.provider) ?? .max
        if leftProviderIndex != rightProviderIndex {
            return leftProviderIndex < rightProviderIndex
        }
        return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
    }

    private static func windowSort(_ lhs: QuotaHistoryWindow, _ rhs: QuotaHistoryWindow) -> Bool {
        if lhs.firstSeenAt != rhs.firstSeenAt {
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}
