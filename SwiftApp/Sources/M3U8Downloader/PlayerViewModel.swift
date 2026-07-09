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
///   releasing reverts to `playbackRate` (or paused). 0 means paused.
@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Tunables

    /// 倍速档位(用户长按时的速率)
    let holdRate: Float = 2.0
    /// 播放速率 slider 的范围 / 步进
    let minRate: Float = 0.5
    let maxRate: Float = 3.0
    let rateStep: Float = 0.5
    /// 双击快进 / 快退的跨度 slider 的范围 / 步进
    let minSkip: Double = 1
    let maxSkip: Double = 30
    let skipStep: Double = 1
    /// 快进 / 快退跨度的默认值(首次启动 / 持久化值越界时用)
    let defaultSkipSeconds: Double = 5

    // MARK: - Skip flash HUD

    /// 双击左右屏后给用户的瞬态视觉反馈。0.8s 自动清空。
    enum SkipFlash: Equatable {
        case backward(Double)  // 秒数
        case forward(Double)
    }

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
    /// 双击左右屏的瞬态反馈,nil = 不显示
    @Published private(set) var skipFlash: SkipFlash?
    /// 当前播放速率(0.5x ~ 3x, step 0.5)。持久化到 UserDefaults,跨会话保留。
    @Published private(set) var playbackRate: Float
    /// 双击右半屏的快进跨度(秒,1 ~ 30, step 1)。持久化。
    @Published private(set) var skipForwardSeconds: Double
    /// 双击左半屏的快退跨度(秒,1 ~ 30, step 1)。持久化。
    @Published private(set) var skipBackwardSeconds: Double

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
    /// 双击 flash 的延迟清空任务;新一次双击会 cancel 旧的,避免错乱
    private var flashTask: Task<Void, Never>?

    /// UserDefaults key:持久化用户选的播放速率
    private static let playbackRateKey = "player.playbackRate"
    private static let skipForwardKey = "player.skipForwardSeconds"
    private static let skipBackwardKey = "player.skipBackwardSeconds"

    init() {
        // 播放速率: clamp 到 slider 范围,非法值回退到 1.0
        let rate = UserDefaults.standard.object(forKey: Self.playbackRateKey) as? Float ?? 1.0
        self.playbackRate = min(max(rate, minRate), maxRate)

        // 快进 / 快退跨度: 非法或越界回退到默认值
        let fwd = UserDefaults.standard.object(forKey: Self.skipForwardKey) as? Double ?? defaultSkipSeconds
        self.skipForwardSeconds = min(max(fwd, minSkip), maxSkip)

        let bwd = UserDefaults.standard.object(forKey: Self.skipBackwardKey) as? Double ?? defaultSkipSeconds
        self.skipBackwardSeconds = min(max(bwd, minSkip), maxSkip)
    }

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
    ///
    /// Every call rebuilds the `AVPlayer` from scratch — we previously had a
    /// "same URL → resume" shortcut that re-used the existing player, but
    /// that path interacted badly with the SwiftUI ZStack layout: when the
    /// user clicked ▶ on a *different* link, `vm.player` did change but the
    /// underlying `AVPlayerLayer.player` sometimes stayed on the previous
    /// video, so the user saw the old content. Rebuilding every time makes
    /// the layer swap observable and predictable. The "save the buffer"
    /// benefit wasn't worth the visual bug.
    func play(urlString: String, referer: String?, headers: [String]) {
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            lastError = "URL 为空或格式错误"
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

        // Tear down old observers. Note: `timeObserverToken` is registered on
        // the *old* player, so it must be removed from `player` (the old one)
        // before we overwrite the property — the previous version called
        // `newPlayer.removeTimeObserver(tok)`, which was a no-op (newPlayer
        // doesn't own that token) and leaked the old player's time observer.
        if let oldP = player, let tok = timeObserverToken {
            oldP.removeTimeObserver(tok)
        }
        statusObserver?.invalidate()
        rateObserver?.invalidate()
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

    // MARK: - Skip (double-tap on left/right half)

    /// 双击视频右半屏 → 前进 skipForwardSeconds 秒(用户可调)
    func skipForward() {
        guard duration > 0 else { return }
        let s = skipForwardSeconds
        seek(to: currentTime + s)
        flashSkip(.forward(s))
    }

    /// 双击视频左半屏 → 后退 skipBackwardSeconds 秒(用户可调)
    func skipBackward() {
        guard duration > 0 else { return }
        let s = skipBackwardSeconds
        seek(to: currentTime - s)
        flashSkip(.backward(s))
    }

    /// 触发一次 HUD 闪烁,0.8s 后自动清空。多次触发会 cancel 上一次的,
    /// 避免最后一次 flash 被更早的清空任务提前抹掉。
    private func flashSkip(_ flash: SkipFlash) {
        flashTask?.cancel()
        skipFlash = flash
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // 只清"同一次"flash,被新一次覆盖过的不要清掉
                if self.skipFlash == flash { self.skipFlash = nil }
            }
        }
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
        flashTask?.cancel(); flashTask = nil
        skipFlash = nil
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
            p.rate = playbackRate
        } else {
            p.rate = 0
        }
    }

    /// 设置播放速率(0.5x ~ 3x, step 0.5)。持久化到 UserDefaults,立即生效。
    /// - 注意:如果当前是暂停状态,只更新状态和持久化,不动 player.rate,
    ///   等下次 play() 触发 applyRate() 再应用。
    func setPlaybackRate(_ rate: Float) {
        guard rate >= minRate, rate <= maxRate else { return }
        guard abs(rate - playbackRate) > 0.001 else { return }
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.playbackRateKey)
        if isPlaying, !isPressing {
            player?.rate = rate
        }
    }

    /// 设置双击右半屏的快进跨度(秒,1 ~ 30, step 1)。持久化。
    func setSkipForward(_ seconds: Double) {
        let s = min(max(seconds, minSkip), maxSkip)
        guard abs(s - skipForwardSeconds) > 0.001 else { return }
        skipForwardSeconds = s
        UserDefaults.standard.set(s, forKey: Self.skipForwardKey)
    }

    /// 设置双击左半屏的快退跨度(秒,1 ~ 30, step 1)。持久化。
    func setSkipBackward(_ seconds: Double) {
        let s = min(max(seconds, minSkip), maxSkip)
        guard abs(s - skipBackwardSeconds) > 0.001 else { return }
        skipBackwardSeconds = s
        UserDefaults.standard.set(s, forKey: Self.skipBackwardKey)
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
