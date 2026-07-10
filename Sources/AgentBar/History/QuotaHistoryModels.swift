import CryptoKit
import Foundation

#if canImport(AgentBarCore)
import AgentBarCore
#endif

enum QuotaHistoryEventKind: Int, Codable, CaseIterable, Sendable {
    case initial = 0
    case interval = 1
    case changed = 2
    case scheduleChanged = 5

    var title: String? {
        switch self {
        case .scheduleChanged:
            return "Reset schedule changed"
        case .initial, .interval, .changed:
            return nil
        }
    }
}

enum QuotaHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case quarter
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        case .year: return "1y"
        case .all: return "All"
        }
    }

    func startDate(relativeTo now: Date) -> Date? {
        let seconds: TimeInterval
        switch self {
        case .day:
            seconds = 24 * 60 * 60
        case .week:
            seconds = 7 * 24 * 60 * 60
        case .month:
            seconds = 30 * 24 * 60 * 60
        case .quarter:
            seconds = 90 * 24 * 60 * 60
        case .year:
            seconds = 365 * 24 * 60 * 60
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
            selected.append(contentsOf: candidates)
        }

        var seen = Set<String>()
        return selected
            .sorted { $0.sampledAt < $1.sampledAt }
            .filter { seen.insert($0.id).inserted }
    }
}

/// Detects quota resets at display time by finding samples where the remaining
/// balance jumps back up near full (`>= thresholdPercent`) after sitting below
/// the threshold. A single reset is emitted at the transition point, so a
/// sustained near-full plateau does not produce repeated markers.
enum QuotaHistoryResetDetector {
    /// A remaining percentage at or above this value counts as "near full".
    static let thresholdPercent: Double = 95

    static func resetDates(in samples: [QuotaHistorySample]) -> [Date] {
        let numeric = samples
            .filter { !$0.isUnlimited }
            .compactMap { sample -> (date: Date, remaining: Double)? in
                guard let remaining = sample.remainingPercent else { return nil }
                return (sample.sampledAt, remaining)
            }
            .sorted { $0.date < $1.date }

        var dates: [Date] = []
        var wasBelowThreshold = false
        for entry in numeric {
            if entry.remaining >= thresholdPercent {
                if wasBelowThreshold {
                    dates.append(entry.date)
                }
                wasBelowThreshold = false
            } else {
                wasBelowThreshold = true
            }
        }
        return dates
    }
}
