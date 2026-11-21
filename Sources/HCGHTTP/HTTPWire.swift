import Foundation

/// HTTP/1.1 request parsing and response serialisation shared by the cleartext
/// socket server and the TLS server. One request per connection; no chunked bodies.
public enum HTTPWire {
    public enum ParseResult {
        case needMore
        case complete(HTTPRequest)
        case failure(status: Int, message: String)
    }

    public static func parse(_ data: Data, maxHeaderBytes: Int = 16 * 1024, maxBodyBytes: Int = 256 * 1024) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .failure(status: 413, message: "headers too large") : .needMore
        }
        guard end.lowerBound - data.startIndex <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .failure(status: 400, message: "malformed headers")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(status: 400, message: "malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(status: 400, message: "malformed header") }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil && (name == "content-length" || name.hasPrefix("x-hcg-")) {
                return .failure(status: 400, message: "duplicate \(name) header")
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .failure(status: 400, message: "transfer-encoding is not supported") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failure(status: 400, message: "bad content-length") }
        guard length <= maxBodyBytes else { return .failure(status: 413, message: "body too large") }
        let bodyStart = end.upperBound
        let available = data.endIndex - bodyStart
        if available < length { return .needMore }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
                query[key] = value
            }
        }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                     headers: headers, body: body, remoteAddress: ""))
    }

    public static func serialize(_ response: HTTPResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(response.status))\r\n"
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        headers["cache-control"] = headers["cache-control"] ?? "no-store"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        return out
    }

    public static func errorResponse(status: Int, message: String) -> HTTPResponse {
        let safe = message.replacingOccurrences(of: "\"", with: "'")
        return HTTPResponse.json(status, Data("{\"error\":{\"code\":\"bad_request\",\"message\":\"\(safe)\"}}".utf8))
    }
}

/// A listener for Connector traffic: the cleartext development server or the TLS server.
public protocol ConnectorServer: AnyObject {
    var port: UInt16 { get }
    @discardableResult func start() throws -> UInt16
    func stop()
}

extension HTTPServer: ConnectorServer {}
