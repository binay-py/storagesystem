// Same key derivation and encryption as public/app.js, so anything this app
// uploads opens normally in the Sanduk web app.
//   secret (base64url) -> HKDF-SHA256, salt = 32 zero bytes
//     info "sanduk/auth/v1" -> 32 bytes -> hex  = bearer token
//     info "sanduk/enc/v1"  -> 32 bytes         = AES-GCM-256 key
//   ciphertext layout = WebCrypto's: ciphertext || 16-byte tag, 12-byte IV

import CryptoKit
import Foundation
import Security

enum SandukCrypto {
    struct Keys {
        let authToken: String
        let encKey: SymmetricKey
    }

    enum CryptoError: LocalizedError {
        case badKey
        var errorDescription: String? { "That doesn't look like a chest key." }
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func derive(secret: String) throws -> Keys {
        guard let raw = base64urlDecode(secret), raw.count >= 16 else { throw CryptoError.badKey }
        let ikm = SymmetricKey(data: raw)
        let salt = Data(count: 32)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                          info: Data("sanduk/auth/v1".utf8), outputByteCount: 32)
        let enc = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("sanduk/enc/v1".utf8), outputByteCount: 32)
        let authBytes = auth.withUnsafeBytes { Data($0) }
        return Keys(authToken: authBytes.hex, encKey: enc)
    }

    static func randomIV() -> Data {
        var d = Data(count: 12)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "no randomness")
        return d
    }

    static func seal(_ plain: Data, key: SymmetricKey, iv: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: iv))
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, iv: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                        ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key)
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hex
    }

    /// Matches hashFile() in app.js: full SHA-256 up to 64 MB, a metadata hash beyond.
    static func contentHash(fileURL: URL, size: Int64, name: String, modifiedMs: Int64) throws -> String {
        let hashLimit: Int64 = 64 * 1024 * 1024
        guard size <= hashLimit else { return "meta:\(size):\(modifiedMs):\(name)" }
        let h = try FileHandle(forReadingFrom: fileURL)
        defer { try? h.close() }
        var hasher = SHA256()
        while let block = try h.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return "sha256:" + Data(hasher.finalize()).hex
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
