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

public enum ClipboardContentKind: Sendable {
    case text(String)
    case image(base64: String, mediaType: String)
    case empty
}

/// Read clipboard content. Uses pbpaste for text, osascript for image detection.
public func readClipboard() throws -> ClipboardContentKind {
    // Check if clipboard has image data
    let infoProcess = Process()
    infoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    infoProcess.arguments = ["-e", "clipboard info"]
    let infoPipe = Pipe()
    infoProcess.standardOutput = infoPipe
    infoProcess.standardError = Pipe()
    try infoProcess.run()
    infoProcess.waitUntilExit()

    let infoOutput = String(data: infoPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    // Check for image types in clipboard info
    if infoOutput.contains("PNGf") || infoOutput.contains("public.png") || infoOutput.contains("TIFF") {
        // Extract image from clipboard via osascript → temp file
        let tempPath = NSTemporaryDirectory() + "claw-clipboard-\(UUID().uuidString).png"
        let script = """
        set theFile to POSIX file "\(tempPath)"
        set imgData to the clipboard as «class PNGf»
        set fRef to open for access theFile with write permission
        write imgData to fRef
        close access fRef
        """
        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        extractProcess.arguments = ["-e", script]
        extractProcess.standardOutput = Pipe()
        extractProcess.standardError = Pipe()
        try extractProcess.run()
        extractProcess.waitUntilExit()

        if FileManager.default.fileExists(atPath: tempPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath)) {
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            let base64 = data.base64EncodedString()
            return .image(base64: base64, mediaType: "image/png")
        }
    }

    // Fall back to text via pbpaste
    let pasteProcess = Process()
    pasteProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
    let pastePipe = Pipe()
    pasteProcess.standardOutput = pastePipe
    pasteProcess.standardError = Pipe()
    try pasteProcess.run()
    pasteProcess.waitUntilExit()

    let text = String(data: pastePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .empty
    }
    return .text(text)
}

/// Capture a screen region interactively. Returns path to the screenshot PNG.
public func captureScreenshot() throws -> String {
    let tempPath = NSTemporaryDirectory() + "claw-screenshot-\(UUID().uuidString).png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", tempPath]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    guard FileManager.default.fileExists(atPath: tempPath) else {
        throw ToolError("Screenshot cancelled or failed")
    }
    return tempPath
}
