import Foundation
import AVFoundation
import CoreMedia

/// Fetches an HLS playlist over HTTP and parses its variants.
///
/// Supports both:
///  - Master playlist  (contains #EXT-X-STREAM-INF lines → returns N variants)
///  - Media playlist   (no STREAM-INF lines            → returns 1 synthetic variant)
///
/// Designed to be lightweight and tolerant of malformed streams.
enum HLSProbe {

    struct Result {
        let variants: [M3U8Variant]
        /// True if the playlist is a master (multi-variant) playlist.
        let isMaster: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case badURL(String)
        case http(Int)
        case emptyBody
        case notHLS

        var errorDescription: String? {
            switch self {
            case .badURL(let s):  return "URL 无效: \(s)"
            case .http(let code): return "HTTP \(code)"
            case .emptyBody:      return "响应为空"
            case .notHLS:         return "不是有效的 HLS / m3u8 内容"
            }
        }
    }

    /// Probe a single URL. Honors optional cookie/user-agent header.
    static func probe(urlString: String,
                      headers: [String] = [],
                      timeout: TimeInterval = 15) async throws -> Result {

        guard let url = URL(string: urlString) else {
            throw ProbeError.badURL(urlString)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        for h in headers {
            let parts = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                req.setValue(parts[1], forHTTPHeaderField: parts[0])
            }
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProbeError.http(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
            throw ProbeError.emptyBody
        }
        guard body.contains("#EXTM3U") else { throw ProbeError.notHLS }
        return parse(body: body, baseURL: url)
    }

    /// Parse an m3u8 body (already loaded as String).
    static func parse(body: String, baseURL: URL) -> Result {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        var variants: [M3U8Variant] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attrs = parseAttributes(afterPrefix: line)
                // Next non-comment, non-blank line is the variant URL
                var j = i + 1
                var variantURL = ""
                while j < lines.count {
                    let l = lines[j]
                    if l.isEmpty || l.hasPrefix("#") { j += 1; continue }
                    variantURL = l
                    break
                }
                let resolved = URL(string: variantURL, relativeTo: baseURL)?.absoluteString
                              ?? variantURL
                let v = M3U8Variant(
                    resolution: attrs["RESOLUTION"],
                    bandwidth: attrs["BANDWIDTH"].flatMap { Int($0) },
                    codecs: attrs["CODECS"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                    frameRate: attrs["FRAME-RATE"].flatMap { Double($0) },
                    mediaType: "VIDEO",
                    url: resolved
                )
                variants.append(v)
                i = j + 1
            } else if line.hasPrefix("#EXT-X-MEDIA") {
                // audio / subtitles track — record as a separate variant
                let attrs = parseAttributes(afterPrefix: line)
                let type = attrs["TYPE"] ?? ""
                let uri  = attrs["URI"] ?? ""
                if !uri.isEmpty {
                    let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
                    variants.append(M3U8Variant(
                        resolution: nil,
                        bandwidth: attrs["BANDWIDTH"].flatMap { Int($0) },
                        codecs: attrs["CODECS"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                        frameRate: nil,
                        mediaType: type.isEmpty ? "AUDIO" : type,
                        url: resolved
                    ))
                }
                i += 1
            } else {
                i += 1
            }
        }

        if variants.isEmpty {
            // Media playlist — synthesize a single variant pointing to the playlist itself.
            return Result(
                variants: [M3U8Variant(
                    resolution: nil,
                    bandwidth: nil,
                    codecs: nil,
                    frameRate: nil,
                    mediaType: "MEDIA",
                    url: baseURL.absoluteString
                )],
                isMaster: false)
        }
        // Sort by descending bandwidth so the user sees highest-res on top.
        let sorted = variants.sorted { (a, b) in
            (a.bandwidth ?? 0) > (b.bandwidth ?? 0)
        }
        return Result(variants: sorted, isMaster: variants.count > 1 || variants[0].resolution != nil)
    }

    // MARK: - AVFoundation fallback probe
    //
    // Media playlists don't carry a `RESOLUTION=` attribute (only master
    // playlists do). For a single-variant media playlist we can still
    // discover the actual width/height/frame-rate of the underlying video
    // track by parsing the first segment ourselves.

    struct MediaTrackInfo {
        let width: Int
        let height: Int
        /// Frames per second (0 if unknown).
        let frameRate: Double
        /// Estimated bitrate in bits-per-second, if AVFoundation reports one.
        let bitrate: Int?
        /// Short codec tag, e.g. "avc1" / "hvc1".
        let codec: String?
    }

    /// Probe the actual video track behind an m3u8 URL.
    /// Returns `nil` if the segment can't be fetched or there's no
    /// video track.
    ///
    /// Strategy: rather than handing the m3u8 to `AVURLAsset` and
    /// hoping AVFoundation will fetch the right segment with our
    /// headers, we (1) download the playlist ourselves with URLSession,
    /// (2) grab the first segment URL out of it, (3) download that
    /// segment to a local tmp file with the same headers, and (4) ask
    /// `AVAsset` to read the local file. This bypasses AVURLAsset's
    /// m3u8 quirks — `AVURLAssetHTTPHeaderFieldsKey` is unreliable for
    /// sub-segment requests on macOS, and the older
    /// `statusOfValue(forKey:)` polling reports `.loaded` immediately
    /// on the macOS 14 SDK before the asset is actually populated.
    static func probeMediaTrack(urlString: String,
                                headers: [String] = [],
                                timeout: TimeInterval = 25) async -> MediaTrackInfo? {
        guard let playlistURL = URL(string: urlString) else { return nil }

        // (1) Download the playlist with URLSession.
        let playlist: String
        do {
            var req = URLRequest(url: playlistURL, timeoutInterval: timeout)
            applyHeaders(headers, to: &req)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let body = String(data: data, encoding: .utf8)
                              ?? String(data: data, encoding: .isoLatin1) else {
                return nil
            }
            playlist = body
        } catch {
            return nil
        }

        // (2) Find the first segment filename from the playlist.
        let firstSegment = playlist
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !line.hasPrefix("#")
            }
        guard let segmentName = firstSegment else { return nil }
        guard let segmentURL = URL(string: segmentName, relativeTo: playlistURL)?.absoluteURL else {
            return nil
        }

        // (3) Download the first segment to a tmp file (with the same headers).
        let tmpFile: URL
        do {
            var req = URLRequest(url: segmentURL, timeoutInterval: timeout)
            applyHeaders(headers, to: &req)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let dir = FileManager.default.temporaryDirectory
            let file = dir.appendingPathComponent("m3u8probe-\(UUID().uuidString).ts")
            try data.write(to: file, options: .atomic)
            tmpFile = file
        } catch {
            return nil
        }
        // Always clean up the tmp file when we're done.
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        // (4) Read the local segment with AVAsset.
        let asset = AVURLAsset(url: tmpFile)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard let track = videoTracks.first else { return nil }

        let size = track.naturalSize
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let frameRate = Double(track.nominalFrameRate)
        let bitrate = track.estimatedDataRate > 0
            ? Int(track.estimatedDataRate.rounded())
            : nil

        var codec: String?
        let descs = track.formatDescriptions as? [CMFormatDescription] ?? []
        if let first = descs.first {
            let fcc = CMFormatDescriptionGetMediaSubType(first)
            let bytes: [UInt8] = [
                UInt8((fcc >> 24) & 0xFF),
                UInt8((fcc >> 16) & 0xFF),
                UInt8((fcc >> 8) & 0xFF),
                UInt8(fcc & 0xFF),
            ]
            codec = String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? nil
        }

        // Guard against zero / placeholder sizes that some streams return
        // while still warming up.
        guard width > 0, height > 0 else { return nil }

        return MediaTrackInfo(
            width: width,
            height: height,
            frameRate: frameRate,
            bitrate: bitrate,
            codec: codec
        )
    }

