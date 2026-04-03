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

// MARK: - Todo Item

public struct TodoItem: Equatable, Sendable {
    public let id: String
    public var title: String
    public var status: TodoStatus
    public var description: String

    public init(id: String, title: String, status: TodoStatus = .pending, description: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.description = description
    }

    public var statusIcon: String {
        switch status {
        case .pending: return "[ ]"
        case .inProgress: return "[~]"
        case .completed: return "[x]"
        }
    }
}

public enum TodoStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

// MARK: - Todo Manager

/// Task list manager with optional file persistence.
/// When a store path is set, todos are saved to `.claw-todos.json`.
public class TodoManager: @unchecked Sendable {
    private var items: [TodoItem] = []
    private var nextId: Int = 1
    private let storePath: String?

    public init(cwd: String? = nil) {
        if let cwd = cwd {
            let envPath = ProcessInfo.processInfo.environment["CLAW_TODO_STORE"]
            self.storePath = envPath ?? "\(cwd)/.claw-todos.json"
        } else {
            self.storePath = nil
        }
        loadFromDisk()
    }

    public func execute(action: String, json: [String: Any]?) throws -> String {
        let oldTodos = list()

        let result: String
        switch action {
        case "add":
            let title = json?["title"] as? String ?? ""
            guard !title.isEmpty else { throw ToolError("todo add requires a 'title'") }
            let description = json?["description"] as? String ?? ""
            result = add(title: title, description: description)

        case "update":
            let id = json?["id"] as? String ?? ""
            guard !id.isEmpty else { throw ToolError("todo update requires an 'id'") }
            let status = json?["status"] as? String
            let title = json?["title"] as? String
            result = try update(id: id, status: status, title: title)

        case "delete":
            let id = json?["id"] as? String ?? ""
            guard !id.isEmpty else { throw ToolError("todo delete requires an 'id'") }
            result = try delete(id: id)

        case "list":
            result = list()
            return result  // no mutation, skip save

        default:
            throw ToolError("Unknown todo action: '\(action)'. Use: add, update, delete, list")
        }

        saveToDisk()

        // Check if all items completed — suggest verification
        var output = result
        if !oldTodos.isEmpty && items.count >= 3 && items.allSatisfy({ $0.status == .completed }) {
            output += "\n\nAll \(items.count) tasks completed. Consider verifying the results before moving on."
            // Auto-cleanup: clear completed file
            items.removeAll()
            saveToDisk()
        }

        return output
    }

    private func add(title: String, description: String) -> String {
        let id = "todo-\(nextId)"
        nextId += 1
        let item = TodoItem(id: id, title: title, description: description)
        items.append(item)
        return "Created task \(id): \(title)"
    }

    private func update(id: String, status: String?, title: String?) throws -> String {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw ToolError("Todo item '\(id)' not found")
        }
        if let status = status {
            guard let parsed = TodoStatus(rawValue: status) else {
                throw ToolError("Invalid status '\(status)'. Use: pending, in_progress, completed")
            }
            items[index].status = parsed
        }
        if let title = title {
            items[index].title = title
        }
        return "Updated \(id): \(items[index].statusIcon) \(items[index].title)"
    }

    private func delete(id: String) throws -> String {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw ToolError("Todo item '\(id)' not found")
        }
        let removed = items.remove(at: index)
        return "Deleted \(removed.id): \(removed.title)"
    }

    private func list() -> String {
        if items.isEmpty { return "No tasks." }
        return items.map { item in
            var line = "\(item.statusIcon) \(item.id): \(item.title)"
            if !item.description.isEmpty {
                line += "\n    \(item.description)"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let path = storePath else { return }
        if items.isEmpty {
            // Clean up empty todo file
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let data: [[String: String]] = items.map { item in
            [
                "id": item.id,
                "title": item.title,
                "status": item.status.rawValue,
                "description": item.description
            ]
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: ["nextId": nextId, "items": data], options: .prettyPrinted) {
            try? jsonData.write(to: URL(fileURLWithPath: path))
        }
    }

    private func loadFromDisk() {
        guard let path = storePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let savedNextId = json["nextId"] as? Int {
            nextId = savedNextId
        }
        if let savedItems = json["items"] as? [[String: String]] {
            items = savedItems.compactMap { dict in
                guard let id = dict["id"], let title = dict["title"] else { return nil }
                let status = TodoStatus(rawValue: dict["status"] ?? "pending") ?? .pending
                return TodoItem(id: id, title: title, status: status, description: dict["description"] ?? "")
            }
        }
    }
}
