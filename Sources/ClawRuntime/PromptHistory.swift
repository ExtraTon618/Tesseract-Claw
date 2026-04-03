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
import CEditline

/// Per-folder prompt history with up/down arrow recall.
/// Stores history at ~/.claw/history/<hash>.txt scoped to the working directory.
public final class PromptHistory {
    public let historyPath: String
    private let maxEntries: Int

    /// Initialize prompt history for the given working directory.
    public init(cwd: String, maxEntries: Int = 500) {
        self.maxEntries = maxEntries

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let histDir = "\(home)/.claw/history"
        try? FileManager.default.createDirectory(atPath: histDir, withIntermediateDirectories: true)

        // Hash the cwd to get a stable, filesystem-safe filename
        let hash = Self.djb2Hash(cwd)
        self.historyPath = "\(histDir)/\(hash).txt"

        // Load existing history into editline
        if FileManager.default.fileExists(atPath: historyPath) {
            read_history(historyPath)
        }
    }

    /// Read a line with prompt and arrow-key history support.
    /// Returns nil on EOF (Ctrl-D).
    public func readline(prompt: String) -> String? {
        guard let cstr = CEditline.readline(prompt) else {
            return nil  // EOF
        }
        let line = String(cString: cstr)
        free(cstr)

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            add_history(trimmed)
        }

        return line
    }

    /// Save history to disk. Call this before exiting.
    public func save() {
        write_history(historyPath)

        // Trim to maxEntries
        if let contents = try? String(contentsOfFile: historyPath, encoding: .utf8) {
            var lines = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count > maxEntries {
                lines = Array(lines.suffix(maxEntries))
                try? lines.joined(separator: "\n").write(toFile: historyPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// DJB2 hash of a string, returned as hex.
    private static func djb2Hash(_ str: String) -> String {
        var hash: UInt64 = 5381
        for byte in str.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
