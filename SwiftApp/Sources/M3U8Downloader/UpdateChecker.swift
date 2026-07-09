import Foundation
import SwiftUI

/// Checks whether the bundled `N_m3u8DL-RE` is up to date against the latest
/// GitHub release. Triggered automatically on app launch (with a 24h cache)
/// and on demand from the Settings pane.
///
/// Design choices, briefly:
///   • Read current version by spawning `N_m3u8DL-RE --version` and parsing
///     the first line — the binary itself is the source of truth, no separate
///     "baked in at build time" version string to keep in sync.
///   • 24h cache via UserDefaults so we don't pummel the GitHub API on every
///     relaunch. Manual "Check now" bypasses the cache.
///   • Network / parse failures are silent (logged via `checkError` for
///     debugging in Settings, never surfaced as a popup or notification).
///   • We do NOT auto-download or auto-replace the binary — that touches
///     codesigning, the running-process file lock, and the user's choice.
///     We just show a banner with a link to the GitHub release page.
@MainActor
final class UpdateChecker: ObservableObject {

    /// Shared instance so the ContentView (which kicks off the auto-check
    /// on launch) and the Settings pane (which shows the result) see the
    /// exact same state without us having to plumb an @EnvironmentObject
    /// across the separate `Settings` scene.
    static let shared = UpdateChecker()

    // MARK: - Published state

    @Published private(set) var latestTag: String? = nil
    @Published private(set) var latestHTMLURL: String? = nil
    @Published private(set) var publishedAt: Date? = nil
    @Published private(set) var lastChecked: Date? = nil
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var checkError: String? = nil
    @Published var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: Keys.autoCheck) }
    }

    /// True iff a successful check has confirmed a newer release than the
    /// one bundled in this app.
    @Published private(set) var updateAvailable: Bool = false

    // MARK: - Public API

    /// The version of the bundled binary, parsed from `N_m3u8DL-RE --version`.
    /// Returns the full string `0.6.0+<gitsha>` if the binary is present.
    /// Used both for the Settings pane and the update-comparison logic.
    static var currentVersion: String? {
        let path = DownloaderViewModel.executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        // `--version` on .NET prints the version banner and exits immediately;
        // a small timeout would be overkill, but cap to 3s anyway in case the
        // binary hangs for any reason.
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        // First non-empty line is the version. N_m3u8DL-RE prints extra
        // `tput: No value for $TERM ...` lines to stderr in a GUI context;
        // they're harmless noise — strip and pick the first meaningful token.
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Version strings start with a digit and contain either '+' or '.'
            if trimmed.first?.isNumber == true, trimmed.contains(".") {
                return trimmed
            }
        }
        return nil
    }

    /// Short tag form of the current version, e.g. "0.6.0-beta" from
    /// "0.6.0+df70f0b3...". Used for equality comparison with the GitHub tag.
    static var currentTag: String? {
        guard let v = currentVersion else { return nil }
        // "0.6.0+df70..." → "0.6.0"; "0.6.0-beta+df70..." → "0.6.0-beta"
        if let plus = v.firstIndex(of: "+") {
            return String(v[..<plus])
        }
        return v
    }

    // MARK: - Init

    init() {
        // Auto-check defaults to true. Stored in UserDefaults so the user's
        // choice persists across launches.
        if UserDefaults.standard.object(forKey: Keys.autoCheck) == nil {
            self.autoCheckEnabled = true
            UserDefaults.standard.set(true, forKey: Keys.autoCheck)
        } else {
            self.autoCheckEnabled = UserDefaults.standard.bool(forKey: Keys.autoCheck)
        }
        self.lastChecked = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
    }

    // MARK: - Check (async)

    /// Fire a release check. Honors the 24h cache unless `force` is true.
    /// Safe to call repeatedly — re-entrancy is guarded by `isChecking`.
    func check(force: Bool = false) async {
        guard !isChecking else { return }
        guard autoCheckEnabled || force else { return }

        // Cache hit: skip the network call.
        if !force,
           let last = lastChecked,
           Date().timeIntervalSince(last) < Self.cacheTTL,
           latestTag != nil {
            return
        }

        isChecking = true
        checkError = nil
        defer { isChecking = false }

        var req = URLRequest(url: URL(string: Self.apiURL)!)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API requires a User-Agent header. Use a stable identifier
        // so it's easy to spot in the API logs if the user ever files a
        // rate-limit complaint.
        req.setValue("m3u8-downloader (\(Self.repo))", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            // 304 Not Modified — GitHub doesn't send this without a
            // conditional request, but handle it for safety.
            if http.statusCode == 304 {
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
                return
            }
            guard http.statusCode == 200 else {
                throw NSError(
                    domain: "UpdateChecker",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub 返回 HTTP \(http.statusCode)"]
                )
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            applyRelease(release)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
        } catch {
            checkError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func applyRelease(_ r: Release) {
        latestTag = r.tag_name
        latestHTMLURL = r.html_url
        // GitHub's published_at is RFC 3339 / ISO 8601.
        let iso = ISO8601DateFormatter()
        publishedAt = iso.date(from: r.published_at)
        updateAvailable = isNewer(latest: r.tag_name, current: Self.currentTag)
    }

    /// Compare GitHub tag (e.g. "v0.6.0-beta") with the current bundled tag
    /// (e.g. "0.6.0-beta"). Both strings are normalised to drop a leading
    /// "v", any "+<sha>" build suffix, and any "-beta"/"-rc1" prerelease
    /// suffix.
    ///
    /// Why strip the prerelease suffix? N_m3u8DL-RE's `--version` output
    /// is `0.6.0+<gitsha>` — it does NOT echo back the `-beta` portion of
    /// the tag. So a release tagged `v0.6.0-beta` reports as `0.6.0+...`
    /// on disk. After dropping the prerelease suffix on the GitHub side
    /// (`v0.6.0-beta` → `0.6.0`) the two match.
    ///
    /// Edge case this misses: if upstream ships a *new* prerelease on top
    /// of an older release (e.g. `v0.5.0-beta` when local is `0.5.0`),
    /// we'd report "no update" — but that's a hotfix prerelease scenario
    /// where semver itself is ambiguous (prerelease of an older line vs
    /// release of a newer line). Acceptable to under-report there.
    private func isNewer(latest: String, current: String?) -> Bool {
        let norm: (String) -> String = { s in
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
            if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
            return t
        }
        let a = norm(latest)
        let b = current.map(norm) ?? ""
        return !b.isEmpty && a != b
    }

    // MARK: - Constants

    private enum Keys {
        static let autoCheck    = "updateCheck.autoCheck"
        static let lastChecked  = "updateCheck.lastChecked"
    }

    private static let repo = "nilaoda/N_m3u8DL-RE"
    private static let apiURL = "https://api.github.com/repos/\(repo)/releases/latest"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60  // 24h

    // MARK: - JSON model (only the fields we actually use)

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let published_at: String
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
        }
    }
}

