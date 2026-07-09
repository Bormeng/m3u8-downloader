import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case mkv = "MKV"
    case ts  = "TS"
    var id: String { rawValue }
}

struct DownloadTask: Identifiable, Hashable {
    let id = UUID()
    var url: String
    var saveName: String = ""
    var saveDir: String
    var headers: [String] = []
    var threads: Int = 12
    var format: OutputFormat = .mp4
    var autoSelect: Bool = true
    var livePerformAsVOD: Bool = false
}

enum DownloadStatus: Equatable {
    case idle
    case running
    case success(Double)      // seconds
    case failed(String)
    case cancelled
}

struct DownloadLogLine: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let text: String
}

// MARK: - HTML discovery & HLS probing models

/// Where the link was found in the HTML — for display only.
enum M3U8LinkSource: String, Hashable {
    case href       // <a href="...">
    case video      // <video src="..."> or <source src="...">
    case embedded   // src="..." in inline JS / JSON
    case unknown

    var label: String {
        switch self {
        case .href:     return "href"
        case .video:    return "video/source"
        case .embedded: return "embedded"
        case .unknown:  return "raw"
        }
    }
}

struct M3U8Variant: Identifiable, Hashable {
    let id = UUID()
    /// Resolution string, e.g. "1920x1080"; nil if not a master playlist.
    var resolution: String?
    /// Bandwidth in bits per second, when known.
    var bandwidth: Int?
    /// Codecs string, e.g. "avc1.64002a,mp4a.40.2"
    var codecs: String?
    /// Frame rate if advertised.
    var frameRate: Double?
    /// Whether this is the audio-only / subtitle-only stream.
    var mediaType: String?      // "VIDEO"/"AUDIO"/"SUBTITLES" if known
    /// Direct URL to the variant playlist (or to the original URL if no children).
    var url: String
    /// human-readable label used in the UI.
    var displayLabel: String {
        var parts: [String] = []
        if let r = resolution, !r.isEmpty { parts.append(r) }
        else if let mt = mediaType { parts.append(mt) }
        if let b = bandwidth {
            let mbps = Double(b) / 1_000_000.0
            parts.append(String(format: "%.2f Mbps", mbps))
        }
        if let fr = frameRate, fr > 0 {
            parts.append(String(format: "%.0ffps", fr))
        }
        if parts.isEmpty { return url }
        return parts.joined(separator: " · ")
    }
}

enum ProbeStatus: Hashable {
    case pending
    case probing
    case done
    case failed(String)
}

struct M3U8Link: Identifiable, Hashable {
    let id = UUID()
    var url: String
    /// Webpage URL we discovered this m3u8 from (used as Referer when
    /// probing or downloading). May be nil if the user pasted the m3u8 directly.
    var referer: String? = nil
    /// Populated after probe.
    var variants: [M3U8Variant] = []
    var status: ProbeStatus = .pending
    var statusMessage: String = ""

    /// If the playlist is a single-resolution media playlist, the lone variant
    /// represents the only downloadable representation.
    var isMaster: Bool { variants.count > 1 ||
        (variants.first?.resolution != nil) }
}