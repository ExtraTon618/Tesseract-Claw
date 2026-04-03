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

// MARK: - ToolSearch Tool

/// Searches available tools by name or keyword, returning matching tool specs.
public func executeToolSearch(query: String, maxResults: Int, specs: [ToolSpec]) -> String {
    let normalized = query.lowercased()

    // Exact name match first
    if let exact = specs.first(where: { $0.name.lowercased() == normalized }) {
        return formatToolResult(exact)
    }

    // Keyword search — score each spec by how many query words appear in name + description
    let queryWords = normalized.split(separator: " ").map(String.init)
    var scored: [(ToolSpec, Int)] = specs.compactMap { spec in
        let haystack = "\(spec.name) \(spec.description)".lowercased()
        let score = queryWords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        return score > 0 ? (spec, score) : nil
    }
    scored.sort { $0.1 > $1.1 }

    let results = scored.prefix(maxResults)
    if results.isEmpty {
        return "No tools matched query '\(query)'. Available tools: \(specs.map(\.name).joined(separator: ", "))"
    }

    return results.map { formatToolResult($0.0) }.joined(separator: "\n\n")
}

private func formatToolResult(_ spec: ToolSpec) -> String {
    "- \(spec.name): \(spec.description) [permission: \(spec.requiredPermission.asString)]"
}
