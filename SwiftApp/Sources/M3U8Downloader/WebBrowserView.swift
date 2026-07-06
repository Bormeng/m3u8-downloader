import SwiftUI
import WebKit

/// A SwiftUI wrapper around `WKWebView` that:
///   - installs `JSExtractor.monkeyPatch` at document-start (every frame)
///   - tracks navigation state (URL, title, loading, back/forward)
///   - auto-runs `JSExtractor.extractScript` 2.5 s after every page-load
///   - exposes a `browserExtract()` method for the manual button
///   - calls back into the parent with the discovered URLs + the page URL
struct WebBrowserView: NSViewRepresentable {
    @ObservedObject var vm: BrowserViewModel
    /// Called with `[discovered m3u8 URLs]` and the `page URL` they came from.
    let onExtract: ([String], String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm, onExtract: onExtract)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(macOS 11.0, *) {
            cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        let ctrl = WKUserContentController()
        ctrl.addUserScript(WKUserScript(
            source: JSExtractor.monkeyPatch,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        cfg.userContentController = ctrl

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        context.coordinator.attachWebView(wv)
        // Store on the VM so SwiftUI buttons can drive the webview.
        DispatchQueue.main.async { vm.webView = wv }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // React to manual "extract now" requests from BrowserViewModel.
        let requested = vm.browserExtractRequested
        if context.coordinator.lastExtractRequestSeen != requested {
            context.coordinator.lastExtractRequestSeen = requested
            context.coordinator.runExtractNow()
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let vm: BrowserViewModel
        let onExtract: ([String], String) -> Void
        weak var webView: WKWebView?
        private var settleTimer: Timer?
        var lastExtractRequestSeen: Int = 0

        init(vm: BrowserViewModel, onExtract: @escaping ([String], String) -> Void) {
            self.vm = vm
            self.onExtract = onExtract
        }

        func attachWebView(_ w: WKWebView) { webView = w }
        func detach() { settleTimer?.invalidate(); settleTimer = nil; webView = nil }

        // MARK: Navigation lifecycle

        func webView(_ wv: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
            DispatchQueue.main.async {
                self.vm.isBrowserLoading = true
            }
        }

        func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
            DispatchQueue.main.async {
                self.vm.isBrowserLoading = false
                self.vm.browserURL = wv.url?.absoluteString ?? self.vm.browserURL
                self.vm.browserTitle = wv.title ?? ""
                self.vm.browserCanGoBack = wv.canGoBack
                self.vm.browserCanGoForward = wv.canGoForward
                self.scheduleAutoExtract()
            }
        }

        func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.vm.isBrowserLoading = false }
        }
        func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.vm.isBrowserLoading = false }
        }

        // MARK: target=_blank / window.open

        func webView(_ wv: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navAction.targetFrame == nil, let url = navAction.request.url {
                wv.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: Extract

        /// Schedule a one-shot extract after `delay` seconds (default 2.5).
        /// Coalesces with previous timers so multiple navigation-finish events
        /// only fire one extract.
        func scheduleAutoExtract(delay: TimeInterval = 2.5) {
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(
                withTimeInterval: delay, repeats: false
            ) { [weak self] _ in
                self?.runExtract()
            }
        }

        func runExtractNow() {
            settleTimer?.invalidate()
            runExtract()
        }

        private func runExtract() {
            guard let wv = webView else { return }
            wv.evaluateJavaScript(JSExtractor.extractScript) { [weak self] result, _ in
                guard let self = self else { return }
                var urls: [String] = []
                if let arr = result as? [String] {
                    urls = arr
                } else if let dict = result as? [String: Any] {
                    for (_, v) in dict {
                        if let a = v as? [String] { urls.append(contentsOf: a) }
                    }
                }
                let pageURL = wv.url?.absoluteString ?? ""
                DispatchQueue.main.async {
                    if !urls.isEmpty {
                        self.onExtract(urls, pageURL)
                    }
                }
            }
        }
    }
}
