import Foundation

enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var intValue: Int? {
        if case .integer(let v) = self { return v }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .float(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .boolean(let v) = self { return v }
        return nil
    }
    var arrayValue: [TOMLValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    var tableValue: [String: TOMLValue]? {
        if case .table(let v) = self { return v }
        return nil
    }
}

struct TOMLError: Error, CustomStringConvertible, Equatable {
    let line: Int
    let message: String
    var description: String { "TOML line \(line): \(message)" }
}

enum TOMLParser {
    static func parse(_ source: String) throws -> [String: TOMLValue] {
        var impl = Parser(source)
        return try impl.parseDocument()
    }

    private enum TableOrigin {
        case implicitSuper
        case explicitHeader
        case dottedKey
        case inlineSealed
        case arrayElement
    }

    private final class TableNode {
        var entries: [String: Node] = [:]
        var origin: TableOrigin
        init(origin: TableOrigin) { self.origin = origin }
    }

    private enum Node {
        case scalar(TOMLValue)
        case arrayNodes([Node], isArrayOfTables: Bool)
        case table(TableNode)

        func toValue() -> TOMLValue {
            switch self {
            case .scalar(let v):
                return v
            case .arrayNodes(let items, _):
                return .array(items.map { $0.toValue() })
            case .table(let t):
                var out: [String: TOMLValue] = [:]
                for (k, v) in t.entries { out[k] = v.toValue() }
                return .table(out)
            }
        }
    }

    private struct Parser {
        let chars: [Character]
        var pos: Int = 0
        var line: Int = 1

        init(_ text: String) {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            var scalars = Array(normalized)
            if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
            self.chars = scalars
        }

        var isEOF: Bool { pos >= chars.count }
        func peek(_ offset: Int = 0) -> Character? {
            let idx = pos + offset
            return idx < chars.count ? chars[idx] : nil
        }

        mutating func advance(_ count: Int = 1) {
            for _ in 0..<count where pos < chars.count {
                if chars[pos] == "\n" { line += 1 }
                pos += 1
            }
        }

        mutating func skipHorizontalSpace() {
            while let c = peek(), c == " " || c == "\t" { advance() }
        }

        mutating func skipComment() throws {
            guard peek() == "#" else { return }
            advance()
            while let c = peek(), c != "\n" {
                for scalar in c.unicodeScalars {
                    if (scalar.value < 0x09) || (scalar.value > 0x0A && scalar.value < 0x20) || scalar.value == 0x7F {
                        throw TOMLError(line: line, message: "control character is not allowed in comment")
                    }
                }
                advance()
            }
        }

        mutating func skipTriviaAndNewlines() throws {
            while !isEOF {
                skipHorizontalSpace()
                if peek() == "#" {
                    try skipComment()
                } else if peek() == "\n" {
                    advance()
                } else {
                    break
                }
            }
        }

        mutating func expectLineEndOrEOF() throws {
            skipHorizontalSpace()
            if peek() == "#" { try skipComment() }
            if isEOF { return }
            if peek() == "\n" { advance(); return }
            throw TOMLError(line: line, message: "unexpected character '\(peek()!)' after statement")
        }

        mutating func parseDocument() throws -> [String: TOMLValue] {
            let root = TableNode(origin: .explicitHeader)
            var currentTable = root

            while true {
                try skipTriviaAndNewlines()
                if isEOF { break }

                if peek() == "[" {
                    if peek(1) == "[" {
                        let headerLine = line
                        advance(2)
                        let path = try parseKeyPath()
                        skipHorizontalSpace()
                        guard peek() == "]" && peek(1) == "]" else {
                            throw TOMLError(line: headerLine, message: "expected ']]' to close array of tables")
                        }
                        advance(2)
                        try expectLineEndOrEOF()
                        currentTable = try defineArrayOfTables(root: root, path: path, atLine: headerLine)
                    } else {
                        let headerLine = line
                        advance(1)
                        let path = try parseKeyPath()
                        skipHorizontalSpace()
                        guard peek() == "]" else {
                            throw TOMLError(line: headerLine, message: "expected ']' to close table header")
                        }
                        advance(1)
                        try expectLineEndOrEOF()
                        currentTable = try defineStandardTable(root: root, path: path, atLine: headerLine)
                    }
                } else {
                    let keyLine = line
                    let path = try parseKeyPath()
                    skipHorizontalSpace()
                    guard peek() == "=" else {
                        throw TOMLError(line: keyLine, message: "expected '=' after key '\(path.joined(separator: "."))'")
                    }
                    advance(1)
                    skipHorizontalSpace()
                    let valueNode = try parseValueNode()
                    try expectLineEndOrEOF()
                    try insertKeyValue(into: currentTable, path: path, value: valueNode, atLine: keyLine)
                }
            }

            guard case .table(let result) = Node.table(root).toValue() else { return [:] }
            return result
        }

        private func defineStandardTable(root: TableNode, path: [String], atLine: Int) throws -> TableNode {
            var cursor = root
            for i in 0..<(path.count - 1) {
                let seg = path[i]
                if let existing = cursor.entries[seg] {
                    switch existing {
                    case .table(let sub):
                        if sub.origin == .inlineSealed {
                            throw TOMLError(line: atLine, message: "cannot extend inline table '\(path.prefix(i + 1).joined(separator: "."))'")
                        }
                        cursor = sub
                    case .arrayNodes(let elements, isArrayOfTables: true):
                        guard case .table(let lastTable) = elements.last else {
                            throw TOMLError(line: atLine, message: "invalid array of tables '\(seg)'")
                        }
                        cursor = lastTable
                    default:
                        throw TOMLError(line: atLine, message: "key '\(path.prefix(i + 1).joined(separator: "."))' is already defined as a non-table")
                    }
                } else {
                    let sub = TableNode(origin: .implicitSuper)
                    cursor.entries[seg] = .table(sub)
                    cursor = sub
                }
            }
            let leaf = path.last!
            if let existing = cursor.entries[leaf] {
                switch existing {
                case .table(let sub) where sub.origin == .implicitSuper:
                    sub.origin = .explicitHeader
                    return sub
                default:
                    throw TOMLError(line: atLine, message: "duplicate table '[\(path.joined(separator: "."))]'")
                }
            } else {
                let sub = TableNode(origin: .explicitHeader)
                cursor.entries[leaf] = .table(sub)
                return sub
            }
        }

        private func defineArrayOfTables(root: TableNode, path: [String], atLine: Int) throws -> TableNode {
            var cursor = root
            for i in 0..<(path.count - 1) {
                let seg = path[i]
                if let existing = cursor.entries[seg] {
                    switch existing {
                    case .table(let sub):
                        if sub.origin == .inlineSealed {
                            throw TOMLError(line: atLine, message: "cannot extend inline table '\(path.prefix(i + 1).joined(separator: "."))'")
                        }
                        cursor = sub
                    case .arrayNodes(let elements, isArrayOfTables: true):
                        guard case .table(let lastTable) = elements.last else {
                            throw TOMLError(line: atLine, message: "invalid array of tables '\(seg)'")
                        }
                        cursor = lastTable
                    default:
                        throw TOMLError(line: atLine, message: "key '\(path.prefix(i + 1).joined(separator: "."))' conflicts with array of tables")
                    }
                } else {
                    let sub = TableNode(origin: .implicitSuper)
                    cursor.entries[seg] = .table(sub)
                    cursor = sub
                }
            }
            let leaf = path.last!
            let element = TableNode(origin: .arrayElement)
            if let existing = cursor.entries[leaf] {
                switch existing {
                case .arrayNodes(var items, isArrayOfTables: true):
                    items.append(.table(element))
                    cursor.entries[leaf] = .arrayNodes(items, isArrayOfTables: true)
                    return element
                default:
                    throw TOMLError(line: atLine, message: "key '\(path.joined(separator: "."))' was already defined as non-array-of-tables")
                }
            } else {
                cursor.entries[leaf] = .arrayNodes([.table(element)], isArrayOfTables: true)
                return element
            }
        }

        private func insertKeyValue(into base: TableNode, path: [String], value: Node, atLine: Int) throws {
            var cursor = base
            for i in 0..<(path.count - 1) {
                let seg = path[i]
                if let existing = cursor.entries[seg] {
                    switch existing {
                    case .table(let sub):
                        if sub.origin == .inlineSealed || sub.origin == .explicitHeader {
                            if sub.origin == .inlineSealed {
                                throw TOMLError(line: atLine, message: "cannot modify inline table '\(seg)'")
                            }
                            if base !== sub && sub.origin == .explicitHeader {
                                throw TOMLError(line: atLine, message: "cannot add dotted key to already defined table '\(seg)'")
                            }
                        }
                        cursor = sub
                    default:
                        throw TOMLError(line: atLine, message: "key '\(seg)' already defined as a value")
                    }
                } else {
                    let sub = TableNode(origin: .dottedKey)
                    cursor.entries[seg] = .table(sub)
                    cursor = sub
                }
            }
            let leaf = path.last!
            if cursor.entries[leaf] != nil {
                throw TOMLError(line: atLine, message: "duplicate key '\(path.joined(separator: "."))'")
            }
            cursor.entries[leaf] = value
        }

        mutating func parseKeyPath() throws -> [String] {
            var parts: [String] = []
            while true {
                skipHorizontalSpace()
                let seg = try parseSingleKey()
                parts.append(seg)
                skipHorizontalSpace()
                if peek() == "." {
                    advance()
                } else {
                    break
                }
            }
            if parts.isEmpty { throw TOMLError(line: line, message: "expected key") }
            return parts
        }

        mutating func parseSingleKey() throws -> String {
            guard let c = peek() else { throw TOMLError(line: line, message: "unexpected end of file while expecting key") }
            if c == "\"" {
                if peek(1) == "\"" && peek(2) == "\"" {
                    throw TOMLError(line: line, message: "multiline strings cannot be used as keys")
                }
                return try parseBasicString()
            }
            if c == "'" {
                if peek(1) == "'" && peek(2) == "'" {
                    throw TOMLError(line: line, message: "multiline strings cannot be used as keys")
                }
                return try parseLiteralString()
            }
            var key = ""
            while let ch = peek(), isBareKeyChar(ch) {
                key.append(ch)
                advance()
            }
            guard !key.isEmpty else {
                throw TOMLError(line: line, message: "invalid key starting with '\(c)'")
            }
            return key
        }

        private func isBareKeyChar(_ c: Character) -> Bool {
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }

        mutating func parseValueNode() throws -> Node {
            guard let c = peek() else {
                throw TOMLError(line: line, message: "expected value")
            }
            if c == "\"" {
                if peek(1) == "\"" && peek(2) == "\"" {
                    return .scalar(.string(try parseMultilineBasicString()))
                }
                return .scalar(.string(try parseBasicString()))
            }
            if c == "'" {
                if peek(1) == "'" && peek(2) == "'" {
                    return .scalar(.string(try parseMultilineLiteralString()))
                }
                return .scalar(.string(try parseLiteralString()))
            }
            if c == "[" {
                return try parseArrayNode()
            }
            if c == "{" {
                return try parseInlineTableNode()
            }
            return .scalar(try parseLiteralOrNumber())
        }

        mutating func parseBasicString() throws -> String {
            let startLine = line
            advance() // opening "
            var out = ""
            while let c = peek() {
                if c == "\"" {
                    advance()
                    return out
                }
                if c == "\n" {
                    throw TOMLError(line: startLine, message: "unterminated string literal")
                }
                if c == "\\" {
                    advance()
                    out.append(try parseEscapeSequence())
                } else {
                    out.append(c)
                    advance()
                }
            }
            throw TOMLError(line: startLine, message: "unterminated string literal")
        }

        mutating func parseMultilineBasicString() throws -> String {
            let startLine = line
            advance(3) // """
            if peek() == "\n" { advance() }
            var out = ""
            while !isEOF {
                if peek() == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                    advance(3)
                    var extraQuotes = 0
                    while peek() == "\"" && extraQuotes < 2 {
                        out.append("\"")
                        advance()
                        extraQuotes += 1
                    }
                    return out
                }
                let c = peek()!
                if c == "\\" {
                    advance()
                    // Check line-ending backslash (trims whitespace + newlines)
                    var look = pos
                    while look < chars.count && (chars[look] == " " || chars[look] == "\t") { look += 1 }
                    if look < chars.count && chars[look] == "\n" {
                        while let ws = peek(), ws == " " || ws == "\t" || ws == "\n" { advance() }
                    } else {
                        out.append(try parseEscapeSequence())
                    }
                } else {
                    out.append(c)
                    advance()
                }
            }
            throw TOMLError(line: startLine, message: "unterminated multiline string")
        }

        mutating func parseEscapeSequence() throws -> Character {
            guard let esc = peek() else {
                throw TOMLError(line: line, message: "unterminated escape sequence")
            }
            advance()
            switch esc {
            case "b": return "\u{0008}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{000C}"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "u": return try parseUnicodeScalar(digits: 4)
            case "U": return try parseUnicodeScalar(digits: 8)
            default:
                throw TOMLError(line: line, message: "invalid escape sequence '\\\(esc)'")
            }
        }

        mutating func parseUnicodeScalar(digits: Int) throws -> Character {
            var hex = ""
            for _ in 0..<digits {
                guard let c = peek(), c.isHexDigit else {
                    throw TOMLError(line: line, message: "expected \(digits) hex digits in unicode escape")
                }
                hex.append(c)
                advance()
            }
            guard let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) else {
                throw TOMLError(line: line, message: "invalid unicode scalar U+\(hex)")
            }
            return Character(scalar)
        }

        mutating func parseLiteralString() throws -> String {
            let startLine = line
            advance() // '
            var out = ""
            while let c = peek() {
                if c == "'" {
                    advance()
                    return out
                }
                if c == "\n" {
                    throw TOMLError(line: startLine, message: "unterminated literal string")
                }
                out.append(c)
                advance()
            }
            throw TOMLError(line: startLine, message: "unterminated literal string")
        }

        mutating func parseMultilineLiteralString() throws -> String {
            let startLine = line
            advance(3) // '''
            if peek() == "\n" { advance() }
            var out = ""
            while !isEOF {
                if peek() == "'" && peek(1) == "'" && peek(2) == "'" {
                    advance(3)
                    var extra = 0
                    while peek() == "'" && extra < 2 {
                        out.append("'")
                        advance()
                        extra += 1
                    }
                    return out
                }
                out.append(peek()!)
                advance()
            }
            throw TOMLError(line: startLine, message: "unterminated multiline literal string")
        }

        mutating func parseArrayNode() throws -> Node {
            let startLine = line
            advance() // [
            var elements: [Node] = []
            while true {
                try skipTriviaAndNewlines()
                if peek() == "]" {
                    advance()
                    return .arrayNodes(elements, isArrayOfTables: false)
                }
                if isEOF {
                    throw TOMLError(line: startLine, message: "unterminated array")
                }
                elements.append(try parseValueNode())
                try skipTriviaAndNewlines()
                if peek() == "," {
                    advance()
                } else if peek() == "]" {
                    advance()
                    return .arrayNodes(elements, isArrayOfTables: false)
                } else {
                    throw TOMLError(line: line, message: "expected ',' or ']' in array")
                }
            }
        }

        mutating func parseInlineTableNode() throws -> Node {
            let startLine = line
            advance() // {
            let table = TableNode(origin: .explicitHeader)
            while true {
                try skipTriviaAndNewlines()
                if peek() == "}" {
                    advance()
                    sealInline(table)
                    return .table(table)
                }
                if isEOF {
                    throw TOMLError(line: startLine, message: "unterminated inline table")
                }
                let keyLine = line
                let path = try parseKeyPath()
                skipHorizontalSpace()
                guard peek() == "=" else {
                    throw TOMLError(line: keyLine, message: "expected '=' in inline table")
                }
                advance()
                skipHorizontalSpace()
                let val = try parseValueNode()
                try insertKeyValue(into: table, path: path, value: val, atLine: keyLine)
                try skipTriviaAndNewlines()
                if peek() == "," {
                    advance()
                } else if peek() == "}" {
                    advance()
                    sealInline(table)
                    return .table(table)
                } else {
                    throw TOMLError(line: line, message: "expected ',' or '}' in inline table")
                }
            }
        }

        private func sealInline(_ table: TableNode) {
            table.origin = .inlineSealed
            for value in table.entries.values {
                if case .table(let sub) = value { sealInline(sub) }
            }
        }

        mutating func parseLiteralOrNumber() throws -> TOMLValue {
            let tokenLine = line
            var raw = ""
            while let c = peek(), c != " " && c != "\t" && c != "\n" && c != "#" && c != "," && c != "]" && c != "}" {
                raw.append(c)
                advance()
            }
            guard !raw.isEmpty else {
                throw TOMLError(line: tokenLine, message: "expected value")
            }
            if raw == "true" { return .boolean(true) }
            if raw == "false" { return .boolean(false) }

            if raw.hasPrefix("0x") || raw.hasPrefix("0o") || raw.hasPrefix("0b") {
                let radix: Int = raw.hasPrefix("0x") ? 16 : (raw.hasPrefix("0o") ? 8 : 2)
                let body = String(raw.dropFirst(2))
                let digits = try stripUnderscores(body, radix: radix, line: tokenLine)
                guard let value = Int(digits, radix: radix) else {
                    throw TOMLError(line: tokenLine, message: "invalid integer '\(raw)'")
                }
                return .integer(value)
            }

            if raw.contains(".") || raw.contains("e") || raw.contains("E") {
                let cleaned = try cleanDecimalFloat(raw, line: tokenLine)
                guard let d = Double(cleaned), d.isFinite else {
                    throw TOMLError(line: tokenLine, message: "invalid float '\(raw)'")
                }
                return .float(d)
            }

            let cleaned = try cleanSignedDecimalInt(raw, line: tokenLine)
            guard let i = Int(cleaned) else {
                throw TOMLError(line: tokenLine, message: "invalid value '\(raw)'")
            }
            return .integer(i)
        }

        private func stripUnderscores(_ text: String, radix: Int, line: Int) throws -> String {
            guard !text.isEmpty, !text.hasPrefix("_"), !text.hasSuffix("_"), !text.contains("__") else {
                throw TOMLError(line: line, message: "invalid underscores in number '\(text)'")
            }
            let valid: (Character) -> Bool = { ch in
                switch radix {
                case 16: return ch.isHexDigit
                case 8: return ch >= "0" && ch <= "7"
                case 2: return ch == "0" || ch == "1"
                default: return ch >= "0" && ch <= "9"
                }
            }
            var out = ""
            let arr = Array(text)
            for idx in arr.indices {
                if arr[idx] == "_" {
                    guard idx > 0 && idx + 1 < arr.count && valid(arr[idx - 1]) && valid(arr[idx + 1]) else {
                        throw TOMLError(line: line, message: "invalid underscore placement in '\(text)'")
                    }
                } else if valid(arr[idx]) {
                    out.append(arr[idx])
                } else {
                    throw TOMLError(line: line, message: "invalid digit '\(arr[idx])' in number")
                }
            }
            return out
        }

        private func cleanSignedDecimalInt(_ text: String, line: Int) throws -> String {
            var rest = text[...]
            var sign = ""
            if rest.first == "+" || rest.first == "-" {
                sign = String(rest.removeFirst())
            }
            let digits = try stripUnderscores(String(rest), radix: 10, line: line)
            if digits.count > 1 && digits.hasPrefix("0") {
                throw TOMLError(line: line, message: "leading zeros are not allowed in integer '\(text)'")
            }
            return sign + digits
        }

        private func cleanDecimalFloat(_ text: String, line: Int) throws -> String {
            let expSplit = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
            guard expSplit.count <= 2 else {
                throw TOMLError(line: line, message: "invalid float '\(text)'")
            }
            let mantissa = String(expSplit[0])
            let dotSplit = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            guard dotSplit.count <= 2 else {
                throw TOMLError(line: line, message: "invalid float '\(text)'")
            }
            let intPart = try cleanSignedDecimalInt(String(dotSplit[0]), line: line)
            var result = intPart
            if dotSplit.count == 2 {
                let frac = try stripUnderscores(String(dotSplit[1]), radix: 10, line: line)
                result += "." + frac
            }
            if expSplit.count == 2 {
                var expRest = expSplit[1]
                var expSign = ""
                if expRest.first == "+" || expRest.first == "-" {
                    expSign = String(expRest.removeFirst())
                }
                let expDigits = try stripUnderscores(String(expRest), radix: 10, line: line)
                result += "e" + expSign + expDigits
            }
            return result
        }
    }
}

enum TOMLWriter {
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{0008}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{000C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    static func stringArray(_ items: [String]) -> String {
        "[" + items.map(quote).joined(separator: ", ") + "]"
    }

    static func formatFloat(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if rounded == rounded.rounded(), abs(rounded) < 1e12 {
            return String(format: "%.1f", rounded)
        }
        var text = String(format: "%.6f", rounded)
        while text.hasSuffix("0") && !text.hasSuffix(".0") {
            text.removeLast()
        }
        return text
    }
}
