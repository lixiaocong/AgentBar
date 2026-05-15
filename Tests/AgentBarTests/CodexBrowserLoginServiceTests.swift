import Foundation
import Testing
@testable import AgentBarCore
@testable import AgentBar

@Test
@MainActor
func codexLoginCanForceAccountSelection() throws {
    let url = try CodexBrowserLoginService().buildAuthorizeURL(
        redirectURI: "http://localhost:1455/auth/callback",
        codeChallenge: "challenge",
        state: "state",
        mode: .forceAccountSelection
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []

    #expect(queryItems.first { $0.name == "prompt" }?.value == "login")
}

@Test
@MainActor
func codexLoginDefaultsToCurrentBrowserSession() throws {
    let url = try CodexBrowserLoginService().buildAuthorizeURL(
        redirectURI: "http://localhost:1455/auth/callback",
        codeChallenge: "challenge",
        state: "state"
    )

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []

    #expect(queryItems.first { $0.name == "prompt" } == nil)
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
