import Foundation

/// Minimal namespace-agnostic XML DOM. Element and attribute names are stored
/// without prefixes, which is enough for reading ONVIF / SOAP responses.
public final class XNode {
    public let name: String
    public let qualifiedName: String
    public internal(set) var attributes: [String: String]
    public internal(set) var children: [XNode] = []
    public internal(set) var text: String = ""

    init(qualifiedName: String, attributes: [String: String]) {
        self.qualifiedName = qualifiedName
        self.name = XNode.localName(qualifiedName)
        var attrs: [String: String] = [:]
        for (key, value) in attributes where !key.hasPrefix("xmlns") {
            attrs[XNode.localName(key)] = value
        }
        self.attributes = attrs
    }

    static func localName(_ qualified: String) -> String {
        if let idx = qualified.lastIndex(of: ":") {
            return String(qualified[qualified.index(after: idx)...])
        }
        return qualified
    }

    /// Trimmed text content.
    public var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isLeaf: Bool { children.isEmpty }

    public func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    public func children(named name: String) -> [XNode] { children.filter { $0.name == name } }
    public func attr(_ name: String) -> String? { attributes[name] }

    public func at(_ path: String...) -> XNode? { at(path) }
    public func at(_ path: [String]) -> XNode? {
        var current: XNode? = self
        for component in path { current = current?.child(component) }
        return current
    }

    /// Non-empty trimmed text at the given child path, or nil.
    public func string(_ path: String...) -> String? {
        guard let node = at(path) else { return nil }
        let v = node.value
        return v.isEmpty ? nil : v
    }

    public func descendant(_ name: String) -> XNode? {
        for c in children {
            if c.name == name { return c }
            if let d = c.descendant(name) { return d }
        }
        return nil
    }

    public func descendants(_ name: String) -> [XNode] {
        var result: [XNode] = []
        for c in children {
            if c.name == name { result.append(c) }
            result.append(contentsOf: c.descendants(name))
        }
        return result
    }
}

public enum XMLTree {
    public static func parse(_ data: Data) throws -> XNode {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let ok = parser.parse()
        guard ok, let root = builder.root else {
            throw ONVIFError.parse(parser.parserError?.localizedDescription ?? "некоректний XML")
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XNode?
    var stack: [XNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XNode(qualifiedName: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(ch)
        }
    }
    return out
}
