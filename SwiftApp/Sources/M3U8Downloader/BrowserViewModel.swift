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
    }
    private static let defaults = UserDefaults.standard

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
    /// Set to true briefly to tell the WebBrowserView Coordinator to run an
    /// immediate extraction (manual button). Coordinator clears it after use.
    @Published var browserExtractRequested: Int = 0

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

    /// Trigger an immediate extract (manual button). The Coordinator watches
    /// `browserExtractRequested` and runs the extract when it changes.
    /// Each manual click starts from a clean slate so the link list only
    /// reflects the current page (auto-extract on page-load is unchanged).
    func browserRequestExtract() {
        resetResults()
        browserExtractRequested &+= 1
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
            await MainActor.run {
                guard let i = self.links.firstIndex(where: { $0.id == id }) else { return }
                self.links[i].variants = r.variants
                self.links[i].status = .done
                self.links[i].statusMessage = r.isMaster
                    ? "Master · \(r.variants.count) 个码率"
                    : "Media · 单一码率"
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
                let name = prefix.isEmpty
                    ? "\(urlHost(link.url))_\(res)_\(i+1)"
                    : "\(prefix)_\(res)_\(i+1)"
                out.append((v.url, name))
            }
        }
        return out
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
