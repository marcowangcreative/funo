#!/usr/bin/env swift
// f/uno license tool — mint Ed25519-signed license keys.
//
//   swift license_tool.swift gen
//       → prints a new PRIVATE and PUBLIC key. Run ONCE. Keep the private
//         key in a password manager; paste the public key into
//         Sources/QuickCull/LicenseManager.swift (publicKeyBase64).
//
//   swift license_tool.swift sign <privateKeyBase64> <email>
//       → prints a FUNO.… license key for that customer.
import Foundation
import CryptoKit

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "gen":
    let priv = Curve25519.Signing.PrivateKey()
    print("PRIVATE (keep secret, e.g. 1Password):")
    print("  \(priv.rawRepresentation.base64EncodedString())")
    print("PUBLIC  (paste into LicenseManager.publicKeyBase64):")
    print("  \(priv.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard args.count == 4,
          let privData = Data(base64Encoded: args[2]),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
        print("usage: swift license_tool.swift sign <privateKeyBase64> <email>"); exit(1)
    }
    let email = args[3]
    let iso = ISO8601DateFormatter().string(from: Date())
    let payload = #"{"email":"\#(email)","id":"\#(UUID().uuidString)","issued":"\#(iso)","plan":"full"}"#
    let data = Data(payload.utf8)
    guard let sig = try? priv.signature(for: data) else { print("signing failed"); exit(1) }
    print("FUNO.\(b64url(data)).\(b64url(sig))")
default:
    print("usage: swift license_tool.swift gen | sign <privateKeyBase64> <email>")
}
