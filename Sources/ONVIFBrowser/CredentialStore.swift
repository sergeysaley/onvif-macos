import Foundation
import Security
import ONVIFCore

/// Saves device credentials in the user's login keychain (generic passwords).
enum CredentialStore {
    private static let service = "local.onvifbrowser.credentials"

    private struct Stored: Codable {
        var username: String
        var password: String
    }

    /// Keys a device is stored under: its WS-Discovery endpoint (survives IP changes)
    /// and its host:port (works for manually added devices).
    static func keys(endpoint: String?, url: URL) -> [String] {
        var keys: [String] = []
        if let ep = endpoint, !ep.isEmpty { keys.append("endpoint:" + ep) }
        if let host = url.host {
            keys.append("host:" + host + (url.port.map { ":\($0)" } ?? ""))
        }
        return keys
    }

    static func load(keys: [String]) -> Credentials? {
        for key in keys {
            if let c = load(key) { return c }
        }
        return nil
    }

    static func save(_ credentials: Credentials, keys: [String]) {
        for key in keys { save(credentials, key) }
    }

    static func delete(keys: [String]) {
        for key in keys { SecItemDelete(baseQuery(key) as CFDictionary) }
    }

    /// Removes every password saved by this app.
    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // The file-based macOS keychain deletes one matching item per call.
        for _ in 0..<1000 {
            if SecItemDelete(query as CFDictionary) != errSecSuccess { break }
        }
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func load(_ key: String) -> Credentials? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return Credentials(username: stored.username, password: stored.password)
    }

    private static func save(_ credentials: Credentials, _ key: String) {
        guard let data = try? JSONEncoder().encode(Stored(username: credentials.username,
                                                          password: credentials.password)) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "ONVIF Browser (\(key))",
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(key)
            for (k, v) in attributes { item[k] = v }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// Devices added by address, restored on the next launch.
enum ManualDevices {
    private static let defaultsKey = "manualDevices"

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).compactMap { URL(string: $0) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if !list.contains(url.absoluteString) { list.append(url.absoluteString) }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }

    static func remove(_ url: URL) {
        let list = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).filter { $0 != url.absoluteString }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }
}
