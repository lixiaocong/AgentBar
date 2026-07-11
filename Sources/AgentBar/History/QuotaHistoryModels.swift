import CryptoKit
import Foundation

#if canImport(AgentBarCore)
import AgentBarCore
#endif

enum QuotaHistoryEventKind: Int, Codable, CaseIterable, Sendable {
    case initial = 0
    case interval = 1
    case changed = 2
    // Internal candidate only. The query path confirms whether it was a reset.
    case scheduleChanged = 3
    // Internal candidate only. Balance recoveries need a second successful
    // sample so transient provider responses do not create false resets.
    // Raw value 4 belonged to the retired `likelyReset` event and must remain
    // unused so legacy databases do not reinterpret those rows as candidates.
    case balanceRecovery = 6
    // Internal candidate only. A sudden 0% remaining value needs a second
    // successful sample before History treats the window as exhausted.
    case terminalExhaustion = 7
    // Keep raw value 5 so existing databases remain readable. New reset events
    // are derived at query time instead of being persisted eagerly.
    case reset = 5
}

enum QuotaHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour
    case halfDay
    case day
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1h"
        case .halfDay: return "12h"
        case .day: return "1d"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    func startDate(relativeTo now: Date) -> Date? {
        let seconds: TimeInterval
        switch self {
        case .hour:
            seconds = 60 * 60
        case .halfDay:
            seconds = 12 * 60 * 60
        case .day:
            seconds = 24 * 60 * 60
        case .week:
            seconds = 7 * 24 * 60 * 60
        case .month:
            seconds = 30 * 24 * 60 * 60
        case .all:
            return nil
        }

        return now.addingTimeInterval(-seconds)
    }
}

struct QuotaHistoryAccount: Identifiable, Equatable, Sendable {
    let accountKey: String
    let provider: AgentProviderKind
    let displayLabel: String
    let planType: String?
    let firstSeenAt: Date
    let lastSeenAt: Date

    var id: String { accountKey }
}

struct QuotaHistoryWindow: Identifiable, Equatable, Sendable {
    let id: Int64
    let accountKey: String
    let metricKey: String
    let title: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let latestSample: QuotaHistorySample?
}

struct QuotaHistorySample: Identifiable, Equatable, Sendable {
    let windowID: Int64
    let sampledAt: Date
    let usedBasisPoints: Int?
    let usedLabel: String?
    let remainingLabel: String?
    let resetsAt: Date?
    let isUnlimited: Bool
    let eventKind: QuotaHistoryEventKind

    var id: String {
        "\(windowID)-\(Int64((sampledAt.timeIntervalSince1970 * 1_000).rounded()))"
    }

    var usedPercent: Double? {
        usedBasisPoints.map { Double($0) / 100 }
    }

    var remainingPercent: Double? {
        usedPercent.map { max(0, 100 - $0) }
    }

    func replacingEventKind(_ eventKind: QuotaHistoryEventKind) -> QuotaHistorySample {
        QuotaHistorySample(
            windowID: windowID,
            sampledAt: sampledAt,
            usedBasisPoints: usedBasisPoints,
            usedLabel: usedLabel,
            remainingLabel: remainingLabel,
            resetsAt: resetsAt,
            isUnlimited: isUnlimited,
            eventKind: eventKind
        )
    }
}

enum QuotaHistoryResetSchedule {
    static let toleranceMilliseconds: Int64 = 5 * 60 * 1_000

    private static let deadlineGraceMilliseconds: Int64 = 2 * 60 * 1_000
    private static let balanceImprovementBasisPoints = 10

    static func changed(
        previousSampledAtMilliseconds: Int64,
        previousResetMilliseconds: Int64?,
        sampledAtMilliseconds: Int64,
        resetMilliseconds: Int64?
    ) -> Bool {
        switch (previousResetMilliseconds, resetMilliseconds) {
        case (nil, nil):
            return false
        case (_?, nil), (nil, _?):
            return true
        case let (oldReset?, newReset?):
            let resetAdvance = newReset - oldReset
            guard abs(resetAdvance) >= toleranceMilliseconds else {
                return false
            }

            let sampleAdvance = sampledAtMilliseconds - previousSampledAtMilliseconds
            return abs(resetAdvance - sampleAdvance) >= toleranceMilliseconds
        }
    }

