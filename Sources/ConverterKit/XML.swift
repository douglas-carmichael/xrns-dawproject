import Foundation

// MARK: - XML node (read + write)
//
// One small ordered XML tree used for both parsing and serialising, on every
// platform. There is deliberately no dependency on Foundation's XML
// (XMLDocument/XMLParser), which is unavailable/unreliable off Apple platforms —
// this is pure Swift.

public final class XML {
    public let name: String
    public private(set) var attributes: [(String, String)] = []
    public private(set) var children: [XML] = []
    public var text: String?

    public init(_ name: String) { self.name = name }

    // MARK: Building / writing

    /// Add an attribute. A nil value is skipped, so optional fields are easy to express.
    @discardableResult
    public func attr(_ key: String, _ value: String?) -> XML {
        if let value { attributes.append((key, value)) }
        return self
    }

    @discardableResult
    public func attr(_ key: String, _ value: Int) -> XML { attr(key, String(value)) }

    /// Append a child element and return it (for chaining into it).
    @discardableResult
    public func add(_ child: XML) -> XML { children.append(child); return child }

    /// Create + append a named child element, returning the new child.
    @discardableResult
    public func element(_ name: String) -> XML { add(XML(name)) }

    /// Create + append a leaf element carrying text, returning self (the parent).
    @discardableResult
    public func leaf(_ name: String, _ value: String?) -> XML {
        let e = XML(name)
        e.text = value
        children.append(e)
        return self
    }

    /// Serialise to a UTF-8 XML document.
    public func document(declaration: String) -> String {
        var out = declaration
        if !out.hasSuffix("\n") { out += "\n" }
        render(into: &out, indent: 0)
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private func render(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        out += pad + "<" + name
        for (k, v) in attributes {
            out += " \(k)=\"\(XML.escapeAttribute(v))\""
        }
        if children.isEmpty && (text == nil || text!.isEmpty) {
            out += "/>\n"
            return
        }
        if children.isEmpty, let text {
            out += ">" + XML.escapeText(text) + "</\(name)>\n"
            return
        }
        out += ">\n"
        for c in children { c.render(into: &out, indent: indent + 1) }
        out += pad + "</\(name)>\n"
    }

    static func escapeText(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.append(ch)
            }
        }
        return r
    }

    static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Reading helpers

    /// First direct child element with the given name.
    public func firstChild(_ name: String) -> XML? { children.first { $0.name == name } }

    /// All direct child elements with the given name.
    public func elements(forName name: String) -> [XML] { children.filter { $0.name == name } }

    /// All direct child elements.
    public var childElements: [XML] { children }

    /// Trimmed text content, or nil if empty/whitespace.
    public var trimmedText: String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    public func childText(_ name: String) -> String? { firstChild(name)?.trimmedText }
    public func childInt(_ name: String) -> Int? { childText(name).flatMap { Int($0) } }
    public func childDouble(_ name: String) -> Double? { childText(name).flatMap { Double($0) } }
    public func childBool(_ name: String) -> Bool? {
        guard let t = childText(name)?.lowercased() else { return nil }
        return t == "true" || t == "1"
    }

    public func attributeText(_ name: String) -> String? {
        for (k, v) in attributes where k == name { return v }
        return nil
    }

    // MARK: Parsing

    public enum ParseError: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self { case let .malformed(m): return "malformed XML: \(m)" }
        }
    }

    /// Parse a UTF-8 XML document into a node tree, returning the root element.
    public static func parse(_ data: Data) throws -> XML {
        var scanner = Scanner(Array(data))
        return try scanner.parse()
    }

    /// Decode the five predefined XML entities plus numeric character references.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].firstIndex(of: ";") {
                let entity = s[s.index(after: i)..<semi]
                switch entity {
                case "amp": out.append("&")
                case "lt": out.append("<")
                case "gt": out.append(">")
                case "quot": out.append("\"")
                case "apos": out.append("'")
                default:
                    if (entity.hasPrefix("#x") || entity.hasPrefix("#X")),
                       let code = UInt32(entity.dropFirst(2), radix: 16),
                       let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                    } else if entity.hasPrefix("#"),
                              let code = UInt32(entity.dropFirst(1)),
                              let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                    } else {
                        out.append("&"); out.append(contentsOf: entity); out.append(";")
                    }
                }
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}

// MARK: - Byte-level XML scanner

