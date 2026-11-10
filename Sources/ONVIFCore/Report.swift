import Foundation

/// A tree of "title: value" rows shown in the UI and exported as text.
public final class ReportNode {
    public var title: String
    public var value: String
    public var children: [ReportNode]
    public var isError: Bool

    public init(_ title: String, _ value: String = "", children: [ReportNode] = [], isError: Bool = false) {
        self.title = title
        self.value = value
        self.children = children
        self.isError = isError
    }

    @discardableResult
    public func add(_ title: String, _ value: String?) -> ReportNode {
        let node = ReportNode(title, (value?.isEmpty == false) ? value! : "—")
        children.append(node)
        return node
    }

    /// Adds a row only when the value is present.
    public func addIf(_ title: String, _ value: String?) {
        if let v = value, !v.isEmpty { children.append(ReportNode(title, v)) }
    }

    public func append(_ node: ReportNode) { children.append(node) }

    public func addError(_ error: Error, title: String = "Помилка") {
        children.append(ReportNode(title, describeError(error), isError: true))
    }

    /// Generic conversion of an XML element: attributes and child elements become rows.
    public static func fromXML(_ x: XNode, title: String? = nil) -> ReportNode {
        let node = ReportNode(title ?? x.name, x.isLeaf ? x.value : "")
        for (key, value) in x.attributes.sorted(by: { $0.key < $1.key }) {
            node.children.append(ReportNode(key, value))
        }
        for c in x.children { node.children.append(fromXML(c)) }
        return node
    }

    public func renderText(level: Int = 0) -> String {
        var line = String(repeating: "    ", count: level) + title
        if !value.isEmpty { line += ": " + value }
        var out = line + "\n"
        for c in children { out += c.renderText(level: level + 1) }
        return out
    }
}

public struct DeviceSummary {
    public var manufacturer: String
    public var model: String
    public var firmware: String
    public var serial: String
    public var hardwareId: String
}

public struct DeviceReport {
    public var sections: [ReportNode]
    public var summary: DeviceSummary?
    public var authFailed: Bool

    public var text: String { sections.map { $0.renderText() }.joined(separator: "\n") }
}
