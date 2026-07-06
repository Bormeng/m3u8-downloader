# M3U8 Downloader 测试素材

本目录保存开发与手测时使用的 HLS 样本流以及 N_m3u8DL-RE 对其进行分析时输出的快照。

```
tests/
└── fixtures/
    ├── apple/             # Apple 官方 HLS 演示流 + 分析快照
    │   ├── raw.m3u8
    │   ├── meta.json            # N_m3u8DL-RE --analyze 完整输出
    │   ├── meta_selected.json   # 选定轨道后的输出
    │   └── 0__avc1.64002a_8144656_/   # 默认下载命名的输出目录
    └── mux/               # Mux 公开测试流 + 分析快照
        ├── raw.m3u8
        ├── meta.json
        ├── meta_selected.json
        └── 0__mp4a.40.2,avc1.640028_6221600_/
```

## 用途

- **手测/回归**:把 `raw.m3u8` 喂给桌面 App,确认选轨、下载与日志流式输出仍然正常。
- **离线参考**:`meta.json` / `meta_selected.json` 是过去某次跑通的快照,可以和当前抓到的对比来确认下载器没有回归。
- **不参与 Xcode/SwiftPM 构建**:`Package.swift` 里没有引用这里的内容,`tests/` 仅作开发期资料存档。

## 来源

| 来源 | 原始 URL |
|------|----------|
| Apple HLS 示例流 | `https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8` |
| Mux 公开测试流 | `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8` |

## 不在此目录的内容

- `N_m3u8DL-RE` 二进制本身不在此处,而是跟打包脚本一起放在 `bin/`,构建时复制到 `dist/M3U8Downloader.app/Contents/MacOS/`
- 用户下载的实际视频也不应该提交到这里,如果不小心下载到了,请删除或加进 `.gitignore`
