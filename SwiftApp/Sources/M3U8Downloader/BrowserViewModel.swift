import Foundation
import SwiftUI
import AppKit
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {

    // MARK: - UserDefaults keys (persist user-chosen settings across launches)
    private enum DefaultsKey {
        static let saveDir        = "m3u8dl.saveDir"
        static let saveNamePrefix = "m3u8dl.saveNamePrefix"
        static let headers        = "m3u8dl.headers"
        static let useIPadUA      = "m3u8dl.useIPadUA"
    }
    private static let defaults = UserDefaults.standard

    /// Standard iPad Safari 17 User-Agent string. Many sites (especially video
    /// platforms) serve a simpler HTML5 player on the iPad layout than on the
    /// desktop one — the m3u8 source is often easier to discover on the mobile
    /// tier, both for our JSExtractor and for site-side 403/UA-gating logic.
    ///
    /// Note: iPadOS 13+ on real iPads sometimes spoofs "Macintosh" in the UA
    /// to dodge desktop-mode websites. WKWebView on macOS does NOT apply that
    /// spoofing — whatever string we hand it via `customUserAgent` is what
    /// the server sees — so a plain "iPad; CPU OS 17_0 like Mac OS X" line
    /// reliably triggers the iPad code path on most CDNs.
    static let iPadUserAgent: String =
        "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.0 Mobile/15E148 Safari/604.1"

    /// Multi-line input for *direct* m3u8 URLs only — paste a list of `.m3u8`
    /// links here to probe them straight away, without going through the
    /// embedded browser. For webpages, use the embedded browser below.
    @Published var urlInput: String = "" {
        didSet { if urlInput != oldValue { resetResults() } }
    }

    @Published var headers: [String] = {
        // Load previously saved headers (e.g. Referer / Cookie lines) so the
        // user doesn't have to re-add them after every launch.
        if let saved = defaults.array(forKey: DefaultsKey.headers) as? [String] {
            return saved
        }
        return []
    }() {
        didSet { Self.defaults.set(headers, forKey: DefaultsKey.headers) }
    }
    @Published var headerInput: String = ""

    @Published var links: [M3U8Link] = []
    @Published var isProbing: Bool = false
    /// `true` between "page finished loading" and "JS extract returned".
    /// Covers the 2.5s settle window (waiting for SPA-injected players to
    /// register their playlists) + the JS evaluation itself — without this
    /// flag, the user sees the page fully loaded but no link cards yet, and
    /// has no idea the app is still working on grabbing m3u8s.
    @Published var isExtracting: Bool = false
    @Published var selectedIDs: Set<UUID> = []
    @Published var lastError: String?

    /// Save dir shared with the main DownloaderViewModel.
    /// Persisted across launches via UserDefaults — first launch falls back to
    /// `~/Movies/M3U8Downloads` and creates the directory on demand.
    @Published var saveDir: String = {
        if let saved = defaults.string(forKey: DefaultsKey.saveDir), !saved.isEmpty {
            return saved
        }
        return NSHomeDirectory() + "/Movies/M3U8Downloads"
    }() {
        didSet {
            guard saveDir != oldValue else { return }
            Self.defaults.set(saveDir, forKey: DefaultsKey.saveDir)
        }
    }
    @Published var saveNamePrefix: String = "" {
        didSet {
            guard saveNamePrefix != oldValue else { return }
            Self.defaults.set(saveNamePrefix, forKey: DefaultsKey.saveNamePrefix)
        }
    }

    // MARK: - Embedded browser state

    @Published var browserURL: String = ""
    @Published var browserTitle: String = ""
    @Published var isBrowserLoading: Bool = false
    @Published var browserCanGoBack: Bool = false
    @Published var browserCanGoForward: Bool = false

    /// When true the embedded WKWebView sends `BrowserViewModel.iPadUserAgent`
    /// as its User-Agent instead of the default macOS Safari string. Persisted
    /// across launches so the user doesn't have to flip it back on every open.
    ///
    /// Default is `true` (iPad UA): the user explicitly prefers the iPad
    /// layout because many video sites serve a simpler HTML5 player on the
    /// tablet tier, with the m3u8 source more exposed to JSExtractor. Only
    /// applies when the key is missing in UserDefaults — users who have
    /// already toggled to desktop keep their stored `false` value.
    @Published var useIPadUA: Bool = {
        if defaults.object(forKey: DefaultsKey.useIPadUA) == nil { return true }
        return defaults.bool(forKey: DefaultsKey.useIPadUA)
    }() {
        didSet {
            guard useIPadUA != oldValue else { return }
            Self.defaults.set(useIPadUA, forKey: DefaultsKey.useIPadUA)
        }
    }

    /// Owned by the NSViewRepresentable; we just hold a weak ref to drive it.
    weak var webView: WKWebView?

    // MARK: - Init

    init() {
        // Make sure the saved directory exists on disk so that
        // N_m3u8DL-RE can write to it immediately.
        let url = URL(fileURLWithPath: saveDir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Input parsing

    /// Split `urlInput` into direct m3u8 URLs only (the multi-line paste is
    /// now used as a "direct m3u8" shortcut; webpage URLs go through the
    /// embedded browser).
    private func directM3U8URLs(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            for token in line.split(whereSeparator: { $0.isWhitespace }) {
                var t = String(token).trimmingCharacters(in: .whitespaces)
                while let last = t.last, ".,;)]}'\"".contains(last) { t.removeLast() }
                guard t.lowercased().contains(".m3u8") else { continue }
                if seen.insert(t).inserted { out.append(t) }
            }
        }
        return out
    }

    // MARK: - Discovery

    /// Probe the multi-line `urlInput` as direct m3u8 URLs only.
    func parseAndProbe() {
        lastError = nil
        let urls = directM3U8URLs(in: urlInput)
        if urls.isEmpty {
            lastError = "未检测到 m3u8 链接 —— 请粘贴 m3u8 URL，或在上面的浏览器中打开网页"
            return
        }
        links = urls.map { M3U8Link(url: $0) }
        selectedIDs = []
        isProbing = true
        Task { await probeAll() }
    }

    func resetResults() {
        links = []
        selectedIDs = []
        lastError = nil
    }

    /// Replace `urlInput` with the clipboard contents.
    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlInput = s
        }
    }

    /// Convenience: paste + immediately probe (direct m3u8 list).
    func pasteAndProbe() {
        pasteFromClipboard()
        parseAndProbe()
    }

    // MARK: - Embedded browser

    /// Load a URL into the embedded WKWebView. Accepts bare hosts
    /// (`example.com/foo`) and prepends `https://` if needed.
    func browserLoad(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        var str = s
        if !str.lowercased().hasPrefix("http://") && !str.lowercased().hasPrefix("https://") {
            str = "https://" + str
        }
        guard let u = URL(string: str) else { return }
        browserURL = u.absoluteString
        webView?.load(URLRequest(url: u))
    }

    func browserGoBack()    { webView?.goBack() }
    func browserGoForward() { webView?.goForward() }
    func browserReload()    { webView?.reload() }
    func browserStop()      { webView?.stopLoading() }

    /// Flip the iPad User-Agent mode and, if a page is currently loaded,
    /// reload it so the new UA goes out on the next request. Setting
    /// `customUserAgent` on an existing WKWebView affects subsequent loads
    /// only — the in-flight page still carries the old UA — so a reload
    /// is the simplest way to make the change visible to the user.
    /// No-op when the value already matches.
    func setUseIPadUA(_ enabled: Bool) {
        guard enabled != useIPadUA else { return }
        useIPadUA = enabled
        guard let wv = webView, wv.url != nil else { return }
        wv.customUserAgent = enabled ? Self.iPadUserAgent : nil
        wv.reload()
    }

    /// Handle a set of m3u8 URLs discovered by the embedded browser.
    /// - If the loaded page is itself an .m3u8, it's added directly.
    /// - Otherwise, the discovered URLs are added with `referer` set to the
    ///   page URL.
    func handleBrowserExtract(urls: [String], pageURL: String) {
        // If the page URL itself is an .m3u8, treat as a direct hit.
        let pageIsM3U8 = pageURL.lowercased().contains(".m3u8")
        var discovered: [String] = []
        if pageIsM3U8, !pageURL.isEmpty, !links.contains(where: { $0.url == pageURL }) {
            discovered.append(pageURL)
        }
        for u in urls where !discovered.contains(u) && !links.contains(where: { $0.url == u }) {
            discovered.append(u)
        }
        if discovered.isEmpty { return }

        // Reset selection, keep any existing links that aren't replaced.
        for u in discovered {
            var link = M3U8Link(url: u)
            if !pageIsM3U8 && !pageURL.isEmpty {
                link.referer = pageURL
                link.statusMessage = "来自「\(pageURL)」"
            }
            links.append(link)
        }
        isProbing = true
        Task { await probeAll() }
    }

    // MARK: - Probing

    func probeAll() async {
        let ids = links.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    await self?.probeOne(id: id)
                }
            }
        }
        await MainActor.run { self.isProbing = false }
    }

    func reprobe(_ link: M3U8Link) {
        guard let idx = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[idx].status = .probing
        links[idx].statusMessage = ""
        Task { await probeOne(id: link.id) }
    }

    private func probeOne(id: UUID) async {
        guard let idx = links.firstIndex(where: { $0.id == id }) else { return }
        links[idx].status = .probing
        let urlString = links[idx].url
        let referer = links[idx].referer
        var probeHeaders = headers
        if let r = referer, !probeHeaders.contains(where: { $0.lowercased().hasPrefix("referer:") }) {
            probeHeaders.append("Referer: \(r)")
        }
        do {
            let r = try await HLSProbe.probe(urlString: urlString, headers: probeHeaders)
            var variants = r.variants
            let isMaster = r.isMaster
            var mediaSummary: String? = nil

            // Media playlists don't carry RESOLUTION attributes. If we only
            // got a single variant and it has no resolution, ask
            // AVFoundation to inspect the underlying video track so the user
            // sees the real 1920x1080 / 30fps in the list instead of a
            // generic "Media" label.
            if !isMaster, variants.count == 1, variants[0].resolution == nil {
                if let info = await HLSProbe.probeMediaTrack(
                    urlString: urlString,
                    headers: probeHeaders) {
                    var v = variants[0]
                    v.resolution = "\(info.width)x\(info.height)"
                    if info.frameRate > 0 { v.frameRate = info.frameRate }
                    if v.bandwidth == nil, let b = info.bitrate { v.bandwidth = b }
                    if (v.codecs ?? "").isEmpty, let c = info.codec { v.codecs = c }
                    variants[0] = v
                    var summary = "Media · \(info.width)x\(info.height)"
                    if info.frameRate > 0 {
                        summary += String(format: " · %.0ffps", info.frameRate)
                    }
                    mediaSummary = summary
                }
            }

            let finalVariants = variants
            let finalIsMaster = isMaster
            let finalSummary = mediaSummary
            await MainActor.run {
                guard let i = self.links.firstIndex(where: { $0.id == id }) else { return }
                self.links[i].variants = finalVariants
                self.links[i].status = .done
                if finalIsMaster {
                    self.links[i].statusMessage = "Master · \(finalVariants.count) 个码率"
                } else if let s = finalSummary {
                    self.links[i].statusMessage = s
                } else {
                    self.links[i].statusMessage = "Media · 单一码率"
                }
            }
        } catch {
            await MainActor.run {
                guard let i = self.links.firstIndex(where: { $0.id == id }) else { return }
                self.links[i].status = .failed(error.localizedDescription)
                self.links[i].statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Header management

    func addHeader() {
        let t = headerInput.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        headers.append(t)
        headerInput = ""
    }

    func removeHeader(_ h: String) {
        headers.removeAll { $0 == h }
    }

    // MARK: - Save dir

    func pickSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url.path
        }
    }

    /// Open the save directory in Finder, creating it on demand.
    func revealSaveDir() {
        let url = URL(fileURLWithPath: saveDir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Download handoff

    /// Builds a list of (variant URL, suggested save name) tuples that the user
    /// wants to download — either an entire link's variants, or selected ones.
    func downloadPayload() -> [(url: String, name: String)] {
        var out: [(url: String, name: String)] = []
        for link in links {
            guard !link.variants.isEmpty else { continue }
            for (i, v) in link.variants.enumerated() {
                if !selectedIDs.isEmpty && !selectedIDs.contains(v.id) { continue }
                let prefix = saveNamePrefix.trimmingCharacters(in: .whitespaces)
                let res = v.resolution ?? v.mediaType ?? "media"
                // `i+1` only disambiguates *variants within one link*
                // (e.g. a master playlist's 1080p / 720p rows). When the
                // user "全选"es a list of independent m3u8 URLs (each a
                // single-variant media playlist, like 11 different videos
                // from the same site), every link's i is 0 and every name
                // collides — so ffmpeg fallback ends up overwriting itself
                // 10 times. Inject a per-link URL key to keep names unique.
                let key = shortUrlKey(link.url)
                let name = prefix.isEmpty
                    ? "\(urlHost(link.url))_\(key)_\(res)_\(i+1)"
                    : "\(prefix)_\(key)_\(res)_\(i+1)"
                out.append((v.url, name))
            }
        }
        return out
    }

    /// Pull a short, filename-safe key from the URL path that uniquely
    /// identifies a given m3u8 within a single batch. We prefer a long
    /// hex-looking segment (most CMSes put a 24-char id in the URL like
    /// `697ce22b3abc34096443971c`); fall back to the last directory; fall
    /// back to the host.
    private func shortUrlKey(_ s: String) -> String {
        guard let u = URL(string: s) else { return "video" }
        let parts = u.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if let hex = parts.first(where: { $0.count >= 16 && $0.allSatisfy(\.isHexDigit) }) {
            return String(hex.prefix(8))
        }
        if parts.count >= 2 {
            return parts[parts.count - 2]
        }
        return parts.first ?? urlHost(s)
    }

    private func urlHost(_ s: String) -> String {
        URL(string: s)?.host?.replacingOccurrences(of: ".", with: "_") ?? "video"
    }

    // MARK: - Referer plumbing

    /// Returns `headers` plus a `Referer: <referer>` line (unless a manual
    /// Referer is already present). Used for downloading & probing.
    func headersWithReferer(_ referer: String?) -> [String] {
        guard let r = referer?.trimmingCharacters(in: .whitespaces), !r.isEmpty else {
            return headers
        }
        if headers.contains(where: { $0.lowercased().hasPrefix("referer:") }) {
            return headers
        }
        var out = headers
        out.append("Referer: \(r)")
        return out
    }

    /// Look up the referer (source webpage) for a given variant URL by
    /// finding which `M3U8Link` (the link card) it was probed under.
    func referer(forVariantURL variantURL: String) -> String? {
        for link in links {
            if link.url == variantURL { return link.referer }
            if link.variants.contains(where: { $0.url == variantURL }) { return link.referer }
        }
        return nil
    }
}
