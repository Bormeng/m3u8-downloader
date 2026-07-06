import Foundation

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