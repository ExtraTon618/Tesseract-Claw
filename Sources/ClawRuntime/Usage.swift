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

// MARK: - Token Usage Extensions

extension TokenUsage {
    public func summaryLines(label: String) -> [String] {
        return [
            "\(label): total_tokens=\(totalTokens) input=\(inputTokens) output=\(outputTokens) cache_write=\(cacheCreationInputTokens) cache_read=\(cacheReadInputTokens)"
        ]
    }
}

// MARK: - Usage Tracker

public class UsageTracker: Equatable, Sendable {
    private var latestTurn: TokenUsage
    private var cumulative: TokenUsage
    private var _turns: UInt32

    public init() {
        self.latestTurn = TokenUsage()
        self.cumulative = TokenUsage()
        self._turns = 0
    }

    public static func fromSession(_ session: Session) -> UsageTracker {
        let tracker = UsageTracker()
        for message in session.messages {
            if let usage = message.usage {
                tracker.record(usage)
            }
        }
        return tracker
    }

    public func record(_ usage: TokenUsage) {
        latestTurn = usage
        cumulative.inputTokens += usage.inputTokens
        cumulative.outputTokens += usage.outputTokens
        cumulative.cacheCreationInputTokens += usage.cacheCreationInputTokens
        cumulative.cacheReadInputTokens += usage.cacheReadInputTokens
        _turns += 1
    }

    public var currentTurnUsage: TokenUsage { latestTurn }
    public var cumulativeUsage: TokenUsage { cumulative }
    public var turns: UInt32 { _turns }

    public static func == (lhs: UsageTracker, rhs: UsageTracker) -> Bool {
        lhs.latestTurn == rhs.latestTurn && lhs.cumulative == rhs.cumulative && lhs._turns == rhs._turns
    }
}
