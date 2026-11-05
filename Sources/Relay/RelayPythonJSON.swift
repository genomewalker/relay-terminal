import Foundation

/// Python's `json` value model, for decisions that must stay byte-identical to
/// the former Python policy (and to relayd's Go port of it): insertion-ordered
/// dicts, int versus float lexemes, unbounded integers, float repr, ensure_ascii
/// escaping, lone surrogates, equality, truthiness and repr. Any Python
/// exception on the original path is `RelayPythonJSON.Failure`.
enum RelayPythonJSON {
    struct Failure: Error {}

    /// A Python `str`: code points, including lone surrogates from `\uD800`.
    struct Text: Hashable {
        var codePoints: [UInt32]
        init(_ text: String) { codePoints = text.unicodeScalars.map(\.value) }
        init(codePoints: [UInt32]) { self.codePoints = codePoints }

        /// `len(text.encode("utf-8"))`; a lone surrogate raises.
        func utf8Count() throws -> Int {
            try codePoints.reduce(0) { total, point in
                if (0xD800...0xDFFF).contains(point) { throw Failure() }
                return total + (point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4)
            }
        }
    }

    /// A Python dict: first insertion fixes a key's position.
    struct Dict {
        private(set) var keys: [Text] = []
        private var values: [Text: Value] = [:]

        init(_ pairs: [(String, Value)] = []) {
            for (key, value) in pairs { self[key] = value }
        }
        func contains(_ key: String) -> Bool { values[Text(key)] != nil }
        subscript(key: Text) -> Value? {
            get { values[key] }
            set {
                guard let newValue else { return }
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            }
        }
        subscript(key: String) -> Value? {
            get { self[Text(key)] }
            set { self[Text(key)] = newValue }
        }
    }

    enum Value {
        case none
        case bool(Bool)
        case int(Int64)
        /// An integer outside Int64, as its canonical decimal lexeme.
        case bigInt(String)
        case float(Double)
        case string(Text)
        case list([Value])
        case dict(Dict)

        static func text(_ text: String) -> Value { .string(Text(text)) }

        /// `bool(value)`.
        var truthy: Bool {
            switch self {
            case .none: false
            case .bool(let value): value
            case .int(let value): value != 0
            case .bigInt: true
            case .float(let value): value != 0
            case .string(let value): !value.codePoints.isEmpty
            case .list(let value): !value.isEmpty
            case .dict(let value): !value.keys.isEmpty
            }
        }

        var isHashable: Bool {
            switch self {
            case .list, .dict: false
            default: true
            }
        }

        /// Python `==`; bool is an int subclass and int/float compare exactly.
        func equals(_ other: Value) -> Bool {
            switch (self, other) {
            case (.none, .none): return true
            case (.string(let a), .string(let b)): return a == b
            case (.list(let a), .list(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.equals($1) }
            case (.dict(let a), .dict(let b)):
                return a.keys.count == b.keys.count && a.keys.allSatisfy { key in
                    guard let left = a[key], let right = b[key] else { return false }
                    return left.equals(right)
                }
            default:
                guard let a = numeric, let b = other.numeric else { return false }
                switch (a, b) {
                case (.integer(let x), .integer(let y)): return x == y
                case (.real(let x), .real(let y)): return x == y
                case (.integer(let x), .real(let y)), (.real(let y), .integer(let x)):
                    return y.isFinite && y.rounded(.towardZero) == y && RelayPythonJSON.integerLexeme(y) == x
                }
            }
        }

        private enum Numeric { case integer(String), real(Double) }
        private var numeric: Numeric? {
            switch self {
            case .bool(let value): .integer(value ? "1" : "0")
            case .int(let value): .integer(String(value))
            case .bigInt(let value): .integer(value)
            case .float(let value): .real(value)
            default: nil
            }
        }
    }

