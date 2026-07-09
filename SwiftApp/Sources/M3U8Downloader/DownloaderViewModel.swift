import Foundation
import SwiftUI
import UserNotifications
import AppKit

@MainActor
final class DownloaderViewModel: ObservableObject {

    /// Path to the bundled N_m3u8DL-RE binary. `bin/package_app.sh` copies
    /// it into `Contents/MacOS/` next to the main executable, so we resolve
    /// it as a sibling executable of the bundle. There is intentionally no
    /// fallback to a hard-coded home-directory copy — if the binary is
    /// missing from the bundle, the caller surfaces the path in the error
    /// message so we know to rebuild the .app.
    static var executablePath: String {
        // 1. Apple-blessed API for sibling executables in Contents/MacOS/.
        if let url = Bundle.main.url(forAuxiliaryExecutable: "N_m3u8DL-RE"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        // 2. Derive from the main executable's directory — covers running
        //    outside a real .app bundle during `swift run` development.
        let candidate = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("N_m3u8DL-RE")
            .path ?? "/missing/N_m3u8DL-RE"
        return candidate
    }

    /// Auto-detected path to the `ffmpeg` binary. N_m3u8DL-RE needs ffmpeg
    /// for `.mp4` / `.mkv` muxing. macOS GUI apps don't get Homebrew's bin
    /// in their PATH, so we have to either inject the path here OR prepend
    /// it to the subprocess environment. We do both.
    static var ffmpegPath: String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",     // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",        // Intel Homebrew
            "/opt/local/bin/ffmpeg",        // MacPorts
            NSHomeDirectory() + "/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// macOS GUI apps inherit a stripped PATH that excludes `/opt/homebrew/bin`,
    /// `/usr/local/bin`, etc. We also force `HOME` and `TMPDIR` so the child
    /// (N_m3u8DL-RE) constructs its temp / work directories under a writable
    /// location. Some .NET binaries otherwise fall back to `Environment.
    /// CurrentDirectory`, which for a Finder-launched GUI app is `/` —
    /// read-only on macOS — and cause `Read-only file system` errors.
    static var inheritedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Make sure HOME is set (some macOS-launched .NET processes lose it).
        if env["HOME"] == nil || env["HOME"]?.isEmpty == true {
            env["HOME"] = NSHomeDirectory()
        }

        // Force TMPDIR to a writable, app-local location. Apple's default
        // ($TMPDIR under /var/folders/...) usually works, but the GUI-app
        // sandbox sometimes doesn't propagate it. Fall back to ~/Library/Caches
        // if the system value is missing or points somewhere we can't write.
        let candidateTmp: String? = {
            if let t = env["TMPDIR"], !t.isEmpty,
               FileManager.default.isWritableFile(atPath: t) {
                return t
            }
            let fallback = NSHomeDirectory() + "/Library/Caches"
            try? FileManager.default.createDirectory(
                atPath: fallback, withIntermediateDirectories: true)
            return FileManager.default.isWritableFile(atPath: fallback)
                ? fallback : nil
        }()
        if let t = candidateTmp {
            env["TMPDIR"] = t
        }

        // Set TERM so subprocesses (e.g. N_m3u8DL-RE) calling `tput` on
        // exit don't fail with "No value for $TERM and no -T specified".
        // We default to "dumb" because:
        //   1. `tput` exits cleanly (no env probing error).
        //   2. N_m3u8DL-RE won't try to emit ANSI colour escapes that
        //      would have been stripped anyway by `strippingAnsi`.
        // If the user has explicitly set $TERM in their shell, we keep it.
        if env["TERM"] == nil || env["TERM"]?.isEmpty == true {
            env["TERM"] = "dumb"
        }

        // Prepend common brew / ports / user bin paths so N_m3u8DL-RE can
        // find `ffmpeg`, etc. without us having to pass `--ffmpeg-binary-path`
        // every time (we still do, as a belt-and-braces).
        let extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(NSHomeDirectory())/bin"
        ].filter { FileManager.default.fileExists(atPath: $0) }
        if !extra.isEmpty {
            let current = env["PATH"] ?? ""
            env["PATH"] = extra.joined(separator: ":") + ":" + current
        }
        return env
    }

    @Published var draft = DownloadTask(
        url: "",
        saveDir: NSHomeDirectory() + "/Movies/M3U8Downloads"
    )
    @Published var status: DownloadStatus = .idle
    @Published var logs: [DownloadLogLine] = []
    /// Single-line, in-place progress text. The UI binds this to a fixed
    /// row above the scrollable log so the progress bar stays anchored
    /// (instead of being appended as a new log line every percent). nil
    /// when no active download or when the ffmpeg fallback hasn't reported
    /// a Duration yet.
    @Published var currentProgress: String? = nil
    @Published var headerInput: String = ""    // staging for new header
    @Published var startedAt: Date?

    /// (current, total) for a batch download in progress; nil when not batching.
    /// UI uses this to show "正在下载 X / N".
    @Published var batchProgress: (current: Int, total: Int)? = nil

    /// Active subprocess. Replaced on every new `start` / `startExternal` /
    /// `runFFmpegFallback` so a previous task's pending `onLine` / `onExit`
    /// callbacks can be filtered out via `self.runner === runnerRef` and
    /// don't clobber the new task's state.
    private var runner: ProcessRunner?

    // MARK: - URL helpers

    /// Pull m3u8 URL from clipboard if draft.url is empty.
    func autofillFromClipboard() {
        guard draft.url.isEmpty,
              let s = NSPasteboard.general.string(forType: .string),
              s.contains("m3u8") else { return }
        draft.url = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Headers management

    func addHeader() {
        let trimmed = headerInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        draft.headers.append(trimmed)
        headerInput = ""
    }

    func removeHeader(_ h: String) {
        draft.headers.removeAll { $0 == h }
    }

    // MARK: - Folder picker

    func pickSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            draft.saveDir = url.path
        }
    }

    func revealSaveDir() {
        let url = URL(fileURLWithPath: draft.saveDir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Build args

    private func buildArguments() -> [String] {
        var args: [String] = [draft.url]
        args += ["--save-dir", draft.saveDir]
        if !draft.saveName.isEmpty {
            args += ["--save-name", draft.saveName]
        }
        for h in draft.headers { args += ["-H", h] }
        args += ["--thread-count", String(draft.threads)]
        if draft.autoSelect { args += ["--auto-select"] }
        switch draft.format {
        case .mp4: args += ["-M", "format=mp4"]
        case .mkv: args += ["-M", "format=mkv"]
        case .ts:  break
        }
        if draft.livePerformAsVOD { args += ["--live-perform-as-vod"] }
        appendFFmpeg(&args)
        return args
    }

    /// If ffmpeg is found, append `--ffmpeg-binary-path <path>` so N_m3u8DL-RE
    /// can mux without depending on the (stripped) child-process PATH.
    private func appendFFmpeg(_ args: inout [String]) {
        if let p = Self.ffmpegPath, !args.contains("--ffmpeg-binary-path") {
            args += ["--ffmpeg-binary-path", p]
        }
    }

    // MARK: - Run / Cancel

    func start() {
        let url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            status = .failed("URL 为空")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            status = .failed("找不到 N_m3u8DL-RE: \(Self.executablePath)")
            return
        }

        // ensure dir
        try? FileManager.default.createDirectory(
            atPath: draft.saveDir, withIntermediateDirectories: true)

        status = .running
        if !logs.isEmpty {
            appendLog("────────────")
        }
        appendLog("▶ \(url)")
        startedAt = Date()
        appendLog("$ \(Self.executablePath) \(buildArguments().joined(separator: " "))")

        // Cancel any in-flight subprocess and swap in a fresh runner so
        // the previous task's onLine/onExit callbacks can be filtered.
        runner?.cancel()
        let active = ProcessRunner()
        self.runner = active

        active.launch(
            executable: Self.executablePath,
            arguments: buildArguments(),
            workingDirectory: draft.saveDir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self, runnerRef = active] line, isErr in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    self.appendLog(isErr ? line : line, isErr: isErr)
                }
            },
            onExit: { [weak self, runnerRef = active] code, err in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    self.currentProgress = nil
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed(err.localizedDescription)
                        self.appendLog("✗ 启动失败: \(err.localizedDescription)")
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.appendLog("✓ N_m3u8DL-RE 完成 (\(String(format: "%.1f", elapsed))s)")
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                        self.appendLog("✗ 已取消")
                    } else if Self.shouldFallback(code: code, err: err) {
                        // N_m3u8DL-RE exited abnormally — try ffmpeg as a
                        // fallback. Status / notification will be set inside.
                        self.appendLog("[fallback] N_m3u8DL-RE 退出码 \(code),改用 ffmpeg")
                        self.runFFmpegFallback(
                            .init(
                                url: self.draft.url,
                                saveDir: self.draft.saveDir,
                                saveName: self.draft.saveName,
                                headers: self.draft.headers,
                                format: self.draft.format
                            ),
                            nmdlreStartedAt: self.startedAt ?? Date()
                        )
                    } else {
                        self.status = .failed("退出码 \(code)")
                        self.appendLog("✗ N_m3u8DL-RE 失败 (退出码 \(code))")
                        self.notifyDone(success: false)
                    }
                }
            })
    }

    func cancel() {
        // When the user hits "取消" we also want to break out of a batch
        // download loop (see startBatchExternal).
        batchProgress = nil
        currentProgress = nil
        runner?.cancel()
    }

    // MARK: - ffmpeg fallback
    //
    // N_m3u8DL-RE's progress bar uses Spectre.Console, which has a known race
    // that occasionally throws `List<T>.RemoveRange` out-of-bounds and crashes
    // the .NET process. When that happens we fall back to `ffmpeg -c copy`,
    // which doesn't parse playlists intelligently but reliably handles a
    // single-variant HLS stream and never goes through Spectre.Console.

    private struct FallbackRequest {
        let url: String
        let saveDir: String
        let saveName: String      // may be empty
        let headers: [String]     // "Referer: xxx" format, as used by N_m3u8DL-RE's -H
        let format: OutputFormat
    }

    private static let fileTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Where N_m3u8DL-RE would have stashed its per-run artifacts for this
    /// download. With `saveName` set it's `<saveDir>/<saveName>`; without
    /// it's `<saveDir>/index_<timestamp>` and we probe ±1 s around the
    /// start time to cover the case where N_m3u8DL-RE's and our timestamps
    /// straddle a second boundary.
    private func nmdlreArtifactDirs(req: FallbackRequest, around ts: Date) -> [String] {
        if !req.saveName.isEmpty {
            return ["\(req.saveDir)/\(req.saveName)"]
        }
        let f = Self.fileTimestamp
        return [
            "\(req.saveDir)/index_\(f.string(from: ts.addingTimeInterval(-1)))",
            "\(req.saveDir)/index_\(f.string(from: ts))",
            "\(req.saveDir)/index_\(f.string(from: ts.addingTimeInterval(1)))"
        ]
    }

    private func runFFmpegFallback(_ req: FallbackRequest, nmdlreStartedAt: Date) {
        guard let ffmpeg = Self.ffmpegPath,
              FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            appendLog("[fallback] ffmpeg 不可用,跳过 (\(Self.ffmpegPath ?? "未找到"))")
            status = .failed("N_m3u8DL-RE 失败,且未找到 ffmpeg")
            notifyDone(success: false)
            return
        }

        // N_m3u8DL-RE always creates a per-run subdirectory under --save-dir
        // before it crashes on the Spectre.Console bug — `index_<ts>/` when
        // saveName is empty, or `<saveName>/` when set. It contains a stray
        // `0____/` empty segments dir plus meta.json / raw.m3u8 that the user
        // doesn't want. Remove them so the save-dir only ends up with the
        // ffmpeg output.
        let candidates = nmdlreArtifactDirs(req: req, around: nmdlreStartedAt)
        for d in candidates where FileManager.default.fileExists(atPath: d) {
            do {
                try FileManager.default.removeItem(atPath: d)
                appendLog("[fallback] 清理 N_m3u8DL-RE 残留: \(d)")
            } catch {
                appendLog("[fallback] 清理残留失败(忽略): \(d) — \(error.localizedDescription)")
            }
        }

        var args: [String] = []
        if !req.headers.isEmpty {
            // ffmpeg's -headers is a single string; each header must end in CRLF.
            let headerStr = req.headers
                .map { $0.hasSuffix("\r\n") ? $0 : "\($0)\r\n" }
                .joined()
            args += ["-headers", headerStr]
        }
        args += ["-y", "-i", req.url]
        args += ["-c", "copy"]

        let ext: String
        switch req.format {
        case .mp4:
            // h264 in TS segments → MP4 needs annex-B bitstream filter so
            // the parameter sets land in the moov box.
            args += ["-bsf:v", "h264_mp4toannexb"]
            args += ["-f", "mp4"]
            ext = "mp4"
        case .mkv:
            args += ["-f", "matroska"]
            ext = "mkv"
        case .ts:
            args += ["-f", "mpegts"]
            ext = "ts"
        }

        // Add _ffmpeg suffix so the file doesn't collide with any partial
        // output N_m3u8DL-RE may have left behind. Also append a 6-char
        // URL-derived suffix so two tasks that happen to share a saveName
        // (e.g. a batch of independent m3u8s that all hashed to the same
        // i+1 = 1 because each link has a single variant) still produce
        // distinct files. abs(hashValue) is fine — collision risk across
        // ~10s of URLs in one batch is negligible.
        let baseName: String = {
            if req.saveName.isEmpty {
                return "fallback_\(Self.fileTimestamp.string(from: Date()))"
            }
            let suffix = String(abs(req.url.hashValue), radix: 16).suffix(6)
            return "\(req.saveName)_ffmpeg_\(suffix)"
        }()
        let outFile = "\(req.saveDir)/\(baseName).\(ext)"
        args += [outFile]

        appendLog("$ \(ffmpeg) \(args.joined(separator: " "))")

        // Swap runner so any straggler callbacks from the failed N_m3u8DL-RE
        // subprocess don't pollute the ffmpeg log.
        runner?.cancel()
        let active = ProcessRunner()
        self.runner = active

        // Holder for state captured by the onLine closure (needs reference
        // semantics so we can mutate `duration` / `lastPercent` from inside
        // the closure across calls).
        let progress = FFmpegProgressState()

        active.launch(
            executable: ffmpeg,
            arguments: args,
            workingDirectory: req.saveDir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self, runnerRef = active, progress] line, isErr in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    // 1) Capture source duration as soon as ffmpeg reports it.
                    //    The Duration line itself is filtered out by
                    //    shouldFilter (`^Duration:`) — the progress bar
                    //    shows the duration immediately after.
                    if progress.duration == nil, let d = Self.parseFFmpegDuration(line) {
                        progress.duration = d
                        return
                    }
                    // 2) Consume ffmpeg's per-frame progress lines. Render
                    //    them into a single in-place progress text (anchored
                    //    row in the UI), NOT into the scrollable log — this
                    //    keeps the log from being spammed at 30 lines/sec.
                    if let p = Self.parseFFmpegFrameLine(line) {
                        if let dur = progress.duration {
                            let percent = max(0, min(100, Int(p.time / dur * 100)))
                            if percent != progress.lastPercent {
                                progress.lastPercent = percent
                                let bar = Self.makeProgressBar(percent: percent, width: 20)
                                let timeStr = Self.formatHMS(p.time)
                                let durStr  = Self.formatHMS(dur)
                                self.currentProgress =
                                    "\(bar) \(percent)%  (\(timeStr) / \(durStr))  \(String(format: "%.1fx", p.speed))"
                            }
                        }
                        return  // drop raw `frame=` line
                    }
                    // 3) Anything else: pass through unchanged.
                    self.appendLog(line, isErr: isErr)
                }
            },
            onExit: { [weak self, runnerRef = active] code, err in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    self.currentProgress = nil
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed("ffmpeg fallback: \(err.localizedDescription)")
                        self.appendLog("✗ ffmpeg 启动失败: \(err.localizedDescription)")
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.appendLog("✓ ffmpeg fallback 完成 (\(String(format: "%.1f", elapsed))s)")
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                        self.appendLog("✗ ffmpeg 已取消")
                    } else {
                        self.status = .failed("N_m3u8DL-RE 和 ffmpeg fallback 都失败 (ffmpeg 退出码 \(code))")
                        self.appendLog("✗ ffmpeg fallback 失败 (退出码 \(code))")
                        self.notifyDone(success: false)
                    }
                }
            })
    }

    /// Returns true when the exit looks like a real failure that should
    /// trigger the ffmpeg fallback. User-cancel and spawn errors are excluded.
    private static func shouldFallback(code: Int32, err: Error?) -> Bool {
        guard err == nil else { return false }
        if code == 0 { return false }
        if code == 15 || code == 9 { return false }   // SIGTERM / SIGKILL
        return true
    }

    // MARK: - ffmpeg progress parsing

    /// Mutable state captured by `runFFmpegFallback`'s onLine closure. Needs
    /// reference semantics so we can update `duration` / `lastPercent` across
    /// calls (Swift closure capture of `let` structs wouldn't allow that).
    fileprivate final class FFmpegProgressState {
        var duration: TimeInterval?
        var lastPercent: Int = -1
    }

    /// Parse a line of ffmpeg stderr for the source `Duration: HH:MM:SS.MS`.
    /// Returns the duration in seconds, or nil if the line isn't one.
    private static func parseFFmpegDuration(_ line: String) -> TimeInterval? {
        guard let r = line.range(of: #"Duration:\s*(\d+):(\d{2}):(\d+\.\d+)"#,
                                 options: .regularExpression) else { return nil }
        let s = line[r]
        // Pull just the time portion. "Duration: " prefix is dropped by the
        // regex's `\s*`; capture group 0 of the first match is the whole
        // "HH:MM:SS.MS" chunk.
        let colonParts = s.split(separator: " ")
        guard let last = colonParts.last else { return nil }
        let hms = last.split(separator: ":")
        guard hms.count == 3,
              let h = Double(hms[0]),
              let m = Double(hms[1]),
              let sec = Double(hms[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Parse a ffmpeg per-frame progress line. Returns (current time in
    /// seconds, encoding speed multiplier) or nil if it isn't one. Lines
    /// look like:
    ///   `frame=  150 fps=0.0 size=    1024KiB time=00:00:05.92 bitrate=... speed=11.7x elapsed=...`
    private static func parseFFmpegFrameLine(_ line: String) -> (time: TimeInterval, speed: Double)? {
        let head = line.trimmingCharacters(in: .whitespaces)
        guard head.hasPrefix("frame=") else { return nil }

        var time: TimeInterval?
        if let r = line.range(of: #"time=(\d+):(\d{2}):(\d+\.\d+)"#, options: .regularExpression) {
            let token = String(line[r]).replacingOccurrences(of: "time=", with: "")
            let p = token.split(separator: ":")
            if p.count == 3,
               let h = Double(p[0]),
               let m = Double(p[1]),
               let s = Double(p[2]) {
                time = h * 3600 + m * 60 + s
            }
        }

        var speed: Double = 1
        if let r = line.range(of: #"speed=([\d.]+)x"#, options: .regularExpression) {
            let token = String(line[r])
            // token is like "speed=11.7x"; strip both ends.
            let stripped = token
                .replacingOccurrences(of: "speed=", with: "")
                .replacingOccurrences(of: "x", with: "")
            speed = Double(stripped) ?? 1
        }

        if let t = time { return (t, speed) }
        return nil
    }

    /// Render an ASCII progress bar. `width` is the total character count
    /// (including the brackets). Filled block: █ ; empty: ░ .
    private static func makeProgressBar(percent: Int, width: Int) -> String {
        let clamped = max(0, min(100, percent))
        // -2 for the brackets
        let inner = max(0, width - 2)
        let filled = clamped * inner / 100
        let empty = inner - filled
        return "[" + String(repeating: "█", count: filled)
                   + String(repeating: "░", count: empty) + "]"
    }

    /// Format seconds as `H:MM:SS` or `M:SS`.
    private static func formatHMS(_ sec: TimeInterval) -> String {
        let total = Int(sec.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - External handoff (used by BrowserView)

    /// Run a download with explicit parameters, independent of `draft`.
    /// The current download is replaced — only one task runs at a time.
    func startExternal(url: String,
                       saveName: String = "",
                       saveDir: String? = nil,
                       extraHeaders: [String] = [],
                       threads: Int = 12,
                       format: OutputFormat = .mp4) {
        // Reset any in-flight task first.
        if case .running = status { runner?.cancel() }

        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else {
            status = .failed("URL 为空")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            status = .failed("找不到 N_m3u8DL-RE")
            return
        }
        let dir = saveDir ?? draft.saveDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        var args: [String] = [u, "--save-dir", dir]
        if !saveName.isEmpty { args += ["--save-name", saveName] }
        for h in extraHeaders.isEmpty ? draft.headers : extraHeaders {
            args += ["-H", h]
        }
        args += ["--thread-count", String(threads), "--auto-select"]
        switch format {
        case .mp4: args += ["-M", "format=mp4"]
        case .mkv: args += ["-M", "format=mkv"]
        case .ts:  break
        }
        appendFFmpeg(&args)

        // Cancel any in-flight subprocess and swap in a fresh runner so
        // the previous task's onLine/onExit callbacks get filtered out via
        // `self.runner === runnerRef` and don't clobber the new state.
        runner?.cancel()
        let active = ProcessRunner()
        self.runner = active

        status = .running
        // NOTE: do NOT logs.removeAll() — a batch download streams multiple
        // tasks through the same VM and we want to see the per-task history.
        // Each launch appends a divider line below for readability.
        // In batch mode, startBatchExternal already printed the per-item
        // header line ("▶ 批量 [X / N]  <url>") before calling us, so we
        // skip the per-task header here to avoid duplication.
        if !logs.isEmpty {
            appendLog("────────────")
        }
        if batchProgress == nil {
            appendLog("▶ \(saveName.isEmpty ? u : saveName)")
        }
        startedAt = Date()
        appendLog("$ \(Self.executablePath) \(args.joined(separator: " "))")

        active.launch(
            executable: Self.executablePath,
            arguments: args,
            workingDirectory: dir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self, runnerRef = active] line, isErr in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    self.appendLog(isErr ? line : line, isErr: isErr)
                }
            },
            onExit: { [weak self, runnerRef = active] code, err in
                Task { @MainActor in
                    guard let self, self.runner === runnerRef else { return }
                    self.currentProgress = nil
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed(err.localizedDescription)
                        self.appendLog("✗ 启动失败: \(err.localizedDescription)")
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.appendLog("✓ N_m3u8DL-RE 完成 (\(String(format: "%.1f", elapsed))s)")
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                        self.appendLog("✗ 已取消")
                    } else if Self.shouldFallback(code: code, err: err) {
                        // N_m3u8DL-RE exited abnormally — try ffmpeg as a
                        // fallback. Status / notification will be set inside.
                        self.appendLog("[fallback] N_m3u8DL-RE 退出码 \(code),改用 ffmpeg")
                        self.runFFmpegFallback(
                            .init(
                                url: u,
                                saveDir: dir,
                                saveName: saveName,
                                headers: extraHeaders.isEmpty ? self.draft.headers : extraHeaders,
                                format: format
                            ),
                            nmdlreStartedAt: self.startedAt ?? Date()
                        )
                    } else {
                        self.status = .failed("退出码 \(code)")
                        self.appendLog("✗ N_m3u8DL-RE 失败 (退出码 \(code))")
                        self.notifyDone(success: false)
                    }
                }
            })
    }

    // MARK: - Batch download

    /// Run a list of downloads serially. Each item kicks off `startExternal`
    /// and we wait for `status` to leave `.running` before starting the next.
    /// `batchProgress` is published so the footer can show "正在下载 X / N".
    ///
    /// The old behaviour was to launch them in parallel from `BrowserView`
    /// with 50ms spacing. That relied on the single shared `ProcessRunner`
    /// not cancelling its predecessor — which it did — so only the *last*
    /// launched download ever finished. This is the fix.
    func startBatchExternal(items: [(url: String, name: String)],
                            saveDir: String,
                            extraHeaders: @escaping (String) -> [String]) {
        guard !items.isEmpty else { return }
        // If something is already running, cancel it cleanly first; the
        // await loop below would never make progress otherwise.
        runner?.cancel()
        batchProgress = (current: 0, total: items.count)

        Task { @MainActor in
            for (i, item) in items.enumerated() {
                if batchProgress == nil {
                    // User hit "取消" while we were between tasks.
                    appendLog("[批量] 已取消 (完成 \(i) / \(items.count))")
                    return
                }
                batchProgress = (current: i + 1, total: items.count)
                let headers = extraHeaders(item.url)
                // Batch mode: use the global batch index as the save name
                // (1, 2, 3, …) so the user gets a tidy, easy-to-count
                // sequence of files. The per-URL `name` from downloadPayload
                // (with its urlKey / host prefix) is still useful for the
                // log line, but we don't pass it to startExternal because
                // the host/key portion is redundant when every file is
                // numbered in order. The ffmpeg fallback still appends a
                // short URL-hash suffix as belt-and-braces.
                appendLog("▶ 批量 [\(i + 1) / \(items.count)]  \(item.url)")
                startExternal(
                    url: item.url,
                    saveName: String(i + 1),
                    saveDir: saveDir,
                    extraHeaders: headers
                )
                // Wait until the current subprocess actually exits (success,
                // fail, cancel, or fallback that completes). Fallback also
                // finishes by flipping `status` out of `.running`, so a plain
                // status-poll is enough.
                while case .running = status {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            batchProgress = nil
            appendLog("[批量] 全部完成 (\(items.count) 个)")
        }
    }

    // MARK: - Logging

    /// External appendLog (used by BrowserView for one-off diagnostic lines,
    /// e.g. "about to start batch of N items"). Same filter / ANSI-strip
    /// pipeline as the private one below.
    func appendLogExternal(_ text: String) {
        appendLog(text)
    }

    private func appendLog(_ text: String, isErr: Bool = false) {
        if Self.shouldFilter(text) { return }
        // strip ANSI escape codes for readability
        let clean = Self.strippingAnsi(text)
        logs.append(.init(time: Date(), text: clean))
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
    }

    /// Drop lines that don't carry actionable info. Per-item log goes from
    /// ~70 lines to ~10 with these in place. Kept (visible to user):
    ///   • our explicit ✓/✗/[fallback] summary lines
    ///   • the actual command lines ("$ N_m3u8DL-RE ..." / "$ ffmpeg ...")
    ///   • ffmpeg's final mux summary (`video:...KiB audio:...KiB ...`)
    ///   • anything that looks like a real error (e.g. ffmpeg's `[error]`).
    ///
    /// `head` is `line` with leading/trailing whitespace stripped, so the
    /// regex patterns don't need a leading `\s+` — that was a previous bug.
    private static func shouldFilter(_ line: String) -> Bool {
        let head = line.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return true }

        // N_m3u8DL-RE bare stderr timestamps: "10:46:21.700"
        if head.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3}\s*$"#,
                      options: .regularExpression) != nil {
            return true
        }
        // N_m3u8DL-RE bracketed status lines. All of its prefixes
        // (INFO / WARN / STATUS / ERROR / DEBUG / TIP) are its own logger's
        // boilerplate — "加载URL", "内容匹配", "写出meta json",
        // "你已开启下载完成后混流", "开始下载...Vid Kbps", etc. Same every run
        // and not actionable; we emit our own ✓/✗/[fallback] summary lines
        // for status. The unanchored match also catches wrapped/merged
        // variants like "  : 内容匹配...HH:MM:SS.MMM INFO : 正在解析" where
        // the prefix appears mid-line after two stdout writes get coalesced
        // without a newline separator.
        if head.range(of: #"(INFO|WARN|STATUS|ERROR|DEBUG|TIP)\s*:"#,
                      options: .regularExpression) != nil {
            return true
        }
        // Empty bracketed line: just "INFO" / "WARN" / etc. with no body
        // and no colon. Same category as above but the regex above requires
        // a `:`, so this catches the bare-prefix case separately. Also
        // matches wrapped orphans like "13:11:14.532 INFO" where N_m3u8DL-RE
        // splits the prefix from its body across two stdout writes.
        if head.range(of: #"^(\d{2}:\d{2}:\d{2}\.\d{3}\s+)?(INFO|WARN|STATUS|ERROR|DEBUG|TIP)$"#,
                      options: .regularExpression) != nil {
            return true
        }
        // N_m3u8DL-RE's Spectre.Console progress-bar fragments — when stdout
        // is a pipe (not a TTY), the in-place `\r`-overwrite rendering
        // breaks into orphan lines like "Vid" alone, then
        // "  Kbps | 125 Segments | ~08m18s" on the next line. We don't have
        // a per-segment progress display so these carry no info.
        if head == "Vid" { return true }
        if head.range(of: #"^Kbps\b"#, options: .regularExpression) != nil {
            return true
        }
        // ffmpeg / N_m3u8DL-RE wrap artifacts — when stdout has no terminal
        // width, long lines get split mid-content and we end up with orphan
        // continuations like "正在解析媒体信息..." (truncated INFO content),
        // ": 写出meta json" (continuation of a wrapped WARN line), or
        // "90k tbn, start 1.480000" (continuation of stream metadata). The
        // leading ": " form is the easiest reliable signal for "this is the
        // tail of something already filtered above".
        if head.range(of: #"^:\s+\S"#, options: .regularExpression) != nil {
            return true
        }
        // Well-known orphan fragments of wrapped lines.
        let knownOrphans: [String] = [
            "HTTP Live Streaming",         // tail of "INFO : 内容匹配: HTTP Live Streaming"
            "正在解析媒体信息...",              // tail of "INFO : 正在解析媒体信息..."
            "90k tbn, start 1.480000",      // tail of Stream #0:0 ... metadata
            "25 fps, 25 tbr, 90k tbn"       // tail of Stream #0:0 ... metadata
        ]
        if knownOrphans.contains(head) { return true }
        // N_m3u8DL-RE's Spectre.Console crash stack trace. Same
        // `List<T>.RemoveRange` out-of-bounds bug every time and not
        // actionable; we already log "[fallback] N_m3u8DL-RE 退出码 X, 改用
        // ffmpeg" so the user has context. Frames are a mix of
        // `System.*` and `Spectre.Console.*` so we match any stack frame.
        if head.hasPrefix("Unhandled exception.") { return true }
        if head.hasPrefix("System.ArgumentException:") { return true }
        if head.range(of: #"^at\s+[A-Z][A-Za-z0-9_.]+(\.|`)"#,
                      options: .regularExpression) != nil { return true }
        if head.hasPrefix("--- End of stack trace") { return true }
        // N_m3u8DL-RE version banner: "N_m3u8DL-RE (Beta version) 20260628"
        if head.range(of: #"^N_m3u8DL-RE\b"#, options: .regularExpression) != nil {
            return true
        }

        // ffmpeg startup banner
        if head.hasPrefix("ffmpeg version") { return true }
        if head.range(of: #"^Copyright\s+\(c\)"#,
                      options: .regularExpression) != nil { return true }
        if head.range(of: #"^(built with|configuration:|lib\w+)"#,
                      options: .regularExpression) != nil { return true }

        // ffmpeg stream / input / output / mapping / metadata / duration.
        // Duration is already shown in the progress bar via parseFFmpegDuration,
        // and the metadata fields are just ffmpeg's verbose playlist dump
        // (we already know codec/dim/bitrate from N_m3u8DL-RE).
        let ffmpegNoise: [String] = [
            #"^Input #\d+,"#,
            #"^Duration:"#,
            #"^Program \d+"#,
            #"^Metadata:"#,
            #"^variant_bitrate\b"#,
            #"^Stream #\d+:"#,
            #"^Stream #\d+: -> #\d+:"#,
            #"^Stream #\d+$"#,            // wrapped second half of a Stream line
            #"^:?\d+\(und\):"#,           // wrapped ":0(und): Audio: ..." continuation
            #"^:\d+: Video:"#,            // wrapped ":0: Video: ..." continuation
            #"^:\d+\[0x[0-9a-fA-F]+\]:"#, // wrapped ":0[0x0]: Video: ..." continuation
            #"^\d+ fps,"#,                // wrapped "25 fps, 25 tbr, 90k tbn" tail
            #"^Stream mapping:"#,
            #"^Output #\d+,"#,
            #"^encoder\s+:"#,
            #"^Press \[q\]"#
        ]
        for pat in ffmpegNoise {
            if head.range(of: pat, options: .regularExpression) != nil { return true }
        }

        // ffmpeg per-segment HTTP chatter — one line per .ts file opened.
        // Pattern: "[<tag> #N @ 0xADDR] Opening '...ts' for reading" or
        // "[<tag>#N @ 0xADDR]" (no space). Final mux summary uses the
        // similar "[out#0/mp4 @ 0xADDR] video:..." form, but the "Opening"
        // tail is unique to the segment-opening chatter.
        if head.range(of: #"\]\s+Opening\s+'"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func strippingAnsi(_ s: String) -> String {
        // very small ANSI stripper covering CSI SGR and OSC
        var out = ""
        var iter = s.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c == "\u{001B}" {
                // skip until letter
                while let n = iter.next() {
                    if (0x40...0x7E).contains(Int(n.value)) { break }
                }
                continue
            }
            out.unicodeScalars.append(c)
        }
        return out
    }

    // MARK: - Notifications

    private func notifyDone(success: Bool) {
        let content = UNMutableNotificationContent()
        content.title = success ? "下载完成" : "下载失败"
        content.body  = success
            ? "保存到: \(draft.saveDir)"
            : "请查看日志"
        content.sound = success ? .default : .defaultCritical
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}