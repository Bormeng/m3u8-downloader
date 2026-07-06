import Foundation
import AVFoundation
import SwiftUI

/// Owns the embedded `AVPlayer` used for the in-app preview pane.
///
/// Design notes:
/// - The player is decoupled from the downloader on purpose — playing never
///   touches the download queue (per product decision: "跟下载解耦").
/// - Custom HTTP headers (Referer / Cookie / UA) are passed in as `[String]`
///   ("Key: Value" lines) and translated to the dictionary AVFoundation
///   understands. Supported on macOS 13+ (this app targets 14+).
/// - `holdRate` is applied while the user is pressing on the video surface;
///   releasing reverts to `normalRate` (or paused). 0 means paused.
@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Tunables

    /// 倍速档位(用户长按时的速率)
    let holdRate: Float = 2.0
    /// 正常播放速率
    let normalRate: Float = 1.0

    // MARK: - Published state

    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentURLString: String = ""
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var lastError: String?
    /// 面板是否展开(用户主动关闭/折叠会改这个)
    @Published var isPanelVisible: Bool = false
    /// 长按状态(由 PlayerView 的手势驱动)
    @Published private(set) var isPressing: Bool = false

    // MARK: - Private observers
    //
    // 全部用 [weak self] 闭包,所以 self 释放后,KVO/Notification/time
    // observer 会自然停止投递。这里把它们标 `nonisolated(unsafe)` 是因为
    // deinit 处于非隔离上下文,需要能在不触发 actor 隔离检查的前提下
    // 把 NotificationCenter 的 token 释放掉,避免长期累积通知槽。
    // 它们只在主线程被读写,实际上没有竞态。
    private nonisolated(unsafe) var statusObserver: NSKeyValueObservation?
    private nonisolated(unsafe) var rateObserver: NSKeyValueObservation?
    private nonisolated(unsafe) var timeObserverToken: Any?
    private nonisolated(unsafe) var endObserver: NSObjectProtocol?

    deinit {
        // KVO / periodic time observer 都靠 [weak self] 自动停,无需操作。
        // NotificationCenter 的 token 是被 self 持有的,不显式释放会一直占槽。
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
        }
    }

    // MARK: - Public API

    /// Load a URL into the player. Replaces any current item. Headers are
    /// "Key: Value" strings; the value-side whitespace is trimmed.
    /// The referer is added as a `Referer:` header if no manual one is set.
    func play(urlString: String, referer: String?, headers: [String]) {
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            lastError = "URL 为空或格式错误"
            return
        }

        // 如果点的是同一个 URL,直接恢复播放(避免重建 AVPlayer 浪费缓冲)
        if currentURLString == urlString, let p = player {
            isPanelVisible = true
            p.play()
            applyRate()
            return
        }

        var headerLines = headers
        let hasReferer = headerLines.contains { $0.lowercased().hasPrefix("referer:") }
        if !hasReferer, let r = referer, !r.isEmpty {
            headerLines.append("Referer: \(r)")
        }
        let headerDict = Self.headerDict(from: headerLines)

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headerDict
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5  // 5s 缓冲,够长按倍速不卡

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.actionAtItemEnd = .pause

        // Tear down old observers
        statusObserver?.invalidate()
        rateObserver?.invalidate()
        if let tok = timeObserverToken { newPlayer.removeTimeObserver(tok) }
        if let end = endObserver { NotificationCenter.default.removeObserver(end) }

        // KVO: item readiness
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.lastError = nil
                case .failed:
                    self.isReady = false
                    self.lastError = item.error?.localizedDescription ?? "无法播放"
                default:
                    self.isReady = false
                }
            }
        }

        // KVO: rate
        rateObserver = newPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                // rate > 0 = playing (any speed)
                self.isPlaying = player.rate != 0
            }
        }

        // Periodic time observer for the progress slider
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // addPeriodicTimeObserver 的 closure 不带 actor 隔离,需要手动跳回主线程。
            Task { @MainActor in
                guard let self else { return }
                let s = time.seconds
                if s.isFinite { self.currentTime = s }
            }
        }

        // End-of-item: just pause, don't loop.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player?.pause()
                self.isPlaying = false
            }
        }

        player = newPlayer
        currentURLString = urlString
        duration = 0
        currentTime = 0
        isReady = false
        lastError = nil
        isPanelVisible = true

        newPlayer.play()
        // 显式同步 isPlaying:play() 已让 rate=1,但 KVO 是异步回调,如果不
        // 立刻把 isPlaying 置 true,紧接着的 applyRate() 会看到 isPlaying=false
        // 然后把 rate 改回 0,视频就立刻被暂停了。
        isPlaying = true
        applyRate()
    }

    /// Pause / resume toggle. Long-press state takes priority (if user is
    /// currently holding, we keep playing at holdRate).
    func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
        applyRate()
    }

    func seek(to seconds: Double) {
        guard let p = player, duration > 0 else { return }
        let t = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t.seconds
    }

    /// Close the player and tear down the current item. Keeps the
    /// `PlayerViewModel` alive so the next play() is a fresh setup.
    func close() {
        if let tok = timeObserverToken, let p = player { p.removeTimeObserver(tok) }
        timeObserverToken = nil
        statusObserver?.invalidate(); statusObserver = nil
        rateObserver?.invalidate(); rateObserver = nil
        if let end = endObserver { NotificationCenter.default.removeObserver(end) }
        endObserver = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        currentURLString = ""
        duration = 0
        currentTime = 0
        isReady = false
        isPlaying = false
        isPressing = false
        isPanelVisible = false
        lastError = nil
    }

    // MARK: - Hold-to-speed

    /// Called by the SwiftUI gesture when the user starts pressing the video.
    func beginHold() {
        guard let p = player, isReady else { return }
        isPressing = true
        p.rate = holdRate
    }

    /// Called by the SwiftUI gesture when the user releases.
    func endHold() {
        isPressing = false
        applyRate()
    }

    private func applyRate() {
        guard let p = player else { return }
        if isPressing {
            p.rate = holdRate
        } else if isPlaying {
            p.rate = normalRate
        } else {
            p.rate = 0
        }
    }

    // MARK: - Header parsing

    /// Convert ["Key: Value", "User-Agent: foo"] into ["Key": "Value", ...]
    /// Lines without ":" are silently skipped.
    private static func headerDict(from lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !val.isEmpty else { continue }
            out[key] = val
        }
        return out
    }
}
