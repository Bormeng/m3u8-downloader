import SwiftUI
import AppKit

/// Main window. The left pane hosts a tiny embedded browser (WKWebView)
/// which auto-extracts m3u8 URLs from the rendered page. The multi-line
/// direct-m3u8 paste input and HTTP header editor live at the top of the
/// right pane as a fast-path for power users who already have the .m3u8
/// URL in hand.
struct BrowserView: View {
    @EnvironmentObject var vm: BrowserViewModel
    @EnvironmentObject var downloader: DownloaderViewModel
    @EnvironmentObject var playerVM: PlayerViewModel
    @State private var showDirectInput: Bool = true
    @State private var logCollapsed: Bool = true
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        HSplitView {
            inputPane
                .frame(minWidth: 460, idealWidth: 540)
            resultsPane
                .frame(minWidth: 460)
        }
        .background(
            // ⌘L focuses the URL field (Safari-style).
            Button("") { urlFieldFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
        )
        .onAppear {
            // Auto-focus the URL field on window open so the user can just
            // start typing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                urlFieldFocused = true
            }
        }
    }

// MARK: - Left: embedded browser + optional player

    private var inputPane: some View {
        VStack(spacing: 0) {
            // ── Nav bar ─────────────────────────────────────────────
            HStack(spacing: 6) {
                Button { vm.browserGoBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!vm.browserCanGoBack)
                    .help("后退")
                Button { vm.browserGoForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!vm.browserCanGoForward)
                    .help("前进")
                Button { vm.browserReload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(vm.browserURL.isEmpty)
                Button { vm.browserStop() } label: { Image(systemName: "xmark") }
                    .help("停止")
                    .disabled(!vm.isBrowserLoading)

                TextField("输入网址，回车打开", text: $vm.browserURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit {
                        vm.browserLoad(vm.browserURL)
                    }
                    .disableAutocorrection(true)

                if vm.isBrowserLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.25)))

            // ── Title bar ───────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(vm.browserTitle.isEmpty ? vm.browserURL : vm.browserTitle)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(vm.browserURL)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            // ── Browser preview (fills remaining space) ─────────
            WebBrowserView(vm: vm) { urls, pageURL in
                vm.handleBrowserExtract(urls: urls, pageURL: pageURL)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            // ── App 内嵌播放器(自动接管 m3u8 预览) ──
            // 默认不渲染,只有 PlayerViewModel 收到 play() 后才出现,出现时自动展开。
            if playerVM.isPanelVisible {
                PlayerView()
                    .environmentObject(playerVM)
                    .frame(maxHeight: 360)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: playerVM.isPanelVisible)
    }

    // MARK: - Right: input controls + discovered links + log

    private var resultsPane: some View {
        VStack(spacing: 0) {
            // ── Top: input controls (paste m3u8 + HTTP headers) ──
            inputControlsPanel
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            // ── Save-dir widget ────────────────────────────────────
            SaveDirPanel(
                saveDir: $vm.saveDir,
                namePrefix: $vm.saveNamePrefix,
                onPick: { vm.pickSaveDir() },
                onReveal: { vm.revealSaveDir() }
            )

            if let err = vm.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()

            // ── Middle: title row + link cards ───────────────────
            HStack {
                Text("链接与分辨率").font(.headline)
                Spacer()
                if vm.isProbing {
                    ProgressView().controlSize(.small)
                    Text("探测中…").font(.caption).foregroundStyle(.secondary)
                }
                Text("共 \(vm.links.count) 个")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    vm.selectedIDs.removeAll()
                    vm.selectedIDs = Set(vm.links.flatMap { $0.variants.map(\.id) })
                } label: { Text("全选") }
                .controlSize(.small)
                .disabled(vm.links.flatMap({$0.variants}).isEmpty)
                Button {
                    vm.selectedIDs.removeAll()
                } label: { Text("清空选择") }
                .controlSize(.small)
                .disabled(vm.selectedIDs.isEmpty)
                Button {
                    downloadBatch()
                } label: {
                    Label("下载选中", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.downloadPayload().isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Link list expands to fill the remaining vertical space.
            if vm.links.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.links) { link in
                            LinkCard(
                                link: link,
                                selectedIDs: $vm.selectedIDs,
                                onReprobe: { vm.reprobe(link) },
                                onDownload: { variant in
                                    // Auto-expand the log pane so users can watch progress live.
                                    logCollapsed = false
                                    downloader.startExternal(
                                        url: variant.url,
                                        saveName: vm.saveNamePrefix.trimmingCharacters(in: .whitespaces).isEmpty
                                            ? "" : "\(vm.saveNamePrefix)_\(variant.displayLabel)",
                                        saveDir: vm.saveDir,
                                        extraHeaders: vm.headersWithReferer(link.referer)
                                    )
                                },
                                onPlay: { variant in
                                    playerVM.play(
                                        urlString: variant.url,
                                        referer: link.referer,
                                        headers: vm.headersWithReferer(link.referer)
                                    )
                                }
                            )
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            // ── Bottom: log pane (live status of N_m3u8DL-RE) ──
            SharedLogPane(collapsed: $logCollapsed, minHeight: 140)
                .environmentObject(downloader)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("在左侧浏览器中打开网页 → 自动抓取 m3u8")
                .foregroundStyle(.secondary)
            Text("或在上方「直接粘贴 m3u8 链接」快速录入")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top of the right pane: paste-m3u8 box + HTTP request headers.
    /// Sits above the save-dir widget so users see the input affordance first.
    private var inputControlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showDirectInput) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把 m3u8 链接粘贴到下面（每行一个），然后点「探测」即可跳过浏览器。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.urlInput)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1))
                    HStack {
                        Button {
                            vm.pasteAndProbe()
                        } label: {
                            Label("粘贴并探测", systemImage: "doc.on.clipboard")
                        }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                        .buttonStyle(.borderedProminent)
                        Button {
                            vm.parseAndProbe()
                        } label: {
                            Label("探测", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(vm.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button {
                            vm.urlInput = ""
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .disabled(vm.urlInput.isEmpty)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("直接粘贴 m3u8 链接", systemImage: "doc.text.magnifyingglass")
                    .font(.callout.weight(.semibold))
            }

            Group {
                sectionTitle("HTTP 请求头（可选）")
                HStack {
                    TextField("Cookie: xxx", text: $vm.headerInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.addHeader() }
                    Button("添加") { vm.addHeader() }
                }
                if vm.headers.isEmpty {
                    Text("（无）").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.headers, id: \.self) { h in
                            HStack {
                                Text(h)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    vm.removeHeader(h)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func downloadBatch() {
        let payload = vm.downloadPayload()
        guard !payload.isEmpty else { return }
        // Auto-expand the log pane so users can watch progress live.
        logCollapsed = false
        for (i, item) in payload.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(i) * 50_000_000)
                let referer = vm.referer(forVariantURL: item.url)
                downloader.startExternal(
                    url: item.url,
                    saveName: item.name,
                    saveDir: vm.saveDir,
                    extraHeaders: vm.headersWithReferer(referer)
                )
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Link card

private struct LinkCard: View {
    let link: M3U8Link
    @Binding var selectedIDs: Set<UUID>
    let onReprobe: () -> Void
    let onDownload: (M3U8Variant) -> Void
    let onPlay: (M3U8Variant) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.url)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    if let r = link.referer, !r.isEmpty {
                        Text("来源: \(r)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    statusBadge
                }
                Spacer()
                Button {
                    onReprobe()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新探测")
                .buttonStyle(.borderless)
            }

            if !link.variants.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(link.variants) { v in
                        VariantRow(
                            variant: v,
                            isSelected: Binding(
                                get: { selectedIDs.contains(v.id) },
                                set: { on in
                                    if on { selectedIDs.insert(v.id) }
                                    else  { selectedIDs.remove(v.id) }
                                }
                            ),
                            onDownload: { onDownload(v) },
                            onPlay: { onPlay(v) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch link.status {
        case .pending:
            Label("待解析", systemImage: "clock")
                .font(.caption2).foregroundStyle(.secondary)
        case .probing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("探测中…").font(.caption2)
            }.foregroundStyle(.secondary)
        case .done:
            Label(link.statusMessage, systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        case .failed:
            Label(link.statusMessage, systemImage: "xmark.octagon.fill")
                .font(.caption2).foregroundStyle(.red).lineLimit(1)
        }
    }
}

private struct VariantRow: View {
    let variant: M3U8Variant
    @Binding var isSelected: Bool
    let onDownload: () -> Void
    let onPlay: () -> Void

    /// 只有视频变体可以播放(音轨/字幕轨单独播放没意义)。
    private var isPlayable: Bool {
        guard let mt = variant.mediaType else { return true }
        return mt == "VIDEO"
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(variant.displayLabel)
                    .font(.system(.callout))
                if let c = variant.codecs, !c.isEmpty {
                    Text(c)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help(isPlayable
                  ? "在 App 内播放(支持长按倍速)"
                  : "该轨道为音频/字幕,无法直接播放")
            .disabled(!isPlayable)
            Button {
                onDownload()
            } label: {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3)))
    }

    private var icon: String {
        switch (variant.resolution, variant.mediaType) {
        case (.some, _):   return "rectangle.3.offgrid"
        case (nil, "AUDIO"): return "waveform"
        case (nil, "SUBTITLES"): return "captions.bubble"
        default:           return "play.rectangle"
        }
    }
}

// MARK: - Save-dir panel
//
// Pinned at the top of the right column so the user always sees and can
// change the save location and naming prefix while scanning detected
// links. Two labelled rows:
//   row 1: 保存目录 — path preview · choose · reveal
//   row 2: 文件名前缀（可选）— prefix field
struct SaveDirPanel: View {
    @Binding var saveDir: String
    @Binding var namePrefix: String
    var onPick: () -> Void
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Row 1: save directory
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("保存目录")
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .imageScale(.small)
                        .frame(width: 16)
                    TextField("保存目录", text: $saveDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .disableAutocorrection(true)
                        .help("下载文件保存到此目录")
                    Button {
                        onPick()
                    } label: {
                        Label("选择", systemImage: "folder.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("选择保存目录")
                    Button {
                        onReveal()
                    } label: {
                        Label("在 Finder 中显示", systemImage: "magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在 Finder 中显示该目录")
                }
            }
            // ── Row 2: file-name prefix
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("文件名前缀（可选）")
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .frame(width: 16)
                    TextField("文件名前缀（可选）", text: $namePrefix)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .help("下载的文件名前缀，留空则按 N_m3u8DL-RE 默认命名")
                    if !namePrefix.isEmpty {
                        Button {
                            namePrefix = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("清空前缀")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
