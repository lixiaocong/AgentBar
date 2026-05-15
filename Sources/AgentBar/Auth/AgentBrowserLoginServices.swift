import AppKit
import Foundation
import Network

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@MainActor
struct GitHubCopilotBrowserLoginService {
    private let clientID = "Ov23liV9UpD7Rnfnskm3"
    private let scopes = ["repo", "workflow", "read:user", "user:email"]

    func signIn(progress: @MainActor @escaping (String?) -> Void = { _ in }) async throws -> AgentProviderStoredAuthSession {
        let device = try await requestDeviceCode()
        progress("If GitHub does not fill the code automatically, enter \(device.userCode).")

        guard NSWorkspace.shared.open(device.verificationURLToOpen) else {
            throw ProviderBrowserLoginError.browserOpenFailed("GitHub Copilot")
        }

        let token = try await pollForAccessToken(device: device)
        guard let accessToken = token.accessToken, !accessToken.isEmpty else {
            throw ProviderBrowserLoginError.invalidTokenResponse("GitHub")
        }
        let user = try await fetchUser(accessToken: accessToken)
        guard let accountID = user.id.map(String.init) ?? user.login,
              !accountID.isEmpty else {
            throw ProviderBrowserLoginError.missingAccountID("GitHub")
        }
        let accountEmail = await loadPrimaryEmail(accessToken: accessToken)
        let accountLabel = Self.preferredAccountLabel(
            email: accountEmail ?? user.email,
            name: user.name,
            login: user.login
        )

        progress(nil)
        return AgentProviderStoredAuthSession(
            provider: .githubCopilot,
            accountID: accountID,
            accountLabel: accountLabel,
            accessToken: accessToken,
            refreshToken: nil,
            expiryDate: nil,
            scopes: token.scope?.split(separator: ",").map(String.init) ?? scopes,
            lastRefresh: Date()
        )
    }

    private func requestDeviceCode() async throws -> GitHubDeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            ("client_id", clientID),
            ("scope", scopes.joined(separator: " "))
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw ProviderBrowserLoginError.tokenExchangeFailed("GitHub device code request failed.")
        }

        return try JSONDecoder().decode(GitHubDeviceCodeResponse.self, from: data)
    }

    private func pollForAccessToken(device: GitHubDeviceCodeResponse) async throws -> GitHubAccessTokenResponse {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(device.interval ?? 5, 1)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formURLEncoded([
                ("client_id", clientID),
                ("device_code", device.deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode) else {
                throw ProviderBrowserLoginError.tokenExchangeFailed("GitHub access token request failed.")
            }

            let token = try JSONDecoder().decode(GitHubAccessTokenResponse.self, from: data)
            if let accessToken = token.accessToken, !accessToken.isEmpty {
                return token
            }

            switch token.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw ProviderBrowserLoginError.oauthFailed("GitHub device code expired.")
            case "access_denied":
                throw ProviderBrowserLoginError.oauthFailed("GitHub sign-in was denied.")
            case let error?:
                throw ProviderBrowserLoginError.oauthFailed(error)
            case nil:
                throw ProviderBrowserLoginError.invalidTokenResponse("GitHub")
            }
        }

        throw ProviderBrowserLoginError.oauthFailed("GitHub sign-in timed out.")
    }

    private func fetchUser(accessToken: String) async throws -> GitHubUserResponse {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw ProviderBrowserLoginError.tokenExchangeFailed("GitHub user lookup failed.")
        }

        return try JSONDecoder().decode(GitHubUserResponse.self, from: data)
    }

    private func loadPrimaryEmail(accessToken: String) async -> String? {
        do {
            return try await fetchPrimaryEmail(accessToken: accessToken)
        } catch {
            return nil
        }
    }

    private func fetchPrimaryEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/emails")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw ProviderBrowserLoginError.tokenExchangeFailed("GitHub email lookup failed.")
        }

        let emails = try JSONDecoder().decode([GitHubEmailResponse].self, from: data)
        return emails
            .filter { $0.verified == true }
            .sorted { lhs, rhs in
                (lhs.primary == true ? 0 : 1) < (rhs.primary == true ? 0 : 1)
            }
            .compactMap { Self.cleanDisplayValue($0.email) }
            .first
    }

    private static func preferredAccountLabel(email: String?, name: String?, login: String?) -> String {
        if let email = cleanDisplayValue(email) {
            return email
        }

        if let name = cleanDisplayValue(name) {
            return name
        }

        if let login = cleanDisplayValue(login) {
            return "@\(login)"
        }

        return "GitHub Account"
    }

    private static func cleanDisplayValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func formURLEncoded(_ items: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: ":#[]@!$&'()*+,;=")
        )
        return Data(
            items.map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .utf8
        )
    }
}

