// End-to-end tests of the upload pipeline against the real Sanduk server, with a
// brand-new throwaway account each run. Everything they create is deleted.
// They exercise the same code the app runs: Uploader.stage (create/resume the
// file, encrypt chunks to disk), the background chunk request, the server's
// auto-finish, and decrypting what comes back.

import CryptoKit
import UIKit
import XCTest
@testable import SandukBackup

final class PipelineTests: XCTestCase {
    static let server = ProcessInfo.processInfo.environment["SANDUK_TEST_SERVER"]
        ?? "https://sanduk.bhandariatt.workers.dev"

    var keys: SandukCrypto.Keys!
    var api: SandukAPI!
    var uploader: Uploader!
    var created: [String] = []
    var temp: [URL] = []

    override func setUp() async throws {
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let secret = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        keys = try SandukCrypto.derive(secret: secret)
        api = SandukAPI(base: Self.server, token: keys.authToken, session: .shared)
        uploader = Uploader(api: api, key: keys.encKey)
        // the server's invite code (CI secret), so this test account may store files
        let invite = ProcessInfo.processInfo.environment["SANDUK_TEST_INVITE"] ?? ""
        try await api.send("POST", "/hello", headers: invite.isEmpty ? [:] : ["x-invite": invite])
    }

    override func tearDown() async throws {
        for id in created { _ = try? await api.send("DELETE", "/files/\(id)") }
        for u in temp {
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: u.appendingPathExtension("json"))
        }
    }

    // a file just over one chunk, so it has 2 chunks (18 MB + a bit)
    func makeFile(bytes: Int) throws -> (URL, Data) {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try data.write(to: url)
        temp.append(url)
        return (url, data)
    }

    func put(_ c: BackgroundUploads.Chunk) async throws -> [String: Any] {
        let req = try XCTUnwrap(BackgroundUploads.chunkRequest(
            server: Self.server, token: keys.authToken, fileId: c.fileId, idx: c.idx,
            iv: c.iv.base64EncodedString(), sha: c.sha))
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: c.file)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func listed(_ id: String) async throws -> Bool {
        let page = try await api.listFiles(cursor: nil)
        return page.files.contains { ($0["id"] as? String) == id }
    }

    func download(_ id: String) async throws -> Data {
        let meta = try await api.sendJSON("GET", "/files/\(id)")
        let chunks = (meta["chunks"] as? [[String: Any]] ?? []).sorted {
            (($0["idx"] as? NSNumber)?.intValue ?? 0) < (($1["idx"] as? NSNumber)?.intValue ?? 0)
        }
        var out = Data()
        for c in chunks {
            let idx = (c["idx"] as? NSNumber)?.intValue ?? 0
            let iv = try XCTUnwrap(Data(base64Encoded: c["iv"] as? String ?? ""))
            let (ct, _) = try await api.send("GET", "/files/\(id)/chunks/\(idx)")
            out.append(try SandukCrypto.open(ct, key: keys.encKey, iv: iv))
        }
        return out
    }

    // MARK: the background upload path, piece by piece

    func testStageUploadAutoFinishAndDownload() async throws {
        let size = Uploader.chunkSize + 123_456
        let (url, original) = try makeFile(bytes: size)
        let hash = "meta:\(size):1700000000000:TEST.MOV"

        let staged = try await uploader.stage(file: url, size: Int64(size), name: "TEST.MOV", mime: "video/quicktime",
                                              hash: hash, thumb: nil, takenAt: 1_700_000_000_000)
        created.append(staged.id)
        temp += staged.chunks.map(\.file)
        XCTAssertEqual(staged.chunks.map(\.idx), [0, 1])

        // each staged file is the encrypted piece, and its checksum + meta are right
        for c in staged.chunks {
            let ct = try Data(contentsOf: c.file)
            XCTAssertEqual(SandukCrypto.sha256Hex(ct), c.sha)
            let plain = try SandukCrypto.open(ct, key: keys.encKey, iv: c.iv)
            let start = c.idx * Uploader.chunkSize
            XCTAssertEqual(plain, original.subdata(in: start..<min(start + Uploader.chunkSize, size)))
        }

        // not visible until finished; the server finishes it on the last piece
        let first = try await put(staged.chunks[0])
        XCTAssertNil(first["complete"])
        let isListedEarly = try await listed(staged.id)
        XCTAssertFalse(isListedEarly)
        let last = try await put(staged.chunks[1])
        XCTAssertEqual(last["complete"] as? Bool, true)
        let isListed = try await listed(staged.id)
        XCTAssertTrue(isListed)

        // and it comes back byte for byte
        let back = try await download(staged.id)
        XCTAssertEqual(back, original)
    }

    func testResumeContinuesInsteadOfStartingOver() async throws {
        let size = Uploader.chunkSize + 50_000
        let (url, original) = try makeFile(bytes: size)
        let hash = "meta:\(size):1700000000001:RESUME.MOV"

        let first = try await uploader.stage(file: url, size: Int64(size), name: "RESUME.MOV", mime: "video/quicktime",
                                             hash: hash, thumb: nil, takenAt: nil)
        created.append(first.id)
        temp += first.chunks.map(\.file)
        _ = try await put(first.chunks[0]) // the app is killed after one piece

        // next run: same file, same id, only the missing piece, in a new file of its own
        // (so an old task can never send these bytes with another IV)
        let again = try await uploader.stage(file: url, size: Int64(size), name: "RESUME.MOV", mime: "video/quicktime",
                                             hash: hash, thumb: nil, takenAt: nil)
        temp += again.chunks.map(\.file)
        XCTAssertEqual(again.id, first.id, "started a new upload instead of resuming")
        XCTAssertEqual(again.chunks.map(\.idx), [1])
        XCTAssertNotEqual(again.chunks[0].file, first.chunks[1].file)
        let r = try await put(again.chunks[0])
        XCTAssertEqual(r["complete"] as? Bool, true)
        let back = try await download(first.id)
        XCTAssertEqual(back, original)
    }

    func testPhotoWithThumbnailAndLabels() async throws {
        let (url, _) = try makeFile(bytes: 40_000)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let staged = try await uploader.stage(file: url, size: 40_000, name: "IMG_1.JPG", mime: "image/jpeg",
                                              hash: "sha256:test-\(UUID().uuidString)", thumb: thumb, takenAt: nil)
        created.append(staged.id)
        temp += staged.chunks.map(\.file)
        _ = try await put(staged.chunks[0])

        // thumbnail decrypts, and labels made from it land on the file
        let t = try await api.thumb(fileId: staged.id)
        XCTAssertEqual(try SandukCrypto.open(t.ciphertext, key: keys.encKey, iv: t.iv), thumb)
        let d = Labeler.Description(labels: ["cat", "animal"], text: "")
        let iv = SandukCrypto.randomIV()
        let ct = try SandukCrypto.seal(Labeler.payload(d), key: keys.encKey, iv: iv)
        let updated = try await api.postLabels([["id": staged.id, "enc": ct.base64EncodedString(), "iv": iv.base64EncodedString()]])
        XCTAssertEqual(updated, 1)
        let row = try await api.listFiles(cursor: nil).files.first { ($0["id"] as? String) == staged.id }
        let enc = try XCTUnwrap(Data(base64Encoded: row?["labels_enc"] as? String ?? ""))
        let liv = try XCTUnwrap(Data(base64Encoded: row?["labels_iv"] as? String ?? ""))
        let obj = try JSONSerialization.jsonObject(with: SandukCrypto.open(enc, key: keys.encKey, iv: liv)) as? [String: Any]
        XCTAssertEqual(obj?["l"] as? [String], ["cat", "animal"]) // the shape the web app reads
        XCTAssertEqual(obj?["v"] as? Int, 1)
    }

    func testDamagedPieceIsRefusedAndLookupFindsFinishedFile() async throws {
        let (url, _) = try makeFile(bytes: 5_000)
        let hash = "sha256:lookup-\(UUID().uuidString)"
        let staged = try await uploader.stage(file: url, size: 5_000, name: "A.JPG", mime: "image/jpeg",
                                              hash: hash, thumb: nil, takenAt: nil)
        created.append(staged.id)
        temp += staged.chunks.map(\.file)
        let c = staged.chunks[0]
        // wrong checksum: refused, file stays unfinished
        var bad = try XCTUnwrap(BackgroundUploads.chunkRequest(server: Self.server, token: keys.authToken, fileId: c.fileId,
                                                               idx: c.idx, iv: c.iv.base64EncodedString(), sha: String(repeating: "0", count: 64)))
        bad.httpMethod = "PUT"
        let (_, resp) = try await URLSession.shared.upload(for: bad, fromFile: c.file)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 400)
        let missing = try await api.lookup(hash: hash)
        XCTAssertNil(missing)
        // right checksum: finished, and lookup by hash finds it (used to pair a live photo's video)
        _ = try await put(c)
        let found = try await api.lookup(hash: hash)
        XCTAssertEqual(found, staged.id)
    }

    func testStreamingCopyIsLinkedWhenFinished() async throws {
        let (bigURL, _) = try makeFile(bytes: 9_000)
        let (smallURL, _) = try makeFile(bytes: 2_000)
        let hash = "sha256:video-\(UUID().uuidString)"
        let original = try await uploader.stage(file: bigURL, size: 9_000, name: "IMG_4K.MOV", mime: "video/quicktime",
                                                hash: hash, thumb: nil, takenAt: nil)
        created.append(original.id)
        temp += original.chunks.map(\.file)
        _ = try await put(original.chunks[0])

        let copy = try await uploader.stage(file: smallURL, size: 2_000, name: "streaming-copy.mp4", mime: "video/mp4",
                                            hash: "copy:" + hash, thumb: nil, takenAt: nil)
        temp += copy.chunks.map(\.file)
        try await api.markStreamingCopy(copy.id, of: original.id)
        let before = try await api.lookupFile(hash: hash)
        XCTAssertEqual(before?.id, original.id)
        XCTAssertNil(before?.previewId, "linked before the copy arrived")
        _ = try await put(copy.chunks[0])
        let after = try await api.lookupFile(hash: hash)
        XCTAssertEqual(after?.previewId, copy.id)
        let listedCopy = try await listed(copy.id)
        XCTAssertFalse(listedCopy, "the copy must not show in the library")
    }

    // MARK: on-device pieces

    func testLabelerReadsTextInAPhoto() async throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 500)).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 500))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.black]
            ("TOTAL 12.50" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: attrs)
            ("THANK YOU FOR SHOPPING" as NSString).draw(at: CGPoint(x: 60, y: 220), withAttributes: attrs)
        }
        let d = await Labeler.describe(imageData: img, isVideo: false)
        let text = (d?.text ?? "").uppercased()
        XCTAssertTrue(text.contains("TOTAL"), "read: \(text)")
        XCTAssertTrue(d?.labels.contains("text") ?? false, "labels: \(d?.labels ?? [])")
    }

    func testLongVideosGoLast() {
        let order = BackupEngine.backupOrder([1, 200, 3, 400, 5], isLong: { $0 > 180 })
        XCTAssertEqual(order, [1, 3, 5, 200, 400])
    }

    func testChunkRequestShape() throws {
        let req = try XCTUnwrap(BackgroundUploads.chunkRequest(server: "https://x.example", token: "t", fileId: "f-1",
                                                               idx: 3, iv: "a+b/c=", sha: "abc"))
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString, "https://x.example/api/files/f-1/chunks/3?iv=a%2Bb%2Fc%3D&auto=1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "authorization"), "Bearer t")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-chunk-sha256"), "abc")
    }
}
