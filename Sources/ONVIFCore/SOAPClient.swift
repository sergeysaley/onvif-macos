import Foundation

public enum ONVIFNamespace {
    public static let soap = "http://www.w3.org/2003/05/soap-envelope"
    public static let schema = "http://www.onvif.org/ver10/schema"
    public static let device = "http://www.onvif.org/ver10/device/wsdl"
    public static let media = "http://www.onvif.org/ver10/media/wsdl"
    public static let media2 = "http://www.onvif.org/ver20/media/wsdl"
    public static let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
    public static let imaging = "http://www.onvif.org/ver20/imaging/wsdl"
    public static let events = "http://www.onvif.org/ver10/events/wsdl"
    public static let analytics = "http://www.onvif.org/ver20/analytics/wsdl"
    public static let deviceIO = "http://www.onvif.org/ver10/deviceIO/wsdl"
    public static let recording = "http://www.onvif.org/ver10/recording/wsdl"
    public static let search = "http://www.onvif.org/ver10/search/wsdl"
    public static let replay = "http://www.onvif.org/ver10/replay/wsdl"

    static let declarations: String = [
        ("s", soap),
        ("tt", schema),
        ("tds", device),
        ("trt", media),
        ("tr2", media2),
        ("tptz", ptz),
    ].map { "xmlns:\($0.0)=\"\($0.1)\"" }.joined(separator: " ")

    private static let friendly: [String: String] = [
        device: "Device",
        media: "Media",
        media2: "Media2",
        ptz: "PTZ",
        imaging: "Imaging",
        events: "Events",
        analytics: "Analytics",
        deviceIO: "DeviceIO",
        recording: "Recording",
        search: "Search",
        replay: "Replay",
        "http://www.onvif.org/ver10/receiver/wsdl": "Receiver",
        "http://www.onvif.org/ver10/display/wsdl": "Display",
        "http://www.onvif.org/ver10/analyticsdevice/wsdl": "AnalyticsDevice",
        "http://www.onvif.org/ver10/accesscontrol/wsdl": "AccessControl",
        "http://www.onvif.org/ver10/doorcontrol/wsdl": "DoorControl",
        "http://www.onvif.org/ver10/credential/wsdl": "Credential",
        "http://www.onvif.org/ver10/accessrules/wsdl": "AccessRules",
        "http://www.onvif.org/ver10/schedule/wsdl": "Schedule",
        "http://www.onvif.org/ver10/thermal/wsdl": "Thermal",
        "http://www.onvif.org/ver10/provisioning/wsdl": "Provisioning",
        "http://www.onvif.org/ver10/advancedsecurity/wsdl": "AdvancedSecurity",
        "http://www.onvif.org/ver10/uplink/wsdl": "Uplink",
        "http://www.onvif.org/ver10/appmgmt/wsdl": "AppManagement",
        "http://www.onvif.org/ver10/authenticationbehavior/wsdl": "AuthenticationBehavior",
    ]

    public static func friendlyName(_ ns: String) -> String {
        if let name = friendly[ns] { return name }
        // ".../verXX/<name>/wsdl" -> name
        let parts = ns.split(separator: "/")
        if parts.count >= 2, parts.last == "wsdl" { return String(parts[parts.count - 2]) }
        return ns
    }
}

/// SOAP 1.2 client with ONVIF authentication.
/// Tries WS-UsernameToken first, then HTTP Digest (+ WS-Security), then HTTP Digest alone,
/// and remembers the mode that worked.
public final class SOAPClient {
    public var credentials: Credentials?
    /// Device clock minus local clock, applied to WS-Security timestamps.
    public var timeOffset: TimeInterval = 0
    public let timeout: TimeInterval

    private enum AuthMode: Equatable { case wsse, httpAndWsse, http }
    private enum Outcome {
        case ok(XNode)
        case unauthorized(String)
    }

    private var learnedMode: AuthMode?
    private var challenge: HTTPAuthChallenge?
    private let session: URLSession

