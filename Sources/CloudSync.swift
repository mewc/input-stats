import Foundation
import CryptoKit
import AppKit

/// Optional cloud sync to the Input Stats backend (Next.js + Postgres on Railway).
///
/// A new login uses a short-lived PKCE browser handoff; released clients can
/// still finish the legacy token/provision flow. Long-lived per-device secrets
/// live in Keychain. Daily sync and privacy-safe minute uploads are best-effort
/// and never block input handling; iCloud remains the offline fallback.
final class CloudSync {
    static let shared = CloudSync()

    // MARK: Config

    /// Backend this build talks to. Release pairs with production only; the dev
    /// build pairs with a local `next dev` only — never mix environments. Override
    /// at runtime with `defaults write com.mewc.input-stats[.dev] cloudBaseURL https://…`
    static let defaultBaseURL = isDevBuild
        ? "http://localhost:3000"
        : "https://input-stats.drummerduck.com"

    var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "cloudBaseURL"),
           let u = URL(string: s) {
            return u
        }
        return URL(string: CloudSync.defaultBaseURL)!
    }

    private let tokenAccount = "deviceToken"
    private let secretAccount = "signingSecret"
    private let serverDeviceAccount = "serverDeviceID"
    private let pendingVerifierAccount = "pendingPairingVerifier"
    private let emailKey = "cloudAccountEmail"
    private let stateLock = NSLock()
    private var storedError: String?

    var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedError
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: State + callbacks (invoked on the main queue)

    /// Fired when login state changes (connected / signed out) so the menu can rebuild.
    var onStateChange: (() -> Void)?
    /// Fired with a freshly pulled/merged blob from the server.
    var onPulled: ((SyncData) -> Void)?

    var deviceToken: String? { Keychain.get(tokenAccount) }
    var signingSecret: String? { Keychain.get(secretAccount) }
    var serverDeviceID: String? { Keychain.get(serverDeviceAccount) }
    var isConnected: Bool { deviceToken != nil && signingSecret != nil }
    var isConnecting: Bool {
        (deviceToken != nil && signingSecret == nil) || Keychain.get(pendingVerifierAccount) != nil
    }
    var accountEmail: String? { UserDefaults.standard.string(forKey: emailKey) }

    /// Released clients already have a token and signing secret, but did not
    /// persist the server device ID introduced for minute-upload cursors. Fetch
    /// it once with the existing credential so upgrades backfill automatically.
    func refreshDeviceIdentityIfNeeded() {
        guard CloudSyncMigration.needsServerDeviceIdentity(
            hasToken: deviceToken != nil,
            hasServerDeviceID: serverDeviceID != nil
        ), let token = deviceToken else { return }
        provision(token: token)
    }

    // MARK: Login

    func beginLogin(clientDeviceID: String, deviceName: String) {
        setStoredError(nil)
        onStateChange?()

        let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        let payload = PairingStartRequest(
            clientDeviceId: clientDeviceID,
            deviceName: deviceName,
            pkceChallenge: challenge
        )
        guard let body = try? JSONEncoder().encode(payload),
              Keychain.set(verifier, for: pendingVerifierAccount) else {
            reportError("Could not prepare cloud sign-in.")
            return
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/device/link/start"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 201,
                  let data,
                  let response = try? JSONDecoder().decode(PairingStartResponse.self, from: data),
                  let url = URL(string: response.browserUrl) else {
                Keychain.delete(self.pendingVerifierAccount)
                self.reportError("Cloud sign-in could not be started.")
                return
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }.resume()
    }

    /// Handle the `<scheme>://connected?token=…` redirect from the browser.
    func handleCallback(url: URL) {
        guard url.scheme == appURLScheme,
              url.host == "connected",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }
        if let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            completePairing(code: code)
            return
        }
        guard let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return }
        Keychain.delete(secretAccount)
        guard Keychain.set(token, for: tokenAccount) else {
            reportError("Could not save the sign-in token.")
            return
        }
        setStoredError(nil)
        DispatchQueue.main.async { self.onStateChange?() }
        provision(token: token)
    }

    func signOut() {
        Keychain.delete(tokenAccount)
        Keychain.delete(secretAccount)
        Keychain.delete(serverDeviceAccount)
        Keychain.delete(pendingVerifierAccount)
        UserDefaults.standard.removeObject(forKey: emailKey)
        setStoredError(nil)
        DispatchQueue.main.async { self.onStateChange?() }
    }

    /// Complete either the custom-URL handoff or a manually entered fallback code.
    func completePairing(code: String) {
        guard let verifier = Keychain.get(pendingVerifierAccount) else {
            reportError("Start sign-in from this Mac before entering a connection code.")
            return
        }
        guard let body = try? JSONEncoder().encode(
            PairingCompleteRequest(code: code, pkceVerifier: verifier)
        ) else {
            reportError("Could not encode the connection code.")
            return
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/device/link/complete"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let response = try? JSONDecoder().decode(PairingCompleteResponse.self, from: data) else {
                self.reportError("The connection code is invalid or expired.")
                return
            }

            guard Keychain.set(response.deviceToken, for: self.tokenAccount),
                  Keychain.set(response.signingSecret, for: self.secretAccount),
                  Keychain.set(response.deviceId, for: self.serverDeviceAccount) else {
                Keychain.delete(self.tokenAccount)
                Keychain.delete(self.secretAccount)
                Keychain.delete(self.serverDeviceAccount)
                self.reportError("Could not save cloud credentials.")
                return
            }
            Keychain.delete(self.pendingVerifierAccount)
            if let email = response.email { UserDefaults.standard.set(email, forKey: self.emailKey) }
            self.setStoredError(nil)
            DispatchQueue.main.async {
                self.onStateChange?()
                self.pull()
            }
        }.resume()
    }

    /// Exchange the device token for the HMAC signing secret (over HTTPS).
    private func provision(token: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/device/provision"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let body = try? JSONDecoder().decode(ProvisionResponse.self, from: data) else {
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    self.expireCredentials()
                } else {
                    self.reportError("Cloud sign-in could not be completed.")
                }
                return
            }
            guard Keychain.set(body.signingSecret, for: self.secretAccount) else {
                self.reportError("Could not save the sync key.")
                return
            }
            _ = Keychain.set(body.deviceId, for: self.serverDeviceAccount)
            if let email = body.email, !email.isEmpty {
                UserDefaults.standard.set(email, forKey: self.emailKey)
            }
            self.setStoredError(nil)
            DispatchQueue.main.async {
                self.onStateChange?()
                self.pull()
            }
        }.resume()
    }

    // MARK: Sync

    /// Upload this device's counts. `deviceData` should be a SyncData containing
    /// only this device's entry (server merges by max, so re-asserting others is
    /// unnecessary and risks resurrecting a reset elsewhere).
    func push(_ deviceData: SyncData, completion: ((Bool) -> Void)? = nil) {
        guard let token = deviceToken, let secret = signingSecret else {
            completion?(false)
            return
        }
        guard let body = try? JSONEncoder().encode(deviceData) else {
            reportError("Could not encode sync data.")
            completion?(false)
            return
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/sync"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.signature(body: body, secret: secret), forHTTPHeaderField: "X-Signature")
        req.httpBody = body

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else {
                completion?(false)
                return
            }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let wrapped = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    self.expireCredentials()
                } else {
                    self.reportError("Cloud sync failed. It will retry automatically.")
                }
                completion?(false)
                return
            }
            self.clearError()
            completion?(true)
            DispatchQueue.main.async { self.onPulled?(wrapped.data) }
        }.resume()
    }

    func pull() {
        guard let token = deviceToken else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/sync"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let wrapped = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    self.expireCredentials()
                } else {
                    self.reportError("Cloud sync failed. It will retry automatically.")
                }
                return
            }
            self.clearError()
            DispatchQueue.main.async { self.onPulled?(wrapped.data) }
        }.resume()
    }

    /// Upload completed one-minute numeric summaries. Five-second rows and input
    /// contents never enter this request.
    func pushMinutes(clientDeviceID: String,
                     buckets: [EventStore.MinuteBucket],
                     completion: @escaping (String?) -> Void) {
        guard !buckets.isEmpty,
              let token = deviceToken,
              let secret = signingSecret else {
            completion(nil)
            return
        }
        let request = MinuteBatchPayload(
            schemaVersion: 1,
            clientDeviceId: clientDeviceID,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            buckets: buckets.map { bucket in
                MinuteBucketPayload(
                    startedAt: bucket.startedAt,
                    utcOffsetMinutes: bucket.utcOffsetMinutes,
                    keys: bucket.keys,
                    clicks: MinuteClicksPayload(
                        left: bucket.clicksLeft,
                        right: bucket.clicksRight,
                        other: bucket.clicksOther
                    ),
                    scrollTicks: bucket.scrollTicks,
                    pointerDistance: bucket.pointerDistance,
                    apps: bucket.apps.map {
                        MinuteAppPayload(bundleId: $0.bundleID, keys: $0.keys)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(request) else {
            reportError("Could not encode minute statistics.")
            completion(nil)
            return
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/v1/minutes"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.signature(body: body, secret: secret), forHTTPHeaderField: "X-Signature")
        req.httpBody = body

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { completion(nil); return }
            guard error == nil,
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let response = try? JSONDecoder().decode(MinuteBatchResponse.self, from: data) else {
                if (resp as? HTTPURLResponse)?.statusCode == 401 {
                    self.expireCredentials()
                } else if (resp as? HTTPURLResponse)?.statusCode == 409 {
                    self.reportError("Minute history conflicts with the cloud copy.")
                } else {
                    self.reportError("Minute sync failed. It will retry automatically.")
                }
                completion(nil)
                return
            }
            self.clearError()
            completion(response.acceptedThrough)
        }.resume()
    }

    private func clearError() {
        guard lastError != nil else { return }
        setStoredError(nil)
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func reportError(_ message: String) {
        setStoredError(message)
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func expireCredentials() {
        Keychain.delete(tokenAccount)
        Keychain.delete(secretAccount)
        Keychain.delete(serverDeviceAccount)
        UserDefaults.standard.removeObject(forKey: emailKey)
        setStoredError("Cloud session expired. Sign in again.")
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func setStoredError(_ message: String?) {
        stateLock.lock()
        storedError = message
        stateLock.unlock()
    }

    // MARK: Signing

    /// Stripe-webhook-style `t=<unix>,v1=<hex hmac-sha256(secret, "<t>.<body>")>`.
    /// The secret's UTF-8 bytes are the HMAC key, matching Node's
    /// `createHmac("sha256", secret)` on the server.
    private static func signature(body: Data, secret: String) -> String {
        let t = Int(Date().timeIntervalSince1970)
        var signed = Data("\(t).".utf8)
        signed.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "t=\(t),v1=\(hex)"
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

private struct PairingStartRequest: Encodable {
    let clientDeviceId: String
    let deviceName: String
    let pkceChallenge: String
}

private struct PairingStartResponse: Decodable {
    let requestId: String
    let browserUrl: String
    let expiresAt: String
}

private struct PairingCompleteRequest: Encodable {
    let code: String
    let pkceVerifier: String
}

private struct PairingCompleteResponse: Decodable {
    let deviceId: String
    let userId: String
    let deviceToken: String
    let signingSecret: String
    let email: String?
}

private struct MinuteBatchResponse: Decodable {
    let acceptedThrough: String
    let accepted: Int
}

private struct ProvisionResponse: Decodable {
    let deviceId: String
    let userId: String
    let signingSecret: String
    let email: String?
}

private struct SyncEnvelope: Decodable {
    let data: SyncData
}