@MainActor
struct GeminiBrowserLoginService {
    private let callbackPorts: [UInt16] = [1458, 1459]
    private let oauthClientProvider: () throws -> GeminiOAuthClientConfiguration

    init(oauthClientProvider: @escaping () throws -> GeminiOAuthClientConfiguration = {
        try GeminiOAuthConfiguration.loadClient()
    }) {
        self.oauthClientProvider = oauthClientProvider
    }

    func signIn(forceAccountSelection: Bool = false) async throws -> AgentProviderStoredAuthSession {
        let oauthClient = try oauthClientProvider()
        let state = UUID().uuidString + UUID().uuidString
        let callbackServer = try await ProviderOAuthCallbackServer.start(preferredPorts: callbackPorts)
        let redirectURI = "http://127.0.0.1:\(callbackServer.port)/oauth2callback"
        let authURL = try buildAuthorizeURL(
            redirectURI: redirectURI,
            state: state,
            forceAccountSelection: forceAccountSelection,
            oauthClient: oauthClient
        )

        guard NSWorkspace.shared.open(authURL) else {
            callbackServer.cancel()
            throw ProviderBrowserLoginError.browserOpenFailed("Gemini")
        }

        let callback = try await callbackServer.waitForCallback()
        if let error = callback.error {
            throw ProviderBrowserLoginError.oauthFailed(error)
        }

        guard callback.state == state else {
            throw ProviderBrowserLoginError.stateMismatch("Gemini")
        }

        guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw ProviderBrowserLoginError.missingAuthorizationCode("Gemini")
        }

        let tokens = try await exchangeCodeForTokens(code: code, redirectURI: redirectURI, oauthClient: oauthClient)
        let user = try await fetchUserInfo(accessToken: tokens.accessToken)
        let accountID = user.id ?? user.email
        guard let accountID, !accountID.isEmpty else {
            throw ProviderBrowserLoginError.missingAccountID("Gemini")
        }

        return AgentProviderStoredAuthSession(
            provider: .gemini,
            accountID: accountID,
            accountLabel: user.email ?? user.name ?? "Google Account",
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiryDate: tokens.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: GeminiOAuthConfiguration.scopes,
            lastRefresh: Date()
        )
    }

    func buildAuthorizeURL(
        redirectURI: String,
        state: String,
        forceAccountSelection: Bool = false
    ) throws -> URL {
        try buildAuthorizeURL(
            redirectURI: redirectURI,
            state: state,
            forceAccountSelection: forceAccountSelection,
            oauthClient: oauthClientProvider()
        )
    }

    private func buildAuthorizeURL(
        redirectURI: String,
        state: String,
        forceAccountSelection: Bool,
        oauthClient: GeminiOAuthClientConfiguration
    ) throws -> URL {
        var components = URLComponents(url: GeminiOAuthConfiguration.authorizationURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: oauthClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: GeminiOAuthConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state)
        ]

        if forceAccountSelection {
            queryItems.append(URLQueryItem(name: "prompt", value: "select_account consent"))
        } else {
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw ProviderBrowserLoginError.invalidAuthorizeURL("Gemini")
        }
        return url
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        oauthClient: GeminiOAuthClientConfiguration
    ) async throws -> GoogleOAuthTokenResponse {
        var request = URLRequest(url: GeminiOAuthConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", oauthClient.clientID),
            ("client_secret", oauthClient.clientSecret)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderBrowserLoginError.invalidTokenResponse("Gemini")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            throw ProviderBrowserLoginError.tokenExchangeFailed("Gemini token exchange failed with HTTP \(httpResponse.statusCode): \(body)")
        }

        return try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
    }

    private func fetchUserInfo(accessToken: String) async throws -> GoogleUserInfoResponse {
        var request = URLRequest(url: GeminiOAuthConfiguration.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw ProviderBrowserLoginError.tokenExchangeFailed("Gemini user lookup failed.")
        }

        return try JSONDecoder().decode(GoogleUserInfoResponse.self, from: data)
    }

    private func formURLEncoded(_ items: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: ":#[]@!$&'()*+,;=")
        )
        return Data(
            items.map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .utf8
        )
    }
}

enum ProviderBrowserLoginError: LocalizedError {
    case browserOpenFailed(String)
    case invalidAuthorizeURL(String)
    case missingAuthorizationCode(String)
    case missingAccountID(String)
    case stateMismatch(String)
    case invalidTokenResponse(String)
    case oauthFailed(String)
    case tokenExchangeFailed(String)
    case callbackServerFailed(String)