    public init(credentials: Credentials?, timeout: TimeInterval = 10) {
        self.credentials = credentials
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Sends a SOAP request and returns the first element inside `<Body>`.
    public func call(_ url: URL, action: String, body: String, authenticated: Bool = true) async throws -> XNode {
        guard authenticated, let creds = credentials, !creds.isEmpty else {
            switch try await perform(url, action: action, body: body, credentials: nil, mode: nil) {
            case .ok(let node): return node
            case .unauthorized(let message): throw ONVIFError.unauthorized(message)
            }
        }

        var modes: [AuthMode] = []
        if let learned = learnedMode { modes.append(learned) }
        for m in [AuthMode.wsse, .httpAndWsse, .http] where !modes.contains(m) { modes.append(m) }

        var lastMessage = ""
        var retriedFreshNonce = false
        var index = 0
        while index < modes.count {
            let mode = modes[index]
            if mode != .wsse && challenge == nil {
                index += 1
                continue
            }
            let challengeBefore = challenge
            switch try await perform(url, action: action, body: body, credentials: creds, mode: mode) {
            case .ok(let node):
                learnedMode = mode
                return node
            case .unauthorized(let message):
                lastMessage = message
                // A stale nonce produces a new challenge: retry the same HTTP mode once.
                if mode != .wsse, mode == learnedMode, !retriedFreshNonce,
                   let fresh = challenge, fresh !== challengeBefore {
                    retriedFreshNonce = true
                    continue
                }
                index += 1
            }
        }
        throw ONVIFError.unauthorized(lastMessage)
    }

    private func perform(_ url: URL, action: String, body: String,
                         credentials creds: Credentials?, mode: AuthMode?) async throws -> Outcome {
        var header = ""
        if let c = creds, mode == .wsse || mode == .httpAndWsse {
            header = WSSecurity.header(credentials: c, date: Date().addingTimeInterval(timeOffset))
        }
        let envelope = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<s:Envelope \(ONVIFNamespace.declarations)>"
            + (header.isEmpty ? "" : "<s:Header>\(header)</s:Header>")
            + "<s:Body>\(body)</s:Body></s:Envelope>"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)
        if let c = creds, mode == .http || mode == .httpAndWsse, let ch = challenge {
            request.setValue(ch.authorization(method: "POST", uri: SOAPClient.requestURI(url), credentials: c),
                             forHTTPHeaderField: "Authorization")
        }

        let (data, http) = try await send(request)

        if http.statusCode == 401 {
            if let value = http.value(forHTTPHeaderField: "WWW-Authenticate"),
               let parsed = HTTPAuthChallenge.parse(value) {
                challenge = parsed
            }
            return .unauthorized("HTTP 401")
        }

        let success = (200..<300).contains(http.statusCode)
        let root: XNode
        do {
            root = try XMLTree.parse(data)
        } catch {
            if success { throw error }
            throw ONVIFError.http(http.statusCode, SOAPClient.snippet(data))
        }
        guard root.name == "Envelope", let bodyNode = root.child("Body") else {
            if success { throw ONVIFError.parse("немає SOAP Envelope/Body") }
            throw ONVIFError.http(http.statusCode, SOAPClient.snippet(data))
        }
        if let first = bodyNode.children.first, first.name == "Fault" {
            let fault = SOAPClient.parseFault(first)
            if SOAPClient.isAuthFault(fault) {
                return .unauthorized(fault.errorDescription ?? "NotAuthorized")
            }
            throw fault
        }
        guard success else { throw ONVIFError.http(http.statusCode, SOAPClient.snippet(data)) }
        return .ok(bodyNode.children.first ?? bodyNode)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: ONVIFError.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ONVIFError.transport("немає HTTP-відповіді"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    static func requestURI(_ url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? ""
        if path.isEmpty { path = "/" }
        if let query = comps?.percentEncodedQuery { path += "?" + query }
        return path
    }

    static func snippet(_ data: Data) -> String {
        let s = String(decoding: data.prefix(300), as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseFault(_ fault: XNode) -> ONVIFError {
        var codes: [String] = []
        if let v = fault.string("Code", "Value") { codes.append(v) }
        var sub = fault.at("Code", "Subcode")
        while let s = sub {
            if let v = s.string("Value") { codes.append(v) }
            sub = s.child("Subcode")
        }
        if let v = fault.string("faultcode") { codes.append(v) }  // SOAP 1.1
        let reason = fault.string("Reason", "Text") ?? fault.string("faultstring") ?? ""
        return .fault(code: codes.map { XNode.localName($0) }.joined(separator: " / "), reason: reason)
    }

    static func isAuthFault(_ error: ONVIFError) -> Bool {
        guard case .fault(let code, let reason) = error else { return false }
        let s = (code + " " + reason).lowercased()
        return s.contains("notauthorized")
            || s.contains("not authorized")
            || s.contains("failedauthentication")
            || s.contains("unauthorized")
            || s.contains("authority failure")
            || s.contains("authentication fail")
    }
}
