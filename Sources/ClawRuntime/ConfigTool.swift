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

// MARK: - Config Tool

/// Gets or sets Claw Code settings from config files.
/// Supports nested JSON path notation (e.g. "hooks.preToolUse").
public func executeConfigTool(setting: String?, value: Any?, cwd: String) -> String {
    let loader = ConfigLoader(cwd: cwd)
    let entries = loader.discover()

    // If no setting specified, list all config
    guard let setting = setting, !setting.isEmpty else {
        if entries.isEmpty {
            return "No config files found.\nSearched:\n  ~/.claw/settings.json\n  .claw/settings.json\n  .claw/settings.local.json"
        }
        var report = "Config files:"
        for entry in entries {
            report += "\n  [\(entry.source)] \(entry.path)"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, val) in json.sorted(by: { $0.key < $1.key }) {
                    report += "\n    \(key) = \(val)"
                }
            }
        }
        return report
    }

    // Get: read the setting value
    if value == nil {
        for entry in entries.reversed() {  // higher priority last
            if let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let resolved = resolveNestedKey(json, path: setting) {
                    return "\(setting) = \(resolved) (from \(entry.path))"
                }
            }
        }
        return "Setting '\(setting)' not found in any config file."
    }

    // Set: write to project-level config
    let projectDir = "\(cwd)/.claw"
    let projectConfig = "\(projectDir)/settings.json"

    do {
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: projectConfig)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let previousValue = resolveNestedKey(json, path: setting)
        setNestedKey(&json, path: setting, value: value!)

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: projectConfig))

        let prev = previousValue.map { "\($0)" } ?? "(unset)"
        return "Set \(setting) = \(value!) (was: \(prev)) in \(projectConfig)"
    } catch {
        return "Error writing config: \(error.localizedDescription)"
    }
}

// MARK: - Nested JSON Path Helpers

private func resolveNestedKey(_ json: [String: Any], path: String) -> Any? {
    let keys = path.split(separator: ".").map(String.init)
    var current: Any = json
    for key in keys {
        guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
        current = next
    }
    return current
}

private func setNestedKey(_ json: inout [String: Any], path: String, value: Any) {
    let keys = path.split(separator: ".").map(String.init)
    guard !keys.isEmpty else { return }

    if keys.count == 1 {
        json[keys[0]] = value
        return
    }

    let first = keys[0]
    var nested = json[first] as? [String: Any] ?? [:]
    let remainingPath = keys.dropFirst().joined(separator: ".")
    setNestedKey(&nested, path: remainingPath, value: value)
    json[first] = nested
}
