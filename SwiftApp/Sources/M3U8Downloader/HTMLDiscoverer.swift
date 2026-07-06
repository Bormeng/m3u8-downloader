import Foundation

/// Fetch a webpage (HTTP GET) and pull out any m3u8 URLs that appear inside it.
///
/// Supports m3u8 URLs embedded in many common ways:
///   - plain `https://...m3u8` text
///   - HTML attributes: `<a href="...m3u8">`, `<source src="...m3u8">`, `<video src="...m3u8">`, `<iframe src="...m3u8">`
///   - JSON-encoded strings (DPlayer / Clappr / videojs config): `https:\/\/...m3u8`
///   - inside `<script>...</script>` blocks (player configs)
///   - relative URLs that get resolved against `baseURL`
///
/// URLs are returned in document order, deduplicated.
enum HTMLDiscoverer {

    struct Result {
        let webpageTitle: String?
        /// Absolute m3u8 URLs found inside the page.
        let m3u8URLs: [String]
        /// Original URL that was fetched (used to resolve relative refs).
        let baseURL: URL
    }

    enum DiscoverError: Error, LocalizedError {
        case badURL(String)
        case http(Int)
        case emptyBody

        var errorDescription: String? {
            switch self {
            case .badURL(let s):  return "URL 无效: \(s)"
            case .http(let code): return "HTTP \(code)"
            case .emptyBody:      return "响应为空"
            }
        }
    }

    // MARK: - Fetch

    /// GET a URL with optional extra headers and a UA suitable for blog pages.
    static func fetch(urlString: String,
                      headers: [String] = [],
                      timeout: TimeInterval = 20) async throws -> (body: String, baseURL: URL) {
        guard let url = URL(string: urlString) else { throw DiscoverError.badURL(urlString) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/120.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent")
        }
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        req.setValue(url.host ?? "", forHTTPHeaderField: "Host")
        for h in headers {
            let parts = h.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                req.setValue(parts[1], forHTTPHeaderField: parts[0])
            }
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DiscoverError.http(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
            throw DiscoverError.emptyBody
        }
        return (body, url)
    }

    // MARK: - Extract

    /// Returns all m3u8 URLs referenced anywhere in `html`, with relative paths
    /// resolved against `baseURL`. Order preserved, deduplicated.
    static func extractM3U8URLs(in html: String, baseURL: URL) -> [String] {
        // 1) Unescape JSON-style backslash-slash (DPlayer / Clappr data-config blocks)
        //    Also handle a few common HTML entity escapes.
        let unescaped = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        // 2) Generic match for any http(s) URL containing ".m3u8".
        //    Stop at typical terminators (quotes, angle brackets, whitespace, brackets).
        let pattern = #"https?://[^\s"'<>\\)\]\}]+?\.m3u8(?:[?#][^\s"'<>\\)\]\}]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = unescaped as NSString
        let matches = regex.matches(in: unescaped,
                                    range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            guard m.range.location != NSNotFound, m.range.length > 0 else { continue }
            var raw = ns.substring(with: m.range)
            // Strip common trailing punctuation that some players add.
            while let last = raw.last, ".,;)]}'\"".contains(last) { raw.removeLast() }
            guard !raw.isEmpty else { continue }
            // If the URL has no scheme (e.g. a relative path that survived escape), resolve.
            let absolute: String
            if let parsed = URL(string: raw), parsed.scheme != nil {
                absolute = parsed.absoluteString
            } else if let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteString {
                absolute = resolved
            } else {
                absolute = raw
            }
            if seen.insert(absolute).inserted { out.append(absolute) }
        }
        return out
    }

    // MARK: - One-shot

    /// Fetch `urlString`, then extract m3u8 URLs from it.
    static func discover(urlString: String, headers: [String] = []) async throws -> Result {
        let (body, baseURL) = try await fetch(urlString: urlString, headers: headers)
        let urls = extractM3U8URLs(in: body, baseURL: baseURL)

        // Try <title>...</title> for the UI badge.
        var title: String?
        if let titleRegex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = body as NSString
            if let m = titleRegex.firstMatch(in: body,
                                             range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                let raw = ns.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                title = decodeHTMLEntities(raw)
            }
        }

        return Result(webpageTitle: title, m3u8URLs: urls, baseURL: baseURL)
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (k, v) in pairs { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