    /// Apply a list of "Header: value" lines onto an existing URLRequest.
    private static func applyHeaders(_ lines: [String], to req: inout URLRequest) {
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[0].isEmpty {
                req.setValue(parts[1], forHTTPHeaderField: parts[0])
            }
        }
    }

    /// Parses the comma-separated `KEY=VALUE[,KEY=VALUE...]` after `#EXT-X-STREAM-INF:`
    /// or after `#EXT-X-MEDIA:`. Values may be quoted.
    private static func parseAttributes(afterPrefix line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let payload = String(line[line.index(after: colon)...])
        var attrs: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingKey = true

        for c in payload {
            if readingKey {
                if c == "=" {
                    readingKey = false
                    continue
                }
                key.append(c)
            } else {
                if c == "\"" {
                    inQuotes.toggle()
                    continue
                }
                if c == "," && !inQuotes {
                    attrs[key.trimmingCharacters(in: .whitespaces)] =
                        value.trimmingCharacters(in: .whitespaces)
                    key = ""
                    value = ""
                    readingKey = true
                    continue
                }
                value.append(c)
            }
        }
        if !key.isEmpty {
            attrs[key.trimmingCharacters(in: .whitespaces)] =
                value.trimmingCharacters(in: .whitespaces)
        }
        return attrs
    }
}