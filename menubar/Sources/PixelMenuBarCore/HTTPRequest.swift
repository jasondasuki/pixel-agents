import Foundation

/// Hook body cap, same as MAX_HOOK_BODY_SIZE in server/src/constants.ts.
public let maxHookBodySize = 64 * 1024
/// Header block cap. Real hook requests have a handful of short headers.
let maxHeaderSize = 8 * 1024

public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    /// Lower-cased names.
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPParseResult: Equatable {
    case needMore
    case request(HTTPRequest)
    /// Reject with this status and stop reading.
    case reject(Int)
}

/// Minimal HTTP/1.1 request parser: request line, headers, Content-Length body.
/// Enough for the hook script's `http.request`; no chunked bodies, no pipelining.
public enum HTTPRequestParser {
    public static func parse(_ buffer: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderSize ? .reject(431) : .needMore
        }
        if headerEnd.lowerBound > maxHeaderSize { return .reject(431) }

        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .reject(400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .reject(400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil { return .reject(501) }

        var length = 0
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { return .reject(400) }
            length = parsed
        }
        if length > maxHookBodySize { return .reject(413) }

        let bodyStart = headerEnd.upperBound
        let available = buffer.endIndex - bodyStart
        if available < length { return .needMore }

        return .request(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: buffer[bodyStart..<(bodyStart + length)]
        ))
    }
}

public struct HookResponse: Equatable {
    public let status: Int
    public let hook: NormalizedHook?
}

/// Auth and routing for `POST /api/hooks/claude`, separate from the socket code so it can be tested.
public struct HookRequestHandler {
    public let token: String
    public static let path = "/api/hooks/claude"

    public init(token: String) { self.token = token }

    public func handle(_ request: HTTPRequest) -> HookResponse {
        guard request.path == Self.path else { return HookResponse(status: 404, hook: nil) }
        guard request.method == "POST" else { return HookResponse(status: 405, hook: nil) }
        guard bearerMatches(request.headers["authorization"]) else { return HookResponse(status: 401, hook: nil) }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HookResponse(status: 400, hook: nil)
        }
        // Valid but uninteresting events are still acknowledged.
        return HookResponse(status: 204, hook: normalizeHookEvent(json))
    }

    private func bearerMatches(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(Array(header.dropFirst(7).utf8), Array(token.utf8))
    }
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for i in 0..<max(a.count, b.count) {
        diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
    }
    return diff == 0
}

public func httpStatusLine(_ status: Int) -> String {
    let reason: String
    switch status {
    case 204: reason = "No Content"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 404: reason = "Not Found"
    case 405: reason = "Method Not Allowed"
    case 413: reason = "Payload Too Large"
    case 431: reason = "Request Header Fields Too Large"
    case 501: reason = "Not Implemented"
    default: reason = "Error"
    }
    return "HTTP/1.1 \(status) \(reason)"
}
