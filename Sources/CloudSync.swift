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
    static let defaultBaseURL = "https://input-stats-cloud.up.railway.app"

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

    private let session = URLSession(configuration: .default)

    // MARK: State + callbacks (invoked on the main queue)

    /// Fired when login state changes (connected / signed out) so the menu can rebuild.
    var onStateChange: (() -> Void)?
    /// Fired with a freshly pulled/merged blob from the server.
    var onPulled: ((SyncData) -> Void)?

    var deviceToken: String? { Keychain.get(tokenAccount) }
    var signingSecret: String? { Keychain.get(secretAccount) }
    var isConnected: Bool { deviceToken != nil && signingSecret != nil }
    var accountEmail: String? { UserDefaults.standard.string(forKey: emailKey) }

    // MARK: Login

    func beginLogin() {
        NSWorkspace.shared.open(baseURL.appendingPathComponent("connect"))
    }

    /// Handle the `inputstats://connected?token=…` redirect from the browser.
    func handleCallback(url: URL) {
        guard url.host == "connected",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return
        }
        Keychain.set(token, for: tokenAccount)
        provision(token: token)
    }

    func signOut() {
        Keychain.delete(tokenAccount)
        Keychain.delete(secretAccount)
        UserDefaults.standard.removeObject(forKey: emailKey)
        DispatchQueue.main.async { self.onStateChange?() }
    }

    /// Exchange the device token for the HMAC signing secret (over HTTPS).
    private func provision(token: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/device/provision"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let body = try? JSONDecoder().decode(ProvisionResponse.self, from: data) else {
                return
            }
            Keychain.set(body.signingSecret, for: self.secretAccount)
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
    func push(_ deviceData: SyncData) {
        guard let token = deviceToken, let secret = signingSecret else { return }
        guard let body = try? JSONEncoder().encode(deviceData) else { return }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/sync"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.signature(body: body, secret: secret), forHTTPHeaderField: "X-Signature")
        req.httpBody = body

        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let wrapped = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.onPulled?(wrapped.data) }
        }.resume()
    }

    func pull() {
        guard let token = deviceToken else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/sync"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let wrapped = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.onPulled?(wrapped.data) }
        }.resume()
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
}

private struct SyncEnvelope: Decodable {
    let data: SyncData
}
