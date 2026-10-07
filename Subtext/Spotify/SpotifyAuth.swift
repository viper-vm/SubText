import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftUI

enum SpotifyError: LocalizedError {
    case noClientID
    case notConnected
    case unauthorized
    case rateLimited(Double)
    case denied(String)
    case badCallback
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noClientID:
            "Add your Spotify Client ID in Settings first."
        case .notConnected:
            "Spotify isn't connected."
        case .unauthorized:
            "Spotify asked to sign in again."
        case .rateLimited:
            "Spotify asked us to slow down for a moment."
        case .denied(let reason):
            reason == "access_denied" ? "Spotify sign-in was cancelled." : "Spotify sign-in failed: \(reason)."
        case .badCallback:
            "Spotify sign-in didn't finish. Please try again."
        case .http(let code, let message):
            if code == 403 {
                "Spotify refused (\(message)). Check that your account is added under User Management in the Spotify dashboard and has Premium."
            } else {
                "Spotify error \(code): \(message)"
            }
        }
    }

    /// Pulls `error.message` (or `error_description`) out of a Spotify error body.
    static func message(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let description = json["error_description"] as? String { return description }
        if let error = json["error"] as? String { return error }
        return ""
    }
}

/// Spotify sign-in with PKCE (no client secret), plus token refresh.
@MainActor
@Observable
final class SpotifyAuth {
    static let scopes = "user-read-currently-playing user-read-playback-state"
    private static let refreshAccount = "spotify.refreshToken"

    private(set) var isConnected: Bool
    /// The Spotify profile name, shown in Settings.
    private(set) var accountName: String?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiresAt = Date.distantPast

    init() {
        isConnected = Keychain.get(Self.refreshAccount) != nil
    }

    func connect(using session: WebAuthenticationSession) async throws {
        let clientID = Prefs.spotifyClientID
        guard !clientID.isEmpty else { throw SpotifyError.noClientID }

        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Config.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]

        let callback = try await session.authenticate(using: components.url!, callbackURLScheme: "subtext",
                                                      preferredBrowserSession: .shared)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw SpotifyError.denied(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw SpotifyError.badCallback }

        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.spotifyRedirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    func validToken() async throws -> String {
        if let token = accessToken, Date() < expiresAt.addingTimeInterval(-60) { return token }
        guard let refresh = Keychain.get(Self.refreshAccount) else {
            isConnected = false
            throw SpotifyError.notConnected
        }
        try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Prefs.spotifyClientID,
        ])
        guard let token = accessToken else { throw SpotifyError.notConnected }
        return token
    }

    func loadAccountName() async {
        guard isConnected, accountName == nil, let token = try? await validToken() else { return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let profile = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else { return }
        let name = (profile["display_name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        accountName = name.isEmpty ? profile["id"] as? String : name
    }

    func invalidateAccessToken() {
        accessToken = nil
        expiresAt = .distantPast
    }

    func disconnect() {
        Keychain.delete(Self.refreshAccount)
        invalidateAccessToken()
        isConnected = false
        accountName = nil
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.formEncoded.utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // A refresh token that Spotify no longer accepts means signing in again.
            if form["grant_type"] == "refresh_token", status == 400 || status == 401 { disconnect() }
            throw SpotifyError.http(status, SpotifyError.message(from: data))
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
        if let refresh = token.refresh_token { Keychain.set(refresh, for: Self.refreshAccount) }
        isConnected = true
    }
}

enum PKCE {
    static func makeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Dictionary where Key == String, Value == String {
    var formEncoded: String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }
}
