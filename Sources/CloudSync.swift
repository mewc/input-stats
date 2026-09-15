import Foundation
import CryptoKit
import AppKit

/// Optional cloud sync to the Input Stats backend (Next.js + Postgres on Railway).
///
/// Flow:
///  1. `beginLogin()` opens `<baseURL>/connect` in the browser (Google sign-in).
///  2. The server redirects to `inputstats://connected?token=…`; the app delegate
///     forwards that URL to `handleCallback(url:)`.
///  3. We store the opaque device token, then `provision()` fetches the per-device
///     HMAC signing secret over HTTPS and stores it in the Keychain.
///  4. `push(deviceData:)` uploads this device's counts (HMAC-signed);
///     `pull()` fetches the user's merged blob. Both are best-effort and never
///     block input handling — iCloud remains the offline fallback.
final class CloudSync {
    static let shared = CloudSync()

    // MARK: Config

    /// Public URL of the deployed backend. Override at runtime for dev with:
    /// `defaults write com.mewc.input-stats cloudBaseURL https://…`
    static let defaultBaseURL = "https://input-stats.drummerduck.com"

    var baseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "cloudBaseURL"),
           let u = URL(string: s) {
            return u
        }
        return URL(string: CloudSync.defaultBaseURL)!
    }

    private let tokenAccount = "deviceToken"
    private let secretAccount = "signingSecret"
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
    var isConnected: Bool { deviceToken != nil && signingSecret != nil }
    var isConnecting: Bool { deviceToken != nil && signingSecret == nil }
    var accountEmail: String? { UserDefaults.standard.string(forKey: emailKey) }

    // MARK: Login

    func beginLogin() {
        setStoredError(nil)
        onStateChange?()
        NSWorkspace.shared.open(baseURL.appendingPathComponent("connect"))
    }

    /// Handle the `inputstats://connected?token=…` redirect from the browser.
    func handleCallback(url: URL) {
        guard url.scheme == "inputstats",
              url.host == "connected",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return
        }
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
        UserDefaults.standard.removeObject(forKey: emailKey)
        setStoredError(nil)
        DispatchQueue.main.async { self.onStateChange?() }
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

private struct ProvisionResponse: Decodable {
    let deviceId: String
    let userId: String
    let signingSecret: String
    let email: String?
}

private struct SyncEnvelope: Decodable {
    let data: SyncData
}
