import Foundation

/// Push messages when a job ends: an ntfy topic (`ntfy://my-topic`, `https://ntfy.sh/my-topic`) or any webhook that accepts JSON.
public enum RemoteNotification {
    /// A message is only sent for jobs that ran at least `minMinutes` (0 = always).
    public static func shouldSend(seconds: Double, minMinutes: Double) -> Bool { seconds >= minMinutes * 60 }

    public struct Message: Equatable {
        public var title: String
        public var body: String
        public var failed: Bool
        public init(title: String, body: String, failed: Bool) { self.title = title; self.body = body; self.failed = failed }
    }

    /// `includeName` is false by default so that file names never leave the Mac unless the person wants it.
    public static func message(jobName: String, seconds: Double, aborted: Bool, errors: Int, includeName: Bool, duration: String,
                               finishedTitle: String, stoppedTitle: String, errorsText: String) -> Message {
        let failed = aborted || errors > 0
        let title = aborted ? stoppedTitle : finishedTitle
        var body = includeName ? "\(jobName) · \(duration)" : duration
        if errors > 0 { body += " · " + errorsText }
        return Message(title: title, body: body, failed: failed)
    }

    /// HTTP headers are ASCII. Text with other letters (ń, ž, ü, 日本語…) would be damaged or dropped on the way, so it is sent
    /// as an RFC 2047 encoded word, which ntfy decodes. The title is also cut to one line.
    static func headerSafe(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first.map { String($0.prefix(120)) } ?? ""
        if line.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return line }
        return "=?UTF-8?B?" + Data(line.utf8).base64EncodedString() + "?="
    }

    /// The HTTP request for a message, or nil when the address is not usable.
    public static func request(address: String, message: Message) -> URLRequest? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var ntfy = false
        if s.lowercased().hasPrefix("ntfy://") { s = "https://ntfy.sh/" + s.dropFirst(7); ntfy = true }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        if host.contains("ntfy") { ntfy = true }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        if ntfy {
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue(headerSafe(message.title), forHTTPHeaderField: "Title")
            req.setValue(message.failed ? "high" : "default", forHTTPHeaderField: "Priority")
            req.setValue(message.failed ? "warning" : "white_check_mark", forHTTPHeaderField: "Tags")
            req.httpBody = Data(message.body.utf8)
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let text = message.title + ": " + message.body
            let json: [String: Any] = ["title": message.title, "message": message.body, "text": text, "content": text]
            req.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return req
    }
}

/// The text for the Dock icon while a job runs.
public enum DockProgressText {
    /// "63%" (or "63% · 12 min").
    public static func label(progress: Double, remainingSeconds: Double?) -> String {
        let p = Int((min(1, max(0, progress)) * 100).rounded())
        guard let r = remainingSeconds, r >= 60 else { return "\(p)%" }
        let m = Int((r / 60).rounded(.up))
        return m >= 120 ? "\(p)% · \(m / 60) h" : "\(p)% · \(m) min"
    }
}