    /// Derives resets from confirmed schedule generations. Providers can briefly
    /// alternate between stale and current responses, so a changed schedule must
    /// be repeated by the following stored sample before it becomes authoritative.
    static func normalizeEvents(in samples: [QuotaHistorySample]) -> [QuotaHistorySample] {
        let confirmedSamples = confirmedBalanceRecoveries(
            in: confirmedTerminalExhaustions(
                in: samples.sorted { $0.sampledAt < $1.sampledAt }
            )
        )
        var normalized = confirmedSamples
            .map { sample in
                switch sample.eventKind {
                case .scheduleChanged, .balanceRecovery, .terminalExhaustion, .reset:
                    return sample.replacingEventKind(.changed)
                case .initial, .interval, .changed:
                    return sample
                }
            }
        guard normalized.count > 1 else { return normalized }

        var stableIndex = 0
        for index in normalized.indices.dropFirst() {
            let stable = normalized[stableIndex]
            let current = normalized[index]

            if schedulesAreEquivalent(stable, current) {
                stableIndex = index
                continue
            }

            let confirmationIndex = normalized.index(after: index)
            guard confirmationIndex < normalized.endIndex,
                  schedulesAreEquivalent(current, normalized[confirmationIndex]) else {
                continue
            }

            if isResetTransition(from: stable, to: current) {
                normalized[index] = current.replacingEventKind(.reset)
            }
            stableIndex = index
        }

        return normalized
    }

    /// A provider can briefly report a fully exhausted window and immediately
    /// return to the prior balance. Hide that terminal point unless the next
    /// successful sample confirms both exhaustion and the schedule generation.
    private static func confirmedTerminalExhaustions(
        in samples: [QuotaHistorySample]
    ) -> [QuotaHistorySample] {
        guard samples.count > 1 else { return samples }

        var confirmed: [QuotaHistorySample] = []
        confirmed.reserveCapacity(samples.count)

        for index in samples.indices {
            let current = samples[index]
            guard let previous = confirmed.last,
                  isTerminalExhaustion(from: previous, to: current) else {
                confirmed.append(current)
                continue
            }

            let confirmationIndex = samples.index(after: index)
            guard confirmationIndex < samples.endIndex,
                  exhaustionIsConfirmed(
                    candidate: current,
                    confirmation: samples[confirmationIndex]
                  ) else {
                continue
            }

            confirmed.append(current)
        }

        return confirmed
    }

    private static func isTerminalExhaustion(
        from previous: QuotaHistorySample,
        to current: QuotaHistorySample
    ) -> Bool {
        guard !previous.isUnlimited,
              !current.isUnlimited,
              let previousUsed = previous.usedBasisPoints,
              let currentUsed = current.usedBasisPoints else {
            return false
        }
        return previousUsed < 10_000 && currentUsed >= 10_000
    }

    private static func exhaustionIsConfirmed(
        candidate: QuotaHistorySample,
        confirmation: QuotaHistorySample
    ) -> Bool {
        guard !confirmation.isUnlimited,
              let confirmationUsed = confirmation.usedBasisPoints,
              confirmationUsed >= 10_000 else {
            return false
        }
        return schedulesAreEquivalent(candidate, confirmation)
    }

    /// A lower used balance means quota became available again. Keep that point
    /// only when the next successful sample reports the same schedule generation
    /// and still shows a meaningful improvement over the previous stable value.
    /// This also removes transient recovery points already stored by older builds.
    private static func confirmedBalanceRecoveries(
        in samples: [QuotaHistorySample]
    ) -> [QuotaHistorySample] {
        guard samples.count > 1 else { return samples }

        var confirmed: [QuotaHistorySample] = []
        confirmed.reserveCapacity(samples.count)

        for index in samples.indices {
            let current = samples[index]
            guard let previous = confirmed.last,
                  isBalanceRecovery(from: previous, to: current) else {
                confirmed.append(current)
                continue
            }

            let confirmationIndex = samples.index(after: index)
            guard confirmationIndex < samples.endIndex,
                  recoveryIsConfirmed(
                    from: previous,
                    candidate: current,
                    confirmation: samples[confirmationIndex]
                  ) else {
                continue
            }

            confirmed.append(current)
        }

        return confirmed
    }

    private static func isBalanceRecovery(
        from previous: QuotaHistorySample,
        to current: QuotaHistorySample
    ) -> Bool {
        guard !previous.isUnlimited,
              !current.isUnlimited,
              let previousUsed = previous.usedBasisPoints,
              let currentUsed = current.usedBasisPoints else {
            return false
        }
        return previousUsed - currentUsed >= balanceImprovementBasisPoints
    }

    private static func recoveryIsConfirmed(
        from previous: QuotaHistorySample,
        candidate: QuotaHistorySample,
        confirmation: QuotaHistorySample
    ) -> Bool {
        guard !confirmation.isUnlimited,
              let previousUsed = previous.usedBasisPoints,
              let confirmationUsed = confirmation.usedBasisPoints,
              previousUsed - confirmationUsed >= balanceImprovementBasisPoints else {
            return false
        }
        return schedulesAreEquivalent(candidate, confirmation)
    }

