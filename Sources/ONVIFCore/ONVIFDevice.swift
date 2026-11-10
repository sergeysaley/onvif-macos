import Foundation

public final class ONVIFDevice {
    public let deviceURL: URL
    public let client: SOAPClient
    /// Service namespace -> service endpoint.
    public private(set) var serviceURLs: [String: URL] = [:]

    public init(url: URL, credentials: Credentials?, timeout: TimeInterval = 10) {
        deviceURL = url
        client = SOAPClient(credentials: credentials, timeout: timeout)
    }

    public func has(_ namespace: String) -> Bool { serviceURLs[namespace] != nil }

    /// Registers a service endpoint. Devices often report XAddrs with an address that is not
    /// reachable from here (wrong NIC, NAT), so the host is replaced with the one we connected to.
    public func registerService(_ namespace: String, xaddr: String, overwrite: Bool = true) {
        if !overwrite, serviceURLs[namespace] != nil { return }
        let trimmed = xaddr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), comps.host != nil else { return }
        if let deviceHost = deviceURL.host, comps.host != deviceHost {
            comps.host = deviceHost
            if let port = deviceURL.port { comps.port = port }
        }
        if let url = comps.url { serviceURLs[namespace] = url }
    }

    public func device(_ action: String, _ body: String, authenticated: Bool = true) async throws -> XNode {
        try await client.call(deviceURL, action: "\(ONVIFNamespace.device)/\(action)", body: body,
                              authenticated: authenticated)
    }

    public func service(_ namespace: String, _ action: String, _ body: String) async throws -> XNode {
        guard let url = serviceURLs[namespace] else {
            throw ONVIFError.notSupported(ONVIFNamespace.friendlyName(namespace))
        }
        return try await client.call(url, action: "\(namespace)/\(action)", body: body)
    }

    static func date(from node: XNode) -> Date? {
        guard let year = Int(node.string("Date", "Year") ?? ""),
              let month = Int(node.string("Date", "Month") ?? ""),
              let day = Int(node.string("Date", "Day") ?? ""),
              let hour = Int(node.string("Time", "Hour") ?? ""),
              let minute = Int(node.string("Time", "Minute") ?? ""),
              let second = Int(node.string("Time", "Second") ?? "") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        c.second = second
        return calendar.date(from: c)
    }
}
