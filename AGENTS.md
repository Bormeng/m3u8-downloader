# M3U8 Downloader — Agent Memory

给后续 agent(包括 Mavis 自己)的工作约定。开始任务前先扫一遍。

## 硬性流程

- **改完 Swift 代码 → 必须 `bin/deploy_app.sh` 重新打包并部署到 `/Applications/`**,
  不要只 `swift build`。用户用的是 `dist/m3u8 下载器.app`,只编译不打包等于白做。
  命令:
  ```bash
  /Users/ming/Documents/Repositories/m3u8-downloader/bin/deploy_app.sh
  ```
  脚本会自动跑 `package_app.sh`(重编译 + 拼 .app bundle + ad-hoc 签名)+ 部署。
- **部署时不要在 `/Applications/` 留旧版本备份** —— `deploy_app.sh` 已经去掉 stash
  步骤,直接 `rm -rf` + `cp -R` 覆盖。版本回滚靠项目内的 `git`,不需要 OS 层备份目录。
- **N_m3u8DL-RE 在 macOS 上以前会崩溃**(Spectre.Console progress bar 的 race condition,
  `List<T>.RemoveRange` 越界,`Process.terminationStatus` 显示成 6)。这是 .NET 库的
  bug,不是 m3u8 链接/headers 的问题。
  现在的**主防线**是把 N_m3u8DL-RE 包在 `/usr/bin/script -q /dev/null` PTY 里跑
  (ProcessRunner.pseudoterminal=true;DownloaderViewModel.start/startExternal 开启),
  Spectre.Console 看到 stdout 是 TTY 就走 interactive 路径,不再 race。**默认应该
  看到 clean exit 0,N_m3u8DL-RE 自己 mux 成 mp4**(用户偏好 N_m3u8DL-RE 因为快)。
  ffmpeg fallback (`runFFmpegFallback`) 仍然保留作为真正失败的兜底,但**不应**作为常规路径。
  日志里看到 `[fallback]` 前缀说明 N_m3u8DL-RE 真的失败了才退的,不是 race —
  不要因为 fallback 出现就"修代码"。

## 项目结构速览

- 源码:`SwiftApp/Sources/M3U8Downloader/*.swift` + `Package.swift`
  (SwiftUI + WKWebView + AVFoundation,`@main` 在 `M3U8DownloaderApp.swift`)
- .app 构建/部署:`bin/package_app.sh`、`bin/deploy_app.sh`、`bin/build_icns.py`
- 二进制:`/Users/ming/Movies/N_m3u8DL-RE`(打包时复制进 `.app/Contents/MacOS/`)
- 最低平台:macOS 14(用 `onChange(of:initial:_:)`、`AVURLAssetHTTPHeaderFieldsKey`)
- 状态注入:`ContentView` 用 `@StateObject` 持有 `DownloaderViewModel` /
  `BrowserViewModel` / `PlayerViewModel`,通过 `.environmentObject` 下发
- 关键坑:`NSView` 在 Swift 5 不暴露 `+layerClass` 钩子,要做 CALayer 子类化
  就手动在 `makeNSView` 里 `v.layer = customLayer`;`@MainActor` 类的 `deinit`
  不能访问主 actor 隔离属性,`NotificationCenter` token 要标 `nonisolated(unsafe)`
  才能在 deinit 里 `removeObserver`

## 产品决策(已与用户确认,不要再问一次)

- 没有 CLI 入口,没有 macOS 快捷指令集成,只有 SwiftUI 桌面 App
- 播放和下载是两条独立链路,**不要在播放面板里加"下载当前播放"按钮**;
  用户想下载就回到链接卡片的"下载"按钮
- App 内嵌 WKWebView 抓 m3u8 后,点变体行的 ▶ 按钮触发 App 内部 AVPlayer
  接管;长按视频画面 = 2x 倍速,松手恢复 1x(不弹菜单、不渐变、不持久化设置)
- 只处理 m3u8,MP4 等其它格式不在范围内
- 下载链路**默认走 N_m3u8DL-RE**(用户偏好,因为快且能 master-playlist 选轨),
  通过 PTY 包装保证 Spectre.Console 不 race。ffmpeg 是兜底,不是默认
