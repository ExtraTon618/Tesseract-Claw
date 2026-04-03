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

// MARK: - Config Source

public enum ConfigSource: Int, Comparable, Equatable, Sendable {
    case user = 0
    case project = 1
    case local = 2

    public static func < (lhs: ConfigSource, rhs: ConfigSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Config Entry

public struct ConfigEntry: Equatable, Sendable {
    public let source: ConfigSource
    public let path: String

    public init(source: ConfigSource, path: String) {
        self.source = source
        self.path = path
    }
}

// MARK: - MCP Transport

public enum McpTransport: String, Equatable, Sendable {
    case stdio, sse, http, ws, sdk, managedProxy
}

// MARK: - MCP Server Config

public enum McpServerConfig: Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case sse(url: String, headers: [String: String])
    case http(url: String, headers: [String: String])
    case ws(url: String, headers: [String: String])
    case sdk(name: String)
    case managedProxy(url: String, id: String)
}

// MARK: - Runtime Feature Config

public struct RuntimeFeatureConfig: Equatable, Sendable {
    public var hooks: HookConfig
    public var model: String?
    public var permissionMode: PermissionMode?

    public init(hooks: HookConfig = HookConfig(), model: String? = nil, permissionMode: PermissionMode? = nil) {
        self.hooks = hooks
        self.model = model
        self.permissionMode = permissionMode
    }
}

// MARK: - Runtime Config

public struct RuntimeConfig: Equatable, Sendable {
    public var merged: [String: Any] { [:] }  // simplified
    public var loadedEntries: [ConfigEntry]
    public var featureConfig: RuntimeFeatureConfig

    public init(loadedEntries: [ConfigEntry] = [], featureConfig: RuntimeFeatureConfig = RuntimeFeatureConfig()) {
        self.loadedEntries = loadedEntries
        self.featureConfig = featureConfig
    }

    public static func == (lhs: RuntimeConfig, rhs: RuntimeConfig) -> Bool {
        lhs.loadedEntries == rhs.loadedEntries && lhs.featureConfig == rhs.featureConfig
    }
}

// MARK: - Config Loader

public struct ConfigLoader {
    private let cwd: String
    private let configHome: String

    public init(cwd: String, configHome: String? = nil) {
        self.cwd = cwd
        self.configHome = configHome ?? Self.defaultConfigHome()
    }

    public static func defaultConfigHome() -> String {
        if let envHome = ProcessInfo.processInfo.environment["CLAW_CONFIG_HOME"] {
            return envHome
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claw"
    }

    public func discover() -> [ConfigEntry] {
        var entries: [ConfigEntry] = []

        // User-level config
        let userSettings = "\(configHome)/settings.json"
        if FileManager.default.fileExists(atPath: userSettings) {
            entries.append(ConfigEntry(source: .user, path: userSettings))
        }

        // Project-level config
        let projectSettings = "\(cwd)/.claw/settings.json"
        if FileManager.default.fileExists(atPath: projectSettings) {
            entries.append(ConfigEntry(source: .project, path: projectSettings))
        }

        // Local overrides
        let localSettings = "\(cwd)/.claw/settings.local.json"
        if FileManager.default.fileExists(atPath: localSettings) {
            entries.append(ConfigEntry(source: .local, path: localSettings))
        }

        return entries
    }

    public func load() -> RuntimeConfig {
        let entries = discover()
        var featureConfig = RuntimeFeatureConfig()

        for entry in entries {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let mode = json["permissionMode"] as? String {
                switch mode {
                case "read-only": featureConfig.permissionMode = .readOnly
                case "workspace-write": featureConfig.permissionMode = .workspaceWrite
                case "danger-full-access": featureConfig.permissionMode = .dangerFullAccess
                default: break
                }
            }
            if let model = json["model"] as? String {
                featureConfig.model = model
            }

            // Parse hooks configuration
            if let hooks = json["hooks"] as? [String: Any] {
                var preToolUse: [String] = []
                var postToolUse: [String] = []

                if let pre = hooks["preToolUse"] as? [String] {
                    preToolUse.append(contentsOf: pre)
                } else if let pre = hooks["preToolUse"] as? String {
                    preToolUse.append(pre)
                }

                if let post = hooks["postToolUse"] as? [String] {
                    postToolUse.append(contentsOf: post)
                } else if let post = hooks["postToolUse"] as? String {
                    postToolUse.append(post)
                }

                if !preToolUse.isEmpty || !postToolUse.isEmpty {
                    featureConfig.hooks = HookConfig(preToolUse: preToolUse, postToolUse: postToolUse)
                }
            }
        }

        return RuntimeConfig(loadedEntries: entries, featureConfig: featureConfig)
    }
}
