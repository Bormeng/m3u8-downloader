# M3U8 下载器

基于 `N_m3u8DL-RE` 的 macOS 原生 SwiftUI 下载工具,带你把 HLS / m3u8 流拉到本地,GUI 实时看进度。

```
m3u8-downloader/
├── SwiftApp/                  # SwiftUI App 源码
│   ├── Package.swift
│   └── Sources/M3U8Downloader/
│       ├── M3U8DownloaderApp.swift   # @main
│       ├── ContentView.swift         # 主界面
│       ├── DownloaderViewModel.swift # 业务逻辑 + 进程调用
│       ├── ProcessRunner.swift       # N_m3u8DL-RE 进程包装
│       └── Models.swift
├── bin/
│   ├── package_app.sh         # .app 打包脚本
│   ├── deploy_app.sh          # 一键构建 + 部署到 /Applications
│   └── build_icns.py          # AppIcon.iconset 生成工具
├── dist/
│   └── m3u8 下载器.app        # 已打包好的 .app
├── docs/
│   └── icon_candidate_*.png   # App 图标设计稿候选
├── tests/
│   └── fixtures/              # HLS 样本流 + N_m3u8DL-RE 分析快照
└── README.md
```

---

## 1. 启动桌面 App

```bash
# 直接跑
open /Users/ming/Documents/Repositories/m3u8-downloader/dist/m3u8\ 下载器.app

# 或一键部署到 /Applications
bin/deploy_app.sh
open /Applications/m3u8\ 下载器.app
```

### 界面速览

- **左侧表单**:URL 输入(含剪贴板自动识别)/ 保存目录 / 文件名 / 线程数 / 格式(MP4/MKV/TS)/ 自动选轨开关 / HTTP 请求头
- **右侧日志**:实时流式输出 N_m3u8DL-RE 的进度,可一键复制
- **底部状态栏**:就绪 / 下载中 / 完成 / 失败 / 已取消,按钮 ⌘. 取消、⌘↩ 开始

### App 内置 N_m3u8DL-RE

打包脚本已把 `/Users/ming/Movies/N_m3u8DL-RE` 复制到 `.app/Contents/MacOS/N_m3u8DL-RE`,
所以即使你之后删掉原始二进制,App 仍能工作。
如需更换版本,重新执行 `bin/package_app.sh` 即可。

---

## 2. 重新编译 / 重新打包

修改源码后:

```bash
# 重新打包 .app(顺带编译)
bin/package_app.sh

# 一键部署到 /Applications
bin/deploy_app.sh
```

---

## 3. 已测试

| 测试项 | 结果 |
|--------|------|
| Swift Package 编译 | ✅ 5.0s 完成 |
| `.app` 启动(PID 22201) | ✅ 正常 |
| Wrapper 脚本启动下载 | ✅ 42.91 MB/s |
| `-H` 多次传 header | ✅ 透传正确 |
| 自动选轨 | ✅ 选 1920x1080 H.264 + 6CH 音频 |
| 日志流式输出 | ✅ 实时刷新 |

---

## 4. 系统要求

- macOS 14.0+(App 使用 `onChange(of:initial:_:)` API)
- Apple Silicon / Intel 均可
- N_m3u8DL-RE 二进制(已包含在 `.app` 内)
