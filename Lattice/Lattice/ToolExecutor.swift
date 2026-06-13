import Foundation

private struct LatticeWebSearchResult {
    let title: String
    let domain: String
    let url: String
    let snippet: String
}

private struct LatticeFetchedWebpage {
    let url: String
    let title: String?
    let domain: String?
    let metaDescription: String?
    let bodyText: String
    let wasTruncated: Bool
    let truncationLimit: Int
}

/// Snapshot for reverting a `write_file` tool call (best-effort; bash and other tools are not undone).
struct LatticeWriteFileUndo: Equatable, Sendable {
    let path: String
    /// `nil` means the path did not exist before the write (undo deletes the file).
    let priorData: Data?

    static func capture(path: String) -> LatticeWriteFileUndo {
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return LatticeWriteFileUndo(path: path, priorData: data)
        }
        return LatticeWriteFileUndo(path: path, priorData: nil)
    }

    func apply() {
        let url = URL(fileURLWithPath: path)
        if let data = priorData {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

struct ToolExecutor {
    func execute(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        switch name {
        case "bash":
            guard let command = input["command"] as? String else {
                return ("Missing 'command' parameter", true)
            }
            return await runBash(command)

        case "read_file":
            guard let path = input["path"] as? String else {
                return ("Missing 'path' parameter", true)
            }
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                return (content, false)
            } catch {
                return (error.localizedDescription, true)
            }

        case "write_file":
            guard let path = input["path"] as? String,
                  let content = input["content"] as? String else {
                return ("Missing 'path' or 'content' parameter", true)
            }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                return ("Written to \(path)", false)
            } catch {
                return (error.localizedDescription, true)
            }

        case "open_spec_docs":
            return ("Spec docs viewer is not available. Use read_file to inspect documents instead.", true)

        case "web_search":
            guard let query = input["query"] as? String else {
                return ("Missing 'query' parameter", true)
            }
            let maxResults = input["max_results"] as? Int ?? 5
            let preferredDomains = input["preferred_domains"] as? [String] ?? []
            let restrictToDomains = input["restrict_to_domains"] as? [String] ?? []
            do {
                return (
                    try await webSearch(
                        query: query,
                        maxResults: maxResults,
                        preferredDomains: preferredDomains,
                        restrictToDomains: restrictToDomains
                    ),
                    false
                )
            } catch {
                return (error.localizedDescription, true)
            }

        case "fetch_webpage":
            guard let url = input["url"] as? String else {
                return ("Missing 'url' parameter", true)
            }
            let maxCharacters = input["max_characters"] as? Int ?? 12_000
            do {
                return (try await fetchWebpage(urlString: url, maxCharacters: maxCharacters), false)
            } catch {
                return (error.localizedDescription, true)
            }

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private static let richPATH: String = {
        // Standard locations where Homebrew, npm globals, and developer tools live.
        let standard = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        // Prepend whatever the app process already has so nothing is lost.
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let merged = (standard + existing.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, p in
                if !acc.contains(p) { acc.append(p) }
            }
        return merged.joined(separator: ":")
    }()

    private static let webUserAgent = "Lattice/1.0 (macOS; built-in web tool)"

    private func runBash(_ command: String) async -> (String, Bool) {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.richPATH

        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: ("Cancelled", false))
                    return
                }
                proc.terminationHandler = { p in
                    let stdout = String(
                        data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                    ) ?? ""
                    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    let isError = p.terminationStatus != 0
                    continuation.resume(returning: (combined.isEmpty ? "(no output)" : combined, isError))
                }
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: (error.localizedDescription, true))
                }
            }
        } onCancel: {
            proc.terminate()
        }
    }

    private func webSearch(
        query: String,
        maxResults: Int,
        preferredDomains: [String],
        restrictToDomains: [String]
    ) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Search query cannot be empty."
            ])
        }

        let cappedResults = min(8, max(1, maxResults))
        let preferred = normalizedDomains(preferredDomains)
        let restricted = normalizedDomains(restrictToDomains)

        let queries = buildWebSearchQueries(
            baseQuery: trimmed,
            preferredDomains: preferred,
            restrictedDomains: restricted
        )

        var merged: [LatticeWebSearchResult] = []
        for candidate in queries {
            let html = try await duckDuckGoHTML(query: candidate)
            let parsed = parseDuckDuckGoResults(html)
            merged.append(contentsOf: parsed)
            if merged.count >= cappedResults * 3 {
                break
            }
        }

        let ranked = rankWebSearchResults(
            merged,
            preferredDomains: preferred,
            restrictedDomains: restricted
        )
        let results = Array(ranked.prefix(cappedResults))

        guard !results.isEmpty else {
            return "No web results found for \"\(trimmed)\"."
        }

        var lines = ["Search results for \"\(trimmed)\":", ""]
        for (index, result) in results.enumerated() {
            lines.append("\(index + 1). \(result.title)")
            lines.append("Domain: \(result.domain)")
            lines.append("URL: \(result.url)")
            if !result.snippet.isEmpty {
                lines.append("Snippet: \(result.snippet)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchWebpage(urlString: String, maxCharacters: Int) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "URL cannot be empty."
            ])
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let url = components.url else {
            throw NSError(domain: "ToolExecutor", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Only http and https URLs are supported."
            ])
        }

        let cappedCharacters = min(20_000, max(1_000, maxCharacters))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "ToolExecutor", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Fetching the webpage failed with HTTP \(http.statusCode)."
            ])
        }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""

        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "ToolExecutor", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Could not decode the webpage content."
            ])
        }

        let title = extractHTMLTitle(from: raw)
        let domain = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased()
        let metaDescription = extractHTMLMetaDescription(from: raw)
        let bodyText: String
        if contentType.contains("html") || raw.contains("<html") || raw.contains("<body") {
            bodyText = extractReadableText(fromHTML: raw)
        } else {
            bodyText = raw
        }

        let collapsed = collapseWhitespacePreservingParagraphs(bodyText)
        let clipped = String(collapsed.prefix(cappedCharacters))

        let page = LatticeFetchedWebpage(
            url: url.absoluteString,
            title: title,
            domain: domain,
            metaDescription: metaDescription,
            bodyText: clipped,
            wasTruncated: collapsed.count > clipped.count,
            truncationLimit: cappedCharacters
        )
        return formatFetchedWebpage(page)
    }

    private func duckDuckGoHTML(query: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            throw NSError(domain: "ToolExecutor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not build the search URL."
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "ToolExecutor", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Web search failed with HTTP \(http.statusCode)."
            ])
        }

        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Web search returned an empty response."
            ])
        }
        return html
    }

    private func buildWebSearchQueries(
        baseQuery: String,
        preferredDomains: [String],
        restrictedDomains: [String]
    ) -> [String] {
        var queries: [String] = [baseQuery]

        if !restrictedDomains.isEmpty {
            queries = restrictedDomains.prefix(4).map { "\(baseQuery) site:\($0)" }
        } else if !preferredDomains.isEmpty {
            for domain in preferredDomains.prefix(3) {
                queries.append("\(baseQuery) site:\(domain)")
            }
        }

        var unique: [String] = []
        for query in queries {
            if !unique.contains(query) {
                unique.append(query)
            }
        }
        return unique
    }

    private func parseDuckDuckGoResults(_ html: String) -> [LatticeWebSearchResult] {
        let primaryTitleMatches = matches(
            pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            in: html
        )
        if !primaryTitleMatches.isEmpty {
            return parsePrimaryDuckDuckGoResults(html, titleMatches: primaryTitleMatches)
        }

        return parseFallbackDuckDuckGoResults(html)
    }

    private func parsePrimaryDuckDuckGoResults(
        _ html: String,
        titleMatches: [[String]]
    ) -> [LatticeWebSearchResult] {
        let snippetMatches = matches(
            pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
            in: html
        )

        var results: [LatticeWebSearchResult] = []
        for (index, groups) in titleMatches.enumerated() {
            guard groups.count >= 2 else { continue }
            let href = resolveDuckDuckGoRedirect(groups[0])
            let title = stripHTML(groups[1])
            guard let domain = extractDomain(from: href),
                  !href.isEmpty, !title.isEmpty else { continue }
            let snippet = index < snippetMatches.count && !snippetMatches[index].isEmpty
                ? stripHTML(snippetMatches[index][0])
                : ""
            results.append(.init(title: title, domain: domain, url: href, snippet: snippet))
        }
        return results
    }

    private func parseFallbackDuckDuckGoResults(_ html: String) -> [LatticeWebSearchResult] {
        let linkMatches = matches(
            pattern: #"<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            in: html
        )

        var results: [LatticeWebSearchResult] = []
        for groups in linkMatches {
            guard groups.count >= 2 else { continue }
            let href = resolveDuckDuckGoRedirect(groups[0])
            guard let domain = extractDomain(from: href),
                  shouldKeepSearchResult(url: href, domain: domain) else { continue }
            let title = stripHTML(groups[1])
            guard !title.isEmpty else { continue }
            results.append(.init(title: title, domain: domain, url: href, snippet: ""))
        }
        return results
    }

    private func rankWebSearchResults(
        _ results: [LatticeWebSearchResult],
        preferredDomains: [String],
        restrictedDomains: [String]
    ) -> [LatticeWebSearchResult] {
        var seen = Set<String>()
        let deduped = results.filter { result in
            guard let normalised = normalizeSearchResultURL(result.url) else { return false }
            guard seen.insert(normalised).inserted else { return false }
            return true
        }

        return deduped.enumerated().sorted { lhs, rhs in
            let leftScore = score(result: lhs.element, originalIndex: lhs.offset, preferredDomains: preferredDomains, restrictedDomains: restrictedDomains)
            let rightScore = score(result: rhs.element, originalIndex: rhs.offset, preferredDomains: preferredDomains, restrictedDomains: restrictedDomains)
            if leftScore == rightScore {
                return lhs.offset < rhs.offset
            }
            return leftScore > rightScore
        }.map(\.element)
    }

    private func resolveDuckDuckGoRedirect(_ href: String) -> String {
        let normalised: String
        if href.hasPrefix("//") {
            normalised = "https:\(href)"
        } else {
            normalised = href
        }

        guard let components = URLComponents(string: normalised) else { return href }
        if components.host?.contains("duckduckgo.com") == true,
           let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           !redirected.isEmpty {
            return redirected
        }
        return normalised
    }

    private func shouldKeepSearchResult(url: String, domain: String) -> Bool {
        if domain.contains("duckduckgo.com") { return false }
        if url.hasPrefix("mailto:") || url.hasPrefix("javascript:") { return false }
        return true
    }

    private func extractDomain(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    private func normalizeSearchResultURL(_ urlString: String) -> String? {
        guard var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            let filtered = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && name != "ref" && name != "ref_src"
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.string
    }

    private func score(
        result: LatticeWebSearchResult,
        originalIndex: Int,
        preferredDomains: [String],
        restrictedDomains: [String]
    ) -> Int {
        var total = max(0, 500 - (originalIndex * 7))
        let domain = result.domain
        let loweredURL = result.url.lowercased()

        if !restrictedDomains.isEmpty {
            total += domainMatches(domain, anyOf: restrictedDomains) ? 800 : -600
        }
        if !preferredDomains.isEmpty, domainMatches(domain, anyOf: preferredDomains) {
            total += 240
        }
        if domain.hasPrefix("developer.") || domain.hasPrefix("docs.") {
            total += 80
        }
        if loweredURL.contains("/docs") || loweredURL.contains("/documentation") {
            total += 65
        }
        if domain.contains("github.com") || domain.contains("stackoverflow.com") {
            total -= 30
        }
        if result.snippet.isEmpty {
            total -= 20
        }
        return total
    }

    private func domainMatches(_ domain: String, anyOf candidates: [String]) -> Bool {
        candidates.contains { candidate in
            domain == candidate || domain.hasSuffix(".\(candidate)")
        }
    }

    private func extractHTMLTitle(from html: String) -> String? {
        matches(pattern: #"<title[^>]*>(.*?)</title>"#, in: html).first?.first.map(stripHTML)
    }

    private func extractHTMLMetaDescription(from html: String) -> String? {
        let patterns = [
            #"<meta[^>]*name=["']description["'][^>]*content=["']([^"']+)["'][^>]*>"#,
            #"<meta[^>]*content=["']([^"']+)["'][^>]*name=["']description["'][^>]*>"#,
            #"<meta[^>]*property=["']og:description["'][^>]*content=["']([^"']+)["'][^>]*>"#
        ]
        for pattern in patterns {
            if let value = matches(pattern: pattern, in: html).first?.first.map(stripHTML),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func extractReadableText(fromHTML html: String) -> String {
        let candidates = [
            firstMatch(pattern: #"(?is)<main\b[^>]*>(.*?)</main>"#, in: html),
            firstMatch(pattern: #"(?is)<article\b[^>]*>(.*?)</article>"#, in: html),
            firstMatch(pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#, in: html),
            html
        ].compactMap { $0 }

        var bestText = ""
        for candidate in candidates {
            let cleaned = plainTextFromHTML(sanitizedHTMLForReading(candidate))
            if cleaned.count > bestText.count {
                bestText = cleaned
            }
        }

        let fallback = plainTextFromHTML(html)
        return bestText.count >= max(280, fallback.count / 4) ? bestText : fallback
    }

    private func sanitizedHTMLForReading(_ html: String) -> String {
        var text = html
        let blockPatterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<svg\b[^>]*>.*?</svg>"#,
            #"(?is)<nav\b[^>]*>.*?</nav>"#,
            #"(?is)<header\b[^>]*>.*?</header>"#,
            #"(?is)<footer\b[^>]*>.*?</footer>"#,
            #"(?is)<aside\b[^>]*>.*?</aside>"#,
            #"(?is)<form\b[^>]*>.*?</form>"#,
            #"(?is)<!--.*?-->"#
        ]
        for pattern in blockPatterns {
            text = replacing(pattern: pattern, in: text, with: " ")
        }
        return text
    }

    private func plainTextFromHTML(_ html: String) -> String {
        var text = html
        let patterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<!--.*?-->"#
        ]
        for pattern in patterns {
            text = replacing(pattern: pattern, in: text, with: " ")
        }

        text = replacing(pattern: #"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replacing(pattern: #"(?i)</p>"#, in: text, with: "\n\n")
        text = replacing(pattern: #"(?i)</div>"#, in: text, with: "\n")
        text = replacing(pattern: #"(?i)</li>"#, in: text, with: "\n")
        text = replacing(pattern: #"(?is)<[^>]+>"#, in: text, with: " ")
        return decodeHTMLEntities(text)
    }

    private func formatFetchedWebpage(_ page: LatticeFetchedWebpage) -> String {
        var lines = ["Fetched: \(page.url)"]
        if let domain = page.domain, !domain.isEmpty {
            lines.append("Domain: \(domain)")
        }
        if let title = page.title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let metaDescription = page.metaDescription, !metaDescription.isEmpty {
            lines.append("Summary: \(metaDescription)")
        }
        lines.append("")
        lines.append(page.bodyText)
        if page.wasTruncated {
            lines.append("")
            lines.append("[truncated to \(page.truncationLimit) characters]")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTML(_ html: String) -> String {
        collapseWhitespacePreservingParagraphs(plainTextFromHTML(html))
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        matches(pattern: pattern, in: text).first?.first
    }

    private func normalizedDomains(_ values: [String]) -> [String] {
        values.compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("http://") || value.hasPrefix("https://"),
               let host = URLComponents(string: value)?.host?.lowercased() {
                value = host
            }
            if value.hasPrefix("www.") {
                value.removeFirst(4)
            }
            return value
        }
    }

    private func collapseWhitespacePreservingParagraphs(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var output: [String] = []
        var previousBlank = false
        for line in lines {
            if line.isEmpty {
                if !previousBlank, !output.isEmpty {
                    output.append("")
                }
                previousBlank = true
            } else {
                output.append(line)
                previousBlank = false
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return (1..<match.numberOfRanges).compactMap { rangeIndex in
                let range = match.range(at: rangeIndex)
                guard let swiftRange = Range(range, in: text) else { return nil }
                return String(text[swiftRange])
            }
        }
    }

    private func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let replacements = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (entity, value) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        if let hexRegex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);"#) {
            let nsRange = NSRange(decoded.startIndex..., in: decoded)
            for match in hexRegex.matches(in: decoded, options: [], range: nsRange).reversed() {
                guard match.numberOfRanges == 2,
                      let range = Range(match.range(at: 1), in: decoded),
                      let scalar = UInt32(decoded[range], radix: 16).flatMap(UnicodeScalar.init) else { continue }
                if let whole = Range(match.range(at: 0), in: decoded) {
                    decoded.replaceSubrange(whole, with: String(scalar))
                }
            }
        }

        if let decimalRegex = try? NSRegularExpression(pattern: #"&#([0-9]+);"#) {
            let nsRange = NSRange(decoded.startIndex..., in: decoded)
            for match in decimalRegex.matches(in: decoded, options: [], range: nsRange).reversed() {
                guard match.numberOfRanges == 2,
                      let range = Range(match.range(at: 1), in: decoded),
                      let scalar = UInt32(decoded[range]).flatMap(UnicodeScalar.init) else { continue }
                if let whole = Range(match.range(at: 0), in: decoded) {
                    decoded.replaceSubrange(whole, with: String(scalar))
                }
            }
        }

        return decoded
    }
}
