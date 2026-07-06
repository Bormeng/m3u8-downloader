import Foundation

/// Wraps an external process and streams stdout/stderr line-by-line.
/// Calls back on a background queue — UI updates must hop to MainActor.
final class ProcessRunner {

    private(set) var process: Process?
    private(set) var isRunning: Bool = false

    /// Start a process. Returns true if successfully launched.
    @discardableResult
    func launch(executable: String,
                arguments: [String],
                workingDirectory: String? = nil,
                environment: [String: String]? = nil,
                onLine: @escaping (String, Bool) -> Void,    // (text, isStderr)
                onExit: @escaping (Int32, Error?) -> Void) -> Bool {

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let wd = workingDirectory {
            p.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        if let env = environment {
            p.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

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
            let errRemain = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: errRemain, encoding: .utf8), !s.isEmpty {
                for line in s.split(whereSeparator: { $0 == "\n" }) where !line.isEmpty {
                    onLine(String(line), true)
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
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