    var errorDescription: String? {
        switch self {
        case let .browserOpenFailed(provider):
            return "AgentBar could not open the browser for \(provider) sign-in."
        case let .invalidAuthorizeURL(provider):
            return "AgentBar could not build the \(provider) sign-in URL."
        case let .missingAuthorizationCode(provider):
            return "\(provider) sign-in did not return an authorization code."
        case let .missingAccountID(provider):
            return "\(provider) sign-in did not return an account id."
        case let .stateMismatch(provider):
            return "\(provider) sign-in callback validation failed."
        case let .invalidTokenResponse(provider):
            return "\(provider) sign-in returned an invalid token response."
        case let .oauthFailed(message), let .tokenExchangeFailed(message), let .callbackServerFailed(message):
            return message
        }
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    var verificationURLToOpen: URL {
        if let verificationURIComplete,
           let url = URL(string: verificationURIComplete) {
            return url
        }

        var components = URLComponents(string: verificationURI)
        components?.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        return components?.url ?? URL(string: verificationURI)!
    }
}

private struct GitHubAccessTokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubUserResponse: Decodable {
    let login: String?
    let email: String?
    let name: String?
    let id: Int?
}

private struct GitHubEmailResponse: Decodable {
    let email: String?
    let primary: Bool?
    let verified: Bool?
}

private struct GoogleOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct GoogleUserInfoResponse: Decodable {
    let id: String?
    let email: String?
    let name: String?
}

private struct ProviderOAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

private final class ProviderOAuthCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.agentbar.provider-oauth-callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderOAuthCallback, Error>?
    private var completedResult: Result<ProviderOAuthCallback, Error>?

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(preferredPorts: [UInt16]) async throws -> ProviderOAuthCallbackServer {
        var lastError: Error?
        for port in preferredPorts {
            do {
                return try await start(port: port)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProviderBrowserLoginError.callbackServerFailed("No callback port was available.")
    }

    func waitForCallback() async throws -> ProviderOAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let completedResult {
                    lock.unlock()
                    continuation.resume(with: completedResult)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        finish(.failure(ProviderBrowserLoginError.callbackServerFailed("Sign-in was cancelled.")))
    }

    private static func start(port: UInt16) async throws -> ProviderOAuthCallbackServer {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ProviderBrowserLoginError.callbackServerFailed("Invalid callback port \(port).")
        }

        let listener = try NWListener(using: .tcp, on: endpointPort)
        let server = ProviderOAuthCallbackServer(listener: listener, port: port)

        return try await withCheckedThrowingContinuation { continuation in
            final class StartState: @unchecked Sendable {
                var resumed = false
            }
            let startState = StartState()

            listener.newConnectionHandler = { connection in
                server.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    server.queue.async {
                        guard !startState.resumed else { return }
                        startState.resumed = true
                        continuation.resume(returning: server)
                    }
                case let .failed(error):
                    server.queue.async {
                        guard !startState.resumed else { return }
                        startState.resumed = true
                        continuation.resume(throwing: ProviderBrowserLoginError.callbackServerFailed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if let error {
                self.sendResponse(status: 400, body: "AgentBar could not read the sign-in callback.", connection: connection)
                self.finish(.failure(ProviderBrowserLoginError.callbackServerFailed(error.localizedDescription)))
                return
            }

            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let callback = Self.parseCallback(from: request) else {
                self.sendResponse(status: 400, body: "AgentBar could not parse the sign-in callback.", connection: connection)
                self.finish(.failure(ProviderBrowserLoginError.callbackServerFailed("Invalid callback request.")))
                return
            }

            if callback.error == nil {
                self.sendResponse(status: 200, body: "Sign-in completed. You can close this window.", connection: connection)
            } else {
                self.sendResponse(status: 400, body: "Sign-in failed. Return to AgentBar to try again.", connection: connection)
            }
            self.finish(.success(callback))
        }
    }

    private static func parseCallback(from request: String) -> ProviderOAuthCallback? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(path)"),
              components.path == "/oauth2callback" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        return ProviderOAuthCallback(
            code: value("code"),
            state: value("state"),
            error: value("error_description") ?? value("error")
        )
    }

    private func sendResponse(status: Int, body: String, connection: NWConnection) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>AgentBar Sign In</title></head>
        <body><p>\(Self.htmlEscaped(body))</p></body>
        </html>
        """
        let response = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(Data(html.utf8).count)",
            "Connection: close",
            "",
            html
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func finish(_ result: Result<ProviderOAuthCallback, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        listener.cancel()
        continuation?.resume(with: result)
    }
}
