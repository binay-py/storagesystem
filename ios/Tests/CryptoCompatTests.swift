// Vectors produced by the browser's WebCrypto with the exact code in
// public/app.js (deriveKeys + AES-GCM encrypt). If these pass, files uploaded
// by the iPhone app open in the web app and vice versa.

import XCTest
@testable import SandukBackup

final class CryptoCompatTests: XCTestCase {
    // raw key bytes 0x00...0x1f, base64url, as the web app shows chest keys
    let secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    func testAuthTokenMatchesWebApp() throws {
        let keys = try SandukCrypto.derive(secret: secret)
        XCTAssertEqual(keys.authToken, "d0ba531ce03f0e0bc2ab2937e8f723b7cd449c3e542999f4e69f4c534934c14a")
    }

    func testEncryptionMatchesWebApp() throws {
        let keys = try SandukCrypto.derive(secret: secret)
        let iv = Data((0..<12).map { UInt8($0) })
        let ct = try SandukCrypto.seal(Data("IMG_0001.HEIC".utf8), key: keys.encKey, iv: iv)
        XCTAssertEqual(ct.base64EncodedString(), "rfsxl6YzY2Sa1BgIROMQFPHBTZqqJMD+LSWLoNc=")
        XCTAssertEqual(String(data: try SandukCrypto.open(ct, key: keys.encKey, iv: iv), encoding: .utf8),
                       "IMG_0001.HEIC")
    }

    func testRejectsShortKey() {
        XCTAssertThrowsError(try SandukCrypto.derive(secret: "abc"))
    }

    func testQueryEscapingMatchesEncodeURIComponent() {
        XCTAssertEqual(SandukAPI.q("ab+/c=="), "ab%2B%2Fc%3D%3D")
    }
}