private struct Scanner {
    let b: [UInt8]
    let n: Int
    var i = 0

    private let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
    private let slash = UInt8(ascii: "/"), eq = UInt8(ascii: "=")
    private let q = UInt8(ascii: "?"), bang = UInt8(ascii: "!")

    init(_ bytes: [UInt8]) { b = bytes; n = bytes.count }

    mutating func parse() throws -> XML {
        var stack: [XML] = []
        var root: XML?

        while i < n {
            // Character data up to the next '<'.
            let textStart = i
            while i < n && b[i] != lt { i += 1 }
            if i > textStart, let current = stack.last {
                let raw = String(decoding: b[textStart..<i], as: UTF8.self)
                current.text = (current.text ?? "") + XML.decodeEntities(raw)
            }
            if i >= n { break }

            i += 1  // consume '<'
            guard i < n else { throw XML.ParseError.malformed("unexpected end after '<'") }

            if b[i] == q {                       // <? … ?>  (declaration / processing instruction)
                try skip(until: [q, gt])
            } else if b[i] == bang {             // <!-- --> | <![CDATA[ ]]> | <!DOCTYPE …>
                if matches("!--") {
                    i += 3; try skip(until: [0x2D, 0x2D, gt])           // -->
                } else if matches("![CDATA[") {
                    i += 8
                    let start = i
                    try skip(until: [0x5D, 0x5D, gt])                   // ]]>
                    if let current = stack.last {
                        current.text = (current.text ?? "") + String(decoding: b[start..<(i - 3)], as: UTF8.self)
                    }
                } else {
                    while i < n && b[i] != gt { i += 1 }
                    if i < n { i += 1 }
                }
            } else if b[i] == slash {            // closing tag </name>
                i += 1
                let name = readName()
                while i < n && b[i] != gt { i += 1 }
                if i < n { i += 1 }
                guard let top = stack.popLast() else {
                    throw XML.ParseError.malformed("unexpected </\(name)>")
                }
                guard top.name == name else {
                    throw XML.ParseError.malformed("mismatched tag </\(name)> (expected </\(top.name)>)")
                }
            } else {                             // opening tag <name …>
                let name = readName()
                let element = XML(name)
                try parseAttributes(into: element)
                skipSpaces()
                if i < n && b[i] == slash {      // self-closing
                    i += 1
                    if i < n && b[i] == gt { i += 1 }
                    if let parent = stack.last { parent.add(element) } else { root = element }
                } else if i < n && b[i] == gt {
                    i += 1
                    if let parent = stack.last { parent.add(element) } else { root = element }
                    stack.append(element)
                } else {
                    throw XML.ParseError.malformed("expected '>' in <\(name)>")
                }
            }
        }

        guard let root else { throw XML.ParseError.malformed("no root element") }
        return root
    }

    private mutating func parseAttributes(into element: XML) throws {
        while true {
            skipSpaces()
            guard i < n else { break }
            if b[i] == gt || b[i] == slash { break }
            let name = readName()
            if name.isEmpty { break }  // defensive: avoid spinning on unexpected input
            skipSpaces()
            guard i < n, b[i] == eq else {
                element.attr(name, "")
                continue
            }
            i += 1  // '='
            skipSpaces()
            guard i < n, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") else {
                throw XML.ParseError.malformed("expected quoted value for attribute '\(name)'")
            }
            let quote = b[i]; i += 1
            let start = i
            while i < n && b[i] != quote { i += 1 }
            let raw = String(decoding: b[start..<min(i, n)], as: UTF8.self)
            if i < n { i += 1 }  // closing quote
            element.attr(name, XML.decodeEntities(raw))
        }
    }

    private mutating func readName() -> String {
        let start = i
        while i < n {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == gt || c == slash || c == eq { break }
            i += 1
        }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    private mutating func skipSpaces() {
        while i < n, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    private func matches(_ ascii: String) -> Bool {
        let s = Array(ascii.utf8)
        guard i + s.count <= n else { return false }
        for k in 0..<s.count where b[i + k] != s[k] { return false }
        return true
    }

    private mutating func skip(until seq: [UInt8]) throws {
        while i + seq.count <= n {
            var hit = true
            for k in 0..<seq.count where b[i + k] != seq[k] { hit = false; break }
            if hit { i += seq.count; return }
            i += 1
        }
        throw XML.ParseError.malformed("unterminated section")
    }
}
