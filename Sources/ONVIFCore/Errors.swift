import Foundation

public enum ONVIFError: Error, LocalizedError {
    case transport(String)
    case http(Int, String)
    case fault(code: String, reason: String)
    case unauthorized(String)
    case parse(String)
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let m): return "Мережева помилка: \(m)"
        case .http(let code, let m): return "HTTP \(code)" + (m.isEmpty ? "" : ": \(m)")
        case .fault(let code, let reason): return "SOAP Fault \(code)" + (reason.isEmpty ? "" : ": \(reason)")
        case .unauthorized(let m): return "Помилка авторизації" + (m.isEmpty ? "" : " (\(m))")
        case .parse(let m): return "Некоректна відповідь: \(m)"
        case .notSupported(let m): return "Не підтримується: \(m)"
        }
    }

    public var isAuthError: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

public func describeError(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return error.localizedDescription
}
