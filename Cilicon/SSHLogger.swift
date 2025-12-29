import Foundation
import NIOCore

@MainActor
final class SSHLogger: ObservableObject {
    static let shared = SSHLogger()

    static let maxLogChunks = 500
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init() { }

    @Published
    var logs: [LogChunk] = []

    var attributedLog: AttributedString {
        return ANSIParser.parse(combinedLog)
    }

    var combinedLog: String {
        var outString = String()
        for item in logs {
            outString.append(formattedLogLine(for: item) + "\n")
        }
        return outString
    }

    func formattedLogLine(for chunk: LogChunk) -> String {
        return "[\(Self.dateFormatter.string(from: chunk.timestamp))] \(chunk.text)"
    }

    func log(buffer: ByteBuffer) {
        log(string: String(buffer: buffer))
    }

    func log(string: String) {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedString.isEmpty else { return }

        let lines = trimmedString.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            logs.append(LogChunk(text: String(line)))
        }
        if logs.count > Self.maxLogChunks {
            // Drop the oldest log entries to keep only the most recent ones
            logs.removeFirst(logs.count - Self.maxLogChunks)
        }
    }

    struct LogChunk: Identifiable, Hashable {
        let id = UUID()
        let timestamp = Date()
        var text: String
    }
}