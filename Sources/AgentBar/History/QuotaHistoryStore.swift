import Foundation
import SQLite3

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct QuotaHistoryStoreError: LocalizedError {
    let operation: String
    let message: String

    var errorDescription: String? {
        "Quota history \(operation) failed: \(message)"
    }
}

actor QuotaHistoryStore: QuotaHistoryQuerying {
    static let samplingInterval: TimeInterval = 15 * 60
    static let immediateChangeBasisPoints = 10
    private static let resetScheduleToleranceMilliseconds: Int64 = 60 * 1_000

    let databaseURL: URL

    private let fileManager: FileManager
    private var database: OpaquePointer?

    init(
        databaseURL: URL = QuotaHistoryStore.defaultDatabaseURL(),
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)

        return applicationSupport
            .appending(path: "AgentBar", directoryHint: .isDirectory)
            .appending(path: "quota-history.sqlite3", directoryHint: .notDirectory)
    }

    func record(
        account: ConfiguredAgentAccount,
        snapshot: AgentQuotaSnapshot,
        sampledAt: Date? = nil
    ) async throws -> QuotaHistoryWriteResult {
        guard !snapshot.metrics.isEmpty else {
            return QuotaHistoryWriteResult(insertedSampleCount: 0)
        }

        let database = try openDatabaseIfNeeded()
        let timestamp = sampledAt ?? snapshot.updatedAt
        let sampledAtMilliseconds = Self.milliseconds(timestamp)
        let accountKey = QuotaHistoryIdentity.accountKey(for: account)

        try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
        do {
            try ensureAccount(
                key: accountKey,
                provider: account.provider,
                displayLabel: snapshot.accountLabel,
                planType: snapshot.planType,
                timestamp: sampledAtMilliseconds,
                database: database
            )

            var insertedSampleCount = 0
            for metric in snapshot.metrics {
                let windowID = try ensureWindow(
                    accountKey: accountKey,
                    metricKey: metric.id,
                    title: metric.title,
                    timestamp: sampledAtMilliseconds,
                    database: database
                )

                if try insertSampleIfNeeded(
                    windowID: windowID,
                    metric: metric,
                    sampledAtMilliseconds: sampledAtMilliseconds,
                    database: database
                ) {
                    insertedSampleCount += 1
                    try updateWindowLastSeen(
                        windowID: windowID,
                        timestamp: sampledAtMilliseconds,
                        database: database
                    )
                }
            }

            if insertedSampleCount > 0 {
                try updateAccountLastSeen(
                    accountKey: accountKey,
                    timestamp: sampledAtMilliseconds,
                    database: database
                )
            }

            try execute("COMMIT", database: database)
            return QuotaHistoryWriteResult(insertedSampleCount: insertedSampleCount)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    func accounts() async throws -> [QuotaHistoryAccount] {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            """
            SELECT a.account_key, a.provider, a.display_label, a.plan_type,
                   a.first_seen_ms, a.last_seen_ms
            FROM history_accounts a
            WHERE EXISTS (
                SELECT 1
                FROM history_windows w
                JOIN history_samples s ON s.window_id = w.id
                WHERE w.account_key = a.account_key
            )
            ORDER BY a.provider, a.display_label COLLATE NOCASE
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var accounts: [QuotaHistoryAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let accountKey = columnText(statement, index: 0),
                  let providerValue = columnText(statement, index: 1),
                  let displayLabel = columnText(statement, index: 2),
                  let provider = AgentProviderKind(rawValue: providerValue) else {
                continue
            }

            accounts.append(
                QuotaHistoryAccount(
                    accountKey: accountKey,
                    provider: provider,
                    displayLabel: displayLabel,
                    planType: columnText(statement, index: 3),
                    firstSeenAt: Self.date(milliseconds: sqlite3_column_int64(statement, 4)),
                    lastSeenAt: Self.date(milliseconds: sqlite3_column_int64(statement, 5))
                )
            )
        }

        try checkCompletion(statement, database: database, operation: "read accounts")
        return accounts
    }

    func windows(for accountKey: String) async throws -> [QuotaHistoryWindow] {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            """
            SELECT id, metric_key, title, first_seen_ms, last_seen_ms
            FROM history_windows
            WHERE account_key = ?
              AND EXISTS (SELECT 1 FROM history_samples s WHERE s.window_id = history_windows.id)
            ORDER BY first_seen_ms, id
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(accountKey, to: 1, in: statement, database: database)

        var windows: [QuotaHistoryWindow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let windowID = sqlite3_column_int64(statement, 0)
            guard let metricKey = columnText(statement, index: 1),
                  let title = columnText(statement, index: 2) else {
                continue
            }

            let latest = try latestState(
                windowID: windowID,
                database: database
            )?.sample(windowID: windowID)
            windows.append(
                QuotaHistoryWindow(
                    id: windowID,
                    accountKey: accountKey,
                    metricKey: metricKey,
                    title: title,
                    firstSeenAt: Self.date(milliseconds: sqlite3_column_int64(statement, 3)),
                    lastSeenAt: Self.date(milliseconds: sqlite3_column_int64(statement, 4)),
                    latestSample: latest
                )
            )
        }

        try checkCompletion(statement, database: database, operation: "read windows")
        return windows
    }

    func samples(for windowID: Int64, startingAt: Date?) async throws -> [QuotaHistorySample] {
        let database = try openDatabaseIfNeeded()
        let startMilliseconds = startingAt.map(Self.milliseconds)
        var effectiveLabels = try labelsBefore(
            windowID: windowID,
            timestamp: startMilliseconds,
            database: database
        )

        let sql: String
        if startMilliseconds == nil {
            sql = """
                SELECT sampled_at_ms, used_basis_points, used_label, remaining_label,
                       resets_at_ms, is_unlimited, event_kind
                FROM history_samples
                WHERE window_id = ?
                ORDER BY sampled_at_ms
                """
        } else {
            sql = """
                SELECT sampled_at_ms, used_basis_points, used_label, remaining_label,
                       resets_at_ms, is_unlimited, event_kind
                FROM history_samples
                WHERE window_id = ? AND sampled_at_ms >= ?
                ORDER BY sampled_at_ms
                """
        }

        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(windowID, to: 1, in: statement, database: database)
        if let startMilliseconds {
            try bind(startMilliseconds, to: 2, in: statement, database: database)
        }

        var samples: [QuotaHistorySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let usedLabel = columnText(statement, index: 2) {
                effectiveLabels.used = usedLabel
            }
            if let remainingLabel = columnText(statement, index: 3) {
                effectiveLabels.remaining = remainingLabel
            }

            samples.append(
                sample(
                    from: statement,
                    windowID: windowID,
                    effectiveLabels: effectiveLabels
                )
            )
        }

        try checkCompletion(statement, database: database, operation: "read samples")
        return samples
    }

    func stats() async throws -> QuotaHistoryStats {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            "SELECT COUNT(*), MIN(sampled_at_ms) FROM history_samples",
            database: database
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read stats")
        }

        let count = Int(sqlite3_column_int64(statement, 0))
        let oldest: Date? = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : Self.date(milliseconds: sqlite3_column_int64(statement, 1))
        return QuotaHistoryStats(
            sampleCount: count,
            oldestSampleAt: oldest,
            databaseSizeBytes: databaseSizeBytes()
        )
    }

    @discardableResult
    func deleteSamples(olderThan cutoff: Date) async throws -> Int {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare(
            "DELETE FROM history_samples WHERE sampled_at_ms < ?",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(Self.milliseconds(cutoff), to: 1, in: statement, database: database)
        try stepDone(statement, database: database, operation: "delete old samples")
        let deleted = Int(sqlite3_changes(database))
        try cleanupOrphansAndCompact(database: database)
        return deleted
    }

    @discardableResult
    func deleteAllSamples() async throws -> Int {
        let database = try openDatabaseIfNeeded()
        let statement = try prepare("DELETE FROM history_samples", database: database)
        defer { sqlite3_finalize(statement) }
        try stepDone(statement, database: database, operation: "delete all samples")
        let deleted = Int(sqlite3_changes(database))
        try cleanupOrphansAndCompact(database: database)
        return deleted
    }

    func rebuildDatabase() async throws {
        closeDatabase()
        for url in databaseRelatedURLs() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        _ = try openDatabaseIfNeeded()
    }

    private func openDatabaseIfNeeded() throws -> OpaquePointer {
        if let database {
            return database
        }

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw QuotaHistoryStoreError(operation: "open", message: message)
        }

        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL", database: handle)
            try execute("PRAGMA foreign_keys=ON", database: handle)
            try execute("PRAGMA busy_timeout=3000", database: handle)
            try migrate(database: handle)
            return handle
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func migrate(database: OpaquePointer) throws {
        let version = try scalarInteger("PRAGMA user_version", database: database)
        guard version <= 1 else {
            throw QuotaHistoryStoreError(
                operation: "migrate",
                message: "Database schema version \(version) is newer than this app supports"
            )
        }

        guard version == 0 else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
        do {
            try execute(
                """
                CREATE TABLE history_accounts (
                    account_key TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    display_label TEXT NOT NULL,
                    plan_type TEXT,
                    first_seen_ms INTEGER NOT NULL,
                    last_seen_ms INTEGER NOT NULL
                )
                """,
                database: database
            )
            try execute(
                """
                CREATE TABLE history_windows (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_key TEXT NOT NULL REFERENCES history_accounts(account_key) ON DELETE CASCADE,
                    metric_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    first_seen_ms INTEGER NOT NULL,
                    last_seen_ms INTEGER NOT NULL,
                    UNIQUE(account_key, metric_key)
                )
                """,
                database: database
            )
            try execute(
                """
                CREATE TABLE history_samples (
                    window_id INTEGER NOT NULL REFERENCES history_windows(id) ON DELETE CASCADE,
                    sampled_at_ms INTEGER NOT NULL,
                    used_basis_points INTEGER,
                    used_label TEXT,
                    remaining_label TEXT,
                    resets_at_ms INTEGER,
                    is_unlimited INTEGER NOT NULL DEFAULT 0,
                    event_kind INTEGER NOT NULL,
                    PRIMARY KEY(window_id, sampled_at_ms)
                )
                """,
                database: database
            )
            try execute(
                "CREATE INDEX history_samples_time_idx ON history_samples(sampled_at_ms)",
                database: database
            )
            try execute("PRAGMA user_version=1", database: database)
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func ensureAccount(
        key: String,
        provider: AgentProviderKind,
        displayLabel: String,
        planType: String?,
        timestamp: Int64,
        database: OpaquePointer
    ) throws {
        let insert = try prepare(
            """
            INSERT OR IGNORE INTO history_accounts(
                account_key, provider, display_label, plan_type, first_seen_ms, last_seen_ms
            ) VALUES(?, ?, ?, ?, ?, ?)
            """,
            database: database
        )
        defer { sqlite3_finalize(insert) }
        try bind(key, to: 1, in: insert, database: database)
        try bind(provider.rawValue, to: 2, in: insert, database: database)
        try bind(displayLabel, to: 3, in: insert, database: database)
        try bind(planType, to: 4, in: insert, database: database)
        try bind(timestamp, to: 5, in: insert, database: database)
        try bind(timestamp, to: 6, in: insert, database: database)
        try stepDone(insert, database: database, operation: "insert account")

        let metadata = try prepare(
            "SELECT display_label, plan_type FROM history_accounts WHERE account_key = ?",
            database: database
        )
        defer { sqlite3_finalize(metadata) }
        try bind(key, to: 1, in: metadata, database: database)
        guard sqlite3_step(metadata) == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read account metadata")
        }

        let storedLabel = columnText(metadata, index: 0) ?? ""
        let storedPlan = columnText(metadata, index: 1)
        guard storedLabel != displayLabel || storedPlan != planType else { return }

        let update = try prepare(
            "UPDATE history_accounts SET display_label = ?, plan_type = ? WHERE account_key = ?",
            database: database
        )
        defer { sqlite3_finalize(update) }
        try bind(displayLabel, to: 1, in: update, database: database)
        try bind(planType, to: 2, in: update, database: database)
        try bind(key, to: 3, in: update, database: database)
        try stepDone(update, database: database, operation: "update account metadata")
    }

    private func ensureWindow(
        accountKey: String,
        metricKey: String,
        title: String,
        timestamp: Int64,
        database: OpaquePointer
    ) throws -> Int64 {
        let insert = try prepare(
            """
            INSERT OR IGNORE INTO history_windows(
                account_key, metric_key, title, first_seen_ms, last_seen_ms
            ) VALUES(?, ?, ?, ?, ?)
            """,
            database: database
        )
        defer { sqlite3_finalize(insert) }
        try bind(accountKey, to: 1, in: insert, database: database)
        try bind(metricKey, to: 2, in: insert, database: database)
        try bind(title, to: 3, in: insert, database: database)
        try bind(timestamp, to: 4, in: insert, database: database)
        try bind(timestamp, to: 5, in: insert, database: database)
        try stepDone(insert, database: database, operation: "insert quota window")

        let query = try prepare(
            "SELECT id, title FROM history_windows WHERE account_key = ? AND metric_key = ?",
            database: database
        )
        defer { sqlite3_finalize(query) }
        try bind(accountKey, to: 1, in: query, database: database)
        try bind(metricKey, to: 2, in: query, database: database)
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read quota window")
        }

        let windowID = sqlite3_column_int64(query, 0)
        if columnText(query, index: 1) != title {
            let update = try prepare(
                "UPDATE history_windows SET title = ? WHERE id = ?",
                database: database
            )
            defer { sqlite3_finalize(update) }
            try bind(title, to: 1, in: update, database: database)
            try bind(windowID, to: 2, in: update, database: database)
            try stepDone(update, database: database, operation: "update quota window title")
        }

        return windowID
    }

    private func insertSampleIfNeeded(
        windowID: Int64,
        metric: AgentQuotaMetric,
        sampledAtMilliseconds: Int64,
        database: OpaquePointer
    ) throws -> Bool {
        let unlimited = Self.isUnlimited(metric)
        let usedBasisPoints = unlimited ? nil : Self.basisPoints(metric.usedPercent)
        let resetMilliseconds = metric.resetsAt.map(Self.milliseconds)
        let previous = try latestState(windowID: windowID, database: database)

        let eventKind: QuotaHistoryEventKind
        let labelsChanged: Bool
        if let previous {
            guard sampledAtMilliseconds > previous.sampledAtMilliseconds else {
                return false
            }

            let amountChanged = Self.amountChanged(previous.usedBasisPoints, usedBasisPoints)
            labelsChanged = previous.usedLabel != metric.usedLabel ||
                previous.remainingLabel != metric.remainingLabel
            let resetChanged = Self.resetScheduleChanged(
                previous: previous,
                resetMilliseconds: resetMilliseconds,
                sampledAtMilliseconds: sampledAtMilliseconds
            )
            let unlimitedChanged = previous.isUnlimited != unlimited
            let intervalElapsed = sampledAtMilliseconds - previous.sampledAtMilliseconds >=
                Int64(Self.samplingInterval * 1_000)

            guard amountChanged || labelsChanged || resetChanged || unlimitedChanged || intervalElapsed else {
                return false
            }

            eventKind = Self.eventKind(
                resetChanged: resetChanged,
                amountChanged: amountChanged,
                labelsChanged: labelsChanged,
                unlimitedChanged: unlimitedChanged,
                intervalElapsed: intervalElapsed
            )
        } else {
            labelsChanged = true
            eventKind = .initial
        }

        let insert = try prepare(
            """
            INSERT INTO history_samples(
                window_id, sampled_at_ms, used_basis_points, used_label, remaining_label,
                resets_at_ms, is_unlimited, event_kind
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
            database: database
        )
        defer { sqlite3_finalize(insert) }
        try bind(windowID, to: 1, in: insert, database: database)
        try bind(sampledAtMilliseconds, to: 2, in: insert, database: database)
        try bind(usedBasisPoints, to: 3, in: insert, database: database)
        try bind(labelsChanged ? metric.usedLabel : nil, to: 4, in: insert, database: database)
        try bind(labelsChanged ? metric.remainingLabel : nil, to: 5, in: insert, database: database)
        try bind(resetMilliseconds, to: 6, in: insert, database: database)
        try bind(unlimited ? 1 : 0, to: 7, in: insert, database: database)
        try bind(eventKind.rawValue, to: 8, in: insert, database: database)
        try stepDone(insert, database: database, operation: "insert quota sample")
        return true
    }

    private static func eventKind(
        resetChanged: Bool,
        amountChanged: Bool,
        labelsChanged: Bool,
        unlimitedChanged: Bool,
        intervalElapsed: Bool
    ) -> QuotaHistoryEventKind {
        if resetChanged {
            return .scheduleChanged
        }
        if amountChanged || labelsChanged || unlimitedChanged {
            return .changed
        }
        if intervalElapsed {
            return .interval
        }
        return .changed
    }

    private func latestState(
        windowID: Int64,
        database: OpaquePointer
    ) throws -> StoredSampleState? {
        let statement = try prepare(
            """
            SELECT s.sampled_at_ms, s.used_basis_points,
                   COALESCE(s.used_label, (
                       SELECT l.used_label FROM history_samples l
                       WHERE l.window_id = s.window_id
                         AND l.sampled_at_ms <= s.sampled_at_ms
                         AND l.used_label IS NOT NULL
                       ORDER BY l.sampled_at_ms DESC LIMIT 1
                   )),
                   COALESCE(s.remaining_label, (
                       SELECT l.remaining_label FROM history_samples l
                       WHERE l.window_id = s.window_id
                         AND l.sampled_at_ms <= s.sampled_at_ms
                         AND l.remaining_label IS NOT NULL
                       ORDER BY l.sampled_at_ms DESC LIMIT 1
                   )),
                   s.resets_at_ms, s.is_unlimited, s.event_kind
            FROM history_samples s
            WHERE s.window_id = ?
            ORDER BY s.sampled_at_ms DESC
            LIMIT 1
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(windowID, to: 1, in: statement, database: database)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read latest sample")
        }

        return StoredSampleState(
            sampledAtMilliseconds: sqlite3_column_int64(statement, 0),
            usedBasisPoints: columnInteger(statement, index: 1).map(Int.init),
            usedLabel: columnText(statement, index: 2),
            remainingLabel: columnText(statement, index: 3),
            resetsAtMilliseconds: columnInteger(statement, index: 4),
            isUnlimited: sqlite3_column_int(statement, 5) != 0,
            eventKind: QuotaHistoryEventKind(rawValue: Int(sqlite3_column_int(statement, 6))) ?? .changed
        )
    }

    private func labelsBefore(
        windowID: Int64,
        timestamp: Int64?,
        database: OpaquePointer
    ) throws -> (used: String?, remaining: String?) {
        guard let timestamp else { return (nil, nil) }
        let statement = try prepare(
            """
            SELECT
                (SELECT used_label FROM history_samples
                 WHERE window_id = ? AND sampled_at_ms < ? AND used_label IS NOT NULL
                 ORDER BY sampled_at_ms DESC LIMIT 1),
                (SELECT remaining_label FROM history_samples
                 WHERE window_id = ? AND sampled_at_ms < ? AND remaining_label IS NOT NULL
                 ORDER BY sampled_at_ms DESC LIMIT 1)
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(windowID, to: 1, in: statement, database: database)
        try bind(timestamp, to: 2, in: statement, database: database)
        try bind(windowID, to: 3, in: statement, database: database)
        try bind(timestamp, to: 4, in: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read historical labels")
        }
        return (columnText(statement, index: 0), columnText(statement, index: 1))
    }

    private func sample(
        from statement: OpaquePointer,
        windowID: Int64,
        effectiveLabels: (used: String?, remaining: String?)
    ) -> QuotaHistorySample {
        QuotaHistorySample(
            windowID: windowID,
            sampledAt: Self.date(milliseconds: sqlite3_column_int64(statement, 0)),
            usedBasisPoints: columnInteger(statement, index: 1).map(Int.init),
            usedLabel: effectiveLabels.used,
            remainingLabel: effectiveLabels.remaining,
            resetsAt: columnInteger(statement, index: 4).map(Self.date(milliseconds:)),
            isUnlimited: sqlite3_column_int(statement, 5) != 0,
            eventKind: QuotaHistoryEventKind(rawValue: Int(sqlite3_column_int(statement, 6))) ?? .changed
        )
    }

    private func updateAccountLastSeen(
        accountKey: String,
        timestamp: Int64,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "UPDATE history_accounts SET last_seen_ms = MAX(last_seen_ms, ?) WHERE account_key = ?",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(timestamp, to: 1, in: statement, database: database)
        try bind(accountKey, to: 2, in: statement, database: database)
        try stepDone(statement, database: database, operation: "update account timestamp")
    }

    private func updateWindowLastSeen(
        windowID: Int64,
        timestamp: Int64,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "UPDATE history_windows SET last_seen_ms = MAX(last_seen_ms, ?) WHERE id = ?",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(timestamp, to: 1, in: statement, database: database)
        try bind(windowID, to: 2, in: statement, database: database)
        try stepDone(statement, database: database, operation: "update quota window timestamp")
    }

    private func cleanupOrphansAndCompact(database: OpaquePointer) throws {
        try execute(
            "DELETE FROM history_windows WHERE NOT EXISTS (SELECT 1 FROM history_samples s WHERE s.window_id = history_windows.id)",
            database: database
        )
        try execute(
            "DELETE FROM history_accounts WHERE NOT EXISTS (SELECT 1 FROM history_windows w WHERE w.account_key = history_accounts.account_key)",
            database: database
        )
        try execute("PRAGMA wal_checkpoint(TRUNCATE)", database: database)
        try execute("VACUUM", database: database)
    }

    private func closeDatabase() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    private func databaseRelatedURLs() -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    private func databaseSizeBytes() -> Int64 {
        databaseRelatedURLs().reduce(0) { total, url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return total
            }
            return total + size.int64Value
        }
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw QuotaHistoryStoreError(operation: "execute SQL", message: message)
        }
    }

    private func scalarInteger(_ sql: String, database: OpaquePointer) throws -> Int {
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError(database: database, operation: "read scalar")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database: database, operation: "prepare SQL")
        }
        return statement
    }

    private func bind(
        _ value: String?,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw sqliteError(database: database, operation: "bind text")
        }
    }

    private func bind(
        _ value: Int?,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        if let value {
            try bind(Int64(value), to: index, in: statement, database: database)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw sqliteError(database: database, operation: "bind integer")
            }
        }
    }

    private func bind(
        _ value: Int64?,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) }
            ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw sqliteError(database: database, operation: "bind integer")
        }
    }

    private func bind(
        _ value: Int64,
        to index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw sqliteError(database: database, operation: "bind integer")
        }
    }

    private func stepDone(
        _ statement: OpaquePointer,
        database: OpaquePointer,
        operation: String
    ) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(database: database, operation: operation)
        }
    }

    private func checkCompletion(
        _ statement: OpaquePointer,
        database: OpaquePointer,
        operation: String
    ) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
            throw sqliteError(database: database, operation: operation)
        }
        _ = statement
    }

    private func sqliteError(database: OpaquePointer, operation: String) -> QuotaHistoryStoreError {
        QuotaHistoryStoreError(
            operation: operation,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnInteger(_ statement: OpaquePointer, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private static func basisPoints(_ usedPercent: Double) -> Int {
        Int((min(max(usedPercent, 0), 100) * 100).rounded())
    }

    private static func amountChanged(_ oldValue: Int?, _ newValue: Int?) -> Bool {
        switch (oldValue, newValue) {
        case let (old?, new?):
            return abs(old - new) >= immediateChangeBasisPoints
        case (nil, nil):
            return false
        case (_?, nil), (nil, _?):
            return true
        }
    }

    private static func resetScheduleChanged(
        previous: StoredSampleState,
        resetMilliseconds: Int64?,
        sampledAtMilliseconds: Int64
    ) -> Bool {
        switch (previous.resetsAtMilliseconds, resetMilliseconds) {
        case (nil, nil):
            return false
        case (_?, nil), (nil, _?):
            return true
        case let (oldReset?, newReset?):
            let resetAdvance = newReset - oldReset
            guard abs(resetAdvance) >= resetScheduleToleranceMilliseconds else {
                return false
            }

            let sampleAdvance = sampledAtMilliseconds - previous.sampledAtMilliseconds
            return abs(resetAdvance - sampleAdvance) >= resetScheduleToleranceMilliseconds
        }
    }

    private static func isUnlimited(_ metric: AgentQuotaMetric) -> Bool {
        [metric.usedLabel, metric.remainingLabel].contains { label in
            label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Unlimited") == .orderedSame
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private struct StoredSampleState {
    let sampledAtMilliseconds: Int64
    let usedBasisPoints: Int?
    let usedLabel: String?
    let remainingLabel: String?
    let resetsAtMilliseconds: Int64?
    let isUnlimited: Bool
    let eventKind: QuotaHistoryEventKind

    func sample(windowID: Int64) -> QuotaHistorySample {
        QuotaHistorySample(
            windowID: windowID,
            sampledAt: Date(timeIntervalSince1970: Double(sampledAtMilliseconds) / 1_000),
            usedBasisPoints: usedBasisPoints,
            usedLabel: usedLabel,
            remainingLabel: remainingLabel,
            resetsAt: resetsAtMilliseconds.map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            },
            isUnlimited: isUnlimited,
            eventKind: eventKind
        )
    }
}
