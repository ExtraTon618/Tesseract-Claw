// MIT License
//
// Copyright (c) 2026 KnotTheory.ai Inc.
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

// MARK: - SendUserMessage / Brief Tool

/// Sends a formatted message to the user with optional file attachments.
/// Primarily used by sub-agents to communicate progress or results.
public func executeSendUserMessage(message: String, attachments: [String]?) -> String {
    var output = message

    if let attachments = attachments, !attachments.isEmpty {
        output += "\n\nAttachments:"
        for path in attachments {
            let resolved = (path as NSString).expandingTildeInPath
            let fm = FileManager.default
            if fm.fileExists(atPath: resolved) {
                let attrs = try? fm.attributesOfItem(atPath: resolved)
                let size = (attrs?[.size] as? Int64).map { formatByteSize($0) } ?? "?"
                let ext = (resolved as NSString).pathExtension.lowercased()
                let isImage = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"].contains(ext)
                let typeLabel = isImage ? " [image]" : ""
                output += "\n  - \(resolved) (\(size))\(typeLabel)"
            } else {
                output += "\n  - \(resolved) (not found)"
            }
        }
    }

    return output
}

private func formatByteSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
}
