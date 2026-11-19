// Thin client for the Sanduk Worker's /api routes. Mirrors api()/apiRaw()/
// withRetry() in public/app.js.

import Foundation

struct SandukAPI {
    let base: String          // e.g. https://sanduk.you.workers.dev (no trailing slash)
    let token: String
    let session: URLSession

    struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        let code: String?
        let retryAfter: Double?
        var errorDescription: String? { "server said \(status): \(message)" }
    }

    static func makeSession(wifiOnly: Bool) -> URLSession {
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = !wifiOnly   // cellular + personal hotspot
        c.allowsConstrainedNetworkAccess = !wifiOnly // Low Data Mode
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }

    // MARK: raw request

    @discardableResult
    func send(_ method: String, _ path: String, json: [String: Any]? = nil,
              body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base + "/api" + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.httpBody = body
        }
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw HTTPError(status: http.statusCode,
                            message: obj?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                            code: obj?["code"] as? String,
                            retryAfter: (obj?["retryAfter"] as? NSNumber)?.doubleValue)
        }
        return (data, http)
    }

    func sendJSON(_ method: String, _ path: String, json: [String: Any]? = nil,
                  headers: [String: String] = [:]) async throws -> [String: Any] {
        let (data, _) = try await withRetry { try await send(method, path, json: json, headers: headers) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: retries (same policy as the web app)

    private static let waits: [Double] = [1, 2, 4, 8, 15]

    static func retryable(_ e: Error) -> Bool {
        if let h = e as? HTTPError {
            return h.status == 408 || h.status == 422 || h.status == 429 || h.status >= 500
        }
        if e is CancellationError { return false }
        if let u = e as? URLError {
            if u.code == .cancelled { return false }
            if u.networkUnavailableReason != nil { return false } // Wi-Fi-only rule said no
            if u.code == .notConnectedToInternet { return false }
        }
        return true // no answer at all: network dropped mid-request
    }

    func withRetry<T>(_ fn: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await fn() } catch {
                try Task.checkCancellation()
                guard Self.retryable(error), attempt < Self.waits.count else { throw error }
                let wait = (error as? HTTPError)?.retryAfter ?? Self.waits[attempt]
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: routes

    func hashes() async throws -> Set<String> {
        let obj = try await sendJSON("GET", "/hashes")
        return Set(obj["hashes"] as? [String] ?? [])
    }

    func resume(hash: String, size: Int64, chunks: Int) async throws -> (id: String, done: Set<Int>)? {
        var q = URLComponents()
        q.queryItems = [.init(name: "hash", value: hash), .init(name: "size", value: String(size)),
                        .init(name: "chunks", value: String(chunks))]
        let obj = try await sendJSON("GET", "/files/resume?" + (q.percentEncodedQuery ?? ""))
        guard let id = obj["id"] as? String else { return nil }
        let done = (obj["done"] as? [NSNumber] ?? []).map(\.intValue)
        return (id, Set(done))
    }

    func createFile(nameEnc: String, nameIv: String, mime: String, size: Int64,
                    chunkCount: Int, contentHash: String) async throws -> String {
        let obj = try await sendJSON("POST", "/files", json: [
            "nameEnc": nameEnc, "nameIv": nameIv, "mime": mime,
            "size": size, "chunkCount": chunkCount, "contentHash": contentHash,
        ])
        guard let id = obj["id"] as? String else { throw HTTPError(status: 500, message: "no id", code: nil, retryAfter: nil) }
        return id
    }

    func putChunk(fileId: String, index: Int, iv: Data, ciphertext: Data) async throws {
        let sha = SandukCrypto.sha256Hex(ciphertext)
        _ = try await withRetry {
            try await send("PUT", "/files/\(fileId)/chunks/\(index)?iv=\(Self.q(iv.base64EncodedString()))",
                           body: ciphertext, headers: ["x-chunk-sha256": sha])
        }
    }

    func putThumb(fileId: String, iv: Data, ciphertext: Data) async throws {
        try await send("PUT", "/files/\(fileId)/thumb?iv=\(Self.q(iv.base64EncodedString()))", body: ciphertext)
    }

    func complete(fileId: String) async throws {
        _ = try await sendJSON("POST", "/files/\(fileId)/complete")
    }

    func pairLive(photoId: String, videoId: String) async throws {
        _ = try await sendJSON("POST", "/files/\(photoId)/live", json: ["videoId": videoId])
    }

    /// encodeURIComponent equivalent for base64 (+ / =)
    static func q(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
