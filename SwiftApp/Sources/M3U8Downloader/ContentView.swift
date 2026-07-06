import SwiftUI
import AppKit

// MARK: - Root container

struct ContentView: View {
    @StateObject private var downloader = DownloaderViewModel()
    @StateObject private var browserVM = BrowserViewModel()
    @StateObject private var playerVM = PlayerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            BrowserView()
                .environmentObject(downloader)
                .environmentObject(browserVM)
                .environmentObject(playerVM)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            SharedFooter()
                .environmentObject(downloader)
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}

// MARK: - Log severity (UI-only classifier)

/// Classify a single log line for the on-screen display. The downloader
/// itself (N_m3u8DL-RE) writes "INFO :", "WARN :", "ERROR :" etc.; we
/// only use this for color-coding — not for control flow.
enum LogSeverity: String {
    case info, warn, error, status, comment, progress, success, command

    var color: Color {
        switch self {
        case .info:     return .primary
        case .warn:     return .orange
        case .error:    return .red
        case .status:   return .accentColor
        case .progress: return .blue
        case .success:  return .green
        case .command:  return .secondary
        case .comment:  return .secondary.opacity(0.85)
        }
    }

    /// Tinted left bar — error & success lines stand out at a glance.
    var hasBar: Bool { self == .error || self == .success }
    var barColor: Color {
        switch self {
        case .error:   return .red
        case .success: return .green
        default:       return .clear
        }
    }

    /// Subtle row background tint for important categories.
    var rowBackground: Color {
        switch self {
        case .error:   return Color.red.opacity(0.08)
        case .success: return Color.green.opacity(0.07)
        case .status:  return Color.accentColor.opacity(0.05)
        default:       return .clear
        }
    }

    static func classify(_ text: String) -> LogSeverity {
        let head = text.trimmingCharacters(in: .whitespaces)
        let lower = head.lowercased()

        // ── Swift-side summary lines we explicitly append ──
        if head.hasPrefix("✓") || head.hasPrefix("[完成]") || head.hasPrefix("[下载完成]") {
            return .success
        }
        if head.hasPrefix("✗") || head.hasPrefix("[失败]") || head.hasPrefix("[下载失败]") {
            return .error
        }
        if head.hasPrefix("[清理") || head.hasPrefix("[fallback]") {
            return .status
        }

        // ── Command echo (the "$ <cmd>" line) — grey monospace ──
        if head.hasPrefix("$") { return .command }

        // ── Progress lines ──
        // ffmpeg stderr: "frame=  123 fps= 30 q=-1.0 size=    1024kB time=00:00:05.00"
        if head.hasPrefix("frame=") { return .progress }
        // N_m3u8DL-RE plain-text progress: "  123 / 125  1.23MB/s  00:00:08"
        if head.range(of: #"^\s*\d+\s*/\s*\d+"#, options: .regularExpression) != nil {
            return .progress
        }
        if lower.contains("进度") || lower.contains("downloading") || lower.contains("merging") {
            return .progress
        }

        // ── Success markers ──
        if head.contains("全部完成") || head.contains("下载完成") ||
           head.contains("合并完成") || head.contains("保存路径") ||
           head.contains("保存文件名") {
            return .success
        }
        // ffmpeg mux summary: "video:12345kB audio:0kB ..."
        if head.range(of: #"^video:\s*\d"#, options: .regularExpression) != nil ||
           head.range(of: #"^audio:\s*\d"#, options: .regularExpression) != nil {
            return .success
        }

        // ── Failure markers ──
        if lower.contains("conversion failed") ||
           lower.contains("failed to") ||
           lower.contains("无法下载") {
            return .error
        }

        // ── N_m3u8DL-RE bracketed prefixes ──
        for prefix in ["ERROR", "WARN", "INFO", "STATUS", "DEBUG", "TIP"] {
            // Match "INFO :" or "INFO:" or "INFO  :"
            let pat = "\(prefix)[:\\s]"
            if head.range(of: pat, options: .regularExpression) != nil {
                switch prefix {
                case "ERROR":  return .error
                case "WARN":   return .warn
                case "STATUS": return .status
                case "INFO", "DEBUG", "TIP":
                    return .info
                default: break
                }
            }
        }

        // ── Swift-side error lines ──
        if head.hasPrefix("退出码") || head.hasPrefix("URL 为空") {
            return .error
        }
        if head.hasPrefix("[FAIL]") || lower.contains("error:") {
            return .error
        }
        return .comment
    }
}

// MARK: - Shared log pane (collapsible)

struct SharedLogPane: View {
    @EnvironmentObject var downloader: DownloaderViewModel
    @Binding var collapsed: Bool
    /// When true, the pane reserves a minimum height even when collapsed, so
    /// that the global status row beneath it remains anchored.
    var minHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                Divider()
                logContent
                    .frame(minHeight: minHeight)
                    .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: collapsed)
    }

    private var errorCount: Int {
        downloader.logs.filter { LogSeverity.classify($0.text) == .error }.count
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                    Text("运行日志").font(.headline)
                    if !downloader.logs.isEmpty {
                        Text("(\(downloader.logs.count))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if errorCount > 0 {
                        Label("\(errorCount)", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开运行日志" : "折叠运行日志")

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    downloader.logs.map {
                        "[\($0.time.formatted(date: .omitted, time: .standard))] \($0.text)"
                    }.joined(separator: "\n"),
                    forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .help("复制全部日志")
            .disabled(downloader.logs.isEmpty || collapsed)
            .opacity(collapsed ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Rectangle().fill(.quaternary.opacity(0.15)))
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(downloader.logs) { line in
                        LogRow(line: line)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: downloader.logs.count) { _, _ in
                if let last = downloader.logs.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// One log line, color-coded by severity.
private struct LogRow: View {
    let line: DownloadLogLine
    var body: some View {
        let severity = LogSeverity.classify(line.text)
        HStack(alignment: .top, spacing: 0) {
            // Left bar — only error / success get a coloured edge stripe so
            // important lines stand out at a glance.
            Rectangle()
                .fill(severity.barColor)
                .frame(width: severity.hasBar ? 3 : 0)
                .opacity(severity.hasBar ? 1 : 0)

            HStack(alignment: .top, spacing: 6) {
                Text("[\(line.time.formatted(date: .omitted, time: .standard))]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .leading)
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(severity.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .background(severity.rowBackground)
    }
}

// MARK: - Shared footer (status + cancel/start for downloader)

struct SharedFooter: View {
    @EnvironmentObject var downloader: DownloaderViewModel

    var body: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            if case .running = downloader.status {
                Button(role: .destructive) {
                    downloader.cancel()
                } label: {
                    Label("取消", systemImage: "stop.circle")
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch downloader.status {
        case .idle:
            Label("就绪", systemImage: "circle").foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("下载中…").foregroundStyle(.secondary)
            }
        case .success(let sec):
            Label("完成（\(String(format: "%.1f", sec)) 秒）",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Label("已取消", systemImage: "xmark.circle").foregroundStyle(.orange)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Settings (used by macOS App Settings scene)

struct SettingsView: View {
    var body: some View {
        Form {
            Section("二进制路径") {
                Text(DownloaderViewModel.executablePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("如需修改，请编辑 Sources/M3U8Downloader/DownloaderViewModel.swift 中的 executablePath。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 160)
    }
}