import OSLog

/// Where every log line goes, so tests can record them.
protocol LogSink: Sendable {
    /// Family names are public; `privateValues` (URLs with tokens) are logged private.
    func log(category: String, level: OSLogType, message: String, privateValues: [String])
}

/// The unified log, subsystem `WebFontKit`.
struct LoggerSink: LogSink {
    func log(category: String, level: OSLogType, message: String, privateValues: [String]) {
        let logger = Logger(subsystem: "WebFontKit", category: category)
        if privateValues.isEmpty {
            logger.log(level: level, "\(message, privacy: .public)")
        } else {
            let values = privateValues.joined(separator: " ")
            logger.log(level: level, "\(message, privacy: .public) \(values, privacy: .private)")
        }
    }
}

extension LogSink {
    func log(_ category: String, _ level: OSLogType, _ message: String, private values: [String] = []) {
        log(category: category, level: level, message: message, privateValues: values)
    }
}

extension LogSink where Self == LoggerSink {
    static var logger: LoggerSink { LoggerSink() }
}
