import Foundation
import Testing
@testable import AgentBarCore

@Test
func decodesCodexCloudUsagePayload() throws {
    let payload = try sharedFixtureData("codex", "usage-team.json")

    let updatedAt = Date(timeIntervalSince1970: 1775600000)
    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: payload,
        accountLabel: "Account test",
        spaceLabel: "Newsbreak-BJ",
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .codex)
    #expect(snapshot.accountLabel == "Account test")
    #expect(snapshot.spaceLabel == "Newsbreak-BJ · Team")
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
func codexBusinessPlanDoesNotInventWorkspaceFromPersonalTokenLabel() throws {
    let payload = """
    {
      "plan_type": "team",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "limit_window_seconds": 18000,
          "reset_at": 1775658567
        }
      }
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "xiaocong.li@newsbreak.com",
        spaceLabel: "Personal",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.spaceLabel == "Team")
    #expect(snapshot.planType == "team")
}

@Test
func codexBusinessPlanUsesPublicWorkspaceDiscoveryTokenLabel() throws {
    let payload = """
    {
      "plan_type": "team",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "limit_window_seconds": 18000,
          "reset_at": 1775658567
        }
      }
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "xiaocong.li@newsbreak.com",
        spaceLabel: "newsbreak.com Workspace #43791",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.spaceLabel == "newsbreak.com · Team")
    #expect(snapshot.planType == "team")
}

@Test
func codexDecodesWorkspaceDisplayNameFromAccountSettings() throws {
    let payload = """
    {
      "workspace_id": "account-work",
      "public_display_name": "newsbreak.com Workspace #43791",
      "workspace_name": "Newsbreak-BJ"
    }
    """

    let displayName = try CodexQuotaService().decodeWorkspaceDisplayName(from: Data(payload.utf8))
    #expect(displayName == "Newsbreak-BJ")
}

@Test
func codexUsesPublicWorkspaceDiscoveryNameWhenPrivateNameUnavailable() throws {
    let payload = """
    {
      "workspace_id": "account-work",
      "public_display_name": "newsbreak.com Workspace #43791"
    }
    """

    let displayName = try CodexQuotaService().decodeWorkspaceDisplayName(from: Data(payload.utf8))
    #expect(displayName == "newsbreak.com Workspace #43791")
}

@Test
func codexDisplaysPersonalProPlanLabel() throws {
    let payload = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {
          "used_percent": 0,
          "limit_window_seconds": 18000,
          "reset_at": 1775658567
        }
      }
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "960418051@qq.com",
        spaceLabel: "Personal",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.spaceLabel == "Personal Pro")
    #expect(snapshot.planType == "prolite")
}

@Test
func codexIgnoresZeroDurationPlaceholderWindows() throws {
    let payload = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 0,
          "limit_window_seconds": 0,
          "reset_after_seconds": 0,
          "reset_at": 1780463229
        },
        "secondary_window": null
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 0,
              "limit_window_seconds": 0,
              "reset_after_seconds": 0,
              "reset_at": 1780463229
            },
            "secondary_window": null
          }
        }
      ],
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "balance": "0"
      }
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "Account test",
        spaceLabel: "Personal",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.planType == "prolite")
    #expect(snapshot.spaceLabel == "Personal Pro")
    #expect(snapshot.sourceSummary == "No active Codex quota windows")
    #expect(snapshot.metrics.isEmpty)
}

@Test
func codexDecodesWindowDurationMinutePayloads() throws {
    let payload = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {
          "used_percent": 25,
          "window_duration_mins": 300,
          "resets_at": 1780463229
        }
      }
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "Account test",
        spaceLabel: "Personal",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.metrics.count == 1)
    #expect(snapshot.metrics.first?.title == "5 hour window")
    #expect(snapshot.metrics.first?.usedPercent == 25)
    #expect(snapshot.metrics.first?.remainingLabel == "75% left")
}

@Test
func codexDisplaysAdditionalRateLimitWindowsIndependently() throws {
    let payload = """
    {
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {
          "used_percent": 12,
          "limit_window_seconds": 18000,
          "reset_at": 1780517499
        },
        "secondary_window": {
          "used_percent": 54,
          "limit_window_seconds": 604800,
          "reset_at": 1780846287
        }
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT-5.3-Codex-Spark",
          "metered_feature": "codex_bengalfox",
          "rate_limit": {
            "primary_window": {
              "used_percent": 7,
              "limit_window_seconds": 18000,
              "reset_at": 1780518342
            },
            "secondary_window": {
              "used_percent": 9,
              "limit_window_seconds": 604800,
              "reset_at": 1781105142
            }
          }
        }
      ]
    }
    """

    let snapshot = try CodexQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabel: "Account test",
        spaceLabel: "Personal",
        updatedAt: Date(timeIntervalSince1970: 1775600000)
    )

    #expect(snapshot.metrics.map(\.id) == [
        "window-300",
        "window-10080",
        "additional-1-window-300",
        "additional-1-window-10080"
    ])
    #expect(snapshot.metrics.map(\.title) == [
        "5 hour window",
        "7 day window",
        "GPT-5.3-Codex-Spark 5 hour window",
        "GPT-5.3-Codex-Spark 7 day window"
    ])
    #expect(snapshot.metrics.map(\.usedPercent) == [12, 54, 7, 9])
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
            "chatgpt_account_id": "account-123",
            "organizations": [
              {
                "id": "org-work",
                "title": "Work",
                "is_default": false
              },
              {
                "id": "org-personal",
                "title": "Personal",
                "is_default": true
              }
            ]
          }
        }
        """#
    )

    let identity = CodexAppAuthStore.identity(from: token)
    #expect(identity?.accountID == "account-123")
    #expect(identity?.spaceID == "org-personal")
    #expect(identity?.spaceName == "Personal")
    #expect(identity?.spaceLabel == "Personal")
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

@Test
func codexLocalAccountIDKeepsDifferentSpacesWithCollidingAccountID() {
    let existing = makeStoredCodexSession(
        accountID: "account-shared",
        subject: "user-one",
        email: "one@example.com",
        spaceID: "org-personal",
        spaceName: "Personal"
    )
    let incoming = makeStoredCodexSession(
        accountID: "account-shared",
        subject: "user-one",
        email: "one@example.com",
        spaceID: "org-work",
        spaceName: "Work"
    )

    let localAccountID = CodexAppAuthStore.localAccountID(
        for: incoming,
        existingLocalAccountIDs: ["account-shared"],
        loadExistingSession: { $0 == "account-shared" ? existing : nil }
    )

    #expect(localAccountID != "account-shared")
    #expect(localAccountID.hasPrefix("account-shared#"))
}

private func makeStoredCodexSession(
    accountID: String,
    subject: String,
    email: String,
    spaceID: String? = nil,
    spaceName: String? = nil
) -> CodexStoredAuthSession {
    let organizationJSON: String
    if let spaceID, let spaceName {
        organizationJSON = """
        ,
            "organizations": [
              {
                "id": "\(spaceID)",
                "title": "\(spaceName)",
                "is_default": true
              }
            ]
        """
    } else {
        organizationJSON = ""
    }

    let token = makeJWT(
        payload: """
        {
          "sub": "\(subject)",
          "https://api.openai.com/profile": {
            "email": "\(email)"
          },
          "https://api.openai.com/auth": {
            "chatgpt_account_id": "\(accountID)"
            \(organizationJSON)
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
