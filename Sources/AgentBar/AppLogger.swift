import Foundation
import os

// MARK: - Subsystem loggers

let quotaLog = Logger(subsystem: "com.agentbar", category: "quota")
let networkLog = Logger(subsystem: "com.agentbar", category: "network")

// MARK: - Terminal helpers

/// Writes an error-level message to both os.Logger and stderr so it is visible
/// in the terminal when running `swift run AgentBar`.
func logError(_ message: String, log: Logger = quotaLog) {
    log.error("\(message, privacy: .public)")
    fputs("[AgentBar ERROR] \(message)\n", stderr)
}

/// Writes an info-level message to both os.Logger and stdout.
func logInfo(_ message: String, log: Logger = quotaLog) {
    log.info("\(message, privacy: .public)")
    print("[AgentBar] \(message)")
}

/// Writes a debug-level message to os.Logger only (quiet during normal use).
/// Enable in Console.app by including "AgentBar" debug messages.
func logDebug(_ message: String, log: Logger = quotaLog) {
    log.debug("\(message, privacy: .public)")
}
