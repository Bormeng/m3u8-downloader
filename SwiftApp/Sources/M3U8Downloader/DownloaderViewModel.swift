import Foundation
import SwiftUI
import UserNotifications
import AppKit

@MainActor
final class DownloaderViewModel: ObservableObject {

    /// Resolved at runtime: prefer the bundled copy, fall back to /Users/ming/Movies/N_m3u8DL-RE.
    static var executablePath: String {
        if let bundled = Bundle.main.path(forResource: "N_m3u8DL-RE", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return "/Users/ming/Movies/N_m3u8DL-RE"
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
    @Published var headerInput: String = ""    // staging for new header
    @Published var startedAt: Date?

    private let runner = ProcessRunner()

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
        logs.removeAll()
        startedAt = Date()
        appendLog("$ \(Self.executablePath) \(buildArguments().joined(separator: " "))")

        runner.launch(
            executable: Self.executablePath,
            arguments: buildArguments(),
            workingDirectory: draft.saveDir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self] line, isErr in
                Task { @MainActor in
                    self?.appendLog(isErr ? line : line, isErr: isErr)
                }
            },
            onExit: { [weak self] code, err in
                Task { @MainActor in
                    guard let self else { return }
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed(err.localizedDescription)
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                    } else if Self.shouldFallback(code: code, err: err) {
                        // N_m3u8DL-RE exited abnormally — try ffmpeg as a
                        // fallback. Status / notification will be set inside.
                        self.runFFmpegFallback(.init(
                            url: self.draft.url,
                            saveDir: self.draft.saveDir,
                            saveName: self.draft.saveName,
                            headers: self.draft.headers,
                            format: self.draft.format
                        ))
                    } else {
                        self.status = .failed("退出码 \(code)")
                        self.notifyDone(success: false)
                    }
                }
            })
    }

    func cancel() {
        runner.cancel()
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

    private func runFFmpegFallback(_ req: FallbackRequest) {
        guard let ffmpeg = Self.ffmpegPath,
              FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            appendLog("[fallback] ffmpeg 不可用,跳过 (\(Self.ffmpegPath ?? "未找到"))")
            status = .failed("N_m3u8DL-RE 失败,且未找到 ffmpeg")
            notifyDone(success: false)
            return
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
        // output N_m3u8DL-RE may have left behind.
        let baseName: String = {
            if req.saveName.isEmpty {
                return "fallback_\(Self.fileTimestamp.string(from: Date()))"
            }
            return "\(req.saveName)_ffmpeg"
        }()
        let outFile = "\(req.saveDir)/\(baseName).\(ext)"
        args += [outFile]

        appendLog("[fallback] N_m3u8DL-RE 失败,改用 ffmpeg")
        appendLog("$ \(ffmpeg) \(args.joined(separator: " "))")

        runner.launch(
            executable: ffmpeg,
            arguments: args,
            workingDirectory: req.saveDir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self] line, isErr in
                Task { @MainActor in
                    self?.appendLog(line, isErr: isErr)
                }
            },
            onExit: { [weak self] code, err in
                Task { @MainActor in
                    guard let self else { return }
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed("ffmpeg fallback: \(err.localizedDescription)")
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                    } else {
                        self.status = .failed("N_m3u8DL-RE 和 ffmpeg fallback 都失败 (ffmpeg 退出码 \(code))")
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
        if case .running = status { runner.cancel() }

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

        status = .running
        logs.removeAll()
        startedAt = Date()
        appendLog("$ \(Self.executablePath) \(args.joined(separator: " "))")

        runner.launch(
            executable: Self.executablePath,
            arguments: args,
            workingDirectory: dir,
            environment: Self.inheritedEnvironment,
            onLine: { [weak self] line, isErr in
                Task { @MainActor in
                    self?.appendLog(isErr ? line : line, isErr: isErr)
                }
            },
            onExit: { [weak self] code, err in
                Task { @MainActor in
                    guard let self else { return }
                    let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if let err = err {
                        self.status = .failed(err.localizedDescription)
                        self.notifyDone(success: false)
                    } else if code == 0 {
                        self.status = .success(elapsed)
                        self.notifyDone(success: true)
                    } else if code == 15 || code == 9 {
                        self.status = .cancelled
                    } else if Self.shouldFallback(code: code, err: err) {
                        // N_m3u8DL-RE exited abnormally — try ffmpeg as a
                        // fallback. Status / notification will be set inside.
                        self.runFFmpegFallback(.init(
                            url: u,
                            saveDir: dir,
                            saveName: saveName,
                            headers: extraHeaders.isEmpty ? self.draft.headers : extraHeaders,
                            format: format
                        ))
                    } else {
                        self.status = .failed("退出码 \(code)")
                        self.notifyDone(success: false)
                    }
                }
            })
    }

    // MARK: - Logging

    private func appendLog(_ text: String, isErr: Bool = false) {
        // strip ANSI escape codes for readability
        let clean = Self.strippingAnsi(text)
        logs.append(.init(time: Date(), text: clean))
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
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