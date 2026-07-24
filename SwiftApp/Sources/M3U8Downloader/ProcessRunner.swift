import Foundation

/// Wraps an external process and streams stdout/stderr line-by-line.
/// Calls back on a background queue — UI updates must hop to MainActor.
final class ProcessRunner {

    private(set) var process: Process?
    private(set) var isRunning: Bool = false

    /// Start a process. Returns true if successfully launched.
    ///
    /// - parameter executable: absolute path to the binary to run.
    /// - parameter arguments: argv list passed to the binary.
    /// - parameter workingDirectory: cwd of the child, if non-nil.
    /// - parameter environment: env dict of the child, if non-nil.
    /// - parameter pseudoterminal: when true, the binary is invoked
    ///   through `/usr/bin/script -q /dev/null`, which attaches it to
    ///   a brand-new PTY. From the child's perspective stdout is a TTY,
    ///   so libraries that probe `Console.IsOutputRedirected` (notably
    ///   Spectre.Console, used by N_m3u8DL-RE for its progress bar) take
    ///   the "interactive terminal" code path instead of the "redirected
    ///   pipe" path. The non-interactive Spectre.Console path has a
    ///   race in its `ProgressRefreshThread` that races into a
    ///   `List<T>.RemoveRange` out-of-bounds and SIGABRTs the .NET
    ///   process — termination then shows up as exit code 6 from Swift's
    ///   `Process.terminationStatus` (134 in shell `$?`). Wrapping the
    ///   binary in a PTY bypasses the bug entirely. ffmpeg is a plain C
    ///   binary with no such issue, so the caller should leave this
    ///   false for the ffmpeg fallback.
    /// - parameter onLine: per-line stdout/stderr callback. For PTY mode
    ///   the stream is the merged stdout+stderr of the wrapped binary.
    /// - parameter onExit: process exit callback (terminationStatus,
    ///   launch error if any).
    @discardableResult
    func launch(executable: String,
                arguments: [String],
                workingDirectory: String? = nil,
                environment: [String: String]? = nil,
                pseudoterminal: Bool = false,
                onLine: @escaping (String, Bool) -> Void,    // (text, isStderr)
                onExit: @escaping (Int32, Error?) -> Void) -> Bool {

        // When wrapping in a PTY, we delegate to `/usr/bin/script -q /dev/null`,
        // which forks a fresh PTY pair, execs its argv under it, and exits
        // with the child's status. macOS ships `/usr/bin/script` as part of
        // the BSD userland, so we don't need a third-party dep.
        let p = Process()
        if pseudoterminal {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", executable] + arguments
        } else {
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
        }
        if let wd = workingDirectory {
            p.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        if let env = environment {
            p.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        // For PTY mode the wrapped binary only has one stdout stream (the
        // controlling terminal), so reading it twice would dup events. Pipe
        // stderr to /dev/null in that case — the important data is on stdout.
        p.standardOutput = outPipe
        p.standardError  = pseudoterminal ? FileHandle(forWritingAtPath: "/dev/null") : errPipe

        // Stream stdout
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                let lines = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
                for line in lines {
                    if line.isEmpty { continue }
                    onLine(String(line), false)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                let lines = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
                for line in lines {
                    if line.isEmpty { continue }
                    onLine(String(line), true)
                }
            }
        }

        p.terminationHandler = { proc in
            // flush remaining buffers
            let outRemain = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: outRemain, encoding: .utf8), !s.isEmpty {
                for line in s.split(whereSeparator: { $0 == "\n" }) where !line.isEmpty {
                    onLine(String(line), false)
                }
            }
            if !pseudoterminal {
                let errRemain = errPipe.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: errRemain, encoding: .utf8), !s.isEmpty {
                    for line in s.split(whereSeparator: { $0 == "\n" }) where !line.isEmpty {
                        onLine(String(line), true)
                    }
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // /usr/bin/script exits with the wrapped child's status, so the
            // terminationStatus we surface to callers is correct in both modes.
            onExit(proc.terminationStatus, proc.terminationReason == .uncaughtSignal ? nil : nil)
        }

        do {
            try p.run()
            self.process = p
            self.isRunning = true
            return true
        } catch {
            onExit(-1, error)
            return false
        }
    }

    func cancel() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
    }
}