    private final class DeepStackJob<T>: @unchecked Sendable {
        let body: () throws -> T
        var result: Result<T, Error>?
        init(_ body: @escaping () throws -> T) { self.body = body }
    }

    /// Runs `body` to completion on a thread whose stack holds `maximumDepth`
    /// levels of recursive parsing, comparison, formatting and release; a
    /// cooperative-pool thread's 512 KB does not.
    static func onDeepStack<T>(_ body: @escaping () throws -> T) throws -> T {
        let job = DeepStackJob(body)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            job.result = Result { try job.body() }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return try job.result!.get()
    }

    // MARK: json.loads

    /// `json.loads` of UTF-8 text read by Python's strict decoder.
    static func decode(_ data: Data) throws -> Value {
        var parser = Parser(points: try codePoints(utf8: data))
        guard parser.points.first != 0xFEFF else { throw Failure() }
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.points.count else { throw Failure() }
        return value
    }

    /// Strict UTF-8 as Python decodes it: no overlongs, surrogates or > U+10FFFF.
    static func codePoints(utf8 data: Data) throws -> [UInt32] {
        let bytes = [UInt8](data)
        var points: [UInt32] = []
        points.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 { points.append(UInt32(lead)); index += 1; continue }
            let length: Int, low: UInt8, high: UInt8
            switch lead {
            case 0xC2...0xDF: (length, low, high) = (2, 0x80, 0xBF)
            case 0xE0: (length, low, high) = (3, 0xA0, 0xBF)
            case 0xE1...0xEC, 0xEE...0xEF: (length, low, high) = (3, 0x80, 0xBF)
            case 0xED: (length, low, high) = (3, 0x80, 0x9F)
            case 0xF0: (length, low, high) = (4, 0x90, 0xBF)
            case 0xF1...0xF3: (length, low, high) = (4, 0x80, 0xBF)
            case 0xF4: (length, low, high) = (4, 0x80, 0x8F)
            default: throw Failure()
            }
            guard index + length <= bytes.count, (low...high).contains(bytes[index + 1]) else { throw Failure() }
            var point = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
            for offset in 1..<length {
                let byte = bytes[index + offset]
                guard offset == 1 || (0x80...0xBF).contains(byte) else { throw Failure() }
                point = point << 6 | UInt32(byte & 0x3F)
            }
            points.append(point)
            index += length
        }
        return points
    }

    /// CPython's C scanner (json/scanner.c, strict mode).
    private struct Parser {
        let points: [UInt32]
        var index = 0
        /// CPython raises RecursionError on deep nesting; refuse it as well.
        static let maximumDepth = 900

        init(points: [UInt32]) { self.points = points }

        mutating func skipWhitespace() {
            while index < points.count, [0x20, 0x09, 0x0A, 0x0D].contains(points[index]) { index += 1 }
        }

        func matches(_ literal: String) -> Bool {
            let scalars = literal.unicodeScalars.map(\.value)
            return index + scalars.count <= points.count && Array(points[index..<index + scalars.count]) == scalars
        }

        mutating func value(depth: Int) throws -> Value {
            guard depth < Self.maximumDepth, index < points.count else { throw Failure() }
            switch points[index] {
            case 0x22: return .string(try string())
            case 0x7B: return .dict(try object(depth: depth))
            case 0x5B: return .list(try array(depth: depth))
            default: break
            }
            for (literal, value) in [("null", Value.none), ("true", .bool(true)), ("false", .bool(false))]
            where matches(literal) {
                index += literal.unicodeScalars.count
                return value
            }
            if let number = try number() { return number }
            for (literal, value) in [("NaN", Double.nan), ("Infinity", .infinity), ("-Infinity", -.infinity)]
            where matches(literal) {
                index += literal.unicodeScalars.count
                return .float(value)
            }
            throw Failure()
        }

