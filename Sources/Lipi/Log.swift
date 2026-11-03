import Foundation

/// Tiny append-only log in ~/Library/Logs/Lipi.log. Logs timings and lengths, never what you said.
enum Log {
    static var echo = false
    private static let queue = DispatchQueue(label: "lipi.log")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Lipi.log")
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Monotonic stopwatch in milliseconds.
struct Clock {
    private let start = DispatchTime.now().uptimeNanoseconds
    var ms: Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}
