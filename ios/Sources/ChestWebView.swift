// The full Sanduk web app (timeline, albums, viewer, favorites, trash, upload)
// inside the app. It is the same page you use in the browser, served by your own
// Worker, so every web feature works here and stays in sync with the web app.
// The chest key is handed to the page the same way the web app's "remember me"
// stores it (localStorage "sanduk.secret"), only for your server's own origin.

import SwiftUI
import WebKit

struct ChestWebView: UIViewRepresentable {
    let server: String
    let secret: String

    func makeCoordinator() -> Coordinator { Coordinator(server: server) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if let origin = URL(string: server).flatMap(Self.origin(of:)) {
            let js = """
            (function () {
              if (location.origin !== \(Self.jsString(origin))) return;
              try {
                if (!localStorage.getItem('sanduk.secret'))
                  localStorage.setItem('sanduk.secret', \(Self.jsString(secret)));
              } catch (e) {}
            })();
            """
            config.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.075, green: 0.071, blue: 0.082, alpha: 1)
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web
        if let url = URL(string: server) { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Safe JS string literal (JSON-encoded).
    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// Forget the key and everything the page cached on this phone.
    static func clearWebData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let server: String
        weak var web: WKWebView?
        init(server: String) { self.server = server }

        @objc func reload(_ sender: UIRefreshControl) {
            web?.reload()
            sender.endRefreshing()
        }

        // Your server stays in the app; any other link opens in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow); return
            }
            if scheme == "blob" || scheme == "data" || scheme == "about" { decisionHandler(.allow); return }
            let mine = URL(string: server).flatMap(ChestWebView.origin(of:))
            if action.targetFrame?.isMainFrame != false, ChestWebView.origin(of: url) != mine,
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