        mutating func object(depth: Int) throws -> Dict {
            var result = Dict()
            index += 1
            skipWhitespace()
            if index < points.count, points[index] == 0x7D { index += 1; return result }
            while true {
                guard index < points.count, points[index] == 0x22 else { throw Failure() }
                let key = try string()
                skipWhitespace()
                guard index < points.count, points[index] == 0x3A else { throw Failure() }
                index += 1
                skipWhitespace()
                result[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < points.count else { throw Failure() }
                if points[index] == 0x7D { index += 1; return result }
                guard points[index] == 0x2C else { throw Failure() }
                index += 1
                skipWhitespace()
            }
        }

        mutating func array(depth: Int) throws -> [Value] {
            var result: [Value] = []
            index += 1
            skipWhitespace()
            if index < points.count, points[index] == 0x5D { index += 1; return result }
            while true {
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < points.count else { throw Failure() }
                if points[index] == 0x5D { index += 1; return result }
                guard points[index] == 0x2C else { throw Failure() }
                index += 1
                skipWhitespace()
            }
        }

        func hex(at start: Int) throws -> UInt32 {
            guard start + 4 <= points.count else { throw Failure() }
            return try points[start..<start + 4].reduce(0) { value, point in
                switch point {
                case 0x30...0x39: return value << 4 | (point - 0x30)
                case 0x41...0x46: return value << 4 | (point - 0x37)
                case 0x61...0x66: return value << 4 | (point - 0x57)
                default: throw Failure()
                }
            }
        }

        mutating func string() throws -> Text {
            index += 1
            var result: [UInt32] = []
            while true {
                guard index < points.count else { throw Failure() }
                let point = points[index]
                if point == 0x22 { index += 1; return Text(codePoints: result) }
                guard point >= 0x20 else { throw Failure() }
                guard point == 0x5C else { result.append(point); index += 1; continue }
                guard index + 1 < points.count else { throw Failure() }
                let escape = points[index + 1]
                let simple: [UInt32: UInt32] = [0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08,
                                                0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09]
                if let replacement = simple[escape] { result.append(replacement); index += 2; continue }
                guard escape == 0x75 else { throw Failure() }
                var code = try hex(at: index + 2)
                index += 6
                if (0xD800...0xDBFF).contains(code), index + 6 < points.count, points[index] == 0x5C, points[index + 1] == 0x75 {
                    let low = try hex(at: index + 2)
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }
                }
                result.append(code)
            }
        }

        /// `_match_number_unicode`; nil when no number starts here.
        mutating func number() throws -> Value? {
            var end = index
            func digit(_ at: Int) -> Bool { at < points.count && (0x30...0x39).contains(points[at]) }
            if end < points.count, points[end] == 0x2D { end += 1 }
            guard end < points.count else { return nil }
            if (0x31...0x39).contains(points[end]) {
                end += 1
                while digit(end) { end += 1 }
            } else if points[end] == 0x30 {
                end += 1
            } else {
                return nil
            }
            var isFloat = false
            if end < points.count, points[end] == 0x2E, digit(end + 1) {
                isFloat = true
                end += 2
                while digit(end) { end += 1 }
            }
            if end < points.count, points[end] == 0x65 || points[end] == 0x45 {
                var exponent = end + 1
                if exponent < points.count, points[exponent] == 0x2B || points[exponent] == 0x2D { exponent += 1 }
                if digit(exponent) {
                    isFloat = true
                    end = exponent + 1
                    while digit(end) { end += 1 }
                }
            }
            let lexeme = String(decoding: points[index..<end].map { UInt8($0) }, as: UTF8.self)
            index = end
            if isFloat {
                guard let value = Double(lexeme) else { throw Failure() }
                return .float(value)
            }
            if let value = Int64(lexeme) { return .int(value) }
            // int() refuses more than 4300 digits (sys.int_info.default_max_str_digits).
            guard lexeme.utf8.count - (lexeme.hasPrefix("-") ? 1 : 0) <= 4300 else { throw Failure() }
            return .bigInt(lexeme)
        }
    }

