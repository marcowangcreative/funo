import Foundation
import CryptoKit

/// Offline license verification - Ed25519-signed keys, minted by the
/// companion `license_tool.swift` (repo root) with a private key that never
/// ships. The app embeds only the PUBLIC key: a valid signature proves the
/// key came from us, so keygens are cryptographically impossible. This
/// keeps honest users honest; it does not pretend to stop binary patchers
/// (nothing does), so nothing here is worth contorting the app around.
///
/// Key format:  FUNO.<base64url payload JSON>.<base64url signature>
/// Payload:     {"email": "...", "id": "...", "issued": "...", "plan": "full"}
final class LicenseManager {

    static let shared = LicenseManager()

    /// PASTE the public key printed by `swift license_tool.swift gen` here.
    /// While this placeholder remains, no license validates (trial still runs).
    private static let publicKeyBase64 = "p2I2hjfO51WYeggyspDuzu/yoKOLTVmCf+2PsLd2wdY="

    static let trialDays = 14

    /// Optional hard cutoff for time-limited builds (disclosed, not a hidden
    /// kill switch). RETIRED in favor of the per-user 14-day demo - every
    /// install gates itself, no calendar cliff needed. Keep nil unless a
    /// build ever needs a fleet-wide end date again.
    static let betaExpiry: Date? = nil

    static var betaExpired: Bool {
        guard let cutoff = betaExpiry else { return false }
        return Date() > cutoff
    }

    enum Status {
        case licensed(email: String)
        case trial(daysLeft: Int)
        case expired
    }

    struct Payload: Codable {
        let email: String
        let id: String
        let issued: String
        let plan: String
    }

    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("QuickCull", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var licenseFile: URL { dir.appendingPathComponent("license.key") }
    private var firstRunFile: URL { dir.appendingPathComponent(".firstrun") }

    // MARK: - Status

    var status: Status {
        if let email = validLicenseEmail() { return .licensed(email: email) }
        if let display = polarLicenseDisplay() { return .licensed(email: display) }
        // Fleet-wide cutoff, if a build ever sets one (nil today - the
        // per-user demo below is the whole gating model).
        if let cutoff = Self.betaExpiry, Date() > cutoff { return .expired }
        let days = trialDaysLeft()
        return days > 0 ? .trial(daysLeft: days) : .expired
    }

    var isUsable: Bool {
        if case .expired = status { return false }
        return true
    }

    // MARK: - Activation

    /// Validate and persist a key - completion always on the MAIN thread.
    /// Two key families coexist:
    ///   FUNO.payload.sig - our Ed25519 keys, verified OFFLINE, instant.
    ///   FUNO-XXXX-…      - Polar-issued keys, validated against Polar's API
    ///                      (org-scoped, no secrets involved).
    func activate(_ rawKey: String, completion: @escaping (_ display: String?, _ error: String?) -> Void) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("FUNO.") {
            guard let email = Self.verify(key) else {
                completion(nil, "That key didn't validate. Check for missing characters.")
                return
            }
            try? Data(key.utf8).write(to: licenseFile)
            UserDefaults.standard.set(key, forKey: "QuickCullLicense")
            completion(email, nil)
        } else if key.hasPrefix("FUNO-") {
            polarActivate(key, completion: completion)
        } else {
            completion(nil, "Keys start with FUNO. or FUNO- - paste the whole thing from your receipt.")
        }
    }

