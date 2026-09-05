import Foundation
import Testing
@testable import AgentBarCore
@testable import AgentBar

@Test
@MainActor
func codexLoginAlwaysRequestsFreshLoginConsent() throws {
    let url = try CodexBrowserLoginService().buildAuthorizeURL(
        redirectURI: "http://localhost:1455/auth/callback",
        codeChallenge: "challenge",
        state: "state"
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []

    #expect(queryItems.first { $0.name == "prompt" }?.value == "login consent")
    #expect(queryItems.first { $0.name == "originator" }?.value == "agentbar")
}

@Test
@MainActor
func claudeLoginAuthorizeURLCarriesPKCEAndState() throws {
    let url = try ClaudeBrowserLoginService().buildAuthorizeURL(
        redirectURI: "http://localhost:54546/callback",
        codeChallenge: "challenge-value",
        state: "state-value"
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(components.host == "platform.claude.com")
    #expect(components.path == "/oauth/authorize")
    #expect(items["response_type"] == "code")
    #expect(items["client_id"] == ClaudeOAuthConfiguration.clientID)
    #expect(items["redirect_uri"] == "http://localhost:54546/callback")
    #expect(items["code_challenge"] == "challenge-value")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["state"] == "state-value")
    #expect(items["scope"] == "user:profile user:inference")
}

@Test
@MainActor
func geminiLoginCanForceAccountSelection() throws {
    let url = try GeminiBrowserLoginService(oauthClientProvider: {
        GeminiOAuthClientConfiguration(
            clientID: "test-client-id.apps.googleusercontent.com",
            clientSecret: "test-client-secret"
        )
    }).buildAuthorizeURL(
        redirectURI: "http://127.0.0.1:1458/oauth2callback",
        state: "state",
        forceAccountSelection: true
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []

    #expect(queryItems.first { $0.name == "prompt" }?.value == "select_account consent")
    #expect(queryItems.first { $0.name == "access_type" }?.value == "offline")
}
