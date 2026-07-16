import Foundation
import CryptoKit

/// Offline license verification — Ed25519-signed keys, minted by the
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

    static let trialDays = 30

    /// Hard beta cutoff. This build is time-limited: after this date an
    /// UNLICENSED copy stops culling and prompts for a license — licensed
    /// users are unaffected. This is disclosed to testers (see TESTERS.md),
    /// NOT a hidden kill switch. Bump the date in each new beta build; set to
    /// nil for the paid release so purchased copies never expire.
    static let betaExpiry: Date? = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 9, day: 15))

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
        if Self.betaExpired { return .expired }   // beta window closed → must license
        let days = trialDaysLeft()
        return days > 0 ? .trial(daysLeft: days) : .expired
    }

    var isUsable: Bool {
        if case .expired = status { return false }
        return true
    }

    // MARK: - Activation

    /// Validate and persist a key. Returns the licensed email on success.
    @discardableResult
    func activate(_ rawKey: String) -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = Self.verify(key) else { return nil }
        try? Data(key.utf8).write(to: licenseFile)
        UserDefaults.standard.set(key, forKey: "QuickCullLicense")
        return email
    }

    private func validLicenseEmail() -> String? {
        let stored = (try? String(contentsOf: licenseFile, encoding: .utf8))
            ?? UserDefaults.standard.string(forKey: "QuickCullLicense")
        guard let stored else { return nil }
        return Self.verify(stored.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Signature check — returns the payload email iff the key is genuine.
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

    // MARK: - Trial

    /// Days remaining. First launch is recorded in Application Support AND
    /// UserDefaults; the EARLIEST surviving stamp wins, so deleting one of
    /// them doesn't restart the clock. (A determined tamperer can still
    /// reset a trial — that's fine; they were never going to pay today.)
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