    // MARK: json.dumps (ensure_ascii)

    static func dumps(_ value: Value, sortKeys: Bool = false,
                      itemSeparator: String = ", ", keySeparator: String = ": ") -> String {
        var output = ""
        encode(value, into: &output, sortKeys: sortKeys, itemSeparator: itemSeparator, keySeparator: keySeparator)
        return output
    }

    private static func encode(_ value: Value, into output: inout String, sortKeys: Bool,
                               itemSeparator: String, keySeparator: String) {
        switch value {
        case .none: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .int(let number): output += String(number)
        case .bigInt(let lexeme): output += lexeme
        case .float(let number):
            output += number.isNaN ? "NaN" : number == .infinity ? "Infinity" : number == -.infinity ? "-Infinity" : floatRepr(number)
        case .string(let text): output += quoted(text)
        case .list(let items):
            output += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { output += itemSeparator }
                encode(item, into: &output, sortKeys: sortKeys, itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            output += "]"
        case .dict(let dict):
            let keys = sortKeys ? dict.keys.sorted { $0.codePoints.lexicographicallyPrecedes($1.codePoints) } : dict.keys
            output += "{"
            for (offset, key) in keys.enumerated() {
                if offset > 0 { output += itemSeparator }
                output += quoted(key) + keySeparator
                encode(dict[key] ?? .none, into: &output, sortKeys: sortKeys,
                       itemSeparator: itemSeparator, keySeparator: keySeparator)
            }
            output += "}"
        }
    }

    /// `py_encode_basestring_ascii`.
    static func quoted(_ text: Text) -> String {
        var output = "\""
        func escape(_ unit: UInt32) { output += "\\u" + String(format: "%04x", unit) }
        for point in text.codePoints {
            switch point {
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x09: output += "\\t"
            case 0x08: output += "\\b"
            case 0x0C: output += "\\f"
            case 0x20...0x7E: output.unicodeScalars.append(Unicode.Scalar(point)!)
            case 0x10000...:
                let offset = point - 0x10000
                escape(0xD800 + (offset >> 10)); escape(0xDC00 + (offset & 0x3FF))
            default: escape(point)
            }
        }
        return output + "\""
    }

    /// `float.__repr__` for a finite value: shortest round-trip digits,
    /// positional for 1e-4 <= |x| < 1e16, otherwise a two-digit exponent.
    static func floatRepr(_ number: Double) -> String {
        if number.isNaN { return "nan" }
        if number.isInfinite { return number < 0 ? "-inf" : "inf" }
        let sign = number.sign == .minus ? "-" : ""
        let magnitude = abs(number)
        if magnitude == 0 { return sign + "0.0" }
        let (digits, decimalPoint) = shortestDigits(magnitude)
        if decimalPoint > -4 && decimalPoint <= 16 {
            if decimalPoint <= 0 { return sign + "0." + String(repeating: "0", count: -decimalPoint) + digits }
            if decimalPoint >= digits.count {
                return sign + digits + String(repeating: "0", count: decimalPoint - digits.count) + ".0"
            }
            return sign + digits.prefix(decimalPoint) + "." + digits.dropFirst(decimalPoint)
        }
        var mantissa = String(digits.prefix(1))
        if digits.count > 1 { mantissa += "." + digits.dropFirst() }
        let exponent = decimalPoint - 1
        let written = String(abs(exponent))
        return sign + mantissa + "e" + (exponent < 0 ? "-" : "+") + (written.count < 2 ? "0" + written : written)
    }

    /// Shortest round-trip significant digits and the decimal point position:
    /// value = 0.digits x 10^decimalPoint. Swift's description is shortest
    /// round-trip, as is Python's repr.
    private static func shortestDigits(_ magnitude: Double) -> (String, Int) {
        let description = magnitude.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var digits = String(mantissa[0]) + (mantissa.count == 2 ? String(mantissa[1]) : "")
        var decimalPoint = mantissa[0].count + exponent
        while digits.hasPrefix("0") { digits.removeFirst(); decimalPoint -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        return (digits, decimalPoint)
    }

    /// The exact decimal lexeme of an integral finite double.
    static func integerLexeme(_ number: Double) -> String {
        if let exact = Int64(exactly: number) { return String(exact) }
        // |number| >= 2^63: significand x 2^exponent, multiplied out in base 1e9.
        var limbs: [UInt64] = [number.significandBitPattern | (1 << 52)]
        var shift = Int(number.exponent) - 52
        var base: [UInt64] = []
        let billion: UInt64 = 1_000_000_000
        var value = limbs[0]
        while value > 0 { base.append(value % billion); value /= billion }
        limbs = base
        while shift > 0 {
            let step = min(shift, 29)
            var carry: UInt64 = 0
            for index in limbs.indices {
                let product = limbs[index] << UInt64(step) + carry
                limbs[index] = product % billion
                carry = product / billion
            }
            while carry > 0 { limbs.append(carry % billion); carry /= billion }
            shift -= step
        }
        var text = String(limbs.last!)
        for limb in limbs.dropLast().reversed() {
            let part = String(limb)
            text += String(repeating: "0", count: 9 - part.count) + part
        }
        return (number < 0 ? "-" : "") + text
    }

    /// `round(x)` for a finite float: ties to even, as an int.
    static func round(_ number: Double) throws -> Value {
        guard number.isFinite else { throw Failure() }
        let rounded = number.rounded(.toNearestOrEven)
        if let exact = Int64(exactly: rounded) { return .int(exact) }
        return .bigInt(integerLexeme(rounded))
    }

    /// `round(x, n)` for a float: the correctly rounded n-place decimal.
    static func round(_ number: Double, digits: Int) -> Double {
        guard number.isFinite else { return number }
        guard let rounded = Double(String(format: "%.\(digits)f", number)) else { return number }
        return rounded == 0 && number.sign == .minus ? -0.0 : rounded
    }

    /// `repr()` for the scalar values a status can carry.
    static func repr(_ value: Value) -> String {
        switch value {
        case .none: return "None"
        case .bool(let flag): return flag ? "True" : "False"
        case .int, .bigInt: return dumps(value)
        case .float(let number): return floatRepr(number)
        case .string(let text): return repr(text)
        case .list(let items): return "[" + items.map(repr).joined(separator: ", ") + "]"
        case .dict(let dict):
            return "{" + dict.keys.map { repr($0) + ": " + repr(dict[$0] ?? .none) }.joined(separator: ", ") + "}"
        }
    }

    /// `unicode_repr`: quote choice, escapes and str.isprintable.
    static func repr(_ text: Text) -> String {
        let quote: UInt32 = text.codePoints.contains(0x27) && !text.codePoints.contains(0x22) ? 0x22 : 0x27
        var output = String(Unicode.Scalar(quote)!)
        for point in text.codePoints {
            switch point {
            case quote, 0x5C: output += "\\" + String(Unicode.Scalar(point)!)
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0..<0x20, 0x7F: output += String(format: "\\x%02x", point)
            case 0x20..<0x7F: output.unicodeScalars.append(Unicode.Scalar(point)!)
            default:
                if let scalar = Unicode.Scalar(point), isPrintable(scalar) {
                    output.unicodeScalars.append(scalar)
                } else if point <= 0xFF {
                    output += String(format: "\\x%02x", point)
                } else if point <= 0xFFFF {
                    output += String(format: "\\u%04x", point)
                } else {
                    output += String(format: "\\U%08x", point)
                }
            }
        }
        return output + String(Unicode.Scalar(quote)!)
    }

    /// `str.isprintable` for one code point: not Other or Separator, except space.
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator: return scalar == " "
        default: return true
        }
    }
}
