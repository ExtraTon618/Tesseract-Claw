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
import PDFKit

public struct PdfReadOutput: Equatable, Sendable {
    public let filePath: String
    public let content: String
    public let numPages: Int
    public let pagesRead: String
}

/// Read text from a PDF file. Supports page ranges like "1-5", "3", or nil for all pages.
/// Caps at 20 pages per request to prevent context overflow.
public func readPdf(path: String, pages: String? = nil) throws -> PdfReadOutput {
    let safePath = try normalizePath(path)
    try validateWorkspaceBoundary(safePath)

    guard let pdfDoc = PDFDocument(url: URL(fileURLWithPath: safePath)) else {
        throw ToolError("Could not open PDF at \(path)")
    }

    let totalPages = pdfDoc.pageCount
    let maxPages = 20

    // Parse page range
    let (startPage, endPage): (Int, Int)
    if let pages = pages?.trimmingCharacters(in: .whitespaces), !pages.isEmpty {
        if pages.contains("-") {
            let parts = pages.split(separator: "-").compactMap { Int($0) }
            if parts.count == 2 {
                startPage = max(1, parts[0])
                endPage = min(totalPages, parts[1])
            } else {
                startPage = 1; endPage = min(totalPages, maxPages)
            }
        } else if let single = Int(pages) {
            startPage = max(1, single)
            endPage = startPage
        } else {
            startPage = 1; endPage = min(totalPages, maxPages)
        }
    } else {
        startPage = 1
        endPage = min(totalPages, maxPages)
    }

    // Cap page count
    let effectiveEnd = min(endPage, startPage + maxPages - 1)

    var textParts: [String] = []
    textParts.append("PDF: \(path) (\(totalPages) pages)")

    for pageNum in startPage...effectiveEnd {
        let pageIndex = pageNum - 1  // PDFKit uses 0-based indexing
        if let page = pdfDoc.page(at: pageIndex) {
            let text = page.string ?? "[No text content on page \(pageNum)]"
            textParts.append("--- Page \(pageNum) ---\n\(text)")
        }
    }

    if effectiveEnd < totalPages {
        textParts.append("[Showing pages \(startPage)-\(effectiveEnd) of \(totalPages). Use pages parameter for more.]")
    }

    let pagesLabel = startPage == effectiveEnd ? "\(startPage)" : "\(startPage)-\(effectiveEnd)"

    return PdfReadOutput(
        filePath: path,
        content: textParts.joined(separator: "\n\n"),
        numPages: totalPages,
        pagesRead: pagesLabel
    )
}