    private static func schedulesAreEquivalent(
        _ lhs: QuotaHistorySample,
        _ rhs: QuotaHistorySample
    ) -> Bool {
        switch (lhs.resetsAt, rhs.resetsAt) {
        case (nil, nil):
            return true
        case (_?, nil), (nil, _?):
            return false
        case let (lhsReset?, rhsReset?):
            let lhsResetMilliseconds = milliseconds(lhsReset)
            let rhsResetMilliseconds = milliseconds(rhsReset)
            if abs(rhsResetMilliseconds - lhsResetMilliseconds) < toleranceMilliseconds {
                return true
            }

            let lhsHorizon = lhsResetMilliseconds - milliseconds(lhs.sampledAt)
            let rhsHorizon = rhsResetMilliseconds - milliseconds(rhs.sampledAt)
            return abs(rhsHorizon - lhsHorizon) < toleranceMilliseconds
        }
    }

    private static func isResetTransition(
        from previous: QuotaHistorySample,
        to current: QuotaHistorySample
    ) -> Bool {
        let sampledAtMilliseconds = milliseconds(current.sampledAt)

        switch (previous.resetsAt, current.resetsAt) {
        case let (previousReset?, currentReset?):
            let previousResetMilliseconds = milliseconds(previousReset)
            let currentResetMilliseconds = milliseconds(currentReset)
            guard currentResetMilliseconds - previousResetMilliseconds >= toleranceMilliseconds else {
                return false
            }

            let deadlineReached = sampledAtMilliseconds >=
                previousResetMilliseconds - deadlineGraceMilliseconds
            let balanceImproved: Bool
            if let previousUsed = previous.usedBasisPoints,
               let currentUsed = current.usedBasisPoints {
                balanceImproved = previousUsed - currentUsed >= balanceImprovementBasisPoints
            } else {
                balanceImproved = false
            }
            return deadlineReached || balanceImproved

        case let (previousReset?, nil):
            return sampledAtMilliseconds >=
                milliseconds(previousReset) - deadlineGraceMilliseconds

        case (nil, _?), (nil, nil):
            // A new future deadline after an idle period starts a quota window;
            // it does not mean a previous quota window reset.
            return false
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

struct QuotaHistoryStats: Equatable, Sendable {
    static let empty = QuotaHistoryStats(sampleCount: 0, oldestSampleAt: nil, databaseSizeBytes: 0)

    let sampleCount: Int
    let oldestSampleAt: Date?
    let databaseSizeBytes: Int64
}

struct QuotaHistoryWriteResult: Equatable, Sendable {
    let insertedSampleCount: Int

    var didWriteSamples: Bool { insertedSampleCount > 0 }
}

enum QuotaHistoryIdentity {
    static func accountKey(for account: ConfiguredAgentAccount) -> String {
        let digest = SHA256.hash(data: Data(account.id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol QuotaHistoryRecording: AnyObject {
    func record(account: ConfiguredAgentAccount, snapshot: AgentQuotaSnapshot)
}

protocol QuotaHistoryQuerying: Sendable {
    func accounts() async throws -> [QuotaHistoryAccount]
    func windows(for accountKey: String) async throws -> [QuotaHistoryWindow]
    func samples(for windowID: Int64, startingAt: Date?) async throws -> [QuotaHistorySample]
    func stats() async throws -> QuotaHistoryStats
}

enum QuotaHistoryDownsampler {
    static let rawSampleLimit = 360
    private static let targetBucketCount = 96

    static func downsample(_ samples: [QuotaHistorySample]) -> [QuotaHistorySample] {
        guard samples.count > rawSampleLimit,
              let first = samples.first,
              let last = samples.last,
              last.sampledAt > first.sampledAt else {
            return samples
        }

        let duration = last.sampledAt.timeIntervalSince(first.sampledAt)
        let bucketDuration = max(1, duration / Double(targetBucketCount))
        var buckets: [Int: [QuotaHistorySample]] = [:]

        for sample in samples {
            let index = Int(sample.sampledAt.timeIntervalSince(first.sampledAt) / bucketDuration)
            buckets[index, default: []].append(sample)
        }

        var selected: [QuotaHistorySample] = []
        for index in buckets.keys.sorted() {
            guard let bucket = buckets[index],
                  let firstSample = bucket.first,
                  let lastSample = bucket.last else { continue }
            var candidates = [firstSample, lastSample]

            if let minimum = bucket.min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }) {
                candidates.append(minimum)
            }
            if let maximum = bucket.max(by: { ($0.remainingPercent ?? -1) < ($1.remainingPercent ?? -1) }) {
                candidates.append(maximum)
            }
            candidates.append(contentsOf: bucket.filter { $0.eventKind == .reset })
            selected.append(contentsOf: candidates)
        }

        var seen = Set<String>()
        return selected
            .sorted { $0.sampledAt < $1.sampledAt }
            .filter { seen.insert($0.id).inserted }
    }
}
