import Foundation
import Testing
@testable import AgentBarCore

@Test
func decodesCodexCloudUsagePayload() throws {
    let payload = """
    {
      "plan_type": "team",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "limit_window_seconds": 18000,
          "reset_at": 1775658567
        },
        "secondary_window": {
          "used_percent": 34,
          "limit_window_seconds": 604800,
          "reset_at": 1775791369
        }
      }
    }
    """

    let updatedAt = Date(timeIntervalSince1970: 1775600000)
    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "Account test",
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .codex)
    #expect(snapshot.accountLabel == "Account test")
    #expect(snapshot.planType == "team")
    #expect(snapshot.sourceSummary == "ChatGPT Codex API")
    #expect(snapshot.updatedAt == updatedAt)
    #expect(snapshot.metrics.count == 2)
    #expect(snapshot.metrics.first?.title == "5 hour window")
    #expect(snapshot.metrics.first?.usedPercent == 40)
    #expect(snapshot.metrics.last?.title == "7 day window")
    #expect(snapshot.metrics.last?.usedPercent == 34)
}

@Test
func rejectsUsagePayloadWithoutQuotaWindows() throws {
    let payload = """
    {
      "plan_type": "pro",
      "rate_limit": {}
    }
    """

    #expect(throws: CodexQuotaError.noQuotaInResponse) {
        try CodexQuotaService().decodeSnapshot(
            from: Data(payload.utf8),
            accountLabel: "Account test",
            updatedAt: Date()
        )
    }
}

@Test
func codexPrefersHumanReadableAccountLabelFromIDToken() {
    let service = CodexQuotaService()

    let emailToken = makeJWT(payload: #"{"email":"dev@example.com","name":"Dev User"}"#)
    #expect(service.preferredAccountLabel(idToken: emailToken, fallbackAccountID: "abcd1234efgh5678") == "dev@example.com")

    let nameOnlyToken = makeJWT(payload: #"{"name":"Dev User"}"#)
    #expect(service.preferredAccountLabel(idToken: nameOnlyToken, fallbackAccountID: "abcd1234efgh5678") == "Dev User")

    #expect(service.preferredAccountLabel(idToken: nil, fallbackAccountID: "abcd1234efgh5678") == "Account abcd...5678")
}

@Test
func codexReadsNamespacedTokenIdentityClaims() {
    let service = CodexQuotaService()
    let token = makeJWT(
        payload: #"""
        {
          "https://api.openai.com/profile": {
            "email": "dev@example.com"
          },
          "https://api.openai.com/auth": {
            "chatgpt_account_id": "account-123"
          }
        }
        """#
    )

    #expect(CodexAppAuthStore.identity(from: token)?.accountID == "account-123")
    #expect(service.preferredAccountLabel(idToken: token, fallbackAccountID: "account-123") == "dev@example.com")
}

@Test
func codexAppManagedAccountDirectoryRoundTripsAccountID() {
    let directory = CodexAppAuthStore.accountDirectory(for: "account/with+symbols")

    #expect(CodexAppAuthStore.accountID(fromAccountDirectory: directory) == "account/with+symbols")
    #expect(CodexAppAuthStore.isAppManagedAccountDirectory(ConfiguredAccountDirectory(path: directory.path)))
}

@Test
func codexLocalAccountIDKeepsSameAccountOnExistingStorageKey() {
    let existing = makeStoredCodexSession(accountID: "account-shared", subject: "user-one", email: "one@example.com")
    let incoming = makeStoredCodexSession(accountID: "account-shared", subject: "user-one", email: "one@example.com")

    let localAccountID = CodexAppAuthStore.localAccountID(
        for: incoming,
        existingLocalAccountIDs: ["account-shared"],
        loadExistingSession: { $0 == "account-shared" ? existing : nil }
    )

    #expect(localAccountID == "account-shared")
}

@Test
func codexLocalAccountIDKeepsDifferentAccountsWithCollidingAccountID() {
    let existing = makeStoredCodexSession(accountID: "account-shared", subject: "user-one", email: "one@example.com")
    let incoming = makeStoredCodexSession(accountID: "account-shared", subject: "user-two", email: "two@example.com")

    let localAccountID = CodexAppAuthStore.localAccountID(
        for: incoming,
        existingLocalAccountIDs: ["account-shared"],
        loadExistingSession: { $0 == "account-shared" ? existing : nil }
    )

    #expect(localAccountID != "account-shared")
    #expect(localAccountID.hasPrefix("account-shared#"))
    #expect(
        CodexAppAuthStore.accountID(
            fromAccountDirectory: CodexAppAuthStore.accountDirectory(for: localAccountID)
        ) == localAccountID
    )
}

private func makeStoredCodexSession(
    accountID: String,
    subject: String,
    email: String
) -> CodexStoredAuthSession {
    let token = makeJWT(
        payload: """
        {
          "sub": "\(subject)",
          "https://api.openai.com/profile": {
            "email": "\(email)"
          },
          "https://api.openai.com/auth": {
            "chatgpt_account_id": "\(accountID)"
          }
        }
        """
    )

    return CodexStoredAuthSession(
        idToken: token,
        accessToken: "access-\(subject)",
        refreshToken: "refresh-\(subject)",
        accountID: accountID,
        lastRefresh: Date(timeIntervalSince1970: 1_775_600_000)
    )
}

private func makeJWT(payload: String) -> String {
    let header = #"{"alg":"none","typ":"JWT"}"#
    return "\(base64URL(header)).\(base64URL(payload)).signature"
}

private func base64URL(_ value: String) -> String {
    Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
