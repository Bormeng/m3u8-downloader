import SwiftUI
import AVFoundation

/// Embedded player pane shown beneath the WebBrowserView.
/// Collapsed by default; auto-expands when a new m3u8 is loaded. Supports
/// hold-to-speed (long-press / mouse-hold on the video surface → 2x).
struct PlayerView: View {
    @EnvironmentObject var vm: PlayerViewModel
    @State private var isCollapsed: Bool = true

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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isCollapsed)
        // 收到新 URL 时自动展开(只在用户没手动折叠过时)
        .onChange(of: vm.isPanelVisible) { _, visible in
            if visible { isCollapsed = false }
        }
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
            videoSurface
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200, idealHeight: 280, maxHeight: 380)
                .background(Color.black)

            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Rectangle().fill(.quaternary.opacity(0.1)))
        }
    }

    private var videoSurface: some View {
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

            // 居中 HUD:未就绪 / 长按倍速 / 错误
            if let err = vm.lastError {
                placeholder(systemImage: "exclamationmark.triangle.fill",
                            primary: "播放失败", secondary: err)
            } else if !vm.isReady {
                placeholder(systemImage: "hourglass",
                            primary: "加载中…", secondary: nil)
            }
            if vm.isPressing {
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
        }
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
                Text("按住画面 = 倍速预览")
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
