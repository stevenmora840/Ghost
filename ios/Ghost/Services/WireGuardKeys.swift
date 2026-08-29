import CryptoKit
import Foundation

/// Device-side WireGuard key handling. The private key is generated here,
/// stored only in the Keychain, and never sent to the control plane — the
/// backend sees the public key alone.
enum WireGuardKeys {
    /// Returns the device's WireGuard public key (base64), generating and
    /// persisting a keypair on first call.
    static func ensureKeypair() -> String {
        if let existing = KeychainStore.get(.wireGuardPrivateKey),
           let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: existing) ?? Data()) {
            return priv.publicKey.rawRepresentation.base64EncodedString()
        }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.set(priv.rawRepresentation.base64EncodedString(), for: .wireGuardPrivateKey)
        return priv.publicKey.rawRepresentation.base64EncodedString()
    }

    static var privateKeyBase64: String? {
        KeychainStore.get(.wireGuardPrivateKey)
    }
}
