import Foundation
import Darwin

public struct DiscoveredDevice {
    public var endpointReference: String
    public var types: [String]
    public var scopes: [String]
    public var xaddrs: [String]
    public var metadataVersion: String
    /// IPv4 address the ProbeMatch came from.
    public var sourceAddress: String

    /// True for ONVIF devices; filters out Windows PCs, printers and other WS-Discovery responders.
    public var isONVIF: Bool {
        types.contains { $0.contains("NetworkVideoTransmitter") || ($0.hasPrefix("tds") && $0.hasSuffix(":Device")) }
            || scopes.contains { $0.lowercased().hasPrefix("onvif://www.onvif.org/") }
    }

    public var name: String? { ONVIFScopes.values(scopes, key: "name").first }
    public var hardware: String? { ONVIFScopes.values(scopes, key: "hardware").first }
    public var locations: [String] { ONVIFScopes.values(scopes, key: "location") }
    public var profiles: [String] { ONVIFScopes.profiles(scopes) }

    /// Best device-service URL: same host as the responder, else the first IPv4 XAddr.
    public var serviceURL: URL? {
        let urls = xaddrs.compactMap { URL(string: $0) }
        if let same = urls.first(where: { $0.host == sourceAddress }) { return same }
        if let v4 = urls.first(where: { DeviceAddress.isIPv4($0.host ?? "") }) { return v4 }
        if let any = urls.first { return any }
        return URL(string: "http://\(sourceAddress)/onvif/device_service")
    }
}

public enum ONVIFScopes {
    private static let prefix = "onvif://www.onvif.org/"

    public static func values(_ scopes: [String], key: String) -> [String] {
        let p = (prefix + key + "/").lowercased()
        return scopes.compactMap { scope in
            guard scope.lowercased().hasPrefix(p) else { return nil }
            let raw = String(scope.dropFirst(p.count))
            return raw.removingPercentEncoding ?? raw
        }
    }

    /// ONVIF profile letters from scopes (`.../Profile/Streaming` is Profile S).
    public static func profiles(_ scopes: [String]) -> [String] {
        var result: [String] = []
        for v in values(scopes, key: "Profile") {
            let letter = v.lowercased() == "streaming" ? "S" : v
            if !result.contains(letter) { result.append(letter) }
        }
        return result
    }
}

public enum DeviceAddress {
    public static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Sort key that orders IPv4 addresses numerically.
    public static func sortKey(_ host: String) -> String {
        guard isIPv4(host) else { return "~" + host }
        return host.split(separator: ".").map { part -> String in
            var s = String(part)
            while s.count < 3 { s = "0" + s }
            return s
        }.joined(separator: ".")
    }

    /// Accepts "192.168.1.10", "192.168.1.10:8080" or a full device-service URL.
    public static func url(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://") { return URL(string: s) }
        return URL(string: "http://\(s)/onvif/device_service")
    }
}

/// WS-Discovery multicast probe (UDP 239.255.255.250:3702), sent on every active IPv4 interface.
public enum WSDiscovery {
    public static func probe(timeout: TimeInterval = 4) async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeBlocking(timeout: timeout))
            }
        }
    }

    static func probeMessage(types: String?) -> String {
        let typesElement = types.map { "<d:Types>\($0)</d:Types>" } ?? ""
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" "
            + "xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" "
            + "xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" "
            + "xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\" "
            + "xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\">"
            + "<e:Header>"
            + "<w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>"
            + "<w:To e:mustUnderstand=\"true\">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
            + "<w:Action e:mustUnderstand=\"true\">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
            + "</e:Header>"
            + "<e:Body><d:Probe>\(typesElement)</d:Probe></e:Body>"
            + "</e:Envelope>"
    }

    static func parseProbeMatches(_ data: Data, source: String) -> [DiscoveredDevice] {
        guard let root = try? XMLTree.parse(data) else { return [] }
        func split(_ s: String?) -> [String] {
            (s ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        }
        return root.descendants("ProbeMatch").map { m in
            DiscoveredDevice(
                endpointReference: m.string("EndpointReference", "Address") ?? "",
                types: split(m.string("Types")),
                scopes: split(m.string("Scopes")),
                xaddrs: split(m.string("XAddrs")),
                metadataVersion: m.string("MetadataVersion") ?? "",
                sourceAddress: source
            )
        }
    }

    static func localIPv4Interfaces() -> [in_addr] {
        var result: [in_addr] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            let flags = Int32(truncatingIfNeeded: ifa.ifa_flags)
            if let sa = ifa.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0,
               flags & IFF_LOOPBACK == 0,
               flags & IFF_MULTICAST != 0 {
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if !result.contains(where: { $0.s_addr == addr.s_addr }) { result.append(addr) }
            }
            cursor = ifa.ifa_next
        }
        return result
    }

    static func probeBlocking(timeout: TimeInterval) -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(3702).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")

        let interfaces = localIPv4Interfaces()

        func sendProbes() {
            let messages = [
                probeMessage(types: "dn:NetworkVideoTransmitter"),
                probeMessage(types: "tds:Device"),
                probeMessage(types: nil),
            ]
            let targets: [in_addr?] = interfaces.isEmpty ? [nil] : interfaces.map { Optional($0) }
            for target in targets {
                if var ifaceAddr = target {
                    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaceAddr, socklen_t(MemoryLayout<in_addr>.size))
                }
                for message in messages {
                    let bytes = Array(message.utf8)
                    _ = bytes.withUnsafeBytes { buffer in
                        withUnsafePointer(to: &dest) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, buffer.baseAddress, buffer.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
        }

        sendProbes()

        var found: [String: DiscoveredDevice] = [:]
        var order: [String] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let start = Date()
        var resent = false

        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= timeout { break }
            if !resent && elapsed >= 1.0 {
                sendProbes()  // UDP is lossy: probe a second time
                resent = true
            }
            let waitMs = Int32(max(10, min(250, (timeout - elapsed) * 1000)))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0 { usleep(10_000); continue }
            if ready == 0 { continue }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLength)
                    }
                }
            }
            if count <= 0 { continue }

            let source = String(cString: inet_ntoa(from.sin_addr))
            for device in parseProbeMatches(Data(buffer[0..<count]), source: source) where device.isONVIF {
                let key = device.endpointReference.isEmpty ? source : device.endpointReference
                if var existing = found[key] {
                    for x in device.xaddrs where !existing.xaddrs.contains(x) { existing.xaddrs.append(x) }
                    for s in device.scopes where !existing.scopes.contains(s) { existing.scopes.append(s) }
                    found[key] = existing
                } else {
                    found[key] = device
                    order.append(key)
                }
            }
        }
        return order.compactMap { found[$0] }
    }
}