// MARK: - View

/// Compact row used inside Settings. Kept here (next to the model) so the
/// Settings pane stays a thin wrapper.
struct UpdateCheckerSettingsSection: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        Section("N_m3u8DL-RE 更新") {
            HStack {
                Text("当前版本")
                Spacer()
                Text(UpdateChecker.currentTag ?? "未知")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let tag = checker.latestTag {
                HStack {
                    Text("最新版本")
                    Spacer()
                    Text(tag)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(checker.updateAvailable ? .orange : .secondary)
                        .textSelection(.enabled)
                }
                if let date = checker.publishedAt {
                    HStack {
                        Text("发布时间")
                        Spacer()
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let err = checker.checkError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if checker.isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("检查中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if checker.lastChecked != nil {
                Text("已是最新版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if checker.updateAvailable, let urlStr = checker.latestHTMLURL,
               let url = URL(string: urlStr) {
                Link(destination: url) {
                    Label("在 GitHub 查看新版", systemImage: "arrow.up.right.square")
                }
            }

            HStack {
                Toggle("启动时自动检查", isOn: $checker.autoCheckEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Button {
                    Task { await checker.check(force: true) }
                } label: {
                    Label("立即检查", systemImage: "arrow.clockwise")
                }
                .disabled(checker.isChecking)
            }
        }
    }
}

// MARK: - Update banner (shown in the main window)

/// Compact top-of-window banner that appears when `UpdateChecker` has
/// confirmed a newer release is available. The dismissal state is local
/// to the view (resets every app launch), so a fresh check 24h later
/// will simply show the banner again — we don't persist "I don't care
/// about this version" because the next one might be a critical fix.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    @State private var dismissed: Bool = false

    var body: some View {
        if !dismissed,
           checker.updateAvailable,
           let tag = checker.latestTag,
           let urlStr = checker.latestHTMLURL,
           let url = URL(string: urlStr) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("N_m3u8DL-RE 有新版本可用")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text("本地 \(UpdateChecker.currentTag ?? "未知") → 最新 \(tag)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 8)
                Link(destination: url) {
                    Label("在 GitHub 查看", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.link)
                .foregroundStyle(.white)
                .help(urlStr)

                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.white)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭（下次启动仍会再检查）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}