    private func validLicenseEmail() -> String? {
        let stored = (try? String(contentsOf: licenseFile, encoding: .utf8))
            ?? UserDefaults.standard.string(forKey: "QuickCullLicense")
        guard let stored else { return nil }
        return Self.verify(stored.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Signature check - returns the payload email iff the key is genuine.
    private static func verify(_ key: String) -> String? {
        guard key.hasPrefix("FUNO.") else { return nil }
        let parts = key.dropFirst(5).split(separator: ".")
        guard parts.count == 2,
              let payloadData = Data(base64URL: String(parts[0])),
              let sigData = Data(base64URL: String(parts[1])),
              let pubData = Data(base64Encoded: publicKeyBase64),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
              pubKey.isValidSignature(sigData, for: payloadData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { return nil }
        return payload.email
    }

    // MARK: - Polar (store-issued keys)

    /// Organization ID from the Polar dashboard (Settings → General).
    /// PUBLIC - it only scopes lookups so keys from other orgs can't collide.
    private static let polarOrgID = "1abc1d85-c2d9-400c-8aa7-d746fb2a46ce"
    private static let polarAPI = "https://api.polar.sh/v1/customer-portal/license-keys"

    private struct PolarState: Codable {
        var key: String
        var activationID: String?
        var display: String
        var lastValidated: Date
    }
    private var polarFile: URL { dir.appendingPathComponent("polar-license.json") }

    private func loadPolarState() -> PolarState? {
        guard let data = try? Data(contentsOf: polarFile) else { return nil }
        return try? JSONDecoder().decode(PolarState.self, from: data)
    }
    private func savePolarState(_ state: PolarState?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            try? data.write(to: polarFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: polarFile)
        }
        UserDefaults.standard.set(state?.key, forKey: "QuickCullPolarKey")
    }

    /// Licensed display string if a Polar license is on file. Deliberately
    /// NETWORK-OPTIMISTIC: a stored license stays valid on pure silence
    /// (photographers work offline for weeks on location) - only a
    /// DEFINITIVE revocation from Polar clears it (see revalidate below,
    /// fired on every launch). A pirate who firewalls api.polar.sh forever
    /// beats revocation; he was never going to pay, and he loses updates.
    private func polarLicenseDisplay() -> String? {
        loadPolarState()?.display
    }

    /// POST helper - both endpoints take the same JSON shape.
    private func polarRequest(_ endpoint: String, body: [String: Any],
                              completion: @escaping (Int?, [String: Any]?) -> Void) {
        guard let url = URL(string: "\(Self.polarAPI)/\(endpoint)") else { completion(nil, nil); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { completion(code, json) }
        }.resume()
    }

    private func polarActivate(_ key: String, completion: @escaping (String?, String?) -> Void) {
        guard Self.polarOrgID != "REPLACE_WITH_POLAR_ORG_ID" else {
            completion(nil, "Store keys aren't enabled in this build yet.")
            return
        }
        let label = Host.current().localizedName ?? "Mac"
        polarRequest("activate", body: ["key": key, "organization_id": Self.polarOrgID, "label": label]) { [weak self] code, json in
            guard let self else { return }
            switch code {
            case .some(200...299):
                let activationID = json?["id"] as? String
                let licenseKey = json?["license_key"] as? [String: Any]
                let customer = licenseKey?["customer"] as? [String: Any]
                let display = (customer?["email"] as? String) ?? "\(key.prefix(14))…"
                self.savePolarState(PolarState(key: key, activationID: activationID,
                                               display: display, lastValidated: Date()))
                completion(display, nil)
            case .some(403):
                completion(nil, "This key is already active on its limit of Macs. Deactivate one in your Polar purchase portal, then retry.")
            case .some(404), .some(400...499):
                completion(nil, "That key didn't validate. Paste the whole key from your receipt.")
            default:
                completion(nil, "Couldn't reach the license server - check your connection and try again.")
            }
        }
    }

    /// Fire-and-forget, called at launch: refresh the stored Polar license.
    /// Success bumps the timestamp; a definitive "gone" (revoked/refunded)
    /// clears it; network silence changes nothing.
    func revalidateInBackground() {
        guard let state = loadPolarState(), Self.polarOrgID != "REPLACE_WITH_POLAR_ORG_ID" else { return }
        var body: [String: Any] = ["key": state.key, "organization_id": Self.polarOrgID]
        if let id = state.activationID { body["activation_id"] = id }
        polarRequest("validate", body: body) { [weak self] code, json in
            guard let self else { return }
            switch code {
            case .some(200...299):
                var refreshed = state
                refreshed.lastValidated = Date()
                if let licenseKey = json?["license_key"] as? [String: Any],
                   let customer = licenseKey["customer"] as? [String: Any],
                   let email = customer["email"] as? String {
                    refreshed.display = email
                }
                self.savePolarState(refreshed)
            case .some(404), .some(403):
                // Definitively dead: revoked, refunded, or deactivated.
                self.savePolarState(nil)
            default:
                break // offline / server hiccup - keep the license
            }
        }
    }

    // MARK: - Trial

    /// Days remaining. First launch is recorded in Application Support AND
    /// UserDefaults; the EARLIEST surviving stamp wins, so deleting one of
    /// them doesn't restart the clock. (A determined tamperer can still
    /// reset a trial - that's fine; they were never going to pay today.)
    private func trialDaysLeft() -> Int {
        let now = Date()
        var stamps: [Date] = []
        if let s = try? String(contentsOf: firstRunFile, encoding: .utf8),
           let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            stamps.append(Date(timeIntervalSince1970: t))
        }
        let d = UserDefaults.standard.double(forKey: "QuickCullFirstLaunch")
        if d > 0 { stamps.append(Date(timeIntervalSince1970: d)) }

        let first: Date
        if let earliest = stamps.min() {
            first = earliest
        } else {
            first = now
            try? String(now.timeIntervalSince1970).write(to: firstRunFile, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "QuickCullFirstLaunch")
        }
        let used = Calendar.current.dateComponents([.day], from: first, to: now).day ?? 0
        return max(0, Self.trialDays - used)
    }
}

private extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
