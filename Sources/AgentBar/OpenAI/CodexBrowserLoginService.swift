import AppKit
import CryptoKit
import Foundation
import Network
import Security

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@MainActor
struct CodexBrowserLoginService {
    private let callbackPorts: [UInt16] = [1457, 1455]

    func signIn(mode: CodexBrowserLoginMode = .browserSession) async throws -> CodexStoredAuthSession {
        let pkce = try CodexPKCE.generate()
        let state = try CodexPKCE.randomURLSafeString(byteCount: 32)
        let callbackServer = try await CodexOAuthCallbackServer.start(preferredPorts: callbackPorts)
        let redirectURI = "http://localhost:\(callbackServer.port)/auth/callback"
        let authURL = try buildAuthorizeURL(
            redirectURI: redirectURI,
            codeChallenge: pkce.codeChallenge,
            state: state,
            mode: mode
        )

        guard NSWorkspace.shared.open(authURL) else {
            callbackServer.cancel()
            throw CodexBrowserLoginError.browserOpenFailed
        }

        let callback = try await callbackServer.waitForCallback()
        if let error = callback.error {
            throw CodexBrowserLoginError.oauthCallbackFailed(error)
        }

        guard callback.state == state else {
            throw CodexBrowserLoginError.stateMismatch
        }

        guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw CodexBrowserLoginError.missingAuthorizationCode
        }

        let tokens = try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier
        )

        guard let accountID = CodexAppAuthStore.identity(from: tokens.idToken)?.accountID,
              !accountID.isEmpty else {
            throw CodexBrowserLoginError.missingAccountID
        }

        let session = CodexStoredAuthSession(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accountID: accountID,
            lastRefresh: Date()
        )

        return session
    }

    func buildAuthorizeURL(
        redirectURI: String,
        codeChallenge: String,
        state: String,
        mode: CodexBrowserLoginMode = .browserSession
    ) throws -> URL {
        var components = URLComponents(url: CodexOAuthConfiguration.authorizationURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexOAuthConfiguration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: CodexOAuthConfiguration.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: CodexOAuthConfiguration.originator)
        ]
        queryItems.append(contentsOf: mode.additionalAuthorizeQueryItems)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw CodexBrowserLoginError.invalidAuthorizeURL
        }

        return url
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexOAuthTokenResponse {
        var request = URLRequest(url: CodexOAuthConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", CodexOAuthConfiguration.clientID),
            ("code_verifier", codeVerifier)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexBrowserLoginError.invalidTokenResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            throw CodexBrowserLoginError.tokenExchangeFailed(httpResponse.statusCode, body)
        }

        return try JSONDecoder().decode(CodexOAuthTokenResponse.self, from: data)
    }

    private func formURLEncoded(_ items: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: ":#[]@!$&'()*+,;=")
        )
        let body = items.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")

        return Data(body.utf8)
    }
}

enum CodexBrowserLoginMode: Equatable, Sendable {
    case browserSession
    case forceAccountSelection

    var additionalAuthorizeQueryItems: [URLQueryItem] {
        switch self {
        case .browserSession:
            return []
        case .forceAccountSelection:
            return [URLQueryItem(name: "prompt", value: "login")]
        }
    }
}

enum CodexBrowserLoginError: LocalizedError {
    case browserOpenFailed
    case invalidAuthorizeURL
    case missingAuthorizationCode
    case missingAccountID
    case stateMismatch
    case invalidTokenResponse
    case oauthCallbackFailed(String)
    case tokenExchangeFailed(Int, String)
    case callbackServerFailed(String)

    var errorDescription: String? {
        switch self {
        case .browserOpenFailed:
            return "AgentBar could not open the browser for Codex sign-in."
        case .invalidAuthorizeURL:
            return "AgentBar could not build the Codex sign-in URL."
        case .missingAuthorizationCode:
            return "Codex sign-in did not return an authorization code."
        case .missingAccountID:
            return "Codex sign-in did not return a ChatGPT account id."
        case .stateMismatch:
            return "Codex sign-in callback validation failed."
        case .invalidTokenResponse:
            return "Codex sign-in returned an invalid token response."
        case let .oauthCallbackFailed(message):
            return "Codex sign-in failed: \(message)"
        case let .tokenExchangeFailed(status, body):
            return "Codex token exchange failed with HTTP \(status): \(body)"
        case let .callbackServerFailed(message):
            return "Codex sign-in callback server failed: \(message)"
        }
    }
}

private struct CodexOAuthTokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct CodexPKCE {
    let codeVerifier: String
    let codeChallenge: String

    static func generate() throws -> CodexPKCE {
        let verifier = try randomURLSafeString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return CodexPKCE(codeVerifier: verifier, codeChallenge: challenge)
    }

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
        }

        guard status == errSecSuccess else {
            throw CodexBrowserLoginError.callbackServerFailed("Secure random generation failed.")
        }

        return data.base64URLEncodedString()
    }
}

private struct CodexOAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

private final class CodexOAuthCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.agentbar.codex-oauth-callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodexOAuthCallback, Error>?
    private var completedResult: Result<CodexOAuthCallback, Error>?

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(preferredPorts: [UInt16]) async throws -> CodexOAuthCallbackServer {
        var lastError: Error?
        for port in preferredPorts {
            do {
                return try await start(port: port)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CodexBrowserLoginError.callbackServerFailed("No callback port was available.")
    }

    func waitForCallback() async throws -> CodexOAuthCallback {
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
        finish(.failure(CodexBrowserLoginError.callbackServerFailed("Sign-in was cancelled.")))
    }

    private static func start(port: UInt16) async throws -> CodexOAuthCallbackServer {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CodexBrowserLoginError.callbackServerFailed("Invalid callback port \(port).")
        }

        let listener = try NWListener(using: .tcp, on: endpointPort)
        let server = CodexOAuthCallbackServer(listener: listener, port: port)

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
                        continuation.resume(throwing: CodexBrowserLoginError.callbackServerFailed(error.localizedDescription))
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
                self.sendResponse(
                    status: 400,
                    body: "AgentBar could not read the Codex sign-in callback.",
                    connection: connection
                )
                self.finish(.failure(CodexBrowserLoginError.callbackServerFailed(error.localizedDescription)))
                return
            }

            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let callback = Self.parseCallback(from: request) else {
                self.sendResponse(
                    status: 400,
                    body: "AgentBar could not parse the Codex sign-in callback.",
                    connection: connection
                )
                self.finish(.failure(CodexBrowserLoginError.callbackServerFailed("Invalid callback request.")))
                return
            }

            if callback.error == nil {
                self.sendResponse(
                    status: 200,
                    body: "Codex sign-in completed. You can close this window.",
                    connection: connection
                )
            } else {
                self.sendResponse(
                    status: 400,
                    body: "Codex sign-in failed. Return to AgentBar to try again.",
                    connection: connection
                )
            }
            self.finish(.success(callback))
        }
    }

    private static func parseCallback(from request: String) -> CodexOAuthCallback? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(path)"),
              components.path == "/auth/callback" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        let error = value("error_description") ?? value("error")
        return CodexOAuthCallback(
            code: value("code"),
            state: value("state"),
            error: error
        )
    }

    private func sendResponse(status: Int, body: String, connection: NWConnection) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>AgentBar Codex Sign In</title></head>
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

    private func finish(_ result: Result<CodexOAuthCallback, Error>) {
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

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
