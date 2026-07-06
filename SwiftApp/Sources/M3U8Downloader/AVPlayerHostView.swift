import SwiftUI
import AVFoundation
import AppKit

/// NSView that hosts an `AVPlayerLayer` and resizes it on layout.
/// NSView 在 Swift 5 里没有暴露 `+layerClass` 类方法,所以我们手动把
/// 默认的 backing layer 替换成 `AVPlayerLayer`(标准 CALayer 子类化
/// 技巧)。`layout()` 让 layer 跟随 bounds;`hitTest` 返回 nil 让
/// 上层的 SwiftUI 手势(长按倍速)能正常透传。
final class AVPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    /// 不拦截 hit test —— 让 SwiftUI 父层的手势(长按倍速)能透过来。
    /// 控件按钮(播放/暂停等)位于 ZStack 顶层,本身也不在这层,所以不会冲突。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI wrapper around `AVPlayerContainerView`. Sets the player on the
/// underlying `AVPlayerLayer` whenever the binding changes.
struct AVPlayerHostView: NSViewRepresentable {
    let player: AVPlayer?
    /// 视频在容器内如何适配,默认 .resizeAspect(保持比例,黑边)。
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerContainerView {
        let v = AVPlayerContainerView(frame: .zero)
        v.wantsLayer = true
        // 用 AVPlayerLayer 替换默认 backing layer。
        v.layer = v.playerLayer
        v.playerLayer.videoGravity = videoGravity
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        if nsView.playerLayer.videoGravity != videoGravity {
            nsView.playerLayer.videoGravity = videoGravity
        }
    }
}
