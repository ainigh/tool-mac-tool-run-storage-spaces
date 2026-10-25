import Foundation

/// One HTTP request, as the API sees it (its body read whole: the API takes small JSON bodies).
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lowercased; repeated headers joined with ", ".
    public var headers: [String: String]
    public var body: Data
    /// The caller is on this machine.
    public var fromLoopback: Bool
    /// Where the caller is, as the server saw it ("127.0.0.1", "192.168.1.20").
    public var peer: String?

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data(),
                fromLoopback: Bool = true, peer: String? = nil) {
        self.method = method.uppercased()
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
        self.fromLoopback = fromLoopback
        self.peer = peer
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? "/"
        path = rawPath.removingPercentEncoding ?? rawPath
        query = parts.count > 1 ? Self.form(String(parts[1])) : [:]
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The media type, lowercased, without parameters ("application/json").
    public var contentType: String {
        (header("content-type") ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
    }

    /// a=1&b=two%20words → ["a": "1", "b": "two words"]
    public static func form(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (x: Substring) in String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
            guard let k = kv.first else { continue }
            out[decode(k)] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}

/// A request the API turns down: its status, a code a program can check, and a sentence.
public struct HTTPError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}

/// Reads one HTTP/1.1 request from bytes as they arrive.
public struct HTTPParser {
    public enum Outcome {
        /// More bytes are needed. `sendContinue`: the client asked to hear "100 Continue" before
        /// sending its body; say it once now.
        case more(sendContinue: Bool)
        case done(HTTPRequest)
    }

    public var maxHead = 64 * 1024
    /// Bodies are a script's name and its arguments, or a flow: a few megabytes is plenty.
    public var maxBody = 8 * 1024 * 1024
    public var fromLoopback = true
    public var peer: String?

    private enum Stage {
        case head
        case sized(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkEnd
        case trailers
        case done
    }

    private var stage = Stage.head
    private var buffer = Data()
    private var method = ""
    private var target = ""
    private var headers: [String: String] = [:]
    private var body = Data()

    public init() {}

    public mutating func feed(_ data: Data) throws -> Outcome {
        buffer.append(data)
        var sendContinue = false
        if case .head = stage {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > maxHead { throw HTTPError(status: 431, code: "bad_request", message: "headers too large") }
                return .more(sendContinue: false)
            }
            try parseHead(Data(buffer[buffer.startIndex..<end.lowerBound]))
            buffer = Data(buffer[end.upperBound...])
            if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
                stage = .chunkSize
            } else if let length = headers["content-length"] {
                guard let n = Int(length.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    throw HTTPError(status: 400, code: "bad_request", message: "bad Content-Length")
                }
                guard n <= maxBody else { throw tooLarge }
                stage = .sized(remaining: n)
            } else {
                stage = .sized(remaining: 0)
            }
            sendContinue = (headers["expect"] ?? "").lowercased() == "100-continue"
        }
        try advance()
        if case .done = stage {
            return .done(HTTPRequest(method: method, target: target, headers: headers, body: body,
                                     fromLoopback: fromLoopback, peer: peer))
        }
        return .more(sendContinue: sendContinue)
    }

    private var tooLarge: HTTPError {
        HTTPError(status: 413, code: "too_large", message: "the body is over \(maxBody / 1024 / 1024) MB")
    }

    private mutating func parseHead(_ head: Data) throws {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            throw HTTPError(status: 400, code: "bad_request", message: "unreadable request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { throw HTTPError(status: 400, code: "bad_request", message: "bad request line") }
        method = String(start[0]).uppercased()
        target = String(start[1])
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
    }

    private mutating func advance() throws {
        while true {
            switch stage {
            case .head, .done:
                return
            case .sized(let remaining):
                let take = min(remaining, buffer.count)
                if take > 0 {
                    body.append(buffer.prefix(take))
                    buffer = Data(buffer.dropFirst(take))
                }
                if remaining - take == 0 {
                    stage = .done
                } else {
                    stage = .sized(remaining: remaining - take)
                    return
                }
            case .chunkSize:
                guard let line = takeLine() else { return }
                let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else {
                    throw HTTPError(status: 400, code: "bad_request", message: "bad chunk")
                }
                guard size <= maxBody - body.count else { throw tooLarge }  // never body.count + size: a huge size overflows
                stage = size == 0 ? .trailers : .chunkData(remaining: size)
            case .chunkData(let remaining):
                let take = min(remaining, buffer.count)
                if take > 0 {
                    body.append(buffer.prefix(take))
                    buffer = Data(buffer.dropFirst(take))
                }
                if remaining - take == 0 {
                    stage = .chunkEnd
                } else {
                    stage = .chunkData(remaining: remaining - take)
                    return
                }
            case .chunkEnd:
                guard takeLine() != nil else { return }
                stage = .chunkSize
            case .trailers:
                guard let line = takeLine() else { return }
                if line.isEmpty { stage = .done }
            }
        }
    }

    /// The next line (without its CRLF), if a whole one has arrived.
    private mutating func takeLine() -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(data: Data(buffer[buffer.startIndex..<end.lowerBound]), encoding: .utf8) ?? ""
        buffer = Data(buffer[end.upperBound...])
        return line
    }
}

/// The client went away while a streamed response was being sent.
public struct WriterGone: Error {
    public init() {}
}

/// Where a streamed response's bytes go. `write` throws once the client has gone, which ends the
/// work making them.
public protocol ResponseWriter: AnyObject {
    func write(_ data: Data) async throws
}

public struct HTTPResponse {
    public enum Body {
        case data(Data)
        /// Sent as it's made (chunked).
        case stream((ResponseWriter) async throws -> Void)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int = 200, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int = 200, contentType: String, data: Data, headers: [(String, String)] = []) {
        self.init(status: status, headers: [("Content-Type", contentType)] + headers, body: .data(data))
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public var bodyData: Data? {
        if case .data(let d) = body { return d }
        return nil
    }

    /// The status line and headers (with Content-Length, or chunked for a stream). Every response
    /// closes the connection after it.
    public func head() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        for (k, v) in headers { lines.append("\(k): \(v)") }
        switch body {
        case .data(let d): lines.append("Content-Length: \(d.count)")
        case .stream: lines.append("Transfer-Encoding: chunked")
        }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// One piece of a chunked body.
    public static func chunk(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        return Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8)
    }

    public static let lastChunk = Data("0\r\n\r\n".utf8)

    public static let continueLine = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public enum JSON {
    /// Two decimals: 2.8134 → 2.81.
    public static func round(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }

    public static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    public static func response(_ object: Any, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", data: data(object), headers: headers)
    }

    /// One NDJSON line.
    public static func line(_ object: Any) -> Data {
        data(object) + Data("\n".utf8)
    }

    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A date as the API writes it: ISO 8601, with milliseconds.
    public static func date(_ d: Date) -> String {
        d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
