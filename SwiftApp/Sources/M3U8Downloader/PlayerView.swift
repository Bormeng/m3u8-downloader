import SwiftUI
import AVFoundation

/// Embedded player pane shown beneath the WebBrowserView.
/// Expands by default when a new m3u8 is loaded (the SwiftUI lifecycle
/// creates PlayerView *after* `vm.isPanelVisible` has already flipped to
/// `true`, so an `onChange(of: vm.isPanelVisible)` hook never fires on the
/// initial render — defaulting `@State isCollapsed` to `false` is the only
/// reliable way to get "auto-expand on first appearance"). User can still
/// manually collapse via the chevron button.
struct PlayerView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @State private var isCollapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                body_
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        // Player now fills the whole left pane (browser area), so we drop
        // the rounded-corner card look — it conflicted with the window edges
        // when stretched full-height.
        .animation(.easeInOut(duration: 0.15), value: isCollapsed)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                    Image(systemName: "play.rectangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                    Text("App 播放器")
                        .font(.callout.weight(.medium))
                    if !vm.currentURLString.isEmpty {
                        Text(URL(string: vm.currentURLString)?.lastPathComponent ?? vm.currentURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if vm.isPressing {
                        Text(String(format: "%.1fx", vm.holdRate))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "展开 App 播放器" : "折叠 App 播放器")

            Spacer()

            if !vm.currentURLString.isEmpty {
                Button {
                    vm.close()
                    isCollapsed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        // Expand the hit area beyond the small icon glyph —
                        // bare `.buttonStyle(.plain)` + SF Symbol only gives
                        // you a ~16pt target, easy to miss.
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭播放器")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Rectangle().fill(.quaternary.opacity(0.15)))
    }

    // MARK: - Body (video + controls)

    private var body_: some View {
        VStack(spacing: 0) {
            // Fill the available area minus the controls strip. AVPlayerLayer
            // uses `.resizeAspect` by default, so the video stays aspect-
            // correct with letterboxing — no distortion regardless of pane
            // size.
            videoSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            // 设置工具栏:速度 / 步退 / 步进 slider(独立一行,放在进度条上方)
            settingsToolbar
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Rectangle().fill(.quaternary.opacity(0.06)))
                .fixedSize(horizontal: false, vertical: true)

            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Rectangle().fill(.quaternary.opacity(0.1)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var videoSurface: some View {
        GeometryReader { geo in
            ZStack {
                AVPlayerHostView(player: vm.player)
                Color.clear
                    .contentShape(Rectangle())
                    // 长按倍速:按住 = vm.holdRate,松开恢复。
                    // 用 DragGesture(minimumDistance: 0) 立即响应 mouseDown。
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !vm.isPressing { vm.beginHold() }
                            }
                            .onEnded { _ in
                                vm.endHold()
                            }
                    )
                    // 双击左右屏:左半屏后退、右半屏前进。和长按并存。
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { evt in
                                let w = geo.size.width
                                guard w > 0 else { return }
                                if evt.location.x < w / 2 {
                                    vm.skipBackward()
                                } else {
                                    vm.skipForward()
                                }
                            }
                    )

                // 居中 HUD:未就绪 / 长按倍速 / 错误
                if let err = vm.lastError {
                    placeholder(systemImage: "exclamationmark.triangle.fill",
                                primary: "播放失败", secondary: err)
                } else if !vm.isReady {
                    placeholder(systemImage: "hourglass",
                                primary: "加载中…", secondary: nil)
                }
                if vm.isPressing {
                    holdHUD
                }
                if let flash = vm.skipFlash {
                    skipHUD(flash)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: vm.isPressing)
            .animation(.easeInOut(duration: 0.18), value: vm.skipFlash)
        }
    }

    // MARK: - HUDs

    @ViewBuilder
    private var holdHUD: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "hare.fill")
                Text(String(format: "%.1fx 倍速", vm.holdRate))
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.65)))
            .foregroundStyle(.white)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func skipHUD(_ flash: PlayerViewModel.SkipFlash) -> some View {
        HStack {
            switch flash {
            case .backward(let s):
                skipBadge(icon: skipIcon(seconds: s, isForward: false),
                          text: "-\(Int(s.rounded()))s")
                Spacer()
            case .forward(let s):
                Spacer()
                skipBadge(icon: skipIcon(seconds: s, isForward: true),
                          text: "+\(Int(s.rounded()))s")
            }
        }
        .padding(.horizontal, 40)
    }

    /// SF Symbols 里 gobackward/goforward 实际只提供这几个秒数档位的 symbol;
    /// 用户跨度 slider 可调到 1-30,中间的值没有对应 symbol,fallback 成 nil
    /// (badge 只显示文字,不会渲染一个无效 symbol 导致空白/警告)。
    private static let supportedSkipIconSeconds: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    private func skipIcon(seconds: Double, isForward: Bool) -> String? {
        let i = Int(seconds.rounded())
        guard Self.supportedSkipIconSeconds.contains(i) else { return nil }
        return isForward ? "goforward.\(i)" : "gobackward.\(i)"
    }

    @ViewBuilder
    private func skipBadge(icon: String?, text: String) -> some View {
        VStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .bold))
            }
            Text(text)
                .font(.title3.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.55)))
    }

    @ViewBuilder
    private func placeholder(systemImage: String, primary: String, secondary: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.7))
            Text(primary)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            if let s = secondary {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2).truncationMode(.middle)
                    .padding(.horizontal, 16)
            }
            if !vm.isReady && vm.lastError == nil {
                VStack(spacing: 2) {
                    Text("按住画面 = 倍速预览")
                    Text("双击左半屏后退 / 双击右半屏前进")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))  // 让 hit test 落到透明层
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!vm.isReady)
            .help(vm.isPlaying ? "暂停" : "播放")

            Text(formatTime(vm.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(vm.duration, 0.001)
            )
            .disabled(!vm.isReady || vm.duration <= 0)

            Text(formatTime(vm.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
        }
    }

    // MARK: - Settings toolbar (speed slider + skip back/forward inputs)

    /// 进度条上方的设置工具栏:速度 slider + 两个跨度数字输入框。
    /// - 速度:0.5x ~ 3x,step 0.5,拖动立即生效
    /// - 后退 / 前进跨度:1s ~ 30s,数字输入框,提交时持久化
    private var settingsToolbar: some View {
        HStack(spacing: 12) {
            sliderField(
                label: "速度",
                value: Binding(
                    get: { Double(vm.playbackRate) },
                    set: { vm.setPlaybackRate(Float($0)) }
                ),
                range: Double(vm.minRate)...Double(vm.maxRate),
                step: Double(vm.rateStep),
                valueText: rateText(vm.playbackRate)
            )
            .help("播放速度(0.5x ~ 3x)")

            skipField(
                label: "后退",
                value: Binding(
                    get: { Int(vm.skipBackwardSeconds) },
                    set: { vm.setSkipBackward(Double($0)) }
                )
            )
            .help("双击视频左半屏的后退跨度(秒)")

            skipField(
                label: "前进",
                value: Binding(
                    get: { Int(vm.skipForwardSeconds) },
                    set: { vm.setSkipForward(Double($0)) }
                )
            )
            .help("双击视频右半屏的快进跨度(秒)")
        }
        // 视频没就绪时整体灰掉,免得用户拖动但没反应
        .opacity(vm.isReady ? 1.0 : 0.5)
        .disabled(!vm.isReady)
    }

    /// 工具栏里单个 slider 单元:[label] [slider] [value]。
    /// 用 .frame(maxWidth: .infinity) 让多个单元等宽平分父容器。
    private func sliderField(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Slider(value: value, in: range, step: step)
            // 等宽数字框,数值变化时不会让 slider 宽度抖
            Text(valueText)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .frame(width: 42, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    /// 工具栏里单个跨度输入框单元:[label] [TextField] [单位]。
    /// 用 format: .number 限制只能输整数;setter 转 Double 调 vm,vm 内部 clamp
    /// 兜底,越界值自动回收到 [minSkip, maxSkip]。TextField 绑 Int 时,空字符串
    /// 不会触发 set(被 format 拒掉),value 保持不变,所以用户编辑过程中不会丢原值。
    private func skipField(
        label: String,
        value: Binding<Int>
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 48)
            Text("s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 把 1.0 显示成 "1x"、1.5 显示成 "1.5x"。整数倍省掉小数点。
    private func rateText(_ r: Float) -> String {
        if abs(r - r.rounded()) < 0.001 {
            return "\(Int(r.rounded()))x"
        }
        return String(format: "%.1gx", r)  // %g 自动去掉尾随 0,1.50 → 1.5
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
