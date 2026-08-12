//
//  Console.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation

/// Terminal output for the benchmark run.
///
/// A full run takes a long time, so progress is reported continuously rather than only at the end.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum Console {
    static func heading(_ text: String) {
        print("")
        print("━━━ \(text) " + String(repeating: "━", count: max(0, 72 - text.count)))
    }

    static func info(_ text: String) {
        print("  \(text)")
    }

    static func warn(_ text: String) {
        print("  ! \(text)")
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data("error: \(text)\n".utf8))
    }

    /// A single-line progress indicator that rewrites itself in place.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    final class Progress: @unchecked Sendable {
        private let total: Int
        private let label: String
        private let start: ContinuousClock.Instant
        private var lastRenderedAt: ContinuousClock.Instant
        private let isTerminal: Bool

        init(total: Int, label: String) {
            self.total = max(total, 1)
            self.label = label
            self.start = ContinuousClock().now
            self.lastRenderedAt = .now - .seconds(1)
            self.isTerminal = isatty(FileHandle.standardOutput.fileDescriptor) == 1
        }

        /// Updates the indicator. Rendering is throttled so the terminal is not the bottleneck.
        ///
        /// - Authored by: Claude Opus 5 (Anthropic)
        func advance(_ completed: Int, detail: String = "") {
            let now = ContinuousClock().now
            guard now - lastRenderedAt > .milliseconds(120) || completed >= total else { return }
            lastRenderedAt = now

            let fraction = Double(completed) / Double(total)
            let elapsed = (now - start).seconds
            let remaining = fraction > 0 ? elapsed / fraction - elapsed : 0

            let barWidth = 28
            let filled = Int(fraction * Double(barWidth))
            let bar = String(repeating: "█", count: min(filled, barWidth))
                + String(repeating: "░", count: max(0, barWidth - filled))

            let line = String(
                format: "  %@ [%@] %d/%d  %.0f%%  elapsed %@  eta %@ %@",
                label, bar, completed, total, fraction * 100,
                formatSeconds(elapsed), formatSeconds(remaining), detail
            )

            if isTerminal {
                print("\u{1B}[2K\r" + line, terminator: "")
                fflush(stdout)
            } else if completed >= total || completed % max(1, total / 20) == 0 {
                print(line)
            }
        }

        func finish() {
            if isTerminal {
                print("")
            }
        }
    }
}

/// Formats a duration in seconds as a compact human readable string.
///
/// - Authored by: Claude Opus 5 (Anthropic)
func formatSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    if seconds < 60 { return String(format: "%.0fs", seconds) }
    if seconds < 3_600 { return String(format: "%dm%02ds", Int(seconds) / 60, Int(seconds) % 60) }
    return String(format: "%dh%02dm", Int(seconds) / 3_600, (Int(seconds) % 3_600) / 60)
}

/// Renders a fixed-width text table.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct TextTable {
    let headers: [String]
    var rows: [[String]] = []

    mutating func append(_ row: [String]) {
        rows.append(row)
    }

    /// The table rendered with aligned columns, ready to print.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func rendered(indent: String = "  ") -> String {
        let widths = headers.indices.map { column in
            max(headers[column].count, rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0)
        }

        func format(_ row: [String]) -> String {
            let cells = headers.indices.map { column -> String in
                let value = row.indices.contains(column) ? row[column] : ""
                // Left align the first column, right align numeric columns.
                return column == 0
                    ? value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: max(0, widths[column] - value.count)) + value
            }
            return indent + cells.joined(separator: "  ")
        }

        var lines = [format(headers)]
        lines.append(indent + widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(format))
        return lines.joined(separator: "\n")
    }

    /// The same table as a GitHub-flavoured Markdown table.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    func markdown() -> String {
        var lines = ["| " + headers.joined(separator: " | ") + " |"]
        lines.append("|" + headers.map { _ in " --- " }.joined(separator: "|") + "|")
        for row in rows {
            let padded = headers.indices.map { row.indices.contains($0) ? row[$0] : "" }
            lines.append("| " + padded.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

/// Formats a double with a fixed number of decimals.
///
/// - Authored by: Claude Opus 5 (Anthropic)
func fixed(_ value: Double, _ decimals: Int = 2) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.\(decimals)f", value)
}
