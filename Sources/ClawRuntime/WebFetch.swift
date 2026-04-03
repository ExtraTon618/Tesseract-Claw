// MIT License
//
// Copyright (c) 2026 KnotTheory.ai
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

// MARK: - Web Fetch

public struct WebFetchOutput: Equatable, Sendable {
    public let url: String
    public let statusCode: Int
    public let content: String
    public let truncated: Bool
}

/// Fetch content from a URL via URLSession. Returns plain text (HTML tags stripped).
public func webFetch(url: String, maxChars: Int = 20_000, timeoutSeconds: Double = 30) throws -> WebFetchOutput {
    guard let urlObj = URL(string: url) else {
        throw ToolError("Invalid URL: \(url)")
    }

    var request = URLRequest(url: urlObj)
    request.timeoutInterval = timeoutSeconds
    request.setValue("Mozilla/5.0 (compatible; TesseractClaw/0.3.0)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var urlResponse: URLResponse?
    var responseError: Error?

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        responseData = data
        urlResponse = response
        responseError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let error = responseError {
        throw ToolError("Fetch failed: \(error.localizedDescription)")
    }

    let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
    guard let data = responseData else {
        throw ToolError("No response data from \(url)")
    }

    let rawContent = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .ascii)
        ?? ""

    // Strip HTML tags for readability
    let stripped = stripHTMLTags(rawContent)
    let trimmed = collapseWhitespace(stripped)

    let truncated = trimmed.count > maxChars
    let content = truncated ? String(trimmed.prefix(maxChars)) + "\n\n[Truncated at \(maxChars) chars]" : trimmed

    return WebFetchOutput(url: url, statusCode: statusCode, content: content, truncated: truncated)
}

// MARK: - Web Search

public struct WebSearchResult: Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
}

public struct WebSearchOutput: Equatable, Sendable {
    public let query: String
    public let results: [WebSearchResult]
}

/// Perform a web search using DuckDuckGo's HTML interface.
public func webSearch(query: String, limit: Int = 8, timeoutSeconds: Double = 15) throws -> WebSearchOutput {
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let searchURL = "https://html.duckduckgo.com/html/?q=\(encoded)"

    guard let url = URL(string: searchURL) else {
        throw ToolError("Failed to construct search URL")
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = timeoutSeconds
    request.setValue("Mozilla/5.0 (compatible; TesseractClaw/0.3.0)", forHTTPHeaderField: "User-Agent")

    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseError: Error?

    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        responseData = data
        responseError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let error = responseError {
        throw ToolError("Search failed: \(error.localizedDescription)")
    }

    guard let data = responseData,
          let html = String(data: data, encoding: .utf8) else {
        throw ToolError("No search results returned")
    }

    let results = parseDuckDuckGoResults(html, limit: limit)
    return WebSearchOutput(query: query, results: results)
}

// MARK: - HTML Parsing Helpers

private func stripHTMLTags(_ html: String) -> String {
    // Remove script and style blocks entirely
    var result = html
    let blockPatterns = [
        "<script[^>]*>[\\s\\S]*?</script>",
        "<style[^>]*>[\\s\\S]*?</style>",
        "<!--[\\s\\S]*?-->"
    ]
    for pattern in blockPatterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
    }
    // Replace block-level tags with newlines
    if let blockRegex = try? NSRegularExpression(pattern: "<(br|p|div|h[1-6]|li|tr)[^>]*>", options: .caseInsensitive) {
        result = blockRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "\n")
    }
    // Strip remaining tags
    if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
        result = tagRegex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
    }
    // Decode common HTML entities
    result = result.replacingOccurrences(of: "&amp;", with: "&")
    result = result.replacingOccurrences(of: "&lt;", with: "<")
    result = result.replacingOccurrences(of: "&gt;", with: ">")
    result = result.replacingOccurrences(of: "&quot;", with: "\"")
    result = result.replacingOccurrences(of: "&#39;", with: "'")
    result = result.replacingOccurrences(of: "&nbsp;", with: " ")
    return result
}

private func collapseWhitespace(_ text: String) -> String {
    var result = ""
    var previousBlank = false
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if !previousBlank { result += "\n" }
            previousBlank = true
        } else {
            result += trimmed + "\n"
            previousBlank = false
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseDuckDuckGoResults(_ html: String, limit: Int) -> [WebSearchResult] {
    var results: [WebSearchResult] = []

    // DuckDuckGo HTML results have class="result__a" for links and class="result__snippet" for snippets
    let resultPattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#
    let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</[a-z]"#

    guard let linkRegex = try? NSRegularExpression(pattern: resultPattern, options: .caseInsensitive),
          let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
        return results
    }

    let linkMatches = linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    let snippetMatches = snippetRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

    for (i, match) in linkMatches.enumerated() where i < limit {
        guard match.numberOfRanges >= 3,
              let urlRange = Range(match.range(at: 1), in: html),
              let titleRange = Range(match.range(at: 2), in: html) else { continue }

        var resultURL = String(html[urlRange])
        let title = stripHTMLTags(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)

        // DuckDuckGo wraps URLs in a redirect — extract the actual URL
        if resultURL.contains("uddg="), let decoded = extractDDGUrl(resultURL) {
            resultURL = decoded
        }

        let snippet: String
        if i < snippetMatches.count, snippetMatches[i].numberOfRanges >= 2,
           let snippetRange = Range(snippetMatches[i].range(at: 1), in: html) {
            snippet = stripHTMLTags(String(html[snippetRange])).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            snippet = ""
        }

        results.append(WebSearchResult(title: title, url: resultURL, snippet: snippet))
    }

    return results
}

private func extractDDGUrl(_ redirectUrl: String) -> String? {
    guard let components = URLComponents(string: redirectUrl),
          let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
        return nil
    }
    return uddg
}
