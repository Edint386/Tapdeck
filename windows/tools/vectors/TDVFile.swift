import Foundation

/// A list of named arrays, little-endian; the format windows/tests/VectorFile.h
/// reads.
///
///     "TDV1", u32 count, then per entry:
///     u32 name length, name (UTF-8), u8 type (1 f32, 2 f64, 3 i32, 4 text),
///     u32 element count (bytes for text), data
struct TDVFile {
    enum Value: Equatable {
        case f32([Float])
        case f64([Double])
        case i32([Int32])
        case text(String)
    }

    struct DecodeError: Error, CustomStringConvertible {
        var description: String
    }

    var entries: [(name: String, value: Value)] = []

    mutating func add(_ name: String, _ value: Value) {
        entries.append((name, value))
    }

    func f32(_ name: String) -> [Float]? {
        guard case .f32(let values)? = entries.first(where: { $0.name == name })?.value else { return nil }
        return values
    }

    func f64(_ name: String) -> [Double]? {
        guard case .f64(let values)? = entries.first(where: { $0.name == name })?.value else { return nil }
        return values
    }

    func encoded() -> Data {
        var data = Data("TDV1".utf8)
        data.append(UInt32(entries.count))
        for (name, value) in entries {
            let nameBytes = Data(name.utf8)
            data.append(UInt32(nameBytes.count))
            data.append(nameBytes)
            switch value {
            case .f32(let values):
                data.append(UInt8(1)); data.append(UInt32(values.count))
                values.forEach { data.append($0.bitPattern) }
            case .f64(let values):
                data.append(UInt8(2)); data.append(UInt32(values.count))
                values.forEach { data.append($0.bitPattern) }
            case .i32(let values):
                data.append(UInt8(3)); data.append(UInt32(values.count))
                values.forEach { data.append(UInt32(bitPattern: $0)) }
            case .text(let text):
                let bytes = Data(text.utf8)
                data.append(UInt8(4)); data.append(UInt32(bytes.count))
                data.append(bytes)
            }
        }
        return data
    }

    static func decode(_ data: Data) throws -> TDVFile {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("TDV1".utf8) else { throw DecodeError(description: "not a TDV1 file") }
        var file = TDVFile()
        let count = try reader.integer(UInt32.self)
        for _ in 0..<count {
            let name = String(decoding: try reader.bytes(Int(try reader.integer(UInt32.self))), as: UTF8.self)
            let type = try reader.integer(UInt8.self)
            let elements = Int(try reader.integer(UInt32.self))
            switch type {
            case 1: file.add(name, .f32(try (0..<elements).map { _ in Float(bitPattern: try reader.integer(UInt32.self)) }))
            case 2: file.add(name, .f64(try (0..<elements).map { _ in Double(bitPattern: try reader.integer(UInt64.self)) }))
            case 3: file.add(name, .i32(try (0..<elements).map { _ in Int32(bitPattern: try reader.integer(UInt32.self)) }))
            case 4: file.add(name, .text(String(decoding: try reader.bytes(elements), as: UTF8.self)))
            default: throw DecodeError(description: "unknown type \(type) in \(name)")
            }
        }
        guard reader.atEnd else { throw DecodeError(description: "trailing bytes") }
        return file
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var atEnd: Bool { offset == bytes.count }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, bytes.count - offset >= count else { throw DecodeError(description: "truncated") }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let raw = try bytes(MemoryLayout<T>.size)
            return raw.reversed().reduce(T.zero) { ($0 << 8) | T($1) }
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
