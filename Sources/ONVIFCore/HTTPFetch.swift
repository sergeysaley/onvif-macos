import Foundation

/// Plain HTTP GET with Basic/Digest authentication (used for snapshot URIs).
public enum HTTPFetch {
    public static func get(_ url: URL, credentials: Credentials?, timeout: TimeInterval = 10) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var (data, http) = try await send(session, request)

        if http.statusCode == 401, let c = credentials, !c.isEmpty,
           let header = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           let challenge = HTTPAuthChallenge.parse(header) {
            request.setValue(challenge.authorization(method: "GET", uri: SOAPClient.requestURI(url), credentials: c),
                             forHTTPHeaderField: "Authorization")
            (data, http) = try await send(session, request)
        }
        if http.statusCode == 401 { throw ONVIFError.unauthorized("HTTP 401") }
        guard (200..<300).contains(http.statusCode) else {
            throw ONVIFError.http(http.statusCode, SOAPClient.snippet(data))
        }
        return data
    }

    private static func send(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
}

public enum StreamURL {
    /// Inserts user:password into a stream URI (percent-encoded), unless it already has a user.
    public static func withCredentials(_ uri: String, _ credentials: Credentials?) -> URL? {
        guard var comps = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if let c = credentials, !c.isEmpty, comps.user == nil {
            comps.user = c.username
            comps.password = c.password
        }
        return comps.url
    }
}
