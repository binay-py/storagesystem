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
    var onBackup: () -> Void = {}
    var onBackupTab: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(server: server)
        c.onBackup = onBackup
        c.onBackupTab = onBackupTab
        return c
    }

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
            // tells the page it runs inside the app: it shows a Backup tab
            config.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.classList.add('sanduk-ios');",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "sanduk")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.scrollView.contentInsetAdjustmentBehavior = .never // the page handles the notch itself
        web.backgroundColor = .systemBackground
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web
        context.coordinator.observeBackups()
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let server: String
        weak var web: WKWebView?
        init(server: String) { self.server = server }
        var onBackup: () -> Void = {}
        var onBackupTab: (Bool) -> Void = { _ in }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? String) == "backup" { onBackup() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("!!document.getElementById('tab-backup')") { [weak self] result, _ in
                self?.onBackupTab((result as? Bool) ?? false)
            }
        }
        private var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        /// New photos were backed up: ask the page to fetch the list again.
        /// Pages without sandukSync (older web app) get a plain reload.
        func observeBackups() {
            observer = NotificationCenter.default.addObserver(
                forName: BackupEngine.chestChanged, object: nil, queue: .main) { [weak self] _ in
                self?.syncPage()
            }
        }

        func syncPage() {
            guard let web, !web.isLoading else { return }
            web.evaluateJavaScript("typeof window.sandukSync === 'function'") { result, _ in
                if (result as? Bool) == true {
                    web.evaluateJavaScript("window.sandukSync(); 0", completionHandler: nil)
                } else {
                    web.reload()
                }
            }
        }

        // the web app uses confirm() before deleting forever, locking, deleting an
        // album. a web view without these handlers silently answers "cancel".
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .destructive) { _ in completionHandler(true) })
            present(alert, from: webView, orElse: { completionHandler(false) })
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, from: webView, orElse: completionHandler)
        }

        private func present(_ alert: UIAlertController, from view: UIView, orElse fallback: @escaping () -> Void) {
            var top = view.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let top else { fallback(); return }
            top.present(alert, animated: true)
        }

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

/// WKUserContentController keeps its handlers alive; this keeps it from
/// keeping the coordinator (and the web view) alive with it.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
