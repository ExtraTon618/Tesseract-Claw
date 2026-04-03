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

// MARK: - Notebook Editor

/// Reads and edits Jupyter notebook (.ipynb) cells.
/// Notebooks are JSON files with a `cells` array, each containing
/// `cell_type` (code/markdown/raw), `source` (array of lines), and `outputs`.

public struct NotebookCellInfo: Equatable, Sendable {
    public let index: Int
    public let cellType: String
    public let source: String
    public let outputPreview: String
}

public struct NotebookReadOutput: Equatable, Sendable {
    public let path: String
    public let cellCount: Int
    public let cells: [NotebookCellInfo]
}

/// Read a Jupyter notebook and return cell summaries.
public func notebookRead(path: String, cellIndex: Int? = nil) throws -> NotebookReadOutput {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cells = json["cells"] as? [[String: Any]] else {
        throw ToolError("Not a valid Jupyter notebook: \(path)")
    }

    var cellInfos: [NotebookCellInfo] = []

    let indices: [Int]
    if let idx = cellIndex {
        guard idx >= 0 && idx < cells.count else {
            throw ToolError("Cell index \(idx) out of range (0..\(cells.count - 1))")
        }
        indices = [idx]
    } else {
        indices = Array(0..<cells.count)
    }

    for i in indices {
        let cell = cells[i]
        let cellType = cell["cell_type"] as? String ?? "unknown"
        let source = extractCellSource(cell)
        let outputPreview = extractCellOutputPreview(cell)
        cellInfos.append(NotebookCellInfo(index: i, cellType: cellType, source: source, outputPreview: outputPreview))
    }

    return NotebookReadOutput(path: path, cellCount: cells.count, cells: cellInfos)
}

/// Edit a specific cell in a Jupyter notebook.
public func notebookEdit(path: String, cellIndex: Int, newSource: String, cellType: String? = nil) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var cells = json["cells"] as? [[String: Any]] else {
        throw ToolError("Not a valid Jupyter notebook: \(path)")
    }

    guard cellIndex >= 0 && cellIndex < cells.count else {
        throw ToolError("Cell index \(cellIndex) out of range (0..\(cells.count - 1))")
    }

    // Convert source string to array of lines (Jupyter format)
    let sourceLines = newSource.components(separatedBy: "\n").enumerated().map { (i, line) -> String in
        i < newSource.components(separatedBy: "\n").count - 1 ? line + "\n" : line
    }
    cells[cellIndex]["source"] = sourceLines

    if let cellType = cellType {
        cells[cellIndex]["cell_type"] = cellType
    }

    // Clear outputs for code cells when source changes
    if (cells[cellIndex]["cell_type"] as? String) == "code" {
        cells[cellIndex]["outputs"] = [] as [Any]
        cells[cellIndex]["execution_count"] = NSNull()
    }

    json["cells"] = cells

    let outputData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try outputData.write(to: URL(fileURLWithPath: path))

    return "Updated cell \(cellIndex) in \(path)"
}

/// Insert a new cell at the given index.
public func notebookInsertCell(path: String, atIndex: Int, source: String, cellType: String = "code") throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var cells = json["cells"] as? [[String: Any]] else {
        throw ToolError("Not a valid Jupyter notebook: \(path)")
    }

    let insertAt = min(max(atIndex, 0), cells.count)
    let sourceLines = source.components(separatedBy: "\n").enumerated().map { (i, line) -> String in
        i < source.components(separatedBy: "\n").count - 1 ? line + "\n" : line
    }

    var newCell: [String: Any] = [
        "cell_type": cellType,
        "source": sourceLines,
        "metadata": [:] as [String: Any]
    ]
    if cellType == "code" {
        newCell["outputs"] = [] as [Any]
        newCell["execution_count"] = NSNull()
    }

    cells.insert(newCell, at: insertAt)
    json["cells"] = cells

    let outputData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try outputData.write(to: URL(fileURLWithPath: path))

    return "Inserted \(cellType) cell at index \(insertAt) in \(path)"
}

// MARK: - Helpers

private func extractCellSource(_ cell: [String: Any]) -> String {
    if let sourceArray = cell["source"] as? [String] {
        return sourceArray.joined()
    }
    if let sourceStr = cell["source"] as? String {
        return sourceStr
    }
    return ""
}

private func extractCellOutputPreview(_ cell: [String: Any]) -> String {
    guard let outputs = cell["outputs"] as? [[String: Any]], !outputs.isEmpty else {
        return ""
    }

    var preview: [String] = []
    for output in outputs.prefix(3) {
        if let text = output["text"] as? [String] {
            preview.append(text.joined().prefix(200).description)
        } else if let data = output["data"] as? [String: Any] {
            if let text = data["text/plain"] as? [String] {
                preview.append(text.joined().prefix(200).description)
            } else {
                let keys = Array(data.keys)
                preview.append("[output: \(keys.joined(separator: ", "))]")
            }
        } else if let ename = output["ename"] as? String {
            let evalue = output["evalue"] as? String ?? ""
            preview.append("Error: \(ename): \(evalue.prefix(100))")
        }
    }
    if outputs.count > 3 {
        preview.append("[+\(outputs.count - 3) more outputs]")
    }
    return preview.joined(separator: "\n")
}
