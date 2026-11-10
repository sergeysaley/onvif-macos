import Foundation
import CryptoKit

public struct Credentials: Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var isEmpty: Bool { username.isEmpty }
}

enum Hashing {
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { byte -> String in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    static func md5Hex(_ s: String) -> String { hex(Insecure.MD5.hash(data: Data(s.utf8))) }
    static func sha256Hex(_ s: String) -> String { hex(SHA256.hash(data: Data(s.utf8))) }
    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}

/// WS-Security UsernameToken with PasswordDigest (ONVIF Core spec, section 5.12).
enum WSSecurity {
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    /// Base64(SHA1(nonce + created + password))
    static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        var input = Data()
        input.append(nonce)
        input.append(Data(created.utf8))
        input.append(Data(password.utf8))
        return Hashing.sha1(input).base64EncodedString()
    }

    static func header(credentials c: Credentials, date: Date) -> String {
        let nonce = Hashing.randomBytes(16)
        let created = timestampFormatter.string(from: date)
        let digest = passwordDigest(nonce: nonce, created: created, password: c.password)
        return "<wsse:Security s:mustUnderstand=\"1\" "
            + "xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\" "
            + "xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">"
            + "<wsse:UsernameToken>"
            + "<wsse:Username>\(xmlEscape(c.username))</wsse:Username>"
            + "<wsse:Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">\(digest)</wsse:Password>"
            + "<wsse:Nonce EncodingType=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary\">\(nonce.base64EncodedString())</wsse:Nonce>"
            + "<wsu:Created>\(created)</wsu:Created>"
            + "</wsse:UsernameToken></wsse:Security>"
    }
}

/// HTTP authentication challenge (RFC 7616 Digest, with Basic as a fallback).
final class HTTPAuthChallenge {
    enum Scheme { case basic, digest }

    let scheme: Scheme
    let params: [String: String]
    private var nonceCount = 0

    init(scheme: Scheme, params: [String: String]) {
        self.scheme = scheme
        self.params = params
    }

    static func parse(_ header: String) -> HTTPAuthChallenge? {
        if let r = header.range(of: "Digest ", options: .caseInsensitive) {
            let params = parseParams(String(header[r.upperBound...]))
            if params["nonce"] != nil {
                return HTTPAuthChallenge(scheme: .digest, params: params)
            }
        }
        if let r = header.range(of: "Basic", options: .caseInsensitive) {
            return HTTPAuthChallenge(scheme: .basic, params: parseParams(String(header[r.upperBound...])))
        }
        return nil
    }

    static func parseParams(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\t" { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=", chars[i] != ",", chars[i] != " " {
                key.append(chars[i])
                i += 1
            }
            // A token without "=" starts the next auth scheme ("..., Basic realm=...").
            guard !key.isEmpty, i < chars.count, chars[i] == "=" else { break }
            i += 1
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    value.append(chars[i])
                    i += 1
                }
                i += 1
            } else {
                while i < chars.count, chars[i] != "," {
                    value.append(chars[i])
                    i += 1
                }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            result[key.lowercased()] = value
        }
        return result
    }

    func authorization(method: String, uri: String, credentials c: Credentials, cnonce fixedCnonce: String? = nil) -> String {
        switch scheme {
        case .basic:
            return "Basic " + Data("\(c.username):\(c.password)".utf8).base64EncodedString()
        case .digest:
            let realm = params["realm"] ?? ""
            let nonce = params["nonce"] ?? ""
            let algorithm = params["algorithm"]
            let alg = (algorithm ?? "MD5").uppercased()
            let hash: (String) -> String = alg.hasPrefix("SHA-256") ? Hashing.sha256Hex : Hashing.md5Hex
            let qopOptions = (params["qop"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let useQop = qopOptions.contains("auth")

            nonceCount += 1
            var nc = String(nonceCount, radix: 16)
            while nc.count < 8 { nc = "0" + nc }
            let cnonce = fixedCnonce ?? Hashing.hex(Hashing.randomBytes(8))

            var ha1 = hash("\(c.username):\(realm):\(c.password)")
            if alg.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(nonce):\(cnonce)") }
            let ha2 = hash("\(method):\(uri)")
            let response = useQop
                ? hash("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
                : hash("\(ha1):\(nonce):\(ha2)")

            var parts = [
                "username=\"\(c.username)\"",
                "realm=\"\(realm)\"",
                "nonce=\"\(nonce)\"",
                "uri=\"\(uri)\"",
            ]
            if let algorithm = algorithm { parts.append("algorithm=\(algorithm)") }
            parts.append("response=\"\(response)\"")
            if useQop { parts += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""] }
            if let opaque = params["opaque"] { parts.append("opaque=\"\(opaque)\"") }
            return "Digest " + parts.joined(separator: ", ")
        }
    }